// SPDX-License-Identifier: GPL-3.0-only
package dev.perant.platform

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Native capability reports and foreground Linux PTY lifecycle. */
class PerantPlatformPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler, ActivityAware {
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var browserMethods: MethodChannel? = null
    private var pdfMethods: MethodChannel? = null
    private var browser: ComputerBrowserRuntime? = null
    private var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private lateinit var linux: AndroidLinuxRuntime
    private lateinit var dataDirectory: java.io.File
    // MethodChannel receives lifecycle requests in order. Keep that order even
    // when Dart times out waiting for start: its subsequent close must run
    // after that start, never acknowledge an empty runtime before a late fork.
    // PTY input, output and waitpid use their own runtime executors.
    private var work = Executors.newSingleThreadExecutor()
    @Volatile private var attached = false
    private val eventLock = Any()
    private val pending = ArrayDeque<Map<String, Any>>()
    private var drainPosted = false
    private var droppedOutput = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = true
        dataDirectory = binding.applicationContext.filesDir
        pdfMethods = MethodChannel(binding.binaryMessenger, "dev.perant/pdf",
            io.flutter.plugin.common.StandardMethodCodec.INSTANCE, binding.binaryMessenger.makeBackgroundTaskQueue()).also {
            it.setMethodCallHandler(PdfMaterials(binding.applicationContext))
        }
        if (work.isShutdown) work = Executors.newSingleThreadExecutor()
        linux = AndroidLinuxRuntime(binding.applicationContext, ::enqueue)
        binding.platformViewRegistry.registerViewFactory("dev.perant/html-preview", StaticHtmlPreviewFactory())
        val browserRuntime = ComputerBrowserRuntime(binding.applicationContext)
        browser = browserRuntime
        binding.platformViewRegistry.registerViewFactory("dev.perant/computer-browser", ComputerBrowserFactory(browserRuntime))
        browserMethods = MethodChannel(binding.binaryMessenger, "dev.perant/browser").also { it.setMethodCallHandler(browserRuntime) }
        methods = MethodChannel(binding.binaryMessenger, "dev.perant/runtime").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "dev.perant/runtime/events").also { it.setStreamHandler(this) }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        pdfMethods?.setMethodCallHandler(null)
        pdfMethods = null
        browserMethods?.setMethodCallHandler(null)
        browser?.dispose(); browser = null; browserMethods = null
        linux.dispose()
        work.shutdown()
        methods?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        sink = null
        synchronized(eventLock) { pending.clear(); drainPosted = false }
        methods = null; events = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) { browser?.attachActivity(binding.activity) }
    override fun onDetachedFromActivityForConfigChanges() { browser?.detachActivity() }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { browser?.attachActivity(binding.activity) }
    override fun onDetachedFromActivity() { browser?.detachActivity() }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            // Pending operations belong to this engine, including during an
            // engine detach/reattach which replaces the plugin's runtime.
            val runtime = linux
            val arguments = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
            when (call.method) {
                "getCapabilities" -> result.success(capabilities())
                "getAvailableStorageBytes" -> result.success(android.os.StatFs(dataDirectory.path).availableBytes)
                "getLinuxStatus" -> result.success(runtime.status())
                "initializeLinux" -> async(result, true) { runtime.initialize() }
                "getLinuxDesktopSession" -> async(result) { runtime.desktopSession() }
                "startLinuxDesktop" -> {
                    val id = id(arguments, "sessionId")
                    val width = integer(arguments, "width", 640, 1600)
                    val height = integer(arguments, "height", 480, 1200)
                    require(width.toLong() * height <= 1_920_000L) { "desktop size" }
                    async(result) { runtime.startDesktop(id, width, height) }
                }
                "stopLinuxDesktop" -> {
                    val id = id(arguments, "sessionId")
                    async(result) { runtime.stopDesktop(id); null }
                }
                "startLinuxSession" -> {
                    val id = id(arguments, "sessionId")
                    val columns = integer(arguments, "columns", 1, 500)
                    val rows = integer(arguments, "rows", 1, 500)
                    async(result) { runtime.startSession(id, columns, rows) }
                }
                "runLinuxCommand" -> {
                    val id = id(arguments, "taskId")
                    val command = text(arguments, "command")
                    require(command.isNotBlank() && '\u0000' !in command) { "Invalid command." }
                    val timeout = integer(arguments, "timeoutMs", 1, 300000).toLong()
                    async(result) { runtime.runCommand(id, command, timeout) }
                }
                "startLinuxTextTask" -> {
                    val id = id(arguments, "taskId")
                    val title = arguments["title"] as? String ?: throw IllegalArgumentException("title")
                    val source = arguments["text"] as? String ?: throw IllegalArgumentException("text")
                    TextTaskContract.validateInput(id, title, source)
                    val timeout = integer(arguments, "timeoutMs", 1, 300000).toLong()
                    async(result) { runtime.runTextTask(id, title, source, timeout) }
                }
                "readLinuxTextTaskResult" -> {
                    val id = id(arguments, "taskId")
                    TextTaskContract.validateId(id)
                    async(result) { runtime.readTextTask(id) }
                }
                "listLinuxDirectory" -> {
                    val path = workspacePath(arguments)
                    async(result) { runtime.listDirectory(path) }
                }
                "readLinuxFile" -> {
                    val path = workspacePath(arguments, allowRoot = false)
                    async(result) { runtime.readFile(path) }
                }
                "writeLinuxFile" -> {
                    val path = workspacePath(arguments, allowRoot = false)
                    val content = arguments["content"] as? String ?: throw IllegalArgumentException("content")
                    WorkspaceFileContract.content(content)
                    val expected = arguments["expectedSha256"]
                    require(expected == null || expected is String && Regex("[0-9a-f]{64}").matches(expected)) { "expectedSha256" }
                    val createOnly = arguments["createOnly"] as? Boolean ?: throw IllegalArgumentException("createOnly")
                    require(!createOnly || expected == null) { "Conflicting write conditions." }
                    async(result) { runtime.writeFile(path, content, expected as String?, createOnly) }
                }
                "createLinuxDirectory" -> {
                    val path = workspacePath(arguments, allowRoot = false)
                    async(result) { runtime.createDirectory(path); null }
                }
                "importLinuxTextFile" -> {
                    val content = arguments["content"] as? String ?: throw IllegalArgumentException("content")
                    WorkspaceFileContract.content(content)
                    async(result) { runtime.importTextFile(content) }
                }
                "writeLinuxSession" -> {
                    val id = id(arguments, "sessionId")
                    val data = text(arguments, "data")
                    runtime.write(id, data) { error -> main.post {
                        if (attached) { if (error == null) result.success(null) else failure(result, error) }
                    } }
                }
                "resizeLinuxSession" -> {
                    val id = id(arguments, "sessionId")
                    val columns = integer(arguments, "columns", 1, 500)
                    val rows = integer(arguments, "rows", 1, 500)
                    async(result) { runtime.resize(id, columns, rows); null }
                }
                "closeLinuxSession" -> {
                    val id = id(arguments, "sessionId")
                    async(result) { runtime.closeSession(id); null }
                }
                "cancelTask" -> {
                    val id = id(arguments, "taskId")
                    async(result) { runtime.cancelTask(id) }
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) { failure(result, error) }
    }
    private fun async(result: MethodChannel.Result, initializing: Boolean = false, action: () -> Any?) {
        work.execute {
            try {
                val value = action()
                main.post { if (attached) result.success(value) }
            } catch (error: Exception) { main.post { if (attached) failure(result, error, initializing) } }
        }
    }
    private fun failure(result: MethodChannel.Result, error: Throwable, initializing: Boolean = false) {
        // Initialization handles only our pinned public resources, never user
        // commands or credentials; keep failures diagnosable on test devices.
        if (initializing) Log.e("PerAntLinux", "Bundled runtime initialization failed", error)
        val code = when (error) {
            is LinuxFailure -> error.code
            is IllegalArgumentException -> "invalid_arguments"
            else -> if (initializing) "initialization_failed" else "linux_error"
        }
        // No command, environment or credentials in exception details.
        val message = when (error) {
            is LinuxFailure -> error.message ?: "Linux 请求失败。"
            is IllegalArgumentException -> "Linux 请求参数无效。"
            else -> if (initializing) "Linux 初始化失败，请检查存储空间与资源完整性。" else "Linux 运行请求失败，请关闭会话后重试。"
        }
        result.error(code, message, null)
    }
    private fun id(arguments: Map<*, *>, key: String): String {
        val value = arguments[key] as? String ?: throw IllegalArgumentException(key)
        require(value.isNotBlank() && value.length <= 128) { key }
        return value
    }
    private fun workspacePath(arguments: Map<*, *>, allowRoot: Boolean = true): String =
        WorkspaceFileContract.path(arguments["path"] as? String ?: throw IllegalArgumentException("path"), allowRoot)
    private fun integer(arguments: Map<*, *>, key: String, minimum: Int, maximum: Int): Int {
        val value = arguments[key] as? Int ?: throw IllegalArgumentException(key)
        require(value in minimum..maximum) { key }
        return value
    }
    private fun text(arguments: Map<*, *>, key: String): String {
        val value = arguments[key] as? String ?: throw IllegalArgumentException(key)
        require(value.toByteArray(Charsets.UTF_8).size <= 65536) { key }
        return value
    }
    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
        sink = eventSink
        eventSink.success(mapOf("type" to "bridgeAttached", "emittedAtEpochMs" to System.currentTimeMillis(), "payload" to capabilities()))
        synchronized(eventLock) { postDrain() }
    }
    override fun onCancel(arguments: Any?) {
        sink = null
        val runtime = linux
        // A subscriber may disappear while start is still queued. Schedule
        // cleanup after all already-received starts rather than observing an
        // empty runtime now and allowing an orphaned shell to appear later.
        // Explicitly owned desktop sessions survive Flutter hot restart and
        // page changes; engine detach still stops every child via dispose().
        if (!work.isShutdown) work.execute { runtime.closeActive(includeDesktop = false) }
    }
    // Bound main-thread backlog even for `yes` or a disconnected subscriber.
    // Exit events survive truncation; a visible notice replaces dropped output.
    private fun enqueue(event: Map<String, Any>) {
        if (!attached) return
        synchronized(eventLock) {
            while (pending.size >= 128) {
                val iterator = pending.iterator()
                var removed = false
                while (iterator.hasNext()) {
                    if (iterator.next()["type"] == "linuxOutput") { iterator.remove(); removed = true; droppedOutput = true; break }
                }
                if (!removed) break
            }
            pending.addLast(event)
            postDrain()
        }
    }
    private fun postDrain() {
        if (sink == null || drainPosted || pending.isEmpty()) return
        drainPosted = true
        main.post {
            synchronized(eventLock) {
                drainPosted = false
                val current = sink ?: return@synchronized
                repeat(minOf(32, pending.size)) {
                    val event = pending.removeFirst()
                    if (droppedOutput && event["type"] == "linuxOutput") {
                        val payload = (event["payload"] as Map<*, *>).toMutableMap()
                        payload["text"] = "\r\n[输出过快，较早内容已截断]\r\n${payload["text"]}"
                        current.success(event + ("payload" to payload))
                        droppedOutput = false
                    } else current.success(event)
                }
                postDrain()
            }
        }
    }
    private fun capabilities(): Map<String, Any> {
        val status = linux.status()
        return mapOf(
            "schemaVersion" to 1, "platform" to "android",
            "systemVersion" to "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
            "nativeBridgeAvailable" to true,
            "linux" to mapOf("available" to (status["supported"] == true), "reason" to status["reason"]!!),
            "localInference" to unavailable("llama.cpp 与本地模型尚未接入此构建。"),
            "backgroundTasks" to unavailable("尚未注册和验证 Android 后台任务服务。")
        )
    }
    private fun unavailable(reason: String): Map<String, Any> = mapOf("available" to false, "reason" to reason)
}
