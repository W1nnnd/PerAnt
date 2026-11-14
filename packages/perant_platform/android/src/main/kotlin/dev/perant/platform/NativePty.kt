// SPDX-License-Identifier: GPL-3.0-only
package dev.perant.platform

internal object NativePty {
    val available: Boolean = try {
        System.loadLibrary("perant_pty")
        true
    } catch (_: LinkageError) {
        false
    }

    @JvmStatic external fun spawn(argv: Array<String>, env: Array<String>, cwd: String, columns: Int, rows: Int): IntArray
    @JvmStatic external fun read(fd: Int, maximum: Int): ByteArray?
    @JvmStatic external fun write(fd: Int, data: ByteArray)
    @JvmStatic external fun resize(fd: Int, columns: Int, rows: Int)
    @JvmStatic external fun waitFor(pid: Int): Int
    @JvmStatic external fun signal(pid: Int, signal: Int, group: Boolean)
    @JvmStatic external fun close(fd: Int)
    @JvmStatic external fun duplicate(fd: Int): Int
    /** Returns zero or an errno. Never falls back to overwriting an existing file. */
    @JvmStatic external fun renameNoReplace(source: String, destination: String): Int
    /** Atomically publishes a generated root-only text file; zero or an errno. */
    @JvmStatic external fun publishWorkspaceText(workspace: String, staging: String, name: String, bytes: ByteArray): Int
}
