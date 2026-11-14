// SPDX-License-Identifier: GPL-3.0-only
package dev.perant.platform

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.nio.charset.CharacterCodingException
import java.nio.charset.StandardCharsets.UTF_8
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS

class LinuxWorkspaceFilesTest {
    @Rule @JvmField val temporary = TemporaryFolder()

    @Test
    fun sharedTextRoundTripUsesExactUnicodeBytesAndStableDigest() {
        val workspace = temporary.newFolder()
        val files = workspaceFiles(workspace)
        files.createDirectory("/workspace/资料")
        val original = "# 协作 🐜\n\n原文 \$(touch never) <script>stay text</script>\n"
        val saved = files.write("资料/会议.md", original, null, true)
        assertEquals("/workspace/资料/会议.md", saved["path"])
        assertEquals(original, saved["content"])
        assertEquals(original.toByteArray(UTF_8).size, saved["sizeBytes"])
        assertEquals(64, (saved["sha256"] as String).length)
        assertEquals(saved, files.read("/workspace/资料/会议.md"))
        assertEquals(1L, (Files.getAttribute(workspace.toPath().resolve("资料/会议.md"), "unix:nlink", NOFOLLOW_LINKS) as Number).toLong())
        assertFalse(workspace.walkTopDown().any { it.name.startsWith(".perant-write-") })
    }

    @Test
    fun updatesRequireTheCurrentDigestAndNeverOverwriteOnConflict() {
        val workspace = temporary.newFolder()
        val files = workspaceFiles(workspace)
        val first = files.write("note.md", "original", null, true)
        for ((digest, createOnly) in listOf(null to true, null to false, "0".repeat(64) to false)) {
            val failure = assertThrows(LinuxFailure::class.java) { files.write("note.md", "lost", digest, createOnly) }
            assertEquals("file_conflict", failure.code)
            assertEquals("original", files.read("note.md")["content"])
        }
        val next = files.write("note.md", "edited", first["sha256"] as String, false)
        assertEquals("edited", next["content"])
        assertTrue(next["sha256"] != first["sha256"])
        assertEquals("file_conflict", assertThrows(LinuxFailure::class.java) {
            files.write("note.md", "stale", first["sha256"] as String, false)
        }.code)
        assertEquals("file_conflict", assertThrows(LinuxFailure::class.java) {
            files.write("missing.md", "lost", first["sha256"] as String, false)
        }.code)
        assertEquals("edited", files.read("note.md")["content"])
        assertFalse(workspace.resolve("missing.md").exists())
    }

    @Test
    fun traversalAbsoluteAliasesAndReservedTaskPathsAreRejectedBeforeIo() {
        val files = workspaceFiles(temporary.newFolder())
        for (path in listOf("", "/", "/etc/passwd", "/workspace-other/file", "/workspace/../file", "a/../../file", ".", "..",
            "a//b", "a/./b", "a/", "a\\b", "/workspace/.perant-tasks/any/input.json", ".perant-tasks", "a/.perant-write-hidden", "a\nb", "a\u0000b", "x".repeat(256))) {
            assertThrows(IllegalArgumentException::class.java) { files.list(path) }
            assertThrows(IllegalArgumentException::class.java) { files.read(path) }
            assertThrows(IllegalArgumentException::class.java) { files.write(path, "x", null, true) }
            assertThrows(IllegalArgumentException::class.java) { files.createDirectory(path) }
        }
        assertThrows(IllegalArgumentException::class.java) { files.read("/workspace") }
        assertThrows(IllegalArgumentException::class.java) { files.write("/workspace", "x", null, true) }
        assertEquals("/workspace/a/中文.md", WorkspaceFileContract.path("a/中文.md"))
        assertEquals("/workspace", WorkspaceFileContract.path("/workspace"))
    }

    @Test
    fun symlinksAndHardlinksCannotReadOrReplaceAnOutsideFile() {
        val workspace = temporary.newFolder().toPath()
        val outside = temporary.newFile().toPath()
        Files.write(outside, "private".toByteArray(UTF_8))
        Files.createSymbolicLink(workspace.resolve("alias.md"), outside)
        Files.createLink(workspace.resolve("hard.md"), outside)
        val files = workspaceFiles(workspace.toFile())
        for (path in listOf("alias.md", "hard.md")) {
            assertThrows(LinuxFailure::class.java) { files.read(path) }
            assertThrows(LinuxFailure::class.java) { files.write(path, "changed", "0".repeat(64), false) }
            assertThrows(LinuxFailure::class.java) { files.write(path, "changed", null, true) }
        }
        assertEquals("private", String(Files.readAllBytes(outside), UTF_8))
        assertTrue((files.list("/workspace")["entries"] as List<*>).isEmpty())
    }

    @Test
    fun symlinkedWorkspaceAndAncestorDirectoriesAreRejected() {
        val outside = temporary.newFolder().toPath()
        Files.write(outside.resolve("private.md"), "private".toByteArray(UTF_8))
        val workspace = temporary.newFolder().toPath()
        Files.createSymbolicLink(workspace.resolve("escape"), outside)
        val files = workspaceFiles(workspace.toFile())
        assertThrows(LinuxFailure::class.java) { files.list("escape") }
        assertThrows(LinuxFailure::class.java) { files.read("escape/private.md") }
        assertThrows(LinuxFailure::class.java) { files.write("escape/new.md", "x", null, true) }
        assertThrows(LinuxFailure::class.java) { files.createDirectory("escape/new") }
        assertFalse(Files.exists(outside.resolve("new.md")))
        val alias = temporary.root.toPath().resolve("workspace-alias")
        Files.createSymbolicLink(alias, workspace)
        assertThrows(LinuxFailure::class.java) { workspaceFiles(alias.toFile()).list("/workspace") }
    }

    @Test
    fun directoryListingHidesInternalStorageAndSortsDirectoriesFirst() {
        val workspace = temporary.newFolder().toPath()
        Files.createDirectory(workspace.resolve(".perant-tasks"))
        Files.write(workspace.resolve(".perant-write-orphan"), byteArrayOf(1))
        val files = workspaceFiles(workspace.toFile())
        files.write("z.md", "z", null, true)
        files.createDirectory("资料")
        files.write("A.md", "a", null, true)
        val result = files.list("/workspace")
        val entries = result["entries"] as List<*>
        assertEquals(false, result["truncated"])
        assertEquals(listOf("资料", "A.md", "z.md"), entries.map { (it as Map<*, *>)["name"] })
        assertEquals(true, (entries[0] as Map<*, *>)["isDirectory"])
        assertEquals(0L, (entries[0] as Map<*, *>)["sizeBytes"])
        assertEquals("/workspace/资料", (entries[0] as Map<*, *>)["path"])
    }

    @Test
    fun directoryListingIsBoundedAndMarksTruncation() {
        val workspace = temporary.newFolder().toPath()
        repeat(501) { Files.createFile(workspace.resolve("$it.txt")) }
        val result = workspaceFiles(workspace.toFile()).list("/workspace")
        assertEquals(500, (result["entries"] as List<*>).size)
        assertEquals(true, result["truncated"])
    }

    @Test
    fun textLimitsUseUtf8BytesAcceptEmptyAndRejectBinaryOrMalformedContent() {
        val workspace = temporary.newFolder().toPath()
        val files = workspaceFiles(workspace.toFile())
        assertEquals(0, files.write("empty.txt", "", null, true)["sizeBytes"])
        assertEquals(262144, files.write("full.txt", "🐜".repeat(65536), null, true)["sizeBytes"])
        assertThrows(IllegalArgumentException::class.java) { files.write("large.txt", "🐜".repeat(65537), null, true) }
        assertThrows(IllegalArgumentException::class.java) { files.write("nul.txt", "a\u0000b", null, true) }
        assertThrows(CharacterCodingException::class.java) { files.write("bad.txt", "\uD800", null, true) }
        for ((name, bytes) in listOf("binary" to byteArrayOf(0), "utf8" to byteArrayOf(0xff.toByte()), "oversized" to ByteArray(262145) { 97 })) {
            Files.write(workspace.resolve(name), bytes)
            assertThrows(LinuxFailure::class.java) { files.read(name) }
        }
        assertFalse(Files.exists(workspace.resolve("large.txt")))
    }

    @Test
    fun directoryCreationDoesNotReuseOrReplaceFilesAndRequiresARealParent() {
        val workspace = temporary.newFolder().toPath()
        val files = workspaceFiles(workspace.toFile())
        files.createDirectory("project")
        assertEquals("file_conflict", assertThrows(LinuxFailure::class.java) { files.createDirectory("project") }.code)
        files.write("note", "keep", null, true)
        assertEquals("file_conflict", assertThrows(LinuxFailure::class.java) { files.createDirectory("note") }.code)
        assertThrows(LinuxFailure::class.java) { files.createDirectory("note/child") }
        assertThrows(LinuxFailure::class.java) { files.createDirectory("missing/child") }
        assertEquals("keep", files.read("note")["content"])
        assertThrows(LinuxFailure::class.java) { files.read("project") }
    }

    @Test
    fun aDestinationCreatedDuringPublicationIsNeverOverwritten() {
        val workspace = temporary.newFolder()
        val files = LinuxWorkspaceFiles(workspace) { source, destination ->
            Files.write(destination, "racing original".toByteArray(UTF_8))
            Files.createLink(destination, source)
            Files.delete(source)
        }
        assertEquals("file_conflict", assertThrows(LinuxFailure::class.java) {
            files.write("new.md", "replacement", null, true)
        }.code)
        assertEquals("racing original", files.read("new.md")["content"])
        assertFalse(workspace.listFiles()!!.any { it.name.startsWith(".perant-write-") })
    }

    @Test
    fun unsupportedAtomicPublicationDoesNotFallBackToANonAtomicWrite() {
        val workspace = temporary.newFolder()
        val files = LinuxWorkspaceFiles(workspace) { _, _ ->
            throw LinuxFailure("storage_error", "Atomic publication unavailable.")
        }
        assertEquals("storage_error", assertThrows(LinuxFailure::class.java) {
            files.write("new.md", "unpublished", null, true)
        }.code)
        assertTrue(workspace.listFiles()!!.isEmpty())
    }

    // Host JVMs cannot load the Android JNI library. Inject the same atomic
    // no-replace publication contract using host links; device tests exercise
    // the production renameat2 path under Android SELinux.
    private fun workspaceFiles(workspace: java.io.File): LinuxWorkspaceFiles =
        LinuxWorkspaceFiles(workspace) { source, destination ->
            Files.createLink(destination, source)
            Files.delete(source)
        }

}
