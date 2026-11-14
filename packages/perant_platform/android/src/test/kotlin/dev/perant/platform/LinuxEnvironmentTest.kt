// SPDX-License-Identifier: GPL-3.0-only

package dev.perant.platform

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.attribute.PosixFilePermission
import java.security.MessageDigest
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream

/** Pure JVM archive tests: no Android Context, shell, network, or Robolectric. */
class LinuxEnvironmentTest {
    @Rule
    @JvmField
    val temporary = TemporaryFolder()

    @Test
    fun bundledAlpineExtractsBusyboxAndPreservesGuestAbsoluteLinks() {
        val root = freshRoot()
        val asset = Paths.get("src/main/assets/perant-linux/rootfs.tar.gz.bin")
        assertTrue(
            "Run this test from the Android library project directory.",
            Files.isRegularFile(asset),
        )
        Files.newInputStream(asset).use { compressed ->
            GZIPInputStream(compressed).use { SafeTarInstaller(root).extract(it) }
        }

        assertTrue(Files.isRegularFile(root.resolve("bin/busybox"), NOFOLLOW_LINKS))
        assertTrue(Files.isExecutable(root.resolve("bin/busybox")))
        assertTrue(Files.isSymbolicLink(root.resolve("bin/sh")))
        assertEquals(Paths.get("/bin/busybox"), Files.readSymbolicLink(root.resolve("bin/sh")))
        assertEquals(
            setOf(
                PosixFilePermission.OWNER_READ,
                PosixFilePermission.OWNER_WRITE,
                PosixFilePermission.OWNER_EXECUTE,
            ),
            Files.getPosixFilePermissions(root),
        )
    }

    @Test
    fun gnuLongNamesAndForwardHardlinksResolveWithoutRetainingSetIdBits() {
        val name = "a".repeat(120) + "/" + "b".repeat(120)
        val root = extract(
            archive(
                hardlink("forward", "chain"),
                hardlink("chain", name),
                file(name, "hello", mode = 0xDED), // 06755 in the input header.
            ),
        )

        assertEquals("hello", readUtf8(root.resolve("forward")))
        assertTrue(Files.isSameFile(root.resolve(name), root.resolve("chain")))
        assertEquals(
            setOf(
                PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE,
                PosixFilePermission.OWNER_EXECUTE, PosixFilePermission.GROUP_READ,
                PosixFilePermission.GROUP_EXECUTE, PosixFilePermission.OTHERS_READ,
                PosixFilePermission.OTHERS_EXECUTE,
            ),
            Files.getPosixFilePermissions(root.resolve(name)),
        )
        // The public POSIX permission API only exposes the lower nine mode bits.
        val unixMode = Files.getAttribute(root.resolve(name), "unix:mode") as Int
        assertEquals(0, unixMode and 0xC00) // No setuid or setgid bits.
    }

    @Test
    fun paxLongUtf8PathsUseByteCountedRecordLengths() {
        val name = "nested/" + "文".repeat(50) + "/" + "z".repeat(100)
        val root = extract(
            rawArchive(
                pax(mapOf("path" to name)),
                file("short-header-name", "pax"),
            ),
        )

        assertEquals("pax", readUtf8(root.resolve(name)))
    }

    @Test
    fun extendedPathsSupersedeShortHeadersTruncatedInsideUtf8Characters() {
        val name = "long/" + "文".repeat(50)
        for (extension in listOf(
            Entry("././@LongLink", 'L', (name + "\u0000").toByteArray(StandardCharsets.UTF_8)),
            pax(mapOf("path" to name)),
        )) {
            val bytes = rawArchive(extension, file("a".repeat(100), "preserved"))
            val headerOffset = 512 + ((extension.data.size + 511) / 512) * 512
            // The 100-byte short name ends after the first two bytes of 文 (E6 96 87).
            bytes[headerOffset + 98] = 0xE6.toByte()
            bytes[headerOffset + 99] = 0x96.toByte()
            for (index in headerOffset + 148..headerOffset + 155) bytes[index] = 32
            val checksum = (headerOffset until headerOffset + 512).sumOf {
                bytes[it].toInt() and 0xff
            }
            putOctal(bytes, headerOffset + 148, 8, checksum.toLong())

            val root = extract(bytes)
            assertEquals("preserved", readUtf8(root.resolve(name)))
        }
    }

    @Test
    fun parentTraversalIsRejectedBeforeWritingOutsideTheRoot() {
        val root = freshRoot()
        assertRejected(archive(file("../escape", "bad")), root)
        assertFalse(Files.exists(root.parent.resolve("escape"), NOFOLLOW_LINKS))
    }

    @Test
    fun absoluteEntryPathsAreRejected() {
        val outside = temporary.root.toPath().resolve("absolute-escape")
        assertRejected(archive(file(outside.toString(), "bad")))
        assertFalse(Files.exists(outside, NOFOLLOW_LINKS))
    }

    @Test
    fun writesThroughSymlinkParentsCannotModifyOutsideFiles() {
        val outside = temporary.newFolder("outside").toPath()
        Files.write(outside.resolve("keep"), "keep".toByteArray(StandardCharsets.UTF_8))
        val root = freshRoot()

        assertRejected(
            archive(
                symlink("escape", outside.toString()),
                file("escape/overwrite", "bad"),
            ),
            root,
        )

        assertTrue(Files.isSymbolicLink(root.resolve("escape")))
        assertFalse(Files.exists(outside.resolve("overwrite"), NOFOLLOW_LINKS))
        assertEquals("keep", readUtf8(outside.resolve("keep")))
    }

    @Test
    fun hardlinksCannotDereferenceSymlinks() {
        assertRejected(
            archive(
                symlink("link", "/bin/busybox"),
                hardlink("copy", "link"),
            ),
        )
    }

    @Test
    fun hardlinkCyclesFailInsteadOfLooping() {
        assertRejected(archive(hardlink("a", "b"), hardlink("b", "a")))
    }

    @Test
    fun duplicateFilesCannotOverwriteEarlierContents() {
        val root = freshRoot()
        assertRejected(archive(file("x", "one"), file("x", "two")), root)
        assertEquals("one", readUtf8(root.resolve("x")))
    }

    @Test
    fun aDirectoryCannotReplaceASymlink() {
        val root = freshRoot()
        assertRejected(archive(symlink("x", "/tmp"), Entry("x", type = '5')), root)
        assertTrue(Files.isSymbolicLink(root.resolve("x")))
    }

    @Test
    fun specialDeviceNodesAreNotCreated() {
        val root = freshRoot()
        assertRejected(archive(Entry("dev/x", type = '3')), root)
        assertFalse(Files.exists(root.resolve("dev/x"), NOFOLLOW_LINKS))
    }

    @Test
    fun headerChecksumCorruptionIsRejectedBeforeWritingTheFile() {
        val corrupted = archive(file("file", "hello"))
        corrupted[0] = (corrupted[0].toInt() xor 1).toByte()
        val root = freshRoot()
        assertRejected(corrupted, root)
        assertFalse(Files.exists(root.resolve("file"), NOFOLLOW_LINKS))
    }

    @Test
    fun truncatedRegularFileContentsAreRejected() {
        assertRejected(archive(file("file", "12345")).copyOf(512 + 2))
    }

    @Test
    fun aTarWithoutAnEndMarkerIsRejected() {
        assertRejected(archive(file("file", "hello")).copyOf(1024))
    }

    @Test
    fun aSingleZeroBlockDoesNotCountAsTheCompleteEndMarker() {
        assertRejected(ByteArray(512))
    }

    @Test
    fun nonzeroDataAfterTheEndMarkerIsRejected() {
        assertRejected(archive(file("file", "hello")) + "bad".toByteArray())
    }

    @Test
    fun oversizedDeclaredFilesFailBeforeAllocatingTheirContents() {
        val root = freshRoot()
        val headerOnly = archive(Entry("huge", declaredSize = 65L * 1024 * 1024))
        assertRejected(headerOnly, root)
        assertFalse(Files.exists(root.resolve("huge"), NOFOLLOW_LINKS))
    }

    @Test
    fun longForwardHardlinkChainsResolveIteratively() {
        val entries = (0 until 1000).map { index ->
            hardlink("h$index", if (index == 999) "real" else "h${index + 1}")
        } + file("real", "end")
        val root = extract(archive(*entries.toTypedArray()))

        assertEquals("end", readUtf8(root.resolve("h0")))
        assertTrue(Files.isSameFile(root.resolve("h0"), root.resolve("real")))
    }

    @Test
    fun gnuLongLinkTargetsRetainGuestAbsolutePaths() {
        val target = "/" + "a".repeat(120) + "/" + "b".repeat(120)
        val root = extract(archive(symlink("link", target)))

        assertTrue(Files.isSymbolicLink(root.resolve("link")))
        assertEquals(Paths.get(target), Files.readSymbolicLink(root.resolve("link")))
    }

    @Test
    fun paxGlobalMetadataAndPerFileSizeOverrideAreSupported() {
        val root = extract(
            rawArchive(
                pax(mapOf("comment" to "global"), global = true),
                pax(mapOf("path" to "deep/real", "size" to "5")),
                Entry("short", data = "hello".toByteArray(), declaredSize = 0),
            ),
        )

        assertEquals("hello", readUtf8(root.resolve("deep/real")))
    }

    @Test
    fun theGzipTrailerIsConsumedAndItsCrcIsValidated() {
        val compressed = gzip(archive(file("file", "hello")))
        compressed[compressed.size - 8] = (compressed[compressed.size - 8].toInt() xor 1).toByte()

        assertThrows(IOException::class.java) {
            GZIPInputStream(ByteArrayInputStream(compressed)).use {
                SafeTarInstaller(freshRoot()).extract(it)
            }
        }
    }

    @Test
    fun aTruncatedGzipTrailerIsRejectedEvenAfterAllFilesWereRead() {
        val compressed = gzip(archive(file("file", "hello"))).let { it.copyOf(it.size - 3) }

        assertThrows(IOException::class.java) {
            GZIPInputStream(ByteArrayInputStream(compressed)).use {
                SafeTarInstaller(freshRoot()).extract(it)
            }
        }
    }

    @Test
    fun desktopCodecManifestRequiresTheFixedPathDigestAndBoundedSize() {
        val data = codecBytes()
        val sha = sha256(data)
        assertEquals(DesktopCodecLibrary.ASSET, DesktopCodecLibrary(DesktopCodecLibrary.ASSET, sha, data.size.toLong()).asset)
        for (asset in listOf("../lib.so", "perant-linux/compat/other.so", "/perant-linux/compat/libgdk_pixbuf-2.0.so.0")) {
            assertThrows(IOException::class.java) { DesktopCodecLibrary(asset, sha, data.size.toLong()) }
        }
        for (digest in listOf("", "f".repeat(63), "G".repeat(64), sha.uppercase())) {
            assertThrows(IOException::class.java) { DesktopCodecLibrary(DesktopCodecLibrary.ASSET, digest, data.size.toLong()) }
        }
        for (size in listOf(0L, 19L, DesktopCodecLibrary.MAX_BYTES + 1)) {
            assertThrows(IOException::class.java) { DesktopCodecLibrary(DesktopCodecLibrary.ASSET, sha, size) }
        }
    }

    @Test
    fun desktopBrowserOfficePackageQuotasRemainBounded() {
        for (count in listOf(1, 214, LinuxRuntimeResourceLimits.MAX_DESKTOP_PACKAGES)) {
            LinuxRuntimeResourceLimits.validateDesktopPackageCount(count)
        }
        for (count in listOf(0, -1, LinuxRuntimeResourceLimits.MAX_DESKTOP_PACKAGES + 1, Int.MAX_VALUE)) {
            assertThrows(IOException::class.java) { LinuxRuntimeResourceLimits.validateDesktopPackageCount(count) }
        }
        // The selected Writer/Calc/Impress closure has a 148,836,331-byte common APK.
        for (size in listOf(1L, 148_836_331L, LinuxRuntimeResourceLimits.MAX_DESKTOP_PACKAGE_BYTES)) {
            LinuxRuntimeResourceLimits.validateDesktopPackageSize(size)
        }
        for (size in listOf(0L, -1L, LinuxRuntimeResourceLimits.MAX_DESKTOP_PACKAGE_BYTES + 1, Long.MAX_VALUE)) {
            assertThrows(IOException::class.java) { LinuxRuntimeResourceLimits.validateDesktopPackageSize(size) }
        }
    }

    @Test
    fun officialMixedCaseDesktopPackageNamesDoNotPermitPathCharacters() {
        for (name in listOf("firefox", "libSvtAv1Enc", "libreoffice-common", "a".repeat(80))) {
            LinuxRuntimeResourceLimits.validateDesktopPackageName(name)
        }
        for (name in listOf("", "-firefox", "../firefox", "lib/encoder", "lib\\encoder", "lib\nencoder", "a".repeat(81))) {
            assertThrows(IOException::class.java) { LinuxRuntimeResourceLimits.validateDesktopPackageName(name) }
        }
    }

    @Test
    fun runtimeManifestByteQuotaRejectsOversizeInputWithoutReadingTheRemainder() {
        val limit = LinuxRuntimeResourceLimits.MAX_MANIFEST_BYTES
        assertEquals(limit, LinuxRuntimeResourceLimits.readManifest(ByteArrayInputStream(ByteArray(limit))).size)
        val input = object : java.io.InputStream() {
            var consumed = 0
            override fun read(): Int {
                consumed += 1
                if (consumed > limit + 4096) throw AssertionError("Manifest reader exceeded its bounded probe.")
                return 32
            }
        }
        assertThrows(IOException::class.java) { LinuxRuntimeResourceLimits.readManifest(input) }
        assertTrue(input.consumed <= limit + 4096)
    }

    @Test
    fun desktopCodecInstallsAsAnIndependentVerifiedRegularLibrary() {
        val root = freshRoot()
        val data = codecBytes()
        val resource = DesktopCodecLibrary(DesktopCodecLibrary.ASSET, sha256(data), data.size.toLong())
        assertFalse(resource.isInstalled(root))
        ByteArrayInputStream(data).use { resource.install(root, it) }
        val path = root.resolve(DesktopCodecLibrary.RELATIVE_PATH)
        assertTrue(resource.isInstalled(root))
        resource.verify(root)
        assertTrue(Files.isRegularFile(path, NOFOLLOW_LINKS))
        assertEquals(setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE), Files.getPosixFilePermissions(path))
        val altered = data.copyOf().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() }
        Files.write(path, altered)
        assertThrows(IOException::class.java) { resource.verify(root) }
        Files.delete(path)
        val outside = temporary.newFile().toPath()
        Files.write(outside, data)
        Files.createSymbolicLink(path, outside)
        assertFalse(resource.isInstalled(root))
        assertThrows(IOException::class.java) { resource.verify(root) }
    }

    @Test
    fun invalidDesktopCodecContentsAreRejectedAndNotRetained() {
        val valid = codecBytes()
        val invalidElf = valid.copyOf().also { it[18] = 62 } // x86-64, not AArch64.
        val cases = listOf(
            valid.copyOf(valid.size - 1) to sha256(valid),
            (valid + byteArrayOf(0)) to sha256(valid),
            valid to "f".repeat(64),
            invalidElf to sha256(invalidElf),
        )
        for ((data, sha) in cases) {
            val root = freshRoot()
            val resource = DesktopCodecLibrary(DesktopCodecLibrary.ASSET, sha, valid.size.toLong())
            assertThrows(IOException::class.java) { ByteArrayInputStream(data).use { resource.install(root, it) } }
            assertFalse(Files.exists(root.resolve(DesktopCodecLibrary.RELATIVE_PATH), NOFOLLOW_LINKS))
        }
    }

    @Test
    fun desktopCodecCannotWriteThroughSymlinkDirectoriesOrReplaceExistingFiles() {
        val root = freshRoot()
        val outside = temporary.newFolder().toPath()
        val data = codecBytes()
        val resource = DesktopCodecLibrary(DesktopCodecLibrary.ASSET, sha256(data), data.size.toLong())
        Files.createDirectories(root.resolve("opt/perant"))
        Files.createSymbolicLink(root.resolve("opt/perant/lib"), outside)
        assertThrows(IOException::class.java) { ByteArrayInputStream(data).use { resource.install(root, it) } }
        assertFalse(Files.exists(outside.resolve("libgdk_pixbuf-2.0.so.0"), NOFOLLOW_LINKS))
        Files.delete(root.resolve("opt/perant/lib"))
        Files.createDirectory(root.resolve("opt/perant/lib"))
        val target = root.resolve(DesktopCodecLibrary.RELATIVE_PATH)
        Files.write(target, "keep".toByteArray(StandardCharsets.UTF_8))
        assertThrows(IOException::class.java) { ByteArrayInputStream(data).use { resource.install(root, it) } }
        assertEquals("keep", readUtf8(target))
        val linkedRoot = temporary.root.toPath().resolve("codec-root-link")
        Files.createSymbolicLink(linkedRoot, root)
        assertFalse(resource.isInstalled(linkedRoot))
        assertThrows(IOException::class.java) { ByteArrayInputStream(data).use { resource.install(linkedRoot, it) } }
    }

    private fun codecBytes(): ByteArray = ByteArray(64) { it.toByte() }.also {
        it[0] = 0x7f; it[1] = 0x45; it[2] = 0x4c; it[3] = 0x46
        it[4] = 2; it[5] = 1; it[18] = 183.toByte(); it[19] = 0
    }

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun readUtf8(path: Path): String =
        String(Files.readAllBytes(path), StandardCharsets.UTF_8)

    private fun freshRoot(): Path = temporary.newFolder().toPath()

    private fun extract(bytes: ByteArray, root: Path = freshRoot()): Path {
        ByteArrayInputStream(bytes).use { SafeTarInstaller(root).extract(it) }
        return root
    }

    private fun assertRejected(bytes: ByteArray, root: Path = freshRoot()) {
        assertThrows(IOException::class.java) { extract(bytes, root) }
    }

    private data class Entry(
        val name: String,
        val type: Char = '0',
        val data: ByteArray = byteArrayOf(),
        val linkName: String = "",
        val mode: Int = 0x1ED,
        val declaredSize: Long = data.size.toLong(),
    )

    private fun file(name: String, text: String, mode: Int = 0x1ED) =
        Entry(name, data = text.toByteArray(StandardCharsets.UTF_8), mode = mode)

    private fun symlink(name: String, target: String) = Entry(name, type = '2', linkName = target)

    private fun hardlink(name: String, target: String) = Entry(name, type = '1', linkName = target)

    /** Generate GNU extensions explicitly; fixtures require no system tar program. */
    private fun archive(vararg entries: Entry): ByteArray {
        val expanded = mutableListOf<Entry>()
        for (entry in entries) {
            var header = entry
            if (entry.name.toByteArray(StandardCharsets.UTF_8).size > 100) {
                expanded.add(
                    Entry("././@LongLink", 'L', (entry.name + "\u0000").toByteArray(StandardCharsets.UTF_8)),
                )
                header = header.copy(name = "gnu-short-header")
            }
            if (entry.linkName.toByteArray(StandardCharsets.UTF_8).size > 100) {
                expanded.add(
                    Entry("././@LongLink", 'K', (entry.linkName + "\u0000").toByteArray(StandardCharsets.UTF_8)),
                )
                header = header.copy(linkName = "gnu-short-link")
            }
            expanded.add(header)
        }
        return rawArchive(*expanded.toTypedArray())
    }

    private fun rawArchive(vararg entries: Entry): ByteArray {
        val output = ByteArrayOutputStream()
        for (entry in entries) {
            val header = ByteArray(512)
            putText(header, 0, 100, entry.name)
            putOctal(header, 100, 8, entry.mode.toLong())
            putOctal(header, 124, 12, entry.declaredSize)
            for (index in 148..155) header[index] = 32
            header[156] = entry.type.code.toByte()
            putText(header, 157, 100, entry.linkName)
            putText(header, 257, 6, "ustar")
            putText(header, 263, 2, "00")
            val checksum = header.sumOf { it.toInt() and 0xff }
            putOctal(header, 148, 8, checksum.toLong())
            output.write(header)
            output.write(entry.data)
            output.write(ByteArray((512 - entry.data.size % 512) % 512))
        }
        output.write(ByteArray(1024))
        return output.toByteArray()
    }

    private fun pax(values: Map<String, String>, global: Boolean = false): Entry {
        val output = ByteArrayOutputStream()
        for ((key, value) in values) {
            val body = "$key=$value\n".toByteArray(StandardCharsets.UTF_8)
            var length = body.size + 2
            while (true) {
                val next = body.size + length.toString().length + 1
                if (next == length) break
                length = next
            }
            output.write("$length ".toByteArray(StandardCharsets.US_ASCII))
            output.write(body)
        }
        return Entry(
            if (global) "GlobalHead" else "PaxHeader",
            if (global) 'g' else 'x',
            output.toByteArray(),
        )
    }

    private fun putText(buffer: ByteArray, offset: Int, length: Int, text: String) {
        val bytes = text.toByteArray(StandardCharsets.UTF_8)
        require(bytes.size <= length)
        bytes.copyInto(buffer, offset)
    }

    private fun putOctal(buffer: ByteArray, offset: Int, length: Int, value: Long) {
        val text = value.toString(8).padStart(length - 1, '0') + "\u0000"
        require(text.length == length)
        text.toByteArray(StandardCharsets.US_ASCII).copyInto(buffer, offset)
    }

    private fun gzip(bytes: ByteArray): ByteArray {
        val output = ByteArrayOutputStream()
        GZIPOutputStream(output).use { it.write(bytes) }
        return output.toByteArray()
    }
}
