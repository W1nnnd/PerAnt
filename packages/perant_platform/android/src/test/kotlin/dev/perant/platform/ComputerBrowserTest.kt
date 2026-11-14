// SPDX-License-Identifier: GPL-3.0-only
package dev.perant.platform

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/** JVM boundary contracts only; actual WebView rendering is an Android test. */
class ComputerBrowserTest {
    @Test
    fun navigationAcceptsWebUrlsAndRejectsHostResourceOrCodeSchemes() {
        for (url in listOf("about:blank", "https://example.com/a?q=x#section", "http://127.0.0.1:8080/", "http://[::1]:8080/"))
            assertEquals(url, ComputerBrowserContract.url(url))
        for (url in listOf("", "file:///data/data/key", "content://provider/private", "javascript:alert(1)",
            "data:text/html,test", "intent://app", "about:config", "https://", "http://user:secret@example.com/",
            "http://example.com:99999/", "https://example.com/\nnext", "https://example.com/%zz"))
            assertThrows(IllegalArgumentException::class.java) { ComputerBrowserContract.url(url) }
    }

    @Test
    fun snapshotCoordinatesAreScaledToTheRealViewportAndNeverWrap() {
        assertEquals(250f, ComputerBrowserContract.coordinate(500, 1000, 500), 0.001f)
        assertEquals(499f, ComputerBrowserContract.coordinate(999, 1000, 500), 0.001f)
        for ((value, source, target) in listOf(Triple(-1, 100, 100), Triple(100, 100, 100), Triple(0, 0, 100), Triple(0, 100, 0)))
            assertThrows(IllegalArgumentException::class.java) { ComputerBrowserContract.coordinate(value, source, target) }
        ComputerBrowserContract.dimensions(1600, 1200)
        assertEquals(720 to 1200, ComputerBrowserContract.frameSize(1080, 1800))
        assertEquals(1600 to 800, ComputerBrowserContract.frameSize(4000, 2000))
        assertEquals(720 to 1080, ComputerBrowserContract.frameSize(720, 1080))
        for ((width, height) in listOf(0 to 100, 100 to 0, 1601 to 1200, 1600 to 1201))
            assertThrows(IllegalArgumentException::class.java) { ComputerBrowserContract.dimensions(width, height) }
    }

    @Test
    fun staleObservationsFailBeforeAnyInputIsDispatched() {
        ComputerBrowserContract.revision(null, 7)
        ComputerBrowserContract.revision(7, 7)
        val error = assertThrows(ComputerBrowserFailure::class.java) { ComputerBrowserContract.revision(6, 7) }
        assertEquals("stale_revision", error.code)
        assertThrows(IllegalArgumentException::class.java) { ComputerBrowserContract.revision(-1, 7) }
    }

    @Test
    fun inputsAndSessionIdsAreBoundedAndDoNotBecomeExecutableCode() {
        ComputerBrowserContract.text("中文 ' quote \" text")
        assertThrows(IllegalArgumentException::class.java) { ComputerBrowserContract.text("x\u0000y") }
        assertThrows(IllegalArgumentException::class.java) { ComputerBrowserContract.text("x".repeat(16385)) }
        assertEquals("browser-session.1", ComputerBrowserContract.id("browser-session.1"))
        for (id in listOf("", "../session", "browser/session", "x".repeat(129)))
            assertThrows(IllegalArgumentException::class.java) { ComputerBrowserContract.id(id) }
        assertThrows(IllegalArgumentException::class.java) { ComputerBrowserContract.key("javascript:run()") }
        assertThrows(IllegalArgumentException::class.java) { ComputerBrowserContract.modifiers(listOf("shell")) }
    }

    @Test
    fun cleartextPolicyRejectsBeforeNavigationAndKeepsErrorsIndependentOfUrls() {
        ComputerBrowserContract.navigationPolicy("https://example.com/private?token=secret") { false }
        ComputerBrowserContract.navigationPolicy("http://127.0.0.1:8080/") { it == "127.0.0.1" }
        ComputerBrowserContract.navigationPolicy("http://[::1]:8080/") { it == "::1" }
        val error = assertThrows(ComputerBrowserFailure::class.java) {
            ComputerBrowserContract.navigationPolicy("http://example.com/private?token=secret") { false }
        }
        assertEquals("cleartext_not_permitted", error.code)
        assertEquals(false, error.message.orEmpty().contains("secret"))
        assertEquals(false, error.message.orEmpty().contains("example.com"))
        assertEquals("无法解析网页地址，请检查网址或网络。", ComputerBrowserContract.loadError(-2))
        assertEquals("网页无法加载，请检查网络或网址。", ComputerBrowserContract.loadError(Int.MIN_VALUE))
    }

    @Test
    fun latePageStartDoesNotClearAnAlreadyReportedHttpOrSslFailure() {
        val failedUrl = "http://127.0.0.1:8080/missing"
        val error = "网页服务器返回错误（HTTP 404）。"
        assertEquals(true, ComputerBrowserContract.retainLoadError(failedUrl, failedUrl, error))
        assertEquals(true, ComputerBrowserContract.retainLoadError(failedUrl, "chrome-error://chromewebdata/", error))
        assertEquals(true, ComputerBrowserContract.retainLoadError(failedUrl, null, error))
        assertEquals(false, ComputerBrowserContract.retainLoadError(failedUrl, "http://127.0.0.1:8080/recovered", error))
        // Explicit navigate clears the previous error before WebView callbacks.
        assertEquals(false, ComputerBrowserContract.retainLoadError(failedUrl, failedUrl, ""))
    }

    @Test
    fun errorsFromNewLinkOrHistoryTargetsStayBoundToTheirRequestUrl() {
        val oldUrl = "https://example.com/old"
        val nextUrl = "https://example.com/missing"
        val error = "网页服务器返回错误（HTTP 404）。"
        // A main-frame error can precede onPageStarted while the address still
        // belongs to oldUrl. Its request source, not that old address, is used.
        assertEquals(true, ComputerBrowserContract.retainLoadError(nextUrl, nextUrl, error))
        assertEquals(false, ComputerBrowserContract.retainLoadError(nextUrl, oldUrl, error))
        assertEquals(true, ComputerBrowserContract.preserveSpecificError(error, nextUrl, nextUrl))
        assertEquals(false, ComputerBrowserContract.preserveSpecificError(error, oldUrl, nextUrl))
        assertEquals(false, ComputerBrowserContract.preserveSpecificError("", nextUrl, nextUrl))
    }

    @Test
    fun readingRequiresASuccessfullyLoadedWebDocument() {
        ComputerBrowserContract.readablePage("https://example.com/", false, "")
        for ((url, loading, error) in listOf(
            Triple("about:blank", false, ""),
            Triple("https://example.com/", true, ""),
            Triple("https://example.com/", false, "HTTP 404"),
        )) {
            val failure = assertThrows(ComputerBrowserFailure::class.java) {
                ComputerBrowserContract.readablePage(url, loading, error)
            }
            assertEquals("page_not_ready", failure.code)
            assertEquals(false, failure.message.orEmpty().contains("example.com"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            ComputerBrowserContract.readablePage("file:///private", false, "")
        }
    }

    @Test
    fun extractedTextHasIndependentUnicodeAndByteBudgets() {
        ComputerBrowserContract.pageText("段落一\n\n段落二 😀")
        ComputerBrowserContract.pageText("a".repeat(120000))
        ComputerBrowserContract.pageText("中".repeat(81920))
        ComputerBrowserContract.pageText("😀".repeat(60000))
        for (text in listOf("a".repeat(120001), "中".repeat(81921), "x\u0000y", "x\uD800", "\uDC00x"))
            assertThrows(IllegalArgumentException::class.java) { ComputerBrowserContract.pageText(text) }
        val failure = assertThrows(ComputerBrowserFailure::class.java) { ComputerBrowserContract.pageText(" \n\t") }
        assertEquals("page_empty", failure.code)
    }
}
