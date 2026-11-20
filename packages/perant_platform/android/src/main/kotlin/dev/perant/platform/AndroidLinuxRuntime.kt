// SPDX-License-Identifier: GPL-3.0-only
package dev.perant.platform

import android.content.Context
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.InputStreamReader
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

internal class LinuxFailure(val code: String, message: String) : Exception(message)

/** One foreground-owned guest process. This is not a security sandbox or daemon. */
internal class AndroidLinuxRuntime(context: Context, private val emit: (Map<String, Any>) -> Unit) {
    private val environment = LinuxEnvironment(context.applicationContext)
    private val desktopCache = context.applicationContext.cacheDir
    private val textTasks = LinuxTextTasks(environment.workspace)
    private val workspaceFiles = LinuxWorkspaceFiles(environment.workspace)
    private val workspaceImport = LinuxWorkspaceImport(environment.workspace, environment.importStaging)
    private val lock = Any()
    private val workers = Executors.newCachedThreadPool { task ->
        Thread(task, "perant-linux-io").apply { isDaemon = true }
    }
    private val input = Executors.newSingleThreadExecutor { task ->
        Thread(task, "perant-linux-input").apply { isDaemon = true }
    }
    private val timer = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "perant-linux-timeout").apply { isDaemon = true }
    }
    @Volatile private var active: GuestProcess? = null
    @Volatile private var initializing = false
    @Volatile private var disposed = false

    fun status(): Map<String, Any?> {
        val supported = environment.supported && NativePty.available
        val installed = supported && environment.installed
        val process = active?.takeIf { !it.finished }
        val reason = when {
            !environment.supported -> environment.unavailableReason
            !NativePty.available -> "此构建的原生 PTY 桥接无法加载。"
            initializing -> "正在离线校验并解包 Alpine 环境。"
            process?.desktop != null -> "Linux 图形桌面运行中；普通文件读写需先暂停桌面，当前不保证后台续跑。"
            process != null -> "本地 Linux 进程运行中；当前不保证后台续跑。"
            installed -> "Alpine 已安装，可打开手动终端或已安装的图形桌面。"
            else -> "首次使用需要离线初始化 APK 内的 Alpine 环境。"
        }
        return mapOf(
            "supported" to supported, "installed" to installed,
            "workspaceAvailable" to (!disposed && NativePty.available),
            "active" to (installed && process != null),
            "sessionId" to process?.takeIf { it.interactive }?.id,
            "distribution" to environment.distribution, "version" to environment.version,
            "workspace" to "/workspace", "reason" to reason,
            "pythonAvailable" to (installed && environment.pythonAvailable),
            "pythonVersion" to environment.pythonVersion.takeIf { installed && environment.pythonAvailable },
            "desktopAvailable" to (installed && environment.desktopAvailable),
            "desktopVersion" to environment.desktopVersion.takeIf { installed && environment.desktopAvailable },
            "desktopSessionId" to process?.takeIf { it.desktop != null }?.id
        )
    }

    fun initialize(): Map<String, Any?> {
        synchronized(lock) {
            ensureSupported()
            if (initializing || active != null) throw LinuxFailure("busy", "请先结束当前 Linux 会话。")
            initializing = true
        }
        try {
            environment.initialize()
            if (disposed) throw LinuxFailure("unavailable", "原生运行时已经关闭。")
        } finally { initializing = false }
        return status()
    }

    fun startSession(id: String, columns: Int, rows: Int): Map<String, Any> {
        val process = start(id, true, null, columns, rows, null)
        return mapOf("sessionId" to id, "pid" to process.pid, "workspace" to "/workspace")
    }

    fun startDesktop(id: String, width: Int, height: Int): Map<String, Any> {
        val launch: LinuxDesktopLaunch
        val process: GuestProcess
        synchronized(lock) {
            ensureSupported()
            val existing = active?.takeIf { it.desktop != null && it.desktopReady && !it.finished && it.exitCode == null }
            if (existing != null) return existing.desktop!!.result(existing.id, existing.pid)
            if (initializing || active != null) throw LinuxFailure("busy", "请先关闭当前终端或图形桌面。")
            if (!environment.installed || !environment.desktopAvailable)
                throw LinuxFailure("not_installed", "请先初始化包含图形桌面的本地 Linux 环境。")
            environment.verifyDesktopTool()
            launch = LinuxDesktopLaunch.create(desktopCache, width, height)
            process = try { start(id, false, launch.command, 80, 24, null, launch) }
                catch (failure: Throwable) { launch.clean(); throw failure }
        }
        // Startup stays on the FIFO control executor. A later stop cannot
        // acknowledge idle before a late Xvnc starts. The fixed script confirms
        // mapped shell windows; a real RFB banner also verifies its transport.
        // Allow cold font/icon caches to settle on slower Android devices.
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(45)
        try {
            while (System.nanoTime() < deadline) {
                if (disposed || process.finished || process.exitCode != null) break
                if (launch.ready()) {
                    synchronized(lock) {
                        if (active !== process || process.exitCode != null || disposed)
                            throw LinuxFailure("desktop_start_failed", "Linux 图形桌面已退出。")
                        process.desktopReady = true
                    }
                    return launch.result(id, process.pid)
                }
                Thread.sleep(100)
            }
            val probe = launch.readinessFailure ?: "RFB socket not observed"
            val startup = process.desktopStartupOutput()
            throw LinuxFailure("desktop_start_failed", "Linux 图形桌面未就绪。检查：$probe\n固定启动脚本输出：\n$startup")
        } catch (failure: Throwable) {
            terminate(process)
            throw failure
        }
    }

    fun desktopSession(): Map<String, Any>? = synchronized(lock) {
        val process = active?.takeIf { it.desktop != null && it.desktopReady && !it.finished && it.exitCode == null }
            ?: return@synchronized null
        process.desktop!!.result(process.id, process.pid)
    }

    fun stopDesktop(id: String) {
        val process = active ?: return
        if (process.id != id || process.desktop == null)
            throw LinuxFailure("session_mismatch", "当前 Linux 进程不属于此图形桌面。")
        terminate(process)
    }

    fun runCommand(id: String, command: String, timeoutMs: Long): Map<String, Any> {
        val process = start(id, false, command, 80, 24, timeoutMs)
        return mapOf("taskId" to id, "pid" to process.pid)
    }

    fun runTextTask(id: String, title: String, text: String, timeoutMs: Long): Map<String, Any> = synchronized(lock) {
        TextTaskContract.validateInput(id, title, text)
        ensureSupported()
        if (initializing || active != null) throw LinuxFailure("busy", "请先结束当前 Linux 任务或终端。")
        if (!environment.installed || !environment.pythonAvailable)
            throw LinuxFailure("not_installed", "请先初始化包含 Python 的本地 Linux 环境。")
        environment.verifyTextTool()
        val request = JSONObject().put("schemaVersion", 1).put("taskId", id).put("title", title).put("text", text)
        textTasks.createInput(id, request.toString().toByteArray(Charsets.UTF_8))
        // All executable and file paths are fixed; source text is only JSON.
        val directory = "/workspace/.perant-tasks/$id"
        runCommand(id, "/usr/bin/python3 -I -B /opt/perant/tools/text_to_markdown.py $directory/input.json $directory/output.md", timeoutMs)
    }

    fun readTextTask(id: String): Map<String, Any> = synchronized(lock) {
        ensureSupported()
        if (initializing || active != null) throw LinuxFailure("busy", "请先等待 Linux 进程完成清理。")
        if (!environment.installed || !environment.pythonAvailable)
            throw LinuxFailure("not_installed", "请先初始化包含 Python 的本地 Linux 环境。")
        textTasks.readResult(id)
    }

    fun listDirectory(path: String): Map<String, Any> = withIdleWorkspace { workspaceFiles.list(path) }

    fun readFile(path: String): Map<String, Any> = withIdleWorkspace { workspaceFiles.read(path) }

    fun writeFile(path: String, content: String, expectedSha256: String?, createOnly: Boolean): Map<String, Any> =
        withIdleWorkspace { workspaceFiles.write(path, content, expectedSha256, createOnly) }

    fun createDirectory(path: String) = withIdleWorkspace { workspaceFiles.createDirectory(path) }

    /** A dedicated create-only inbox operation may coexist with a ready desktop.
     * General file reads/replacements still require an idle guest.
     */
    fun importTextFile(content: String): Map<String, Any> = synchronized(lock) {
        val process = active
        val readyDesktop = process != null && process.desktop != null && process.desktopReady &&
            !process.finished && process.exitCode == null
        if (initializing || (process != null && !readyDesktop))
            throw LinuxFailure("busy", "请等待桌面启动完成，或先结束当前 Linux 任务或终端。")
        if (readyDesktop) {
            // The running guest already shares this directory. Keep the import
            // on the no-follow JNI path without preparing or chmod'ing it again.
            ensureSupported()
        } else {
            prepareWorkspace()
        }
        workspaceImport.importText(content)
    }

    private fun <T> withIdleWorkspace(action: () -> T): T = synchronized(lock) {
        if (initializing || active != null) throw LinuxFailure("busy", "请先结束当前 Linux 任务或终端，再访问共享文件。")
        prepareWorkspace()
        action()
    }

    private fun prepareWorkspace() {
        if (disposed || !NativePty.available) throw LinuxFailure("unavailable", "本地文件工作区不可用。")
        environment.prepareWorkspace()
    }

    private fun start(id: String, interactive: Boolean, command: String?, columns: Int, rows: Int, timeoutMs: Long?, desktop: LinuxDesktopLaunch? = null): GuestProcess {
        synchronized(lock) {
            ensureSupported()
            if (initializing || active != null) throw LinuxFailure("busy", "已有 Linux 进程占用工作区，请先关闭或取消。")
            if (!environment.installed) throw LinuxFailure("not_installed", "请先初始化本地 Linux 环境。")
            environment.verifyExecutables()
            val temp = File(environment.tmpRoot, UUID.randomUUID().toString()).apply {
                if (!mkdirs()) throw LinuxFailure("storage_error", "无法创建 Linux 临时目录。")
            }
            val argv = mutableListOf(
                environment.proot.absolutePath, "-0", "--link2symlink", "--kill-on-exit",
                "-r", environment.rootfs.absolutePath,
                "-b", "/dev", "-b", "/proc", "-b", "/sys",
                "-b", "${environment.workspace.absolutePath}:/workspace"
            )
            if (desktop != null) argv.addAll(listOf(
                "-b", "${desktop.directory.absolutePath}:/run/perant-desktop",
                "-b", "${desktop.temporary.absolutePath}:/tmp"
            ))
            argv.addAll(listOf("-w", "/workspace", "/bin/sh"))
            if (interactive) argv.add("-i") else argv.addAll(listOf("-c", command!!))
            // No System.getenv() inheritance. Provider credentials and app data
            // descriptors are never deliberately passed into this guest.
            val env = arrayOf(
                "HOME=/root", "SHELL=/bin/sh", "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "TERM=xterm-256color", "LANG=C.UTF-8", "LC_ALL=C.UTF-8", "TZ=UTC", "TMPDIR=/tmp",
                "PS1=perant:\\w# ", "PROOT_TMP_DIR=${temp.absolutePath}",
                "PROOT_LOADER=${environment.loader.absolutePath}"
            )
            val spawned = try {
                NativePty.spawn(argv.toTypedArray(), env, environment.workspace.absolutePath, columns, rows)
            } catch (error: Throwable) {
                temp.delete()
                throw error
            }
            val process = GuestProcess(id, interactive, spawned[0], spawned[1], temp, desktop)
            active = process
            workers.execute { readOutput(process) }
            workers.execute { waitForExit(process) }
            if (timeoutMs != null) process.timeout = timer.schedule({
                workers.execute { terminate(process, timedOut = true) }
            }, timeoutMs, TimeUnit.MILLISECONDS)
            return process
        }
    }

    // Execute all key/paste writes in arrival order. A cached worker per key
    // would reorder input under load and could run a different command.
    fun write(id: String, data: String, complete: (Throwable?) -> Unit) {
        input.execute {
            try {
                val process = requireSession(id)
                val descriptor = synchronized(process.ioLock) {
                    if (process.finished) throw LinuxFailure("not_running", "终端会话已退出。")
                    NativePty.duplicate(process.fd)
                }
                // Do not hold ioLock across a potentially blocking paste: the
                // reader must keep draining echo/output to avoid a full-PTY
                // writer/reader deadlock. This duplicate cannot be fd-reused.
                try { NativePty.write(descriptor, data.toByteArray(Charsets.UTF_8)) }
                finally { NativePty.close(descriptor) }
                complete(null)
            } catch (error: Throwable) { complete(error) }
        }
    }

    fun resize(id: String, columns: Int, rows: Int) {
        val process = requireSession(id)
        synchronized(process.ioLock) {
            if (!process.finished) NativePty.resize(process.fd, columns, rows)
        }
    }

    fun closeSession(id: String) {
        val process = active ?: return
        if (!process.interactive || process.id != id)
            throw LinuxFailure("session_mismatch", "当前工作区已属于另一个 Linux 进程，请重新检查会话。")
        terminate(process)
    }

    fun cancelTask(id: String): Map<String, String> {
        val process = active?.takeIf { !it.interactive && it.desktop == null && it.id == id && !it.finished && it.exitCode == null }
            ?: return mapOf("taskId" to id, "status" to "notRunning", "reason" to "没有此 ID 的活动 Linux 命令。")
        terminate(process)
        return if (process.cancelled) mapOf("taskId" to id, "status" to "cancelled", "reason" to "Linux 命令已终止并回收。")
        else mapOf("taskId" to id, "status" to "notRunning", "reason" to "命令已结束或超时，没有重复发送取消信号。")
    }

    private fun requireSession(id: String): GuestProcess = active?.takeIf {
        it.interactive && it.id == id && !it.finished
    } ?: throw LinuxFailure("not_running", "此终端会话已经退出。")

    private fun ensureSupported() {
        if (disposed || !environment.supported || !NativePty.available)
            throw LinuxFailure("unavailable", status()["reason"] as String)
    }

    private fun readOutput(process: GuestProcess) {
        try {
            // InputStreamReader preserves UTF-8 sequences split across PTY reads.
            InputStreamReader(object : InputStream() {
                override fun read(): Int {
                    val one = ByteArray(1)
                    return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and 255
                }
                override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                    if (length == 0) return 0
                    var idleAfterExit = 0
                    while (!process.finished) {
                        val descriptor = synchronized(process.ioLock) {
                            if (process.finished) -1 else NativePty.duplicate(process.fd)
                        }
                        if (descriptor < 0) return -1
                        // The owned duplicate prevents a racing close from
                        // exposing another file which reuses the master fd.
                        val bytes = try {
                            NativePty.read(descriptor, minOf(8192, length))
                        } finally { NativePty.close(descriptor) }
                        if (bytes == null) {
                            if (process.exitCode != null && ++idleAfterExit >= 5) return -1
                            continue
                        }
                        if (bytes.isEmpty()) return -1
                        bytes.copyInto(buffer, offset)
                        return bytes.size
                    }
                    return -1
                }
            }, Charsets.UTF_8).use { reader ->
                val buffer = CharArray(4096)
                while (true) {
                    val count = reader.read(buffer)
                    if (count < 0) break
                    if (count > 0) {
                        val text = String(buffer, 0, count)
                        process.captureDesktopStartup(text)
                        emit(event(process, "linuxOutput", mapOf("text" to text)))
                    }
                }
            }
        } catch (_: Exception) {
            if (process.exitCode == null && !disposed) {
                emit(event(process, "linuxOutput", mapOf("text" to "\r\n[PTY 输出连接中断]\r\n")))
                workers.execute { terminate(process) }
            }
        } finally { process.readerDone.countDown() }
    }

    private fun waitForExit(process: GuestProcess) {
        val code = NativePty.waitFor(process.pid)
        process.exitCode = code
        process.childDone.countDown()
        process.timeout?.cancel(false)
        process.readerDone.await(1, TimeUnit.SECONDS)
        synchronized(process.ioLock) {
            process.finished = true
            NativePty.close(process.fd)
        }
        synchronized(lock) { if (active === process) active = null }
        // Only a freshly-created, internal temp directory; never guest workspace.
        try {
            try { deleteTreeWithoutFollowingLinks(process.temp) } catch (_: Exception) { /* Keep workspace intact. */ }
            process.desktop?.clean()
            val exit = mapOf("exitCode" to code, "cancelled" to process.cancelled, "timedOut" to process.timedOut)
            emit(event(process, "linuxExit", exit))
            if (process.desktop != null) emit(event(process, "linuxDesktopExit", exit + ("sessionId" to process.id)))
        } finally { process.done.countDown() }
    }

    private fun terminate(process: GuestProcess, timedOut: Boolean = false) {
        synchronized(process.stopLock) {
            if (process.done.count == 0L) return
            if (process.exitCode == null) {
                process.cancelled = !timedOut
                process.timedOut = timedOut
                val children = descendants(process.pid)
                // TERM lets PRoot's handler kill/reap tracees, including job-control
                // groups. --kill-on-exit also covers guest shell normal exit.
                NativePty.signal(process.pid, 15, false)
                NativePty.signal(process.pid, 15, true)
                if (!process.childDone.await(800, TimeUnit.MILLISECONDS)) {
                    (children + descendants(process.pid)).distinctBy { it.pid }.forEach {
                        if (startTime(it.pid) == it.startTime) NativePty.signal(it.pid, 9, false)
                    }
                    NativePty.signal(process.pid, 9, true)
                    NativePty.signal(process.pid, 9, false)
                }
            }
            if (!process.done.await(2500, TimeUnit.MILLISECONDS))
                throw LinuxFailure("cleanup_timeout", "Linux 进程尚未确认清理完成，请重试关闭。")
        }
    }

    private data class Child(val pid: Int, val startTime: String)
    private fun descendants(root: Int): List<Child> {
        val result = mutableListOf<Child>()
        val queue = ArrayDeque<Int>().apply { add(root) }
        val visited = mutableSetOf(root)
        while (queue.isNotEmpty() && visited.size <= 512) {
            val pid = queue.removeFirst()
            val children = try { File("/proc/$pid/task/$pid/children").readText() } catch (_: Exception) { "" }
            for (text in children.trim().split(Regex("\\s+"))) {
                val child = text.toIntOrNull() ?: continue
                if (child > 0 && visited.add(child)) {
                    startTime(child)?.let { result.add(Child(child, it)) }
                    queue.add(child)
                }
            }
        }
        return result.reversed()
    }
    private fun startTime(pid: Int): String? = try {
        File("/proc/$pid/stat").readText().substringAfterLast(") ").split(' ').getOrNull(19)
    } catch (_: Exception) { null }

    private fun event(process: GuestProcess, type: String, data: Map<String, Any>): Map<String, Any> {
        val payload = data.toMutableMap()
        if (process.interactive) payload["sessionId"] = process.id
        val event = mutableMapOf<String, Any>(
            "type" to type, "emittedAtEpochMs" to System.currentTimeMillis(), "payload" to payload
        )
        if (!process.interactive) event["taskId"] = process.id
        return event
    }

    fun closeActive(includeDesktop: Boolean = true) = synchronized(lock) {
        if (!workers.isShutdown) active?.takeIf { includeDesktop || it.desktop == null }?.let {
            workers.execute { try { terminate(it) } catch (_: Exception) {} }
        }
    }
    fun dispose() {
        // Serialize against spawn so an engine detach cannot shut down the
        // waiter pool between fork and registration, orphaning a new process.
        synchronized(lock) {
            disposed = true
            closeActive()
            timer.shutdownNow()
            input.shutdown()
            workers.shutdown()
        }
    }

    private class GuestProcess(val id: String, val interactive: Boolean, val fd: Int, val pid: Int, val temp: File, val desktop: LinuxDesktopLaunch? = null) {
        val ioLock = Any()
        val stopLock = Any()
        val childDone = CountDownLatch(1)
        val readerDone = CountDownLatch(1)
        val done = CountDownLatch(1)
        @Volatile var exitCode: Int? = null
        @Volatile var finished = false
        @Volatile var desktopReady = false
        @Volatile var cancelled = false
        @Volatile var timedOut = false
        @Volatile var timeout: ScheduledFuture<*>? = null
        private val startupOutput = ByteArrayOutputStream()
        fun captureDesktopStartup(text: String) {
            if (desktop == null || desktopReady) return
            synchronized(startupOutput) {
                val remaining = 8192 - startupOutput.size()
                if (remaining <= 0) return
                val bytes = text.toByteArray(Charsets.UTF_8)
                startupOutput.write(bytes, 0, minOf(remaining, bytes.size))
            }
        }
        fun desktopStartupOutput(): String = synchronized(startupOutput) {
            // Only the fixed startup interval, before clients can type. Never
            // retain a user's later desktop/terminal output or credentials.
            String(startupOutput.toByteArray(), Charsets.UTF_8).filter {
                it == '\n' || it == '\t' || (it.code >= 32 && it.code != 127)
            }.ifBlank { "(无启动输出)" }
        }
    }
}

// A guest can create symlinks in its temporary directory. Cleanup must not walk
// those links into workspace, app data or the Android filesystem.
internal fun deleteTreeWithoutFollowingLinks(root: File) {
    if (!root.exists() && !java.nio.file.Files.isSymbolicLink(root.toPath())) return
    java.nio.file.Files.walkFileTree(root.toPath(), object : java.nio.file.SimpleFileVisitor<java.nio.file.Path>() {
        override fun visitFile(file: java.nio.file.Path, attrs: java.nio.file.attribute.BasicFileAttributes): java.nio.file.FileVisitResult {
            java.nio.file.Files.deleteIfExists(file)
            return java.nio.file.FileVisitResult.CONTINUE
        }
        override fun postVisitDirectory(directory: java.nio.file.Path, error: java.io.IOException?): java.nio.file.FileVisitResult {
            java.nio.file.Files.deleteIfExists(directory)
            return java.nio.file.FileVisitResult.CONTINUE
        }
    })
}
