// SPDX-License-Identifier: GPL-3.0-only
package dev.perant.platform

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.OpenOption
import java.nio.file.StandardOpenOption.CREATE_NEW
import java.nio.file.StandardOpenOption.READ
import java.nio.file.StandardOpenOption.WRITE
import java.nio.file.attribute.PosixFilePermissions

/** Fixed task files only. Call while the native runtime is idle and locked. */
internal class LinuxTextTasks(private val workspace: File) {
    fun createInput(id: String, bytes: ByteArray) {
        TextTaskContract.validateId(id)
        if (bytes.isEmpty() || bytes.size > 192 * 1024) throw IOException("Task input exceeds its quota.")
        directory(workspace, create = false)
        val parent = File(workspace, ".perant-tasks")
        directory(parent, create = true)
        val task = File(parent, id)
        // A previously used ID is never reused, including an interrupted task.
        Files.createDirectory(task.toPath(), PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")))
        FileChannel.open(File(task, "input.json").toPath(), setOf<OpenOption>(CREATE_NEW, WRITE, NOFOLLOW_LINKS)).use { channel ->
            val buffer = ByteBuffer.wrap(bytes)
            while (buffer.hasRemaining()) channel.write(buffer)
            channel.force(true)
        }
    }

    fun readResult(id: String): Map<String, Any> {
        TextTaskContract.validateId(id)
        directory(workspace, create = false)
        directory(File(workspace, ".perant-tasks"), create = false)
        val task = File(File(workspace, ".perant-tasks"), id)
        directory(task, create = false)
        val input = File(task, "input.json").toPath()
        if (!Files.isRegularFile(input, NOFOLLOW_LINKS)) throw IOException("Missing regular task input.")
        val output = File(task, "output.md").toPath()
        if (!Files.isRegularFile(output, NOFOLLOW_LINKS)) throw IOException("No regular Markdown result.")
        // Hard-linked files are not task output either. Never use this API to
        // read another application file through an alias inside the workspace.
        if ((Files.getAttribute(output, "unix:nlink", NOFOLLOW_LINKS) as Number).toLong() != 1L) {
            throw IOException("A task result must not be hard-linked.")
        }
        val bytes = FileChannel.open(output, setOf<OpenOption>(READ, NOFOLLOW_LINKS)).use { channel ->
            if (channel.size() !in 1L..262144L) throw IOException("Markdown result exceeds its quota.")
            val collected = ByteArrayOutputStream()
            val buffer = ByteBuffer.allocate(8192)
            while (true) {
                buffer.clear()
                val count = channel.read(buffer)
                if (count < 0) break
                if (collected.size() + count > 262144) throw IOException("Markdown result grew beyond its quota.")
                collected.write(buffer.array(), 0, count)
            }
            collected.toByteArray()
        }
        val markdown = StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes)).toString()
        if (markdown.isBlank()) throw IOException("Empty Markdown result.")
        return mapOf("taskId" to id, "markdown" to markdown,
            "workspacePath" to "/workspace/.perant-tasks/$id/output.md", "sizeBytes" to bytes.size)
    }

    private fun directory(file: File, create: Boolean) {
        val path = file.toPath()
        if (create && !Files.exists(path, NOFOLLOW_LINKS)) {
            Files.createDirectory(path, PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")))
        }
        if (!Files.isDirectory(path, NOFOLLOW_LINKS)) throw IOException("Task storage is not a real directory.")
    }
}

internal object TextTaskContract {
    fun validateId(id: String) {
        require(Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,95}").matches(id)) { "Invalid text task ID." }
    }

    fun validateInput(id: String, title: String, text: String) {
        validateId(id)
        require(title.isNotBlank() && title.codePointCount(0, title.length) <= 80 &&
            title.none { it.code < 32 || it.code in 127..159 || it == '\u2028' || it == '\u2029' }) { "Invalid text task title." }
        StandardCharsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).encode(java.nio.CharBuffer.wrap(title))
        require(text.isNotBlank() && '\u0000' !in text && text.codePointCount(0, text.length) <= 20000) { "Invalid text task source." }
        val encoded = StandardCharsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).encode(java.nio.CharBuffer.wrap(text))
        require(encoded.remaining() <= 131072) { "Text task source is too large." }
    }
}
