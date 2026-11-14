// SPDX-License-Identifier: GPL-3.0-only
package dev.perant.platform

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.IOException
import java.nio.charset.CharacterCodingException
import java.nio.charset.StandardCharsets.UTF_8
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path

/** Real temporary files and POSIX links, without an Android host or mock IO. */
class LinuxTextTasksTest {
    @Rule
    @JvmField
    val temporary = TemporaryFolder()

    @Test
    fun inputContractCountsUnicodeCodePointsRatherThanUtf16Units() {
        TextTaskContract.validateInput("a", "标题", "界".repeat(20000))
        TextTaskContract.validateInput("a".repeat(96), "🐜".repeat(80), "🐜".repeat(20000))
        TextTaskContract.validateInput("task.with-dash_1", "原文 ' \$()", "  保留\r\n\t原文 \$() 🐜  ")
    }

    @Test
    fun taskIdsCannotEscapeOrSelectAnExistingDirectory() {
        val fixture = fixture()
        for (id in listOf("", " ", ".", "..", ".task", "../outside", "a/b", "a\\b", "/absolute", "中文", "a".repeat(97))) {
            assertThrows(IllegalArgumentException::class.java) { TextTaskContract.validateId(id) }
            assertThrows(IllegalArgumentException::class.java) { fixture.tasks.createInput(id, inputBytes) }
            assertThrows(IllegalArgumentException::class.java) { fixture.tasks.readResult(id) }
        }
        assertFalse(Files.exists(fixture.workspace.resolve(".perant-tasks"), NOFOLLOW_LINKS))
    }

    @Test
    fun invalidSourceLimitsAndEncodingCannotReachFilePreparation() {
        for (text in listOf("", " \r\n", "a\u0000b", "界".repeat(20001), "🐜".repeat(20001))) {
            assertThrows(IllegalArgumentException::class.java) { TextTaskContract.validateInput("task-1", "标题", text) }
        }
        for (title in listOf("", " ", "a\nb", "a\rb", "a\tb", "a\u007fb", "a\u0085b", "a\u009fb", "a\u2028b", "a\u2029b", "🐜".repeat(81))) {
            assertThrows(IllegalArgumentException::class.java) { TextTaskContract.validateInput("task-1", title, "原文") }
        }
        assertThrows(CharacterCodingException::class.java) { TextTaskContract.validateInput("task-1", "标题", "\uD800") }
        assertThrows(CharacterCodingException::class.java) { TextTaskContract.validateInput("task-1", "\uD800", "原文") }
    }

    @Test
    fun anExecutionIdIsExclusiveAndCannotOverwriteAnEarlierTask() {
        val fixture = fixture()
        fixture.tasks.createInput("task-1", inputBytes)
        val task = fixture.task("task-1")
        val original = Files.readAllBytes(task.resolve("input.json"))
        Files.write(task.resolve("output.md"), "# 已有成果\n".toByteArray(UTF_8))

        assertThrows(IOException::class.java) {
            fixture.tasks.createInput("task-1", "replacement".toByteArray(UTF_8))
        }

        assertArrayEquals(inputBytes, original)
        assertArrayEquals(original, Files.readAllBytes(task.resolve("input.json")))
        assertEquals("# 已有成果\n", readUtf8(task.resolve("output.md")))
    }

    @Test
    fun inputByteQuotaFailsBeforeCreatingAnyTaskStorage() {
        val fixture = fixture()
        for (bytes in listOf(byteArrayOf(), ByteArray(192 * 1024 + 1) { 32 })) {
            assertThrows(IOException::class.java) { fixture.tasks.createInput("task-1", bytes) }
        }
        assertFalse(Files.exists(fixture.workspace.resolve(".perant-tasks"), NOFOLLOW_LINKS))
        fixture.tasks.createInput("maximum", ByteArray(192 * 1024) { 32 })
        assertEquals(192L * 1024, Files.size(fixture.task("maximum").resolve("input.json")))
    }

    @Test
    fun symlinkedWorkspaceAndTaskParentCannotRedirectInputWrites() {
        val outside = temporary.newFolder("outside-input").toPath()
        Files.write(outside.resolve("keep"), "keep".toByteArray(UTF_8))
        val linkedWorkspace = temporary.root.toPath().resolve("linked-workspace")
        Files.createSymbolicLink(linkedWorkspace, outside)
        assertThrows(IOException::class.java) {
            LinuxTextTasks(linkedWorkspace.toFile()).createInput("escaped", inputBytes)
        }

        val fixture = fixture()
        Files.createSymbolicLink(fixture.workspace.resolve(".perant-tasks"), outside)
        assertThrows(IOException::class.java) { fixture.tasks.createInput("escaped", inputBytes) }

        assertFalse(Files.exists(outside.resolve("escaped"), NOFOLLOW_LINKS))
        assertFalse(Files.exists(outside.resolve(".perant-tasks"), NOFOLLOW_LINKS))
        assertEquals("keep", readUtf8(outside.resolve("keep")))
    }

    @Test
    fun anExistingSymlinkTaskCannotBeReusedForInputOrResult() {
        val fixture = fixture()
        val outside = temporary.newFolder("outside-task").toPath()
        Files.write(outside.resolve("input.json"), inputBytes)
        Files.write(outside.resolve("output.md"), "private outside text".toByteArray(UTF_8))
        Files.createDirectory(fixture.workspace.resolve(".perant-tasks"))
        Files.createSymbolicLink(fixture.task("task-1"), outside)

        assertThrows(IOException::class.java) { fixture.tasks.createInput("task-1", inputBytes) }
        assertThrows(IOException::class.java) { fixture.tasks.readResult("task-1") }
        assertEquals("private outside text", readUtf8(outside.resolve("output.md")))
        assertArrayEquals(inputBytes, Files.readAllBytes(outside.resolve("input.json")))
    }

    @Test
    fun readingDoesNotFollowSymlinkedTaskParentsOrInputMarkers() {
        val fixture = fixture()
        fixture.tasks.createInput("task-1", inputBytes)
        Files.write(fixture.task("task-1").resolve("output.md"), "# 完成\n".toByteArray(UTF_8))
        val originalParent = fixture.workspace.resolve(".perant-tasks")
        val detachedParent = fixture.workspace.resolve("detached-tasks")
        Files.move(originalParent, detachedParent)
        Files.createSymbolicLink(originalParent, detachedParent)
        assertThrows(IOException::class.java) { fixture.tasks.readResult("task-1") }
        Files.delete(originalParent)
        Files.move(detachedParent, originalParent)

        val input = fixture.task("task-1").resolve("input.json")
        val outsideInput = temporary.newFile("outside-input.json").toPath()
        Files.write(outsideInput, inputBytes)
        Files.delete(input)
        Files.createSymbolicLink(input, outsideInput)
        assertThrows(IOException::class.java) { fixture.tasks.readResult("task-1") }
    }

    @Test
    fun outputAliasesCannotReadAnotherFileThroughSymlinksOrHardlinks() {
        val fixture = fixture()
        fixture.tasks.createInput("task-1", inputBytes)
        val outside = temporary.newFile("outside-output.md").toPath()
        Files.write(outside, "outside content must stay outside".toByteArray(UTF_8))
        val output = fixture.task("task-1").resolve("output.md")
        Files.createSymbolicLink(output, outside)
        assertThrows(IOException::class.java) { fixture.tasks.readResult("task-1") }
        Files.delete(output)
        Files.createLink(output, outside)
        assertEquals(2L, (Files.getAttribute(output, "unix:nlink", NOFOLLOW_LINKS) as Number).toLong())
        assertThrows(IOException::class.java) { fixture.tasks.readResult("task-1") }
        assertEquals("outside content must stay outside", readUtf8(outside))
    }

    @Test
    fun resultsRequireBothInputAndOutputToBeRegularFiles() {
        val fixture = fixture()
        fixture.tasks.createInput("task-1", inputBytes)
        val output = fixture.task("task-1").resolve("output.md")
        assertThrows(IOException::class.java) { fixture.tasks.readResult("task-1") }
        Files.createDirectory(output)
        assertThrows(IOException::class.java) { fixture.tasks.readResult("task-1") }
        Files.delete(output)
        Files.write(output, "# Valid result\n".toByteArray(UTF_8))
        Files.delete(fixture.task("task-1").resolve("input.json"))
        assertThrows(IOException::class.java) { fixture.tasks.readResult("task-1") }
    }

    @Test
    fun malformedUtf8EmptyAndOversizedResultsAreNeverPublished() {
        val fixture = fixture()
        fixture.tasks.createInput("task-1", inputBytes)
        val output = fixture.task("task-1").resolve("output.md")
        for (bytes in listOf(
            byteArrayOf(),
            " \t\r\n".toByteArray(UTF_8),
            byteArrayOf(0xff.toByte()),
            byteArrayOf(0xc3.toByte()),
            byteArrayOf(0xed.toByte(), 0xa0.toByte(), 0x80.toByte()),
            ByteArray(262145) { 97 },
        )) {
            Files.write(output, bytes)
            assertThrows(IOException::class.java) { fixture.tasks.readResult("task-1") }
        }
    }

    @Test
    fun aResultContainsTheExactUtf8BytesAndItsOwnedGuestPath() {
        val fixture = fixture()
        fixture.tasks.createInput("task-1", inputBytes)
        val markdown = "# 中文 🐜\n\n引号 '\" 和 \$(echo literal) 保持可见。\n"
        val bytes = markdown.toByteArray(UTF_8)
        Files.write(fixture.task("task-1").resolve("output.md"), bytes)

        val result = fixture.tasks.readResult("task-1")
        assertEquals("task-1", result["taskId"])
        assertEquals(markdown, result["markdown"])
        assertEquals(bytes.size, result["sizeBytes"])
        assertEquals("/workspace/.perant-tasks/task-1/output.md", result["workspacePath"])
        assertThrows(IOException::class.java) { fixture.tasks.readResult("other-task") }
        assertFalse(Files.exists(fixture.task("other-task"), NOFOLLOW_LINKS))
    }

    @Test
    fun theExactOutputByteLimitIsAcceptedWithoutTruncation() {
        val fixture = fixture()
        fixture.tasks.createInput("maximum", inputBytes)
        val bytes = ByteArray(262144) { 97 }
        Files.write(fixture.task("maximum").resolve("output.md"), bytes)

        val result = fixture.tasks.readResult("maximum")
        assertEquals(262144, result["sizeBytes"])
        assertEquals(262144, (result["markdown"] as String).length)
        assertTrue((result["markdown"] as String).all { it == 'a' })
    }

    private fun fixture(): Fixture {
        val workspace = temporary.newFolder().toPath()
        return Fixture(workspace, LinuxTextTasks(workspace.toFile()))
    }

    private fun readUtf8(path: Path): String = String(Files.readAllBytes(path), UTF_8)

    private data class Fixture(val workspace: Path, val tasks: LinuxTextTasks) {
        fun task(id: String): Path = workspace.resolve(".perant-tasks").resolve(id)
    }

    private val inputBytes = "{\"schemaVersion\":1,\"title\":\"标题\",\"text\":\"中文 🐜\"}".toByteArray(UTF_8)
}
