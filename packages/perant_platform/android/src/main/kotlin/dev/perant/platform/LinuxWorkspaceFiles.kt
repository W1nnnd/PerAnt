// SPDX-License-Identifier: GPL-3.0-only
package dev.perant.platform

import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.channels.FileChannel
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets.UTF_8
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.OpenOption
import java.nio.file.Path
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.nio.file.StandardOpenOption.CREATE_NEW
import java.nio.file.StandardOpenOption.READ
import java.nio.file.StandardOpenOption.WRITE
import java.nio.file.attribute.BasicFileAttributes
import java.nio.file.attribute.PosixFilePermissions
import java.security.MessageDigest
import java.util.UUID

/** Shared /workspace files. The caller holds the runtime lock with no guest running. */
internal class LinuxWorkspaceFiles(
    private val workspace: File,
    private val publishNewFile: (Path, Path) -> Unit = ::publishNewWorkspaceFile
) {
    fun list(path: String): Map<String, Any> {
        val guest = WorkspaceFileContract.path(path)
        val directory = resolve(guest, allowMissingLeaf = false)
        requireDirectory(directory)
        val entries = mutableListOf<Map<String, Any>>()
        var truncated = false
        Files.newDirectoryStream(directory).use { stream ->
            for (entry in stream) {
                val name = entry.fileName.toString()
                if (!WorkspaceFileContract.visibleName(name)) continue
                val childGuest = "$guest/$name"
                try { WorkspaceFileContract.path(childGuest) } catch (_: IllegalArgumentException) { continue }
                val attributes = Files.readAttributes(entry, BasicFileAttributes::class.java, NOFOLLOW_LINKS)
                // Unsupported aliases and device files are deliberately not exposed as editable files.
                if (!attributes.isDirectory && !attributes.isRegularFile) continue
                if (attributes.isRegularFile && links(entry) != 1L) continue
                if (entries.size == WorkspaceFileContract.MAX_ENTRIES) { truncated = true; break }
                entries.add(mapOf(
                    "name" to name, "path" to childGuest, "isDirectory" to attributes.isDirectory,
                    "sizeBytes" to if (attributes.isDirectory) 0L else attributes.size(),
                    "modifiedAtEpochMs" to attributes.lastModifiedTime().toMillis().coerceAtLeast(0L)
                ))
            }
        }
        val sorted = entries.sortedWith(compareBy<Map<String, Any>> { !(it["isDirectory"] as Boolean) }
            .thenBy { (it["name"] as String).lowercase(java.util.Locale.ROOT) }.thenBy { it["name"] as String })
        return mapOf("path" to guest, "entries" to sorted, "truncated" to truncated)
    }

    fun read(path: String): Map<String, Any> {
        val guest = WorkspaceFileContract.path(path, allowRoot = false)
        return readFile(resolve(guest, allowMissingLeaf = false), guest)
    }

    fun write(path: String, content: String, expectedSha256: String?, createOnly: Boolean): Map<String, Any> {
        val guest = WorkspaceFileContract.path(path, allowRoot = false)
        val bytes = WorkspaceFileContract.content(content)
        require(expectedSha256 == null || Regex("[0-9a-f]{64}").matches(expectedSha256)) { "Invalid digest." }
        require(!createOnly || expectedSha256 == null) { "Conflicting write conditions." }
        val destination = resolve(guest, allowMissingLeaf = true)
        val existed = Files.exists(destination, NOFOLLOW_LINKS)
        if (existed) {
            if (createOnly || expectedSha256 == null)
                throw LinuxFailure("file_conflict", "文件已存在，请重新读取后再保存。")
            val current = readFile(destination, guest)
            if (current["sha256"] != expectedSha256)
                throw LinuxFailure("file_conflict", "文件已被修改，请重新读取后合并更改。")
        } else if (expectedSha256 != null) {
            throw LinuxFailure("file_conflict", "文件已不存在，请重新检查工作区。")
        }
        val temporary = destination.parent.resolve(".perant-write-${UUID.randomUUID()}")
        try {
            FileChannel.open(temporary, setOf<OpenOption>(CREATE_NEW, WRITE, NOFOLLOW_LINKS),
                PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------"))).use { channel ->
                val buffer = ByteBuffer.wrap(bytes)
                while (buffer.hasRemaining()) channel.write(buffer)
                channel.force(true)
            }
            if (existed) {
                // The runtime lock excludes all guest and host file operations during this replacement.
                Files.move(temporary, destination, ATOMIC_MOVE, REPLACE_EXISTING)
            } else {
                // Android can deny hard links in app data. renameat2(NOREPLACE)
                // publishes complete bytes atomically without overwriting a racing destination.
                try { publishNewFile(temporary, destination) }
                catch (_: java.nio.file.FileAlreadyExistsException) {
                    throw LinuxFailure("file_conflict", "文件已存在，没有覆盖原文件。")
                }
            }
        } finally { Files.deleteIfExists(temporary) }
        return readFile(destination, guest)
    }

    fun createDirectory(path: String) {
        val guest = WorkspaceFileContract.path(path, allowRoot = false)
        val directory = resolve(guest, allowMissingLeaf = true)
        try {
            Files.createDirectory(directory, PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")))
        } catch (_: java.nio.file.FileAlreadyExistsException) {
            throw LinuxFailure("file_conflict", "同名文件或文件夹已存在。")
        }
    }

    private fun readFile(path: Path, guest: String): Map<String, Any> {
        if (!Files.isRegularFile(path, NOFOLLOW_LINKS) || links(path) != 1L)
            throw LinuxFailure("unsupported_file", "只支持工作区中的普通文件，不读取链接或设备文件。")
        val bytes = FileChannel.open(path, setOf<OpenOption>(READ, NOFOLLOW_LINKS)).use { channel ->
            if (channel.size() > WorkspaceFileContract.MAX_BYTES)
                throw LinuxFailure("file_too_large", "文本文件不能超过 256 KiB。")
            val output = ByteArrayOutputStream()
            val buffer = ByteBuffer.allocate(8192)
            while (true) {
                buffer.clear()
                val count = channel.read(buffer)
                if (count < 0) break
                if (output.size() + count > WorkspaceFileContract.MAX_BYTES)
                    throw LinuxFailure("file_too_large", "文本文件不能超过 256 KiB。")
                output.write(buffer.array(), 0, count)
            }
            output.toByteArray()
        }
        val content = try {
            UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: java.nio.charset.CharacterCodingException) {
            throw LinuxFailure("unsupported_file", "此文件不是有效的 UTF-8 文本。")
        }
        if ('\u0000' in content) throw LinuxFailure("unsupported_file", "此文件包含二进制内容。")
        return mapOf("path" to guest, "content" to content, "sha256" to sha256(bytes), "sizeBytes" to bytes.size)
    }

    private fun resolve(guest: String, allowMissingLeaf: Boolean): Path {
        var current = workspace.toPath()
        requireDirectory(current)
        val components = guest.removePrefix("/workspace").removePrefix("/")
            .takeIf { it.isNotEmpty() }?.split('/') ?: emptyList()
        components.forEachIndexed { index, component ->
            current = current.resolve(component)
            if (index < components.lastIndex) requireDirectory(current)
            else if (Files.isSymbolicLink(current)) throw LinuxFailure("invalid_path", "工作区路径不能使用符号链接。")
            else if (!allowMissingLeaf && !Files.exists(current, NOFOLLOW_LINKS))
                throw LinuxFailure("file_not_found", "工作区文件或文件夹不存在。")
        }
        return current
    }

    private fun requireDirectory(path: Path) {
        if (!Files.isDirectory(path, NOFOLLOW_LINKS))
            throw LinuxFailure("invalid_path", "工作区路径不是可用的普通文件夹。")
    }

    private fun links(path: Path): Long = (Files.getAttribute(path, "unix:nlink", NOFOLLOW_LINKS) as Number).toLong()

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 255) }
}

private fun publishNewWorkspaceFile(source: Path, destination: Path) {
    when (NativePty.renameNoReplace(source.toString(), destination.toString())) {
        0 -> Unit
        17 -> throw java.nio.file.FileAlreadyExistsException(destination.toString()) // Linux EEXIST.
        else -> throw LinuxFailure("storage_error", "设备无法以不覆盖方式原子发布文件，原有文件未被覆盖。")
    }
}

internal object WorkspaceFileContract {
    const val MAX_BYTES = 262144
    const val MAX_ENTRIES = 500

    fun path(value: String, allowRoot: Boolean = true): String {
        val bytes = strictUtf8(value)
        require(bytes.size in 1..1024 && value.none {
            it.code < 32 || it.code in 127..159 || it == '\\' || it == '\u2028' || it == '\u2029'
        }) { "Invalid workspace path." }
        if (value == "/workspace") {
            require(allowRoot) { "Expected a file path." }
            return value
        }
        val relative = if (value.startsWith("/workspace/")) value.removePrefix("/workspace/") else value
        require(!relative.startsWith('/')) { "Path must stay in /workspace." }
        val parts = relative.split('/')
        require(parts.size <= 32 && parts.all {
            it.isNotEmpty() && it != "." && it != ".." && visibleName(it) && strictUtf8(it).size <= 255
        }) { "Invalid workspace path components." }
        return "/workspace/$relative"
    }

    fun visibleName(value: String): Boolean = value != ".perant-tasks" && !value.startsWith(".perant-write-")

    fun content(value: String): ByteArray {
        require('\u0000' !in value) { "Text must not contain NUL." }
        val bytes = strictUtf8(value)
        require(bytes.size <= MAX_BYTES) { "Text exceeds its byte quota." }
        return bytes
    }

    private fun strictUtf8(value: String): ByteArray {
        val buffer = UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).encode(CharBuffer.wrap(value))
        return ByteArray(buffer.remaining()).also { buffer.get(it) }
    }
}
