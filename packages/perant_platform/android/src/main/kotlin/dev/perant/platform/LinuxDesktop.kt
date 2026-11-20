// SPDX-License-Identifier: GPL-3.0-only
package dev.perant.platform

import android.net.LocalSocket
import android.net.LocalSocketAddress
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardOpenOption.CREATE_NEW
import java.nio.file.StandardOpenOption.READ
import java.nio.file.StandardOpenOption.WRITE
import java.nio.file.attribute.PosixFilePermissions
import java.security.SecureRandom
import java.util.UUID

/** A private filesystem RFB endpoint: no TCP listener and no public credentials. */
internal class LinuxDesktopLaunch private constructor(
    val directory: File,
    val temporary: File,
    val socket: File,
    val display: Int,
    val width: Int,
    val height: Int,
) {
    val command: String get() = "/bin/sh /opt/perant/tools/start_desktop.sh $display $width $height"

    /** Thunar receives a single file URI on this desktop's private session bus. */
    internal fun revealArguments(path: String): List<String> {
        val name = path.removePrefix("/workspace/")
        require(path == "/workspace/$name" && WorkspaceImportContract.validName(name))
        return listOf("-b", "${directory.absolutePath}:/run/perant-desktop",
            "/usr/bin/dbus-send", "--bus=unix:path=/run/perant-desktop/bus",
            "--type=method_call", "--print-reply", "--reply-timeout=5000",
            "--dest=org.freedesktop.FileManager1", "/org/freedesktop/FileManager1",
            "org.freedesktop.FileManager1.ShowItems", "array:string:file://$path", "string:")
    }

    fun result(id: String, pid: Int): Map<String, Any> = mapOf(
        "sessionId" to id, "pid" to pid, "socketPath" to socket.absolutePath,
        "width" to width, "height" to height, "display" to display, "workspace" to "/workspace"
    )

    @Volatile var readinessFailure: String? = null
        private set

    /** The fixed guest script publishes this only after the actual shell maps. */
    internal fun shellReady(): Boolean {
        val marker = File(directory, "desktop.ready").toPath()
        return try {
            if (!Files.isRegularFile(marker, NOFOLLOW_LINKS)) return false
            // NOFOLLOW also applies to the open, rather than merely the check.
            Files.newByteChannel(marker, setOf(READ, NOFOLLOW_LINKS)).use { input ->
                val expected = "perant-desktop-v6\n".toByteArray(Charsets.US_ASCII)
                val buffer = ByteBuffer.allocate(expected.size + 1)
                while (buffer.hasRemaining() && input.read(buffer) >= 0) { }
                buffer.position() == expected.size && buffer.array().copyOf(expected.size).contentEquals(expected)
            }
        } catch (_: Exception) {
            false
        }
    }

    fun ready(): Boolean {
        if (!shellReady()) {
            readinessFailure = "Desktop shell ready marker not observed"
            return false
        }
        if (!Files.exists(socket.toPath(), NOFOLLOW_LINKS) || Files.isSymbolicLink(socket.toPath())) {
            readinessFailure = "RFB socket not observed"
            return false
        }
        return try {
            LocalSocket().use { connection ->
                // LocalSocket.setSoTimeout does not create its fd. Calling it
                // before connect throws "socket not created" on Android.
                connection.connect(LocalSocketAddress(socket.absolutePath, LocalSocketAddress.Namespace.FILESYSTEM))
                connection.soTimeout = 500
                val banner = ByteArray(12)
                var offset = 0
                while (offset < banner.size) {
                    val count = connection.inputStream.read(banner, offset, banner.size - offset)
                    if (count <= 0) return false
                    offset += count
                }
                val valid = String(banner, Charsets.US_ASCII) in setOf("RFB 003.003\n", "RFB 003.007\n", "RFB 003.008\n")
                readinessFailure = if (valid) null else "Unexpected RFB banner"
                valid
            }
        } catch (failure: Exception) {
            readinessFailure = "${failure.javaClass.simpleName}: ${failure.message.orEmpty().take(300)}"
            false
        }
    }

    fun clean() { try { deleteTreeWithoutFollowingLinks(directory) } catch (_: Exception) {} }

    companion object {
        fun create(cache: File, width: Int, height: Int): LinuxDesktopLaunch {
            require(width in 640..1600 && height in 480..1200 && width.toLong() * height <= 1_920_000L) {
                "Invalid desktop size."
            }
            val home = File(cache, "g")
            directory(home)
            val root = File(home, UUID.randomUUID().toString().replace("-", "").take(8))
            if (Files.exists(root.toPath(), NOFOLLOW_LINKS)) throw LinuxFailure("storage_error", "无法创建独立桌面目录。")
            directory(root)
            try {
                val temporary = File(root, "t")
                directory(temporary)
                val socket = File(root, "rfb.sock")
                if (socket.absolutePath.toByteArray(Charsets.UTF_8).size >= 104) {
                    throw LinuxFailure("unsupported_path", "应用私有目录过长，无法创建 Linux 桌面套接字。")
                }
                val display = 100 + SecureRandom().nextInt(30000)
                val cookie = ByteArray(16).also { SecureRandom().nextBytes(it) }
                val authorityFile = File(root, "Xauthority")
                Files.write(authorityFile.toPath(), authority(display, cookie), CREATE_NEW, WRITE)
                Files.setPosixFilePermissions(authorityFile.toPath(), PosixFilePermissions.fromString("rw-------"))
                return LinuxDesktopLaunch(root, temporary, socket, display, width, height)
            } catch (failure: Throwable) {
                try { deleteTreeWithoutFollowingLinks(root) } catch (_: Exception) {}
                throw failure
            }
        }

        private fun directory(path: File) {
            if (!Files.exists(path.toPath(), NOFOLLOW_LINKS)) {
                Files.createDirectory(path.toPath(), PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")))
            }
            if (!Files.isDirectory(path.toPath(), NOFOLLOW_LINKS) || Files.isSymbolicLink(path.toPath())) {
                throw LinuxFailure("invalid_path", "桌面私有目录不可用。")
            }
            Files.setPosixFilePermissions(path.toPath(), PosixFilePermissions.fromString("rwx------"))
        }

        /** Xauthority wire record: FamilyWild, display number, MIT cookie. */
        internal fun authority(display: Int, cookie: ByteArray): ByteArray {
            require(display in 0..65535 && cookie.size == 16)
            val output = ByteArrayOutputStream()
            DataOutputStream(output).use { writer ->
                fun field(bytes: ByteArray) { writer.writeShort(bytes.size); writer.write(bytes) }
                writer.writeShort(65535)
                field(byteArrayOf())
                field(display.toString().toByteArray(Charsets.US_ASCII))
                field("MIT-MAGIC-COOKIE-1".toByteArray(Charsets.US_ASCII))
                field(cookie)
            }
            return output.toByteArray()
        }
    }
}
