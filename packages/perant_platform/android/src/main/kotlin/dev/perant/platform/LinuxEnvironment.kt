// SPDX-License-Identifier: GPL-3.0-only

package dev.perant.platform

import android.content.Context
import android.os.Build
import android.os.Process
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.File
import java.io.FileOutputStream
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.io.SequenceInputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardOpenOption.CREATE_NEW
import java.nio.file.StandardOpenOption.READ
import java.nio.file.StandardOpenOption.WRITE
import java.nio.file.attribute.PosixFilePermission
import java.security.MessageDigest
import java.util.EnumSet
import java.util.UUID
import java.util.zip.GZIPInputStream

/**
 * Installs the bundled userspace and signed local Python/desktop APKs offline.
 *
 * This implementation is original PerAnt code. Alpine and PRoot resources retain their own
 * licenses and provenance in assets/perant-linux/licenses and runtime-manifest.json.
 * The caller must stop native processes before installation; this class does not manage PTYs.
 */
class LinuxEnvironment(context: Context) {
    private val appContext = context.applicationContext
    private val manifestResult = runCatching { readManifest() }
    private val manifest: RuntimeManifest? get() = manifestResult.getOrNull()
    @Volatile private var pendingBootstrapCleanup: java.util.concurrent.CountDownLatch? = null
    private val runtimeHome = File(appContext.filesDir, "linux-runtime")
    private val versions = File(runtimeHome, "versions")
    private val versionHome: File get() = File(versions, runtimeId)

    val distribution: String get() = manifest?.distribution ?: "Alpine"
    val version: String get() = manifest?.version ?: "unavailable"
    val runtimeId: String get() = manifest?.runtimeId ?: "unavailable"
    val rootfs: File get() = File(versionHome, "rootfs")
    val workspace = File(runtimeHome, "workspace")
    // Native import staging is app-private and is never bound into /workspace.
    val importStaging = File(runtimeHome, "import-staging")
    val tmpRoot = File(runtimeHome, "tmp")
    val proot: File get() = File(appContext.applicationInfo.nativeLibraryDir, "libproot.so")
    val loader: File get() = File(appContext.applicationInfo.nativeLibraryDir, "libproot-loader.so")
    val pythonVersion: String? get() = manifest?.pythonVersion
    val desktopVersion: String? get() = manifest?.desktopVersion
    private val desktopExecutables = listOf(
        "usr/bin/Xvnc", "usr/bin/xfce4-session", "usr/bin/xfwm4", "usr/bin/xfsettingsd",
        "usr/bin/xfce4-panel", "usr/bin/xfdesktop", "usr/bin/thunar", "usr/bin/xfconf-query",
        "usr/bin/xfce4-terminal", "usr/bin/mousepad", "usr/bin/xfce4-settings-manager",
        "usr/bin/dbus-daemon", "usr/bin/xdotool",
        "usr/lib/libreoffice/program/soffice", "usr/lib/libreoffice/program/soffice.bin",
        "usr/lib/libreoffice/program/oosplash"
    )
    private val desktopLibraries = listOf("usr/lib/libreoffice/program/libvclplug_gtk3lo.so")
    val desktopAvailable: Boolean get() = installed && manifest?.desktopVersion != null &&
        manifest?.desktopCodec?.isInstalled(rootfs.toPath()) == true &&
        desktopExecutables.all {
            Files.isRegularFile(File(rootfs, it).toPath(), NOFOLLOW_LINKS) && Files.isExecutable(File(rootfs, it).toPath())
        } && desktopLibraries.all {
            Files.isRegularFile(File(rootfs, it).toPath(), NOFOLLOW_LINKS)
        }
    val pythonAvailable: Boolean get() = installed && manifest?.pythonVersion != null &&
        Files.isDirectory(File(rootfs, "usr").toPath(), NOFOLLOW_LINKS) &&
        Files.isDirectory(File(rootfs, "usr/bin").toPath(), NOFOLLOW_LINKS) &&
        Files.isRegularFile(File(rootfs, "usr/bin/python3.14").toPath(), NOFOLLOW_LINKS) &&
        Files.isExecutable(File(rootfs, "usr/bin/python3.14").toPath())

    private val supportFailure: String? by lazy {
        val specification = manifest
        when {
            specification == null -> "Linux resource manifest is invalid: " +
                (manifestResult.exceptionOrNull()?.message ?: "unknown manifest error")
            Build.VERSION.SDK_INT < specification.minAndroidApi ->
                "Linux requires Android API ${specification.minAndroidApi} or newer."
            Build.SUPPORTED_64_BIT_ABIS.firstOrNull() != specification.abi || !Process.is64Bit() ->
                "此 Linux 环境需要原生 ARM64 Android。此设备仍可使用浏览器和工作文件。"
            !Files.isRegularFile(proot.toPath(), NOFOLLOW_LINKS) ->
                "The bundled PRoot executable is unavailable."
            !Files.isRegularFile(loader.toPath(), NOFOLLOW_LINKS) ->
                "The bundled PRoot loader is unavailable."
            else -> try {
                appContext.assets.open(specification.rootfsAsset).use { }
                specification.pythonPackages.forEach { appContext.assets.open(it.asset).use { } }
                specification.desktopPackages.forEach { appContext.assets.open(it.asset).use { } }
                specification.textTool?.let { appContext.assets.open(it.asset).use { } }
                specification.desktopTool?.let { appContext.assets.open(it.asset).use { } }
                specification.desktopCodec?.let { appContext.assets.open(it.asset).use { } }
                null
            } catch (_: IOException) {
                "The bundled Alpine root filesystem is unavailable."
            }
        }
    }

    val supported: Boolean get() = supportFailure == null
    val unavailableReason: String get() = supportFailure.orEmpty()

    /** A ready marker alone cannot turn a missing or symlinked BusyBox into an installation. */
    val installed: Boolean
        get() = runCatching {
            val specification = manifest ?: return@runCatching false
            if (!supported || !safeVersionAncestors()) return@runCatching false
            val marker = File(versionHome, READY_MARKER).toPath()
            val binary = File(rootfs, "bin/busybox").toPath()
            Files.isRegularFile(marker, NOFOLLOW_LINKS) && Files.size(marker) <= 1024 &&
                specification.matchesInstallation(Files.readAllBytes(marker)) &&
                Files.isDirectory(File(rootfs, "bin").toPath(), NOFOLLOW_LINKS) &&
                Files.isRegularFile(binary, NOFOLLOW_LINKS) && Files.isExecutable(binary)
        }.getOrDefault(false)

    /** Validates both ELF identity and the manifest's exact SHA-256 for the executable assets. */
    fun verifyExecutables() {
        val specification = requireSupported()
        verifyElf(proot, specification.prootSha256)
        verifyElf(loader, specification.loaderSha256)
    }

    fun verifyTextTool() {
        val specification = requireSupported().textTool ?: throw IOException("Bundled text tool is unavailable.")
        for (directory in listOf("opt", "opt/perant", "opt/perant/tools")) {
            if (!Files.isDirectory(File(rootfs, directory).toPath(), NOFOLLOW_LINKS)) throw IOException("Unsafe tool directory.")
        }
        val path = File(rootfs, "opt/perant/tools/text_to_markdown.py")
        if (!Files.isRegularFile(path.toPath(), NOFOLLOW_LINKS)) throw IOException("Bundled text tool is missing.")
        path.inputStream().use { verifyDigest(it, specification.sha256, specification.sizeBytes) }
    }

    fun prepareDesktopTool(directory: File) {
        val runtime = requireSupported()
        val specification = runtime.desktopTool ?: throw IOException("Bundled desktop tool is unavailable.")
        (runtime.desktopCodec ?: throw IOException("Bundled desktop codec is unavailable.")).verify(rootfs.toPath())
        val script = appContext.assets.open(specification.asset).use { readLimited(it, specification.sizeBytes.toInt()) }
        verifyDigest(ByteArrayInputStream(script), specification.sha256, specification.sizeBytes)
        Files.write(File(directory, "start_desktop.sh").toPath(), script, CREATE_NEW, WRITE, NOFOLLOW_LINKS)
    }

    /**
     * Stages a complete version and only then publishes it through a same-filesystem rename.
     * Other versions and the separately stored workspace are never removed or reset.
     */
    @Synchronized
    fun initialize() {
        if (pendingBootstrapCleanup?.count?.let { it > 0 } == true) {
            throw IOException("The previous Linux bootstrap is still being cleaned up.")
        }
        pendingBootstrapCleanup = null
        val specification = requireSupported()
        verifyExecutables()
        appContext.assets.open(specification.rootfsAsset).use {
            verifyDigest(it, specification.rootfsSha256, specification.rootfsSize)
        }
        prepareWorkspace()
        hostDirectory(versions)
        hostDirectory(tmpRoot)
        if (installed) return

        val staging = File(versions, ".staging-${specification.runtimeId}-${UUID.randomUUID()}")
        var published = false
        try {
            hostDirectory(staging)
            val stagedRootfs = File(staging, "rootfs")
            hostDirectory(stagedRootfs)
            appContext.assets.open(specification.rootfsAsset).use { compressed ->
                GZIPInputStream(compressed).use { gzip ->
                    SafeTarInstaller(stagedRootfs.toPath()).extract(gzip)
                }
            }
            for (directory in listOf("workspace", "root", "tmp", "proc", "sys", "dev")) {
                val path = File(stagedRootfs, directory).toPath()
                if (!Files.exists(path, NOFOLLOW_LINKS)) Files.createDirectory(path)
                if (!Files.isDirectory(path, NOFOLLOW_LINKS)) {
                    throw IOException("Linux mount placeholder is not a directory: $directory")
                }
                if (directory == "root" || directory == "workspace") setMode(path, 0x1c0)
            }
            setMode(stagedRootfs.toPath(), 0x1c0)
            val busybox = File(stagedRootfs, "bin/busybox").toPath()
            if (!Files.isDirectory(File(stagedRootfs, "bin").toPath(), NOFOLLOW_LINKS) ||
                !Files.isRegularFile(busybox, NOFOLLOW_LINKS) || !Files.isExecutable(busybox)
            ) {
                throw IOException("The root filesystem contains no regular executable BusyBox.")
            }
            if (specification.pythonVersion != null) installPython(stagedRootfs, specification)
            val marker = File(staging, READY_MARKER)
            FileOutputStream(marker).use { output ->
                output.write(specification.readyMarker())
                output.fd.sync()
            }
            setMode(marker.toPath(), 0x180)
            publishVersion(staging)
            published = true
        } catch (failure: Exception) {
            if (!published && failure !is LinuxBootstrapCleanupFailure) {
                try {
                    deleteTreeNoFollow(staging.toPath())
                } catch (cleanup: Exception) {
                    failure.addSuppressed(cleanup)
                }
            }
            throw failure
        }
    }

    private fun installPython(stagedRootfs: File, specification: RuntimeManifest) {
        fun rootDirectory(relative: String): File {
            var directory = stagedRootfs
            for (part in relative.split('/')) {
                directory = File(directory, part)
                if (!Files.exists(directory.toPath(), NOFOLLOW_LINKS)) Files.createDirectory(directory.toPath())
                if (!Files.isDirectory(directory.toPath(), NOFOLLOW_LINKS)) throw IOException("Unsafe bootstrap directory.")
            }
            return directory
        }
        fun copyResource(resource: BundledResource, target: File) {
            Files.newOutputStream(target.toPath(), CREATE_NEW, WRITE, NOFOLLOW_LINKS).use { output ->
                appContext.assets.open(resource.asset).use { input ->
                    val buffer = ByteArray(16384)
                    var copied = 0L
                    while (true) {
                        val size = input.read(buffer)
                        if (size < 0) break
                        copied += size
                        if (copied > resource.sizeBytes) throw IOException("Bootstrap resource exceeds its quota.")
                        output.write(buffer, 0, size)
                    }
                }
            }
            target.inputStream().use { verifyDigest(it, resource.sha256, resource.sizeBytes) }
            setMode(target.toPath(), 0x180)
        }
        val packages = rootDirectory("opt/perant/packages")
        val paths = (specification.pythonPackages + specification.desktopPackages).map { resource ->
            val filename = resource.asset.substringAfterLast('/').removeSuffix(".bin")
            copyResource(resource, File(packages, filename))
            "/opt/perant/packages/$filename"
        }
        val tool = specification.textTool ?: throw IOException("Python text tool is absent from manifest.")
        copyResource(tool, File(rootDirectory("opt/perant/tools"), "text_to_markdown.py"))
        if (specification.desktopTool != null) rootDirectory("run/perant-desktop")
        specification.desktopCodec?.let { codec ->
            appContext.assets.open(codec.asset).use { codec.install(stagedRootfs.toPath(), it) }
        }
        val temporary = File(tmpRoot, "bootstrap-${UUID.randomUUID()}")
        hostDirectory(temporary)
        var cleanupConfirmed = true
        try {
            val bootstrap = LinuxBootstrap(proot, loader, stagedRootfs, temporary)
            // Local signed archives only: apk verifies Alpine's keys and manages
            // its real installed database; missing dependencies fail offline.
            bootstrap.run(listOf("/sbin/apk", "add", "--no-network", "--no-cache", "--no-progress") + paths,
                if (specification.desktopPackages.isEmpty()) 75 else 240)
            val output = bootstrap.run(listOf("/usr/bin/python3", "-I", "-B", "-c",
                "import sys,ssl,sqlite3,json,pathlib; assert sys.version.split()[0] == '${specification.pythonVersion}'; " +
                "assert ssl.create_default_context().cert_store_stats()['x509_ca'] > 0; " +
                "assert sqlite3.connect(':memory:').execute('select 1').fetchone()[0] == 1; " +
                "print('PYTHON_READY:${specification.pythonVersion}')"), 15)
            if (!output.contains("PYTHON_READY:${specification.pythonVersion}")) throw IOException("Python self-check did not complete.")
            if (specification.desktopVersion != null) {
                val desktopOutput = bootstrap.run(listOf("/bin/sh", "-c",
                    "/usr/bin/Xvnc -version 2>&1 && " +
                    desktopExecutables.joinToString(" && ") { "test -x /$it" } +
                    " && " + desktopLibraries.joinToString(" && ") { "test -f /$it" } +
                    " && printf 'DESKTOP_READY\\n'"), 30)
                if (!desktopOutput.contains("DESKTOP_READY")) throw IOException("Desktop executable self-check did not complete.")
                val codecOutput = bootstrap.run(listOf("/usr/bin/python3", "-I", "-B", "-c",
                    DesktopCodecLibrary.SELF_CHECK), 20)
                if (!codecOutput.contains("DESKTOP_CODEC_READY:PNG+XPM"))
                    throw IOException("Desktop PNG/XPM codec self-check did not complete.")
            }
        } catch (failure: LinuxBootstrapCleanupFailure) {
            cleanupConfirmed = false
            pendingBootstrapCleanup = failure.completion
            throw failure
        } finally { if (cleanupConfirmed) deleteTreeNoFollow(temporary.toPath()) }
        // Keep source copies in APK assets, not a second installed package cache.
        deleteTreeNoFollow(packages.toPath())
    }

    private fun publishVersion(staging: File) {
        val destination = versionHome.toPath()
        var backup: Path? = null
        if (Files.exists(destination, NOFOLLOW_LINKS)) {
            if (!Files.isDirectory(destination, NOFOLLOW_LINKS)) {
                throw IOException("An unsafe path occupies the Linux version directory.")
            }
            backup = File(versions, ".previous-$runtimeId-${UUID.randomUUID()}").toPath()
            Files.move(destination, backup, ATOMIC_MOVE)
        }
        try {
            Files.move(staging.toPath(), destination, ATOMIC_MOVE)
        } catch (failure: Exception) {
            if (backup != null) {
                try {
                    Files.move(backup, destination, ATOMIC_MOVE)
                } catch (rollback: Exception) {
                    failure.addSuppressed(rollback)
                }
            }
            throw failure
        }
        // A replaced, incomplete version is retained in .previous-* for recovery.
    }

    private fun safeVersionAncestors(): Boolean =
        listOf(runtimeHome, versions, versionHome, rootfs).all {
            Files.isDirectory(it.toPath(), NOFOLLOW_LINKS)
        }

    fun prepareWorkspace() {
        if (pendingBootstrapCleanup?.count?.let { it > 0 } == true)
            throw LinuxFailure("busy", "请等待上一次 Linux 安装清理完成。")
        hostDirectory(runtimeHome)
        hostDirectory(workspace)
    }

    private fun hostDirectory(directory: File) {
        val parent = directory.parentFile ?: throw IOException("Directory has no parent.")
        if (parent != appContext.filesDir && !Files.exists(parent.toPath(), NOFOLLOW_LINKS)) {
            hostDirectory(parent)
        }
        if (!Files.isDirectory(parent.toPath(), NOFOLLOW_LINKS)) {
            throw IOException("Linux storage parent is not a real directory.")
        }
        val path = directory.toPath()
        if (!Files.exists(path, NOFOLLOW_LINKS)) Files.createDirectory(path)
        if (!Files.isDirectory(path, NOFOLLOW_LINKS)) {
            throw IOException("Linux storage path is not a real directory.")
        }
        setMode(path, 0x1c0) // 0700; do not change files inside the user's workspace.
    }

    private fun requireSupported(): RuntimeManifest {
        if (!supported) throw IOException(unavailableReason)
        return manifest ?: throw IOException("The Linux resource manifest is unavailable.")
    }

    private fun verifyElf(file: File, expectedSha256: String) {
        val path = file.toPath()
        if (!Files.isRegularFile(path, NOFOLLOW_LINKS) || !Files.isExecutable(path)) {
            throw IOException("Linux executable is missing or not executable: ${file.name}")
        }
        file.inputStream().use { input ->
            val header = ByteArray(20)
            readExactly(input, header)
            if (!header.copyOfRange(0, 4).contentEquals(byteArrayOf(0x7f, 0x45, 0x4c, 0x46)) ||
                header[4].toInt() != 2 || header[5].toInt() != 1 ||
                header[18].toInt() and 0xff != 183 || header[19].toInt() != 0
            ) {
                throw IOException("Linux executable is not a little-endian ARM64 ELF: ${file.name}")
            }
        }
        file.inputStream().use { verifyDigest(it, expectedSha256, null) }
    }

    private fun readManifest(): RuntimeManifest {
        val manifestBytes = appContext.assets.open(MANIFEST_ASSET).use { LinuxRuntimeResourceLimits.readManifest(it) }
        val json = JSONObject(decodeUtf8(manifestBytes))
        if (json.requiredLong("schemaVersion") != 1L) throw IOException("Unknown manifest schema.")
        val runtimeId = json.requiredString("runtimeId")
        if (!Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,127}").matches(runtimeId)) {
            throw IOException("Unsafe Linux runtime ID.")
        }
        val abi = json.requiredString("abi")
        if (abi != "arm64-v8a") throw IOException("Unsupported bundled Linux ABI.")
        val minApi = json.requiredLong("minAndroidApi")
        if (minApi !in 29L..1000L) throw IOException("Invalid minimum Android API.")
        val root = json.getJSONObject("rootfs")
        if (root.requiredString("asset") != "perant-linux/rootfs.tar.gz.bin") {
            throw IOException("Unexpected root filesystem asset path.")
        }
        if (root.requiredString("architecture") != "aarch64") {
            throw IOException("Unsupported root filesystem architecture.")
        }
        val rootfsSize = root.requiredLong("sizeBytes")
        if (rootfsSize !in 1L..MAX_COMPRESSED_BYTES) throw IOException("Invalid rootfs asset size.")
        val proot = json.getJSONObject("proot")
        val loader = json.getJSONObject("loader")
        if (proot.requiredString("library") != "libproot.so" ||
            loader.requiredString("library") != "libproot-loader.so"
        ) throw IOException("Unexpected Linux executable asset path.")
        val python = json.optJSONObject("python")
        val packages = mutableListOf<BundledResource>()
        var pythonVersion: String? = null
        var tool: BundledResource? = null
        var desktopVersion: String? = null
        var desktopTool: BundledResource? = null
        var desktopCodec: DesktopCodecLibrary? = null
        val desktopPackages = mutableListOf<BundledResource>()
        if (json.getJSONObject("features").getBoolean("python")) {
            if (python == null) throw IOException("Python package manifest is missing.")
            pythonVersion = python.requiredString("version")
            if (!Regex("3\\.14\\.[0-9]+").matches(pythonVersion)) throw IOException("Unsupported Python version.")
            val records = python.getJSONArray("packages")
            if (records.length() !in 1..40) throw IOException("Invalid Python package count.")
            val names = mutableSetOf<String>()
            for (index in 0 until records.length()) {
                val record = records.getJSONObject(index)
                val name = record.requiredString("name")
                val packageVersion = record.requiredString("version")
                if (!Regex("[a-z0-9][a-z0-9+._-]{0,79}").matches(name) ||
                    !Regex("[A-Za-z0-9][A-Za-z0-9+._-]{0,79}").matches(packageVersion) || !names.add(name)) {
                    throw IOException("Invalid Python package identity.")
                }
                val asset = "perant-linux/packages/$name-$packageVersion.apk.bin"
                if (record.requiredString("asset") != asset) throw IOException("Unexpected Python package path.")
                val size = record.requiredLong("sizeBytes")
                if (size !in 1L..(32L * 1024 * 1024)) throw IOException("Python package exceeds quota.")
                packages += BundledResource(asset, record.requiredSha256("sha256"), size)
            }
            val description = json.getJSONObject("tools").getJSONObject("textToMarkdown")
            if (description.requiredString("asset") != "perant-linux/tools/text_to_markdown.py" ||
                description.requiredLong("version") != 1L) throw IOException("Unsupported bundled text tool.")
            val toolSize = description.requiredLong("sizeBytes")
            if (toolSize !in 1L..65536L) throw IOException("Text tool exceeds quota.")
            tool = BundledResource(description.requiredString("asset"), description.requiredSha256("sha256"), toolSize)
        }
        if (json.getJSONObject("features").optBoolean("desktop", false)) {
            if (pythonVersion == null) throw IOException("The desktop bundle requires Python bootstrap support.")
            val desktop = json.getJSONObject("desktop")
            desktopVersion = desktop.requiredString("version")
            if (desktopVersion.length !in 1..100 || desktopVersion.any { it.code < 32 })
                throw IOException("Invalid desktop version label.")
            val records = desktop.getJSONArray("packages")
            LinuxRuntimeResourceLimits.validateDesktopPackageCount(records.length())
            val names = mutableSetOf<String>()
            for (index in 0 until records.length()) {
                val record = records.getJSONObject(index)
                val name = record.requiredString("name")
                val packageVersion = record.requiredString("version")
                LinuxRuntimeResourceLimits.validateDesktopPackageName(name)
                if (!Regex("[A-Za-z0-9][A-Za-z0-9+._-]{0,79}").matches(packageVersion) || !names.add(name)) {
                    throw IOException("Invalid desktop package identity.")
                }
                val asset = "perant-linux/packages/$name-$packageVersion.apk.bin"
                if (record.requiredString("asset") != asset) throw IOException("Unexpected desktop package path.")
                val size = record.requiredLong("sizeBytes")
                LinuxRuntimeResourceLimits.validateDesktopPackageSize(size)
                desktopPackages += BundledResource(asset, record.requiredSha256("sha256"), size)
            }
            val description = desktop.getJSONObject("startupScript")
            if (description.requiredString("asset") != "perant-linux/tools/start_desktop.sh" ||
                description.requiredLong("version") != 1L) throw IOException("Unsupported desktop startup script.")
            val size = description.requiredLong("sizeBytes")
            if (size !in 1L..65536L) throw IOException("Desktop startup script exceeds quota.")
            desktopTool = BundledResource(description.requiredString("asset"), description.requiredSha256("sha256"), size)
            val codec = desktop.getJSONObject("codecLibrary")
            desktopCodec = DesktopCodecLibrary(codec.requiredString("asset"),
                codec.requiredSha256("sha256"), codec.requiredLong("sizeBytes"))
        }
        return RuntimeManifest(
            runtimeId = runtimeId,
            abi = abi,
            minAndroidApi = minApi.toInt(),
            distribution = root.requiredString("distribution"),
            version = root.requiredString("version"),
            rootfsAsset = root.requiredString("asset"),
            rootfsSha256 = root.requiredSha256("sha256"),
            rootfsSize = rootfsSize,
            prootSha256 = proot.requiredSha256("sha256"),
            loaderSha256 = loader.requiredSha256("sha256"),
            pythonVersion = pythonVersion, pythonPackages = packages, textTool = tool,
            desktopVersion = desktopVersion, desktopPackages = desktopPackages, desktopTool = desktopTool,
            desktopCodec = desktopCodec,
            desktopBaseSha256 = if (json.has("desktopBaseSha256")) json.requiredSha256("desktopBaseSha256") else null,
            manifestSha256 = MessageDigest.getInstance("SHA-256").digest(manifestBytes).joinToString("") { "%02x".format(it.toInt() and 0xff) },
        )
    }

    private data class RuntimeManifest(
        val runtimeId: String,
        val abi: String,
        val minAndroidApi: Int,
        val distribution: String,
        val version: String,
        val rootfsAsset: String,
        val rootfsSha256: String,
        val rootfsSize: Long,
        val prootSha256: String,
        val loaderSha256: String,
        val pythonVersion: String?,
        val pythonPackages: List<BundledResource>,
        val textTool: BundledResource?,
        val desktopVersion: String?,
        val desktopPackages: List<BundledResource>,
        val desktopTool: BundledResource?,
        val desktopCodec: DesktopCodecLibrary?,
        val desktopBaseSha256: String?,
        val manifestSha256: String,
    ) {
        private fun marker(identity: String): ByteArray =
            "$runtimeId\n$identity\n$rootfsSha256\n$prootSha256\n$loaderSha256\n".toByteArray(StandardCharsets.US_ASCII)

        fun readyMarker(): ByteArray = marker(desktopBaseSha256?.let { "session-ui-v1:$it" } ?: manifestSha256)

        fun matchesInstallation(bytes: ByteArray): Boolean = bytes.contentEquals(readyMarker()) ||
            (desktopBaseSha256 != null && bytes.contentEquals(marker(desktopBaseSha256)))
    }

    private data class BundledResource(val asset: String, val sha256: String, val sizeBytes: Long)

    private companion object {
        const val MANIFEST_ASSET = "perant-linux/runtime-manifest.json"
        const val READY_MARKER = ".ready-sha256"
        const val MAX_COMPRESSED_BYTES = 64L * 1024 * 1024
    }
}

/** Bounded APK metadata and package resources, distinct from base-rootfs tar quotas. */
internal object LinuxRuntimeResourceLimits {
    const val MAX_MANIFEST_BYTES = 256 * 1024
    const val MAX_DESKTOP_PACKAGES = 384
    const val MAX_DESKTOP_PACKAGE_BYTES = 256L * 1024 * 1024

    fun readManifest(input: InputStream): ByteArray = readLimited(input, MAX_MANIFEST_BYTES)

    fun validateDesktopPackageCount(count: Int) {
        if (count !in 1..MAX_DESKTOP_PACKAGES) throw IOException("Invalid desktop package count.")
    }

    fun validateDesktopPackageName(name: String) {
        if (!Regex("[A-Za-z0-9][A-Za-z0-9+._-]{0,79}").matches(name))
            throw IOException("Invalid desktop package name.")
    }

    fun validateDesktopPackageSize(size: Long) {
        if (size !in 1L..MAX_DESKTOP_PACKAGE_BYTES) throw IOException("Desktop package exceeds quota.")
    }
}

/** A separately verified compatibility library; official Alpine APKs stay untouched. */
internal data class DesktopCodecLibrary(val asset: String, val sha256: String, val sizeBytes: Long) {
    init {
        if (asset != ASSET || !Regex("[0-9a-f]{64}").matches(sha256) || sizeBytes !in 20L..MAX_BYTES)
            throw IOException("Invalid desktop codec resource.")
    }

    fun isInstalled(root: Path): Boolean = runCatching {
        Files.isDirectory(root, NOFOLLOW_LINKS) && DIRECTORIES.all {
            Files.isDirectory(root.resolve(it), NOFOLLOW_LINKS)
        } && Files.isRegularFile(root.resolve(RELATIVE_PATH), NOFOLLOW_LINKS) &&
            Files.size(root.resolve(RELATIVE_PATH)) == sizeBytes
    }.getOrDefault(false)

    fun install(root: Path, input: InputStream) {
        if (!Files.isDirectory(root, NOFOLLOW_LINKS)) throw IOException("Unsafe desktop codec root directory.")
        for (relative in DIRECTORIES) {
            val directory = root.resolve(relative)
            if (!Files.exists(directory, NOFOLLOW_LINKS)) Files.createDirectory(directory)
            if (!Files.isDirectory(directory, NOFOLLOW_LINKS)) throw IOException("Unsafe desktop codec directory.")
        }
        val target = root.resolve(RELATIVE_PATH)
        var created = false
        try {
            Files.newOutputStream(target, CREATE_NEW, WRITE, NOFOLLOW_LINKS).use { output ->
                created = true
                val buffer = ByteArray(16384)
                var copied = 0L
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    copied += count
                    if (copied > sizeBytes) throw IOException("Desktop codec exceeds its declared size.")
                    output.write(buffer, 0, count)
                }
            }
            setMode(target, 0x180)
            verify(root)
        } catch (failure: Exception) {
            if (created) try { Files.deleteIfExists(target) } catch (cleanup: Exception) { failure.addSuppressed(cleanup) }
            throw failure
        }
    }

    fun verify(root: Path) {
        if (!isInstalled(root)) throw IOException("Bundled desktop codec is missing or unsafe.")
        Files.newInputStream(root.resolve(RELATIVE_PATH), READ, NOFOLLOW_LINKS).use { input ->
            val header = ByteArray(20)
            readExactly(input, header)
            if (!header.copyOfRange(0, 4).contentEquals(byteArrayOf(0x7f, 0x45, 0x4c, 0x46)) ||
                header[4].toInt() != 2 || header[5].toInt() != 1 ||
                header[18].toInt() and 0xff != 183 || header[19].toInt() != 0)
                throw IOException("Desktop codec is not a little-endian ARM64 ELF.")
            verifyDigest(SequenceInputStream(ByteArrayInputStream(header), input), sha256, sizeBytes)
        }
    }

    companion object {
        const val ASSET = "perant-linux/compat/libgdk_pixbuf-2.0.so.0"
        const val RELATIVE_PATH = "opt/perant/lib/libgdk_pixbuf-2.0.so.0"
        const val MAX_BYTES = 4L * 1024 * 1024
        private val DIRECTORIES = listOf("opt", "opt/perant", "opt/perant/lib")

        // Fixed, generated test images only. No workspace files or user content.
        val SELF_CHECK = """
            import ctypes, pathlib, struct, tempfile, zlib
            lib = ctypes.CDLL('/opt/perant/lib/libgdk_pixbuf-2.0.so.0')
            obj = ctypes.CDLL('libgobject-2.0.so.0')
            lib.gdk_pixbuf_new_from_file.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
            lib.gdk_pixbuf_new_from_file.restype = ctypes.c_void_p
            for name in ('gdk_pixbuf_get_width', 'gdk_pixbuf_get_height', 'gdk_pixbuf_get_n_channels'):
                fn = getattr(lib, name)
                fn.argtypes = [ctypes.c_void_p]
                fn.restype = ctypes.c_int
            lib.gdk_pixbuf_get_pixels.argtypes = [ctypes.c_void_p]
            lib.gdk_pixbuf_get_pixels.restype = ctypes.POINTER(ctypes.c_ubyte)
            obj.g_object_unref.argtypes = [ctypes.c_void_p]
            obj.g_object_unref.restype = None
            def chunk(kind, data):
                return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
            png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0))
            png += chunk(b'IDAT', zlib.compress(b'\x00\x11\x22\x33\xff')) + chunk(b'IEND', b'')
            xpm = b'/* XPM */\nstatic const char *image[] = {"1 1 1 1", "a c #112233", "a"};\n'
            with tempfile.TemporaryDirectory(prefix='perant-codec-') as directory:
                for suffix, data in (('png', png), ('xpm', xpm)):
                    path = pathlib.Path(directory) / ('fixed.' + suffix)
                    path.write_bytes(data)
                    error = ctypes.c_void_p()
                    image = lib.gdk_pixbuf_new_from_file(bytes(path), ctypes.byref(error))
                    if not image:
                        raise RuntimeError('Desktop codec cannot decode fixed ' + suffix)
                    try:
                        assert lib.gdk_pixbuf_get_width(image) == 1 and lib.gdk_pixbuf_get_height(image) == 1
                        assert lib.gdk_pixbuf_get_n_channels(image) in (3, 4)
                        pixels = lib.gdk_pixbuf_get_pixels(image)
                        assert tuple(pixels[i] for i in range(3)) == (17, 34, 51)
                    finally:
                        obj.g_object_unref(image)
            print('DESKTOP_CODEC_READY:PNG+XPM')
        """.trimIndent()
    }
}

/**
 * Restricted POSIX/GNU tar reader. No external program or host filesystem symlink is followed.
 * Absolute symlink targets are deliberately retained as guest paths for PRoot to resolve.
 */
internal class SafeTarInstaller(private val root: Path) {
    private val directoryModes = linkedMapOf<Path, Int>()
    private val kinds = mutableMapOf<Path, Char>()
    private val hardLinks = mutableListOf<Pair<Path, Path>>()
    private val globalPax = mutableMapOf<String, String>()
    private val nextPax = mutableMapOf<String, String>()
    private var longName: String? = null
    private var longLink: String? = null
    private var entries = 0
    private var totalBytes = 0L

    fun extract(source: InputStream) {
        if (!Files.isDirectory(root, NOFOLLOW_LINKS)) throw IOException("Unsafe extraction root.")
        val input = QuotaInputStream(source, MAX_TAR_BYTES)
        val header = ByteArray(BLOCK_SIZE)
        while (true) {
            readExactly(input, header)
            if (header.all { it == 0.toByte() }) {
                readExactly(input, header)
                if (header.any { it != 0.toByte() }) throw IOException("Invalid tar end marker.")
                if (longName != null || longLink != null || nextPax.isNotEmpty()) {
                    throw IOException("Tar metadata has no following entry.")
                }
                // Consume the gzip trailer too, so CRC errors and appended nonzero data fail.
                val tail = ByteArray(16384)
                while (true) {
                    val count = input.read(tail)
                    if (count < 0) break
                    if ((0 until count).any { tail[it] != 0.toByte() }) {
                        throw IOException("Nonzero data follows the tar end marker.")
                    }
                }
                break
            }
            if (++entries > MAX_ENTRIES) throw IOException("Too many root filesystem entries.")
            verifyHeader(header)
            val type = (header[156].toInt() and 0xff).toChar()
            val headerSize = tarNumber(header, 124, 12)
            if (type in listOf('x', 'g', 'L', 'K')) {
                if (headerSize > MAX_METADATA_BYTES) throw IOException("Oversized tar metadata.")
                val data = ByteArray(headerSize.toInt())
                readExactly(input, data)
                skipPadding(input, headerSize)
                when (type) {
                    'x' -> nextPax.putAll(parsePax(data))
                    'g' -> applyPax(globalPax, parsePax(data))
                    'L' -> longName = longString(data)
                    'K' -> longLink = longString(data)
                }
                continue
            }
            val pax = globalPax.toMutableMap().also { applyPax(it, nextPax) }
            if (pax.keys.any { it.startsWith("GNU.sparse") || it == "SCHILY.filetype" }) {
                throw IOException("Sparse or special tar extensions are unsupported.")
            }
            // Extended names supersede the byte-limited header fields entirely. GNU tar
            // can truncate the unused short name in the middle of a UTF-8 code point.
            val name = pax["path"] ?: longName ?: run {
                val prefix = if (tarString(header, 257, 6) == "ustar") tarString(header, 345, 155) else ""
                val baseName = tarString(header, 0, 100)
                if (prefix.isEmpty()) baseName else "$prefix/$baseName"
            }
            val linkName = pax["linkpath"] ?: longLink ?: tarString(header, 157, 100)
            val size = pax["size"]?.let { decimalSize(it) } ?: headerSize
            val mode = (tarNumber(header, 100, 8) and 0x1ffL).toInt()
            nextPax.clear()
            longName = null
            longLink = null
            if (size > MAX_FILE_BYTES) throw IOException("Root filesystem entry exceeds its quota.")
            val path = entryPath(name)
            if (path == root && type != '5') throw IOException("Only a directory may name the tar root.")
            ensureParents(path)
            when (type) {
                '\u0000', '0', '7' -> {
                    claim(path, '0')
                    totalBytes += size
                    if (totalBytes > MAX_CONTENT_BYTES) throw IOException("Root filesystem exceeds its quota.")
                    Files.newOutputStream(path, CREATE_NEW, WRITE).use { copyExactly(input, it, size) }
                    setMode(path, mode)
                }
                '5' -> {
                    requireNoData(size)
                    if (path != root) {
                        claim(path, '5')
                        if (!Files.exists(path, NOFOLLOW_LINKS)) Files.createDirectory(path)
                        if (!Files.isDirectory(path, NOFOLLOW_LINKS)) throw IOException("Directory collides with a link or file.")
                        setMode(path, 0x1c0)
                        directoryModes[path] = mode
                    }
                }
                '2' -> {
                    requireNoData(size)
                    claim(path, '2')
                    validateLinkText(linkName)
                    Files.createSymbolicLink(path, java.nio.file.Paths.get(linkName))
                }
                '1' -> {
                    requireNoData(size)
                    claim(path, '1')
                    hardLinks += path to entryPath(linkName)
                }
                else -> throw IOException("Unsupported tar entry type: ${type.code}")
            }
            skipPadding(input, size)
        }
        resolveHardLinks()
        for ((path, mode) in directoryModes.entries.sortedByDescending { it.key.nameCount }) {
            setMode(path, mode)
        }
        setMode(root, 0x1c0)
    }

    private fun claim(path: Path, kind: Char) {
        val previous = kinds[path]
        if (previous != null && !(kind == '5' && previous == '5')) {
            throw IOException("Duplicate or conflicting tar entry.")
        }
        if (Files.exists(path, NOFOLLOW_LINKS) &&
            !(kind == '5' && Files.isDirectory(path, NOFOLLOW_LINKS))
        ) throw IOException("Tar entry would replace an existing filesystem object.")
        kinds[path] = kind
    }

    private fun ensureParents(path: Path) {
        val relative = root.relativize(path)
        var parent = root
        for (index in 0 until maxOf(0, relative.nameCount - 1)) {
            parent = parent.resolve(relative.getName(index))
            if (kinds[parent] != null && kinds[parent] != '5') {
                throw IOException("A tar entry attempts to write through a non-directory parent.")
            }
            if (!Files.exists(parent, NOFOLLOW_LINKS)) {
                Files.createDirectory(parent)
                setMode(parent, 0x1c0)
                directoryModes[parent] = 0x1ed
                kinds[parent] = '5'
            }
            if (!Files.isDirectory(parent, NOFOLLOW_LINKS)) {
                throw IOException("A tar entry attempts to follow a symlink parent.")
            }
        }
    }

    private fun entryPath(name: String): Path {
        validateLinkText(name)
        if (name.startsWith('/') || name.contains('\\')) throw IOException("Absolute or ambiguous tar entry path.")
        val segments = name.split('/').filter { it.isNotEmpty() && it != "." }
        if (segments.size > 128 || segments.any { it == ".." || it.toByteArray(StandardCharsets.UTF_8).size > 255 }) {
            throw IOException("Unsafe tar entry path.")
        }
        var result = root
        for (segment in segments) result = result.resolve(segment)
        if (!result.normalize().startsWith(root)) throw IOException("Tar entry escapes its root.")
        return result
    }

    private fun resolveHardLinks() {
        val pending = hardLinks.toMap().toMutableMap()
        while (pending.isNotEmpty()) {
            var target = pending.keys.first()
            val chain = mutableListOf<Path>()
            val visiting = mutableSetOf<Path>()
            while (pending.containsKey(target)) {
                if (!visiting.add(target)) throw IOException("Tar hardlinks contain a cycle.")
                chain.add(target)
                target = pending.getValue(target)
            }
            ensureParents(target)
            if (!Files.isRegularFile(target, NOFOLLOW_LINKS)) {
                throw IOException("A tar hardlink targets a missing, linked, or non-regular file.")
            }
            for (path in chain.asReversed()) Files.createLink(path, pending.remove(path)!!)
        }
    }

    private fun verifyHeader(header: ByteArray) {
        val expected = tarNumber(header, 148, 8)
        var unsigned = 0L
        var signed = 0L
        for (index in header.indices) {
            unsigned += if (index in 148..155) 32 else header[index].toInt() and 0xff
            signed += if (index in 148..155) 32 else header[index].toInt()
        }
        if (expected != unsigned && expected != signed) throw IOException("Tar header checksum mismatch.")
        val magic = tarString(header, 257, 6)
        if (magic.isNotEmpty() && magic != "ustar" && magic != "ustar ") {
            throw IOException("Unknown tar header format.")
        }
    }

    private fun parsePax(data: ByteArray): Map<String, String> {
        val result = mutableMapOf<String, String>()
        var offset = 0
        while (offset < data.size) {
            var space = offset
            while (space < data.size && data[space] != 32.toByte()) space++
            if (space == data.size || space == offset || space - offset > 9) throw IOException("Invalid PAX record length.")
            val lengthText = String(data, offset, space - offset, StandardCharsets.US_ASCII)
            val length = decimalSize(lengthText)
            if (length <= space - offset + 2 || length > data.size - offset) throw IOException("Truncated PAX record.")
            val end = offset + length.toInt()
            if (data[end - 1] != 10.toByte()) throw IOException("PAX record lacks its newline.")
            val record = decodeUtf8(data.copyOfRange(space + 1, end - 1))
            val equals = record.indexOf('=')
            if (equals <= 0 || equals > 255 || record.indexOf('\u0000') >= 0) throw IOException("Invalid PAX record.")
            result[record.substring(0, equals)] = record.substring(equals + 1)
            offset = end
        }
        return result
    }

    private fun applyPax(destination: MutableMap<String, String>, values: Map<String, String>) {
        for ((key, value) in values) {
            if (value.isEmpty()) destination.remove(key) else destination[key] = value
        }
    }

    private fun longString(data: ByteArray): String {
        val terminator = data.indexOf(0.toByte())
        if (terminator >= 0 && data.copyOfRange(terminator, data.size).any { it != 0.toByte() }) {
            throw IOException("Invalid GNU long-name record.")
        }
        return decodeUtf8(if (terminator < 0) data else data.copyOf(terminator)).removeSuffix("\n")
    }

    private fun validateLinkText(value: String) {
        if (value.isEmpty() || value.indexOf('\u0000') >= 0 ||
            value.toByteArray(StandardCharsets.UTF_8).size > MAX_PATH_BYTES
        ) throw IOException("Invalid tar path or link target.")
    }

    private fun requireNoData(size: Long) {
        if (size != 0L) throw IOException("A non-regular tar entry contains unexpected data.")
    }

    private fun skipPadding(input: InputStream, size: Long) {
        val padding = ((BLOCK_SIZE - size % BLOCK_SIZE) % BLOCK_SIZE).toInt()
        if (padding > 0) readExactly(input, ByteArray(padding))
    }

    private fun tarString(header: ByteArray, offset: Int, length: Int): String {
        var end = offset
        while (end < offset + length && header[end] != 0.toByte()) end++
        return decodeUtf8(header.copyOfRange(offset, end))
    }

    private fun tarNumber(header: ByteArray, offset: Int, length: Int): Long {
        if (header[offset].toInt() and 0x80 != 0) {
            if (header[offset].toInt() and 0x40 != 0) throw IOException("Negative tar numeric field.")
            var value = (header[offset].toInt() and 0x7f).toLong()
            for (index in offset + 1 until offset + length) {
                if (value > (Long.MAX_VALUE ushr 8)) throw IOException("Tar numeric field overflows.")
                value = (value shl 8) or (header[index].toLong() and 0xff)
            }
            return value
        }
        val text = String(header, offset, length, StandardCharsets.US_ASCII).trim(' ', '\u0000')
        if (text.isEmpty()) return 0
        if (text.any { it !in '0'..'7' }) throw IOException("Invalid octal tar numeric field.")
        return text.toLongOrNull(8) ?: throw IOException("Tar numeric field overflows.")
    }

    private fun decimalSize(value: String): Long {
        if (value.isEmpty() || value.any { it !in '0'..'9' }) throw IOException("Invalid decimal tar size.")
        return value.toLongOrNull() ?: throw IOException("Tar size overflows.")
    }

    private companion object {
        const val BLOCK_SIZE = 512
        const val MAX_ENTRIES = 100000
        const val MAX_PATH_BYTES = 4096
        const val MAX_METADATA_BYTES = 1024L * 1024
        const val MAX_FILE_BYTES = 64L * 1024 * 1024
        const val MAX_CONTENT_BYTES = 256L * 1024 * 1024
        const val MAX_TAR_BYTES = 512L * 1024 * 1024
    }
}

private class QuotaInputStream(input: InputStream, private val limit: Long) : FilterInputStream(input) {
    private var consumed = 0L

    override fun read(): Int {
        val result = `in`.read()
        if (result >= 0 && ++consumed > limit) throw IOException("Decompressed tar exceeds its quota.")
        return result
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        val result = `in`.read(buffer, offset, length)
        if (result > 0) {
            consumed += result
            if (consumed > limit) throw IOException("Decompressed tar exceeds its quota.")
        }
        return result
    }
}

private fun readExactly(input: InputStream, buffer: ByteArray) {
    var offset = 0
    while (offset < buffer.size) {
        val count = input.read(buffer, offset, buffer.size - offset)
        if (count < 0) throw EOFException("Truncated Linux archive or executable.")
        if (count == 0) continue
        offset += count
    }
}

private fun copyExactly(input: InputStream, output: java.io.OutputStream, size: Long) {
    val buffer = ByteArray(16384)
    var remaining = size
    while (remaining > 0) {
        val count = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
        if (count < 0) throw EOFException("Truncated tar file contents.")
        if (count == 0) continue
        output.write(buffer, 0, count)
        remaining -= count
    }
}

private fun readLimited(input: InputStream, limit: Int): ByteArray {
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(4096)
    while (true) {
        val count = input.read(buffer)
        if (count < 0) break
        if (output.size() + count > limit) throw IOException("Manifest exceeds its quota.")
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}

private fun verifyDigest(input: InputStream, expectedSha256: String, expectedSize: Long?) {
    val digest = MessageDigest.getInstance("SHA-256")
    val buffer = ByteArray(16384)
    var count = 0L
    while (true) {
        val read = input.read(buffer)
        if (read < 0) break
        count += read
        if (count > (expectedSize ?: (64L * 1024 * 1024))) throw IOException("Linux asset exceeds its declared size.")
        digest.update(buffer, 0, read)
    }
    if (expectedSize != null && count != expectedSize) throw IOException("Linux asset is truncated.")
    val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    if (actual != expectedSha256) throw IOException("Linux asset SHA-256 mismatch.")
}

private fun JSONObject.requiredString(name: String): String {
    val value = get(name)
    if (value !is String || value.isBlank() || value.length > 4096) {
        throw IOException("Invalid Linux manifest string: $name")
    }
    return value
}

private fun JSONObject.requiredLong(name: String): Long {
    val value = get(name)
    if (value !is Int && value !is Long) throw IOException("Invalid Linux manifest integer: $name")
    return (value as Number).toLong()
}

private fun JSONObject.requiredSha256(name: String): String {
    val value = requiredString(name)
    if (!Regex("[0-9a-f]{64}").matches(value)) throw IOException("Invalid Linux asset digest.")
    return value
}

private fun decodeUtf8(value: ByteArray): String =
    StandardCharsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(value)).toString()

/** Only called for verified regular files and directories, never for a symlink. */
private fun setMode(path: Path, mode: Int) {
    val permissions = EnumSet.noneOf(PosixFilePermission::class.java)
    val bits = listOf(
        0x100 to PosixFilePermission.OWNER_READ,
        0x80 to PosixFilePermission.OWNER_WRITE,
        0x40 to PosixFilePermission.OWNER_EXECUTE,
        0x20 to PosixFilePermission.GROUP_READ,
        0x10 to PosixFilePermission.GROUP_WRITE,
        0x8 to PosixFilePermission.GROUP_EXECUTE,
        0x4 to PosixFilePermission.OTHERS_READ,
        0x2 to PosixFilePermission.OTHERS_WRITE,
        0x1 to PosixFilePermission.OTHERS_EXECUTE,
    )
    for ((bit, permission) in bits) if (mode and bit != 0) permissions.add(permission)
    Files.setPosixFilePermissions(path, permissions)
}

/** A guest absolute symlink must be deleted as a link, never traversed during cleanup. */
private fun deleteTreeNoFollow(path: Path) {
    if (Files.isDirectory(path, NOFOLLOW_LINKS)) {
        setMode(path, 0x1c0)
        Files.newDirectoryStream(path).use { children ->
            for (child in children) deleteTreeNoFollow(child)
        }
    }
    Files.deleteIfExists(path)
}
