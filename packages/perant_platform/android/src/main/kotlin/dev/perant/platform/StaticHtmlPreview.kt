// SPDX-License-Identifier: GPL-3.0-only
package dev.perant.platform

import android.content.Context
import android.graphics.Color
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.ByteArrayInputStream

/** Static, offline HTML artifact display. No guest network or JavaScript bridge. */
internal class StaticHtmlPreviewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val html = (args as? Map<*, *>)?.get("html") as? String
            ?: throw IllegalArgumentException("Expected static HTML text.")
        WorkspaceFileContract.content(html)
        return StaticHtmlPreview(context, html)
    }
}

private class StaticHtmlPreview(context: Context, html: String) : PlatformView {
    private val webView = WebView(context).apply {
        setBackgroundColor(Color.WHITE)
        settings.apply {
            javaScriptEnabled = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            allowFileAccess = false
            allowContentAccess = false
            blockNetworkLoads = true
            blockNetworkImage = true
            domStorageEnabled = false
            setGeolocationEnabled(false)
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            cacheMode = WebSettings.LOAD_NO_CACHE
        }
        webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean = true
            @Deprecated("Required for older WebView compatibility")
            override fun shouldOverrideUrlLoading(view: WebView?, url: String?): Boolean = true
            override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse = blocked()
            @Deprecated("Required for older WebView compatibility")
            override fun shouldInterceptRequest(view: WebView?, url: String?): WebResourceResponse = blocked()
            private fun blocked() = WebResourceResponse("text/plain", "UTF-8", ByteArrayInputStream(byteArrayOf()))
        }
        loadDataWithBaseURL("https://perant.invalid/", html, "text/html", "UTF-8", null)
    }

    override fun getView(): WebView = webView

    override fun dispose() {
        webView.stopLoading()
        webView.removeAllViews()
        webView.destroy()
    }
}
