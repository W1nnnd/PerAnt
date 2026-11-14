// SPDX-License-Identifier: GPL-3.0-only
package dev.perant.platform

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.attribute.PosixFilePermissions
import java.security.MessageDigest
import java.util.UUID

/** Create-only text publication, separate from the idle workspace editor.
 *
 * A receipt describes the bytes atomically published by this request. An active
 * desktop may subsequently edit or remove that file; this is not a read-back.
 */
internal class LinuxWorkspaceImport(
    private val workspace: File,
    private val staging: File,
    private val publish: (String, String, String, ByteArray) -> Int = NativePty::publishWorkspaceText,
    private val identifier: () -> String = { UUID.randomUUID().toString() }
) {
    fun importText(content: String): Map<String, Any> {
        val bytes = WorkspaceFileContract.content(content)
        val name = "web-${identifier()}.md"
        require(WorkspaceImportContract.validName(name)) { "Invalid generated import name." }
        prepareStaging()
        when (publish(workspace.absolutePath, staging.absolutePath, name, bytes)) {
            0 -> Unit
            17 -> throw LinuxFailure("file_conflict", "同名文件已存在，未覆盖原文件。")
            else -> throw LinuxFailure("storage_error", "网页资料未能保存，请检查工作区后重试。")
        }
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        return mapOf("path" to "/workspace/$name", "sizeBytes" to bytes.size, "sha256" to digest)
    }

    private fun prepareStaging() {
        val destination = workspace.toPath().toAbsolutePath().normalize()
        val source = staging.toPath().toAbsolutePath().normalize()
        require(!source.startsWith(destination)) { "Import staging must not be in the shared workspace." }
        try {
            Files.createDirectory(source,
                PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")))
        } catch (_: java.nio.file.FileAlreadyExistsException) { /* Checked without following below. */ }
        if (!Files.isDirectory(source, NOFOLLOW_LINKS))
            throw LinuxFailure("storage_error", "网页资料暂存目录不可用。")
    }
}

internal object WorkspaceImportContract {
    fun validName(value: String): Boolean =
        Regex("web-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.md").matches(value)

}
