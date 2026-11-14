// SPDX-License-Identifier: GPL-3.0-only
package dev.perant.platform

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

internal class LinuxBootstrapCleanupFailure(val completion: CountDownLatch) : IOException("Linux bootstrap cleanup is not yet confirmed; staging is retained.")

/** Bounded, noninteractive bootstrap before a staged rootfs is published. */
internal class LinuxBootstrap(private val proot: File, private val loader: File, private val rootfs: File, private val temporary: File) {
    fun run(arguments: List<String>, timeoutSeconds: Long): String {
        val argv = listOf(proot.absolutePath, "-0", "--link2symlink", "--kill-on-exit",
            "-r", rootfs.absolutePath, "-b", "/dev", "-b", "/proc", "-b", "/sys", "-w", "/") + arguments
        val env = arrayOf("HOME=/root", "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "LANG=C.UTF-8", "LC_ALL=C.UTF-8", "TZ=UTC", "TERM=dumb", "TMPDIR=/tmp",
            "PROOT_TMP_DIR=${temporary.absolutePath}", "PROOT_LOADER=${loader.absolutePath}")
        val process = NativePty.spawn(argv.toTypedArray(), env, rootfs.absolutePath, 100, 30)
        val descriptor = process[0]
        val pid = process[1]
        val exited = CountDownLatch(1)
        val readDone = CountDownLatch(1)
        val stopReading = AtomicBoolean(false)
        val output = ByteArrayOutputStream()
        val exitCode = AtomicInteger(-1)
        thread(name = "perant-bootstrap-wait", isDaemon = true) {
            try { exitCode.set(NativePty.waitFor(pid)) } finally { exited.countDown() }
        }
        thread(name = "perant-bootstrap-read", isDaemon = true) {
            try {
                var idleAfterExit = 0
                while (!stopReading.get()) {
                    val bytes = NativePty.read(descriptor, 8192)
                    if (bytes == null) {
                        if (exited.count == 0L && ++idleAfterExit >= 5) break
                        continue
                    }
                    if (bytes.isEmpty()) break
                    // Always drain, retain only bounded diagnostics of public
                    // package names. No private task data exists in bootstrap.
                    if (output.size() < 32768) output.write(bytes, 0, minOf(bytes.size, 32768 - output.size()))
                }
            } catch (_: Exception) { /* Exit status and self-check determine success. */ }
            finally { NativePty.close(descriptor); readDone.countDown() }
        }
        try {
            if (!exited.await(timeoutSeconds, TimeUnit.SECONDS)) {
                NativePty.signal(pid, 15, false)
                NativePty.signal(pid, 15, true)
                if (!exited.await(800, TimeUnit.MILLISECONDS)) {
                    NativePty.signal(pid, 9, true)
                    NativePty.signal(pid, 9, false)
                    if (!exited.await(2, TimeUnit.SECONDS)) throw LinuxBootstrapCleanupFailure(exited)
                }
                throw IOException("Offline Linux bootstrap timed out.")
            }
            readDone.await(1, TimeUnit.SECONDS)
            if (exitCode.get() != 0) throw IOException("Offline Linux bootstrap failed (exit ${exitCode.get()}): " + output.toString("UTF-8").takeLast(4000))
            return output.toString("UTF-8")
        } finally {
            stopReading.set(true)
            readDone.await(250, TimeUnit.MILLISECONDS)
        }
    }
}
