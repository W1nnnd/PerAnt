// SPDX-License-Identifier: GPL-3.0-only
package dev.perant.platform

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.Files
import java.nio.charset.CharacterCodingException
import java.nio.charset.StandardCharsets.UTF_8
import java.security.MessageDigest

class LinuxWorkspaceImportTest {
    @Rule @JvmField val temporary = TemporaryFolder()
    private val identifier = "12345678-1234-1234-1234-123456789abc"

    @Test
    fun generatedRootOnlyPublicationReturnsExactBytesReceiptWithoutReadBack() {
        val workspace = temporary.newFolder()
        val content = "# 资料 🐜\n\n\$(touch never) <script>plain text</script>\n"
        var calls = 0
        val importer = LinuxWorkspaceImport(workspace, privateStaging(workspace), { root, stage, name, bytes ->
            calls++
            assertEquals(workspace.absolutePath, root)
            assertEquals(privateStaging(workspace).absolutePath, stage)
            assertTrue(File(stage).isDirectory)
            assertEquals("web-$identifier.md", name)
            assertTrue(bytes.contentEquals(content.toByteArray(UTF_8)))
            // No file is materialized: the receipt must not perform a read-back.
            0
        }, { identifier })
        val receipt = importer.importText(content)
        assertEquals(1, calls)
        assertEquals(setOf("path", "sha256", "sizeBytes"), receipt.keys)
        assertEquals("/workspace/web-$identifier.md", receipt["path"])
        assertEquals(content.toByteArray(UTF_8).size, receipt["sizeBytes"])
        assertEquals(MessageDigest.getInstance("SHA-256").digest(content.toByteArray(UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 255) }, receipt["sha256"])
        assertTrue(workspace.listFiles()!!.isEmpty())
    }

    @Test
    fun strictUtf8NulAndSizeRejectBeforePublicationAndExactLimitIsAccepted() {
        var calls = 0
        val workspace = temporary.newFolder()
        val importer = LinuxWorkspaceImport(workspace, privateStaging(workspace), { _, _, _, _ -> calls++; 0 }, { identifier })
        assertThrows(CharacterCodingException::class.java) { importer.importText("\uD800") }
        assertThrows(IllegalArgumentException::class.java) { importer.importText("a\u0000b") }
        assertThrows(IllegalArgumentException::class.java) { importer.importText("🐜".repeat(65537)) }
        assertEquals(0, calls)
        assertEquals(262144, importer.importText("🐜".repeat(65536))["sizeBytes"])
        assertEquals(1, calls)
    }

    @Test
    fun publicationFailuresDoNotReturnSuccessOrRetryAndNamesCannotIntroducePaths() {
        for ((errno, code) in listOf(17 to "file_conflict", 5 to "storage_error", 38 to "storage_error")) {
            var calls = 0
            val workspace = temporary.newFolder()
            val importer = LinuxWorkspaceImport(workspace, privateStaging(workspace), { _, _, _, _ -> calls++; errno }, { identifier })
            assertEquals(code, assertThrows(LinuxFailure::class.java) { importer.importText("keep") }.code)
            assertEquals(1, calls)
        }
        for (id in listOf("../outside", "", "12345678-1234-1234-1234-123456789abC", "a/b")) {
            val workspace = temporary.newFolder()
            val importer = LinuxWorkspaceImport(workspace, privateStaging(workspace), { _, _, _, _ -> throw AssertionError("must not publish") }, { id })
            assertThrows(IllegalArgumentException::class.java) { importer.importText("keep") }
        }
    }

    @Test
    fun stagingMustBeASeparateRealPrivateDirectoryBeforeNativePublication() {
        val workspace = temporary.newFolder()
        val outside = temporary.newFolder()
        val symbolic = File(temporary.root, "staging-alias").toPath()
        Files.createSymbolicLink(symbolic, outside.toPath())
        val regular = temporary.newFile()
        for (stage in listOf(symbolic.toFile(), regular)) {
            val importer = LinuxWorkspaceImport(workspace, stage,
                { _, _, _, _ -> throw AssertionError("must not publish") }, { identifier })
            assertEquals("storage_error", assertThrows(LinuxFailure::class.java) { importer.importText("keep") }.code)
        }
        val importer = LinuxWorkspaceImport(workspace, File(workspace, "temporary"),
            { _, _, _, _ -> throw AssertionError("must not publish") }, { identifier })
        assertThrows(IllegalArgumentException::class.java) { importer.importText("keep") }
        assertTrue(workspace.listFiles()!!.isEmpty())
        assertTrue(outside.listFiles()!!.isEmpty())
    }

    private fun privateStaging(workspace: File): File = File(workspace.parentFile, "${workspace.name}-import-staging")

}
