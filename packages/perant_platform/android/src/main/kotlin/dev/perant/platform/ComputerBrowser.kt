// SPDX-License-Identifier: GPL-3.0-only
package dev.perant.platform

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.MutableContextWrapper
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.net.http.SslError
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.security.NetworkSecurityPolicy
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewConfiguration
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputConnectionWrapper
import android.view.inputmethod.TextAttribute
import android.view.inputmethod.CompletionInfo
import android.view.inputmethod.CorrectionInfo
import android.view.inputmethod.InputContentInfo
import android.webkit.GeolocationPermissions
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebResourceError
import android.webkit.JsResult
import android.webkit.JsPromptResult
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.URI
import java.net.URL
import java.lang.ref.WeakReference
import kotlin.math.roundToInt

internal class ComputerBrowserFailure(val code: String, message: String) : Exception(message)

/** Pure contracts are also exercised by JVM tests, independently of WebView. */
internal object ComputerBrowserContract {
    const val MAX_PNG = 2 * 1024 * 1024
    const val MAX_PAGE_CHARACTERS = 120000
    const val MAX_PAGE_BYTES = 240 * 1024
    fun id(value: String): String {
        require(Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,127}").matches(value)) { "id" }
        return value
    }
    fun url(value: String): String {
        require(value.length in 1..8192 && value.none { it.code <= 32 || it.code == 127 }) { "url" }
        if (value == "about:blank") return value
        val uri = try { URI(value) } catch (_: Exception) { throw IllegalArgumentException("url") }
        require(uri.scheme?.lowercase() in setOf("http", "https") && !uri.isOpaque) { "url" }
        val parsed = URL(value)
        require(parsed.host.isNotBlank() && parsed.userInfo == null &&
            (parsed.port == -1 || parsed.port in 1..65535)) { "url" }
        return value
    }
    fun dimensions(width: Int, height: Int) {
        require(width in 1..1600 && height in 1..1200 && width.toLong() * height <= 1_920_000L) { "size" }
    }
    fun viewport(width: Int, height: Int) {
        require(width in 1..8192 && height in 1..8192) { "viewport" }
    }
    fun frameSize(width: Int, height: Int): Pair<Int, Int> {
        viewport(width, height)
        val scale = minOf(1.0, 1600.0 / width, 1200.0 / height)
        return (width * scale).toInt().coerceAtLeast(1) to (height * scale).toInt().coerceAtLeast(1)
    }
    fun coordinate(value: Int, source: Int, target: Int): Float {
        require(source > 0 && target > 0 && value in 0 until source) { "coordinate" }
        return (value.toDouble() * target / source).toFloat().coerceAtMost((target - 1).toFloat())
    }
    fun text(value: String) {
        require('\u0000' !in value && value.toByteArray(Charsets.UTF_8).size <= 16384) { "text" }
    }
    fun key(value: String): Int {
        val normalized = value.lowercase()
        return when (normalized) {
            "enter", "return" -> KeyEvent.KEYCODE_ENTER
            "tab" -> KeyEvent.KEYCODE_TAB
            "backspace" -> KeyEvent.KEYCODE_DEL
            "delete" -> KeyEvent.KEYCODE_FORWARD_DEL
            "escape", "esc" -> KeyEvent.KEYCODE_ESCAPE
            "arrowleft", "left" -> KeyEvent.KEYCODE_DPAD_LEFT
            "arrowright", "right" -> KeyEvent.KEYCODE_DPAD_RIGHT
            "arrowup", "up" -> KeyEvent.KEYCODE_DPAD_UP
            "arrowdown", "down" -> KeyEvent.KEYCODE_DPAD_DOWN
            "home" -> KeyEvent.KEYCODE_MOVE_HOME
            "end" -> KeyEvent.KEYCODE_MOVE_END
            "pageup" -> KeyEvent.KEYCODE_PAGE_UP
            "pagedown" -> KeyEvent.KEYCODE_PAGE_DOWN
            "space", " " -> KeyEvent.KEYCODE_SPACE
            else -> when {
                normalized.length == 1 && normalized[0] in 'a'..'z' -> KeyEvent.KEYCODE_A + normalized[0].code - 'a'.code
                normalized.length == 1 && normalized[0] in '0'..'9' -> KeyEvent.KEYCODE_0 + normalized[0].code - '0'.code
                else -> throw IllegalArgumentException("key")
            }
        }
    }
    fun modifiers(values: List<String>): Int {
        require(values.size <= 4) { "modifiers" }
        return values.fold(0) { mask, value -> mask or when (value.lowercase()) {
            "ctrl", "control" -> KeyEvent.META_CTRL_ON
            "shift" -> KeyEvent.META_SHIFT_ON
            "alt" -> KeyEvent.META_ALT_ON
            "super", "meta" -> KeyEvent.META_META_ON
            else -> throw IllegalArgumentException("modifiers")
        } }
    }
    fun revision(expected: Long?, current: Long) {
        require(expected == null || expected >= 0) { "revision" }
        if (expected != null && expected != current)
            throw ComputerBrowserFailure("stale_revision", "页面已被用户或导航更新，请重新观察后操作。")
    }
    fun navigationPolicy(value: String, cleartextAllowed: (String) -> Boolean) {
        url(value)
        if (value == "about:blank") return
        val parsed = URL(value)
        val host = parsed.host.removePrefix("[").removeSuffix("]")
        if (parsed.protocol.equals("http", true) && !cleartextAllowed(host))
            throw ComputerBrowserFailure("cleartext_not_permitted", "此站点的明文 HTTP 被网络策略阻止，请使用 HTTPS。")
    }
    fun loadError(code: Int): String = when (code) {
        WebViewClient.ERROR_HOST_LOOKUP -> "无法解析网页地址，请检查网址或网络。"
        WebViewClient.ERROR_CONNECT -> "无法连接网页服务器，请稍后重试。"
        WebViewClient.ERROR_TIMEOUT -> "网页连接超时，请稍后重试。"
        WebViewClient.ERROR_FAILED_SSL_HANDSHAKE -> "网页安全连接失败，已停止加载。"
        WebViewClient.ERROR_UNSUPPORTED_SCHEME, WebViewClient.ERROR_BAD_URL -> "此网页地址暂不支持。"
        else -> "网页无法加载，请检查网络或网址。"
    }
    fun retainLoadError(errorUrl: String?, startedUrl: String?, error: String): Boolean =
        error.isNotEmpty() && (startedUrl == errorUrl || startedUrl == null ||
            runCatching { url(startedUrl) }.isFailure)
    fun preserveSpecificError(error: String, errorUrl: String?, nextErrorUrl: String): Boolean =
        error.isNotEmpty() && errorUrl == nextErrorUrl
    fun readablePage(pageUrl: String, loading: Boolean, error: String) {
        if (pageUrl == "about:blank" || loading || error.isNotEmpty())
            throw ComputerBrowserFailure("page_not_ready", "请等待网页成功加载后再保存正文。")
        url(pageUrl)
    }
    fun pageText(value: String) {
        require(value.length <= MAX_PAGE_CHARACTERS && '\u0000' !in value &&
            value.toByteArray(Charsets.UTF_8).size <= MAX_PAGE_BYTES) { "pageText" }
        var index = 0
        while (index < value.length) {
            val char = value[index++]
            if (char.isHighSurrogate()) {
                require(index < value.length && value[index].isLowSurrogate()) { "pageText" }
                index++
            } else require(!char.isLowSurrogate()) { "pageText" }
        }
        if (value.isBlank()) throw ComputerBrowserFailure("page_empty", "当前网页没有可保存的正文。")
    }
}

/**
 * Fixed top-level DOM reader, not a caller-supplied JavaScript endpoint.
 * Reads rendered body text only: no frame traversal, HTML, form fields,
 * content-editable regions, attributes, storage, or cookies. Both traversal
 * and text scanning stop at a budget; no whole-document clone/innerText copy.
 */
internal object ComputerBrowserPageReader {
    val script = """
        (function() {
          'use strict';
          var root = document.body;
          if (!root || root.isContentEditable || root.hidden || root.getAttribute('aria-hidden') === 'true')
            return {text:'', truncated:false};
          var rootStyle = getComputedStyle(root);
          if (rootStyle.display === 'none' || rootStyle.visibility === 'hidden' || rootStyle.opacity === '0')
            return {text:'', truncated:false};
          var excluded = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','FORM','INPUT',
            'TEXTAREA','SELECT','OPTION','BUTTON','IFRAME','FRAME','OBJECT','EMBED',
            'SVG','CANVAS','AUDIO','VIDEO']);
          var blocks = new Set(['ADDRESS','ARTICLE','ASIDE','BLOCKQUOTE','DD','DIV','DL',
            'DT','FIGCAPTION','FIGURE','FOOTER','H1','H2','H3','H4','H5','H6','HEADER',
            'HR','LI','MAIN','NAV','OL','P','PRE','SECTION','TABLE','TD','TH','TR','UL']);
          var visited = 0, scanned = 0, characters = 0, bytes = 0;
          var truncated = false, chunks = [], lastBlock = null;
          var deadline = performance.now() + 1500, stop = {};
          function append(value) {
            var accepted = '';
            for (var character of value) {
              var point = character.codePointAt(0);
              if (point === 0 || (point >= 55296 && point <= 57343)) {
                character = '\uFFFD'; point = 65533;
              }
              var size = point < 128 ? 1 : point < 2048 ? 2 : point < 65536 ? 3 : 4;
              if (characters + character.length > 120000 || bytes + size > 245760) {
                truncated = true; break;
              }
              accepted += character; characters += character.length; bytes += size;
            }
            if (accepted) chunks.push(accepted);
          }
          var walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
            acceptNode: function(node) {
              if (++visited > 20000 || performance.now() > deadline) {
                truncated = true; throw stop;
              }
              if (node.nodeType === Node.ELEMENT_NODE) {
                if (excluded.has(node.tagName) || node.isContentEditable || node.hidden ||
                    node.getAttribute('aria-hidden') === 'true') return NodeFilter.FILTER_REJECT;
                var style = getComputedStyle(node);
                if (style.display === 'none' || style.visibility === 'hidden' ||
                    style.visibility === 'collapse' || style.opacity === '0') return NodeFilter.FILTER_REJECT;
                return NodeFilter.FILTER_SKIP;
              }
              return NodeFilter.FILTER_ACCEPT;
            }
          });
          try { while (!truncated) {
            var node = walker.nextNode();
            if (!node || truncated) break;
            var raw = node.nodeValue || '';
            var remaining = 480000 - scanned;
            if (raw.length > remaining) { raw = raw.slice(0, remaining); truncated = true; }
            scanned += raw.length;
            var text = raw.replace(/\s+/g, ' ').trim();
            if (text) {
              var block = node.parentElement, depth = 0;
              while (block && block !== root && !blocks.has(block.tagName) && depth++ < 64)
                block = block.parentElement;
              if (depth >= 64) { truncated = true; break; }
              if (characters) append(block === lastBlock ? ' ' : '\n\n');
              append(text); lastBlock = block;
            }
            if (scanned >= 480000) truncated = true;
          } } catch (error) { if (error !== stop) throw error; }
          return {text:chunks.join('').trim(), truncated:truncated};
        })()
    """.trimIndent()
}

/** Owns one standard Android WebView; page changes never create a second renderer. */
internal class ComputerBrowserRuntime(context: Context) : MethodChannel.MethodCallHandler,
    Application.ActivityLifecycleCallbacks {
    private val application = context.applicationContext as Application
    private val main = Handler(Looper.getMainLooper())
    private var activity: Activity? = null
    private var resumed = false
    private var disposed = false
    private var session: Session? = null
    private var visualSequence = 0L

    init { application.registerActivityLifecycleCallbacks(this) }

    private inner class Session(val id: String, var width: Int, var height: Int) {
        val context = MutableContextWrapper(activity ?: application)
        val view = BrowserWebView(context) { changed(this) }
        var revision = 0L
        var url = "about:blank"
        var title = ""
        var error = ""
        var errorUrl: String? = null
        var committedUrl = "about:blank"
        var loading = false
        var visible = false
        var viewer: BrowserHost? = null
        var temporaryHost: FrameLayout? = null
        var previousFocus: WeakReference<View>? = null
        var pending: Pending? = null
        var closed = false
        fun viewport(): Pair<Int, Int> = if (visible && view.parent === viewer && view.isAttachedToWindow && view.width > 0 && view.height > 0)
            view.width to view.height else width to height
        fun state(): Map<String, Any> {
            val (viewportWidth, viewportHeight) = viewport()
            ComputerBrowserContract.viewport(viewportWidth, viewportHeight)
            return mapOf(
            "id" to id, "url" to url, "title" to title, "loading" to loading,
            "error" to error,
            "canGoBack" to view.canGoBack(), "canGoForward" to view.canGoForward(),
            "width" to viewportWidth, "height" to viewportHeight, "visible" to visible,
            "attached" to (view.parent === viewer && view.isAttachedToWindow),
            "revision" to revision,
            "provider" to (WebView.getCurrentWebViewPackage()?.let { "${it.packageName} / ${it.versionName}" }
                ?: "Android System WebView")
            )
        }
    }

    private class Pending(val result: MethodChannel.Result) {
        var done = false
        var cancelInput: (() -> Unit)? = null
        fun success(value: Any?) { if (!done) { done = true; result.success(value) } }
        fun error(code: String, message: String) { if (!done) {
            done = true
            try { cancelInput?.invoke() } catch (_: Exception) {}
            cancelInput = null
            result.error(code, message, null)
        } }
    }

    fun attachActivity(value: Activity) {
        activity = value
        resumed = !value.isFinishing
        session?.context?.baseContext = value
        reconcile()
    }
    fun detachActivity() {
        resumed = false
        session?.let { abort(it, "unavailable", "浏览器已离开前台。")
            detach(it); it.context.baseContext = application; it.viewer = null }
        activity = null
    }
    fun dispose() {
        disposed = true
        session?.let(::destroy)
        session = null
        application.unregisterActivityLifecycleCallbacks(this)
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            check(Looper.myLooper() == Looper.getMainLooper())
            if (disposed) throw ComputerBrowserFailure("unavailable", "浏览器运行时已关闭。")
            val args = call.arguments as? Map<*, *> ?: throw IllegalArgumentException("arguments")
            val id = ComputerBrowserContract.id(args["id"] as? String ?: throw IllegalArgumentException("id"))
            if (call.method == "state") { result.success(session?.takeIf { it.id == id }?.state()); return }
            if (call.method == "close") {
                session?.takeIf { it.id == id }?.let(::destroy)
                if (session?.id == id) session = null
                result.success(null); return
            }
            if (call.method == "cancel") {
                session?.takeIf { it.id == id }?.let {
                    abort(it, "canceled", "浏览器操作已取消。")
                    if (!it.visible || !resumed || it.viewer?.isAttachedToWindow != true) detach(it)
                }
                result.success(null); return
            }
            if (call.method == "open") {
                val url = ComputerBrowserContract.url(args["url"] as? String ?: throw IllegalArgumentException("url"))
                checkNavigationPolicy(url)
                val width = integer(args, "width"); val height = integer(args, "height")
                ComputerBrowserContract.dimensions(width, height)
                val existing = session
                if (existing != null && existing.id != id)
                    throw ComputerBrowserFailure("busy", "请先关闭当前浏览器会话。")
                val current = existing ?: create(id, width, height).also { session = it }
                if (current.width != width || current.height != height) {
                    current.width = width; current.height = height; changed(current)
                    if (!current.visible || current.viewer?.isAttachedToWindow != true) layoutHidden(current)
                }
                if (existing == null || current.url != url) navigate(current, url)
                result.success(current.state()); return
            }
            val current = session?.takeIf { it.id == id && !it.closed }
                ?: throw ComputerBrowserFailure("not_found", "浏览器会话已关闭。")
            when (call.method) {
                "navigate" -> {
                    navigate(current, ComputerBrowserContract.url(args["url"] as? String ?: throw IllegalArgumentException("url")))
                    result.success(current.state())
                }
                "visible" -> {
                    current.visible = args["visible"] as? Boolean ?: throw IllegalArgumentException("visible")
                    reconcile(); result.success(current.state())
                }
                "capture" -> capture(current, result)
                "readPage" -> readPage(current, args, result)
                "action" -> action(current, args, result)
                "back", "forward" -> {
                    requireForeground()
                    ensureAttached(current)
                    changed(current)
                    if (call.method == "back" && current.view.canGoBack()) current.view.goBack()
                    if (call.method == "forward" && current.view.canGoForward()) current.view.goForward()
                    idleDetach(current); result.success(current.state())
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) { fail(result, error) }
    }

    private fun create(id: String, width: Int, height: Int): Session {
        requireForeground()
        val current = Session(id, width, height)
        current.view.apply {
            setBackgroundColor(Color.WHITE)
            settings.apply {
                javaScriptEnabled = true; domStorageEnabled = true
                javaScriptCanOpenWindowsAutomatically = false; setSupportMultipleWindows(false)
                allowFileAccess = false; allowContentAccess = false
                @Suppress("DEPRECATION")
                allowFileAccessFromFileURLs = false
                @Suppress("DEPRECATION")
                allowUniversalAccessFromFileURLs = false
                mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                setGeolocationEnabled(false); mediaPlaybackRequiresUserGesture = true
                builtInZoomControls = true; displayZoomControls = false
                useWideViewPort = true; loadWithOverviewMode = true
            }
            setDownloadListener { _, _, _, _, _ -> /* Downloads require a future explicit file flow. */ }
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean =
                    request?.url?.toString()?.let { filterNavigation(current, it, request.isForMainFrame) } ?: true
                @Deprecated("Older WebView compatibility")
                override fun shouldOverrideUrlLoading(view: WebView?, url: String?): Boolean = url?.let { filterNavigation(current, it, true) } ?: true
                override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? {
                    val scheme = request?.url?.scheme?.lowercase()
                    return if (scheme in setOf("file", "content", "ftp", "intent"))
                        WebResourceResponse("text/plain", "UTF-8", ByteArrayInputStream(byteArrayOf())) else null
                }
                override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
                    if (current.closed) return
                    // HTTP errors may be delivered before this callback. A
                    // start for that same request (including its internal error
                    // document) must not turn the failure into apparent success.
                    val retainError = ComputerBrowserContract.retainLoadError(current.errorUrl, url, current.error)
                    if (url != null && allowed(url)) current.url = url
                    if (!retainError) { current.error = ""; current.errorUrl = null }
                    current.loading = current.error.isEmpty(); changed(current)
                }
                override fun onPageFinished(view: WebView?, url: String?) {
                    if (current.closed) return
                    if (url != null && allowed(url)) current.url = url
                    if (current.error.isEmpty()) current.committedUrl = current.url
                    current.title = current.view.title.orEmpty().take(1024)
                    current.loading = false; changed(current); idleDetach(current, 150)
                }
                override fun doUpdateVisitedHistory(view: WebView?, url: String?, isReload: Boolean) {
                    if (!current.closed && url != null && allowed(url) && current.url != url) {
                        current.url = url; changed(current)
                    }
                }
                override fun onReceivedSslError(view: WebView?, handler: SslErrorHandler?, error: SslError?) {
                    handler?.cancel()
                    loadFailed(current, "网页证书验证失败，已停止加载。", sourceUrl = error?.url)
                }
                override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
                    if (request?.isForMainFrame == true) loadFailed(current,
                        ComputerBrowserContract.loadError(error?.errorCode ?: ERROR_UNKNOWN),
                        preserveExisting = true, sourceUrl = request.url.toString())
                }
                override fun onReceivedHttpError(view: WebView?, request: WebResourceRequest?, response: WebResourceResponse?) {
                    if (request?.isForMainFrame == true) {
                        val code = response?.statusCode ?: 0
                        loadFailed(current, if (code in 400..599) "网页服务器返回错误（HTTP $code）。" else "网页服务器返回错误。",
                            sourceUrl = request.url.toString())
                    }
                }
                override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
                    destroy(current); if (session === current) session = null; return true
                }
            }
            webChromeClient = object : WebChromeClient() {
                override fun onReceivedTitle(view: WebView?, title: String?) { if (!current.closed) current.title = title.orEmpty().take(1024) }
                override fun onPermissionRequest(request: PermissionRequest?) { request?.deny() }
                override fun onGeolocationPermissionsShowPrompt(origin: String?, callback: GeolocationPermissions.Callback?) { callback?.invoke(origin, false, false) }
                override fun onShowFileChooser(view: WebView?, callback: ValueCallback<Array<android.net.Uri>>?, params: WebChromeClient.FileChooserParams?): Boolean {
                    callback?.onReceiveValue(null); return true
                }
                override fun onCreateWindow(view: WebView?, isDialog: Boolean, isUserGesture: Boolean, resultMsg: android.os.Message?): Boolean = false
                override fun onJsAlert(view: WebView?, url: String?, message: String?, result: JsResult?): Boolean {
                    result?.cancel(); return true
                }
                override fun onJsConfirm(view: WebView?, url: String?, message: String?, result: JsResult?): Boolean {
                    result?.cancel(); return true
                }
                override fun onJsPrompt(view: WebView?, url: String?, message: String?, defaultValue: String?, result: JsPromptResult?): Boolean {
                    result?.cancel(); return true
                }
                override fun onJsBeforeUnload(view: WebView?, url: String?, message: String?, result: JsResult?): Boolean {
                    result?.cancel()
                    current.url = view?.url?.takeIf(::allowed) ?: current.committedUrl
                    loadFailed(current, "网页要求确认离开，已取消导航并保留当前页面。")
                    return true
                }
            }
        }
        return current
    }

    private fun allowed(url: String): Boolean = runCatching { ComputerBrowserContract.url(url); true }.getOrDefault(false)
    private fun checkNavigationPolicy(url: String) = ComputerBrowserContract.navigationPolicy(url) {
        NetworkSecurityPolicy.getInstance().isCleartextTrafficPermitted(it)
    }
    private fun filterNavigation(current: Session, url: String, mainFrame: Boolean): Boolean {
        return try { checkNavigationPolicy(url); false } catch (error: Exception) {
            if (mainFrame && !current.closed) {
                current.url = current.view.url?.takeIf(::allowed) ?: current.committedUrl
                loadFailed(current, if (error is ComputerBrowserFailure) error.message.orEmpty() else "此网页地址暂不支持。")
            }
            true
        }
    }
    private fun loadFailed(current: Session, message: String, preserveExisting: Boolean = false, sourceUrl: String? = null) {
        if (current.closed) return
        val target = sourceUrl?.takeIf(::allowed) ?: if (preserveExisting) current.errorUrl ?: current.url else current.url
        if (!preserveExisting || !ComputerBrowserContract.preserveSpecificError(current.error, current.errorUrl, target)) {
            current.error = message; current.errorUrl = target
        }
        current.loading = false; changed(current); idleDetach(current, 150)
    }
    private fun changed(current: Session) { if (!current.closed) current.revision = Math.addExact(current.revision, 1L) }
    private fun requireForeground() {
        if (!resumed || activity == null) throw ComputerBrowserFailure("unavailable", "请在前台打开应用后操作浏览器。")
    }
    private fun navigate(current: Session, url: String) {
        checkNavigationPolicy(url)
        requireForeground()
        if (current.pending != null) throw ComputerBrowserFailure("busy", "浏览器操作尚未完成。")
        ensureAttached(current)
        current.url = url; current.error = ""; current.errorUrl = null; current.loading = true; changed(current)
        current.view.loadUrl(url); idleDetach(current)
    }
    private fun ensureAttached(current: Session) {
        requireForeground()
        if (current.visible && current.viewer?.isAttachedToWindow == true) {
            removeTemporary(current, false)
            current.view.suppressIme = false
            val host = current.viewer!!
            if (current.view.parent !== host) {
                (current.view.parent as? ViewGroup)?.removeView(current.view)
                host.addView(current.view, FrameLayout.LayoutParams(-1, -1))
            }
        } else if (current.temporaryHost == null) {
            current.previousFocus = activity?.currentFocus?.let(::WeakReference)
            current.view.suppressIme = true
            (current.view.parent as? ViewGroup)?.removeView(current.view)
            val host = FrameLayout(activity!!).apply {
                translationX = -(current.width + activity!!.resources.displayMetrics.widthPixels + 100).toFloat()
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            }
            (activity!!.window.decorView as ViewGroup).addView(host,
                ViewGroup.LayoutParams(current.width, current.height))
            host.addView(current.view, FrameLayout.LayoutParams(current.width, current.height))
            current.temporaryHost = host
            layoutHidden(current)
        }
        current.view.visibility = View.VISIBLE
        if (current.view.width == 0 || current.view.height == 0) {
            current.view.measure(View.MeasureSpec.makeMeasureSpec(current.width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(current.height, View.MeasureSpec.EXACTLY))
            current.view.layout(0, 0, current.width, current.height)
        }
        current.view.onResume()
    }
    private fun layoutHidden(current: Session) {
        current.temporaryHost?.layoutParams = FrameLayout.LayoutParams(current.width, current.height)
        current.view.layoutParams = FrameLayout.LayoutParams(current.width, current.height)
        current.view.measure(View.MeasureSpec.makeMeasureSpec(current.width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(current.height, View.MeasureSpec.EXACTLY))
        current.view.layout(0, 0, current.width, current.height)
    }
    private fun removeTemporary(current: Session, restoreFocus: Boolean = true) {
        current.temporaryHost?.let { host ->
            host.removeView(current.view); (host.parent as? ViewGroup)?.removeView(host)
        }
        current.temporaryHost = null
        if (restoreFocus) {
            val focused = activity?.currentFocus
            if (focused == null || focused === current.view) current.previousFocus?.get()?.let {
                if (it.isAttachedToWindow) it.requestFocus()
            }
        }
        current.previousFocus = null
    }
    private fun detach(current: Session) {
        removeTemporary(current)
        (current.view.parent as? ViewGroup)?.removeView(current.view)
        current.view.settings.offscreenPreRaster = false
        current.view.onPause()
    }
    private fun idleDetach(current: Session, delay: Long = 1500) {
        main.postDelayed({ if (!current.closed && current.pending == null &&
            (!current.visible || current.viewer?.isAttachedToWindow != true || !resumed)) detach(current) }, delay)
    }
    private fun reconcile() {
        session?.let { current ->
            if (resumed && current.visible && current.viewer?.isAttachedToWindow == true) ensureAttached(current)
            else if (current.pending == null) detach(current)
        }
    }

    private fun pending(current: Session, result: MethodChannel.Result): Pending {
        if (current.pending != null) throw ComputerBrowserFailure("busy", "浏览器操作尚未完成。")
        requireForeground()
        val pending = Pending(result); current.pending = pending
        main.postDelayed({
            if (current.pending === pending && !pending.done) {
                finish(current, pending) { pending.error("timeout", "浏览器渲染等待超时，请重新观察。") }
            }
        }, 10000)
        return pending
    }
    private fun finish(current: Session, pending: Pending, response: () -> Unit) {
        if (pending.done) return
        if (current.pending === pending) current.pending = null
        current.view.settings.offscreenPreRaster = false
        if (!current.visible || !resumed || current.viewer?.isAttachedToWindow != true) detach(current)
        response()
    }
    private fun visual(current: Session, pending: Pending, after: () -> Unit) {
        if (pending.done || current.closed) return
        current.view.settings.offscreenPreRaster = true
        current.view.invalidate()
        current.view.postVisualStateCallback(++visualSequence, object : WebView.VisualStateCallback() {
            override fun onComplete(requestId: Long) {
                if (pending.done || current.closed) return
                main.postDelayed({
                    if (!pending.done && !current.closed) try { after() }
                    catch (error: Exception) { finish(current, pending) { fail(pending.result, error); pending.done = true } }
                }, 50)
            }
        })
    }
    private fun capture(current: Session, result: MethodChannel.Result) {
        val pending = pending(current, result)
        try {
            ensureAttached(current)
            visual(current, pending) {
                val sourceWidth = current.view.width.coerceAtLeast(1)
                val sourceHeight = current.view.height.coerceAtLeast(1)
                val size = ComputerBrowserContract.frameSize(sourceWidth, sourceHeight)
                var width = size.first; var height = size.second
                var bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                var png: ByteArray? = null
                try {
                    val canvas = Canvas(bitmap)
                    canvas.drawColor(Color.WHITE)
                    canvas.scale(width.toFloat() / sourceWidth, height.toFloat() / sourceHeight)
                    current.view.draw(canvas)
                    repeat(6) {
                        if (png != null) return@repeat
                        val output = BoundedPng()
                        val success = try { bitmap.compress(Bitmap.CompressFormat.PNG, 100, output) }
                            catch (error: Exception) { if (!output.exceeded) throw error; false }
                        if (success && !output.exceeded) png = output.toByteArray()
                        else if (output.exceeded) {
                            width = (width * 0.75).roundToInt().coerceAtLeast(1)
                            height = (height * 0.75).roundToInt().coerceAtLeast(1)
                            val smaller = Bitmap.createScaledBitmap(bitmap, width, height, true)
                            if (smaller !== bitmap) bitmap.recycle()
                            bitmap = smaller
                        } else throw ComputerBrowserFailure("capture_failed", "浏览器截图失败。")
                    }
                } finally { bitmap.recycle() }
                val encoded = png ?: throw ComputerBrowserFailure("capture_failed", "浏览器截图超过大小限制。")
                finish(current, pending) { pending.success(mapOf("state" to current.state(), "png" to encoded,
                    "width" to width, "height" to height)) }
            }
        } catch (error: Exception) { finish(current, pending) { fail(result, error); pending.done = true } }
    }
    private fun readPage(current: Session, args: Map<*, *>, result: MethodChannel.Result) {
        val expected = args["expectedRevision"]?.let {
            require(it is Int || it is Long) { "expectedRevision" }; (it as Number).toLong()
        }
        ComputerBrowserContract.revision(expected, current.revision)
        ComputerBrowserContract.readablePage(current.url, current.loading, current.error)
        val pending = pending(current, result)
        try {
            ensureAttached(current)
            ComputerBrowserContract.revision(expected, current.revision)
            val revision = current.revision
            val url = current.url
            current.view.evaluateJavascript(ComputerBrowserPageReader.script) { raw ->
                if (pending.done || current.closed || session !== current || current.pending !== pending) return@evaluateJavascript
                try {
                    requireForeground()
                    ComputerBrowserContract.revision(revision, current.revision)
                    if (current.url != url || current.view.url != url)
                        throw ComputerBrowserFailure("stale_revision", "网页已更新，请重新读取正文。")
                    ComputerBrowserContract.readablePage(current.url, current.loading, current.error)
                    // The fixed reader returns at most 120k UTF-16 characters;
                    // bound even the escaped bridge payload before JSON parsing.
                    if (raw == null || raw.length > 6 * ComputerBrowserContract.MAX_PAGE_CHARACTERS + 1024)
                        throw ComputerBrowserFailure("invalid_page", "网页正文读取结果无效。")
                    val data = JSONObject(raw)
                    val text = data.get("text") as? String ?: throw IllegalArgumentException("pageText")
                    val truncated = data.get("truncated") as? Boolean ?: throw IllegalArgumentException("truncated")
                    ComputerBrowserContract.pageText(text)
                    val page = mapOf("id" to current.id, "url" to url,
                        "title" to current.title, "revision" to revision,
                        "text" to text, "truncated" to truncated)
                    finish(current, pending) { pending.success(page) }
                } catch (error: Exception) {
                    finish(current, pending) { fail(result, error); pending.done = true }
                }
            }
        } catch (error: Exception) { finish(current, pending) { fail(result, error); pending.done = true } }
    }
    private fun action(current: Session, args: Map<*, *>, result: MethodChannel.Result) {
        val expected = args["expectedRevision"]?.let {
            require(it is Int || it is Long) { "expectedRevision" }; (it as Number).toLong()
        }
        ComputerBrowserContract.revision(expected, current.revision)
        val kind = args["action"] as? String ?: throw IllegalArgumentException("action")
        require(kind in setOf("tap", "long_press", "scroll", "text", "key")) { "action" }
        val viewport = current.viewport()
        val sourceWidth = args["width"]?.let { integer(args, "width") } ?: viewport.first
        val sourceHeight = args["height"]?.let { integer(args, "height") } ?: viewport.second
        if (args["width"] != null || args["height"] != null) ComputerBrowserContract.dimensions(sourceWidth, sourceHeight)
        else ComputerBrowserContract.viewport(sourceWidth, sourceHeight)
        val text = if (kind == "text") (args["text"] as? String ?: throw IllegalArgumentException("text")).also { ComputerBrowserContract.text(it) } else null
        val key = if (kind == "key") ComputerBrowserContract.key(args["key"] as? String ?: throw IllegalArgumentException("key")) else null
        val modifierValues = (args["modifiers"] as? List<*>) ?: emptyList<Any>()
        val modifiers = ComputerBrowserContract.modifiers(modifierValues.map { it as? String ?: throw IllegalArgumentException("modifiers") })
        val x = if (kind == "tap" || kind == "long_press") integer(args, "x") else 0
        val y = if (kind == "tap" || kind == "long_press") integer(args, "y") else 0
        if (kind == "tap" || kind == "long_press") {
            ComputerBrowserContract.coordinate(x, sourceWidth, sourceWidth)
            ComputerBrowserContract.coordinate(y, sourceHeight, sourceHeight)
        }
        val delta = if (kind == "scroll") integer(args, "deltaY").also { require(it in -12000..12000) { "deltaY" } } else 0
        val pending = pending(current, result)
        try {
            ensureAttached(current)
            visual(current, pending) {
            ComputerBrowserContract.revision(expected, current.revision)
            current.view.requestFocus(); changed(current)
            fun done() { visual(current, pending) { finish(current, pending) { pending.success(current.state()) } } }
            when (kind) {
                "tap", "long_press" -> {
                    val px = ComputerBrowserContract.coordinate(x, sourceWidth, current.view.width.coerceAtLeast(1))
                    val py = ComputerBrowserContract.coordinate(y, sourceHeight, current.view.height.coerceAtLeast(1))
                    val time = SystemClock.uptimeMillis()
                    motion(current.view, time, time, MotionEvent.ACTION_DOWN, px, py)
                    pending.cancelInput = { motion(current.view, time, SystemClock.uptimeMillis(), MotionEvent.ACTION_CANCEL, px, py) }
                    main.postDelayed({ if (!current.closed && !pending.done) {
                        motion(current.view, time, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, px, py)
                        pending.cancelInput = null; done()
                    } }, if (kind == "long_press") ViewConfiguration.getLongPressTimeout().toLong() + 100 else 40)
                }
                "scroll" -> { current.view.scrollBy(0, (delta.toDouble() * current.view.height / sourceHeight).roundToInt()); done() }
                "key" -> {
                    val now = SystemClock.uptimeMillis()
                    current.view.dispatchKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, key!!, 0, modifiers))
                    current.view.dispatchKeyEvent(KeyEvent(now, now + 1, KeyEvent.ACTION_UP, key, 0, modifiers)); done()
                }
                "text" -> {
                    val connection = current.view.onCreateInputConnection(EditorInfo())
                    if (connection != null && connection.commitText(text!!, 1)) done()
                    else {
                        val encoded = JSONObject.quote(text)
                        current.view.evaluateJavascript("(function(){var e=document.activeElement;if(!e||!(e.tagName==='INPUT'||e.tagName==='TEXTAREA'||e.isContentEditable))return false;return document.execCommand('insertText',false,$encoded);})()") { value ->
                            if (value == "true") done()
                            else finish(current, pending) { pending.error("input_unavailable", "请先点击网页中的可编辑输入框。") }
                        }
                    }
                }
            }
            }
        } catch (error: Exception) { finish(current, pending) { fail(result, error); pending.done = true } }
    }
    private fun motion(view: View, down: Long, time: Long, action: Int, x: Float, y: Float) {
        MotionEvent.obtain(down, time, action, x, y, 0).also { event ->
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            try { view.dispatchTouchEvent(event) } finally { event.recycle() }
        }
    }
    private fun destroy(current: Session) {
        if (current.closed) return
        current.pending?.error("closed", "浏览器会话已关闭。")
        current.pending = null
        detach(current); current.closed = true; current.viewer = null
        current.view.stopLoading(); current.view.removeAllViews(); current.view.destroy()
        current.context.baseContext = application
    }
    private fun abort(current: Session, code: String, message: String) {
        current.pending?.error(code, message); current.pending = null
    }
    private fun fail(result: MethodChannel.Result, error: Exception) {
        when (error) {
            is ComputerBrowserFailure -> result.error(error.code, error.message, null)
            is IllegalArgumentException -> result.error("invalid_arguments", "浏览器请求参数无效。", null)
            else -> result.error("browser_error", "浏览器操作失败，请关闭会话后重试。", null)
        }
    }
    private fun integer(args: Map<*, *>, key: String): Int = args[key] as? Int ?: throw IllegalArgumentException(key)

    fun viewer(context: Context, id: String): PlatformView {
        ComputerBrowserContract.id(id)
        val current = session?.takeIf { it.id == id } ?: throw IllegalArgumentException("Unknown browser session")
        val host = BrowserHost(context) { attached ->
            if (current.viewer?.isAttachedToWindow == true && attached) reconcile()
            else if (!attached && current.view.parent === current.viewer) detach(current)
        }
        current.viewer?.removeView(current.view)
        current.viewer = host
        return object : PlatformView {
            override fun getView(): View = host
            override fun dispose() {
                if (!current.closed && current.viewer === host) {
                    current.visible = false; detach(current); current.viewer = null
                }
            }
        }
    }
    override fun onActivityResumed(value: Activity) { if (value === activity) { resumed = true; reconcile() } }
    override fun onActivityPaused(value: Activity) { if (value === activity) { resumed = false
        session?.let { abort(it, "unavailable", "浏览器已离开前台。"); detach(it) } } }
    override fun onActivityDestroyed(value: Activity) { if (value === activity) detachActivity() }
    override fun onActivityCreated(value: Activity, bundle: Bundle?) {}
    override fun onActivityStarted(value: Activity) {}
    override fun onActivityStopped(value: Activity) {}
    override fun onActivitySaveInstanceState(value: Activity, bundle: Bundle) {}

    private class BrowserHost(context: Context, private val changed: (Boolean) -> Unit) : FrameLayout(context) {
        override fun onAttachedToWindow() { super.onAttachedToWindow(); changed(true) }
        override fun onDetachedFromWindow() { changed(false); super.onDetachedFromWindow() }
    }
    private class BrowserWebView(context: Context, private val changed: () -> Unit) : WebView(context) {
        var suppressIme = false
        override fun onCheckIsTextEditor(): Boolean = !suppressIme && super.onCheckIsTextEditor()
        override fun onTouchEvent(event: MotionEvent): Boolean {
            if (event.actionMasked == MotionEvent.ACTION_DOWN) changed()
            return super.onTouchEvent(event)
        }
        override fun dispatchKeyEvent(event: KeyEvent): Boolean {
            if (event.action == KeyEvent.ACTION_DOWN) changed()
            return super.dispatchKeyEvent(event)
        }
        override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
            super.onSizeChanged(w, h, oldw, oldh)
            if (w != oldw || h != oldh) changed()
        }
        override fun onCreateInputConnection(info: EditorInfo): InputConnection? {
            val connection = super.onCreateInputConnection(info) ?: return null
            return if (Build.VERSION.SDK_INT >= 34) BrowserInputConnection34(connection, changed)
                else if (Build.VERSION.SDK_INT >= 33) BrowserInputConnection33(connection, changed)
                else BrowserInputConnection(connection, changed)
        }
    }
    private open class BrowserInputConnection(connection: InputConnection, protected val changed: () -> Unit) : InputConnectionWrapper(connection, false) {
        override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean { changed(); return super.commitText(text, newCursorPosition) }
        override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean { changed(); return super.setComposingText(text, newCursorPosition) }
        override fun setComposingRegion(start: Int, end: Int): Boolean { changed(); return super.setComposingRegion(start, end) }
        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean { changed(); return super.deleteSurroundingText(beforeLength, afterLength) }
        override fun deleteSurroundingTextInCodePoints(beforeLength: Int, afterLength: Int): Boolean { changed(); return super.deleteSurroundingTextInCodePoints(beforeLength, afterLength) }
        override fun setSelection(start: Int, end: Int): Boolean { changed(); return super.setSelection(start, end) }
        override fun sendKeyEvent(event: KeyEvent): Boolean { changed(); return super.sendKeyEvent(event) }
        override fun performEditorAction(editorAction: Int): Boolean { changed(); return super.performEditorAction(editorAction) }
        override fun performContextMenuAction(id: Int): Boolean { changed(); return super.performContextMenuAction(id) }
        override fun commitCompletion(text: CompletionInfo?): Boolean { changed(); return super.commitCompletion(text) }
        override fun commitCorrection(info: CorrectionInfo?): Boolean { changed(); return super.commitCorrection(info) }
        override fun finishComposingText(): Boolean { changed(); return super.finishComposingText() }
        override fun commitContent(info: InputContentInfo, flags: Int, options: Bundle?): Boolean { changed(); return super.commitContent(info, flags, options) }
        override fun performPrivateCommand(action: String?, data: Bundle?): Boolean { changed(); return super.performPrivateCommand(action, data) }
    }
    @android.annotation.TargetApi(33)
    private open class BrowserInputConnection33(connection: InputConnection, changed: () -> Unit) : BrowserInputConnection(connection, changed) {
        override fun commitText(text: CharSequence, newCursorPosition: Int, attribute: TextAttribute?): Boolean {
            changed(); return super.commitText(text, newCursorPosition, attribute)
        }
        override fun setComposingText(text: CharSequence, newCursorPosition: Int, attribute: TextAttribute?): Boolean {
            changed(); return super.setComposingText(text, newCursorPosition, attribute)
        }
        override fun setComposingRegion(start: Int, end: Int, attribute: TextAttribute?): Boolean {
            changed(); return super.setComposingRegion(start, end, attribute)
        }
    }
    @android.annotation.TargetApi(34)
    private class BrowserInputConnection34(connection: InputConnection, changed: () -> Unit) : BrowserInputConnection33(connection, changed) {
        override fun replaceText(start: Int, end: Int, text: CharSequence, newCursorPosition: Int, attribute: TextAttribute?): Boolean {
            changed(); return super.replaceText(start, end, text, newCursorPosition, attribute)
        }
        override fun performHandwritingGesture(gesture: android.view.inputmethod.HandwritingGesture,
            executor: java.util.concurrent.Executor?, consumer: java.util.function.IntConsumer?) {
            changed(); super.performHandwritingGesture(gesture, executor, consumer)
        }
        override fun previewHandwritingGesture(gesture: android.view.inputmethod.PreviewableHandwritingGesture,
            cancellation: android.os.CancellationSignal?): Boolean {
            changed(); return super.previewHandwritingGesture(gesture, cancellation)
        }
    }
    private class BoundedPng : ByteArrayOutputStream() {
        var exceeded = false
            private set
        override fun write(value: Int) { if (count >= ComputerBrowserContract.MAX_PNG) { exceeded = true; throw IllegalStateException("PNG limit") }; super.write(value) }
        override fun write(bytes: ByteArray, offset: Int, length: Int) {
            if (count.toLong() + length > ComputerBrowserContract.MAX_PNG) { exceeded = true; throw IllegalStateException("PNG limit") }
            super.write(bytes, offset, length)
        }
    }
}

internal class ComputerBrowserFactory(private val runtime: ComputerBrowserRuntime) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        runtime.viewer(context, (args as? Map<*, *>)?.get("id") as? String ?: throw IllegalArgumentException("id"))
}
