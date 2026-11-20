// SPDX-License-Identifier: GPL-3.0-only
package dev.perant.platform

import android.content.Context
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Read the text layer in page order. No OCR, external files or network. */
internal class PdfMaterials(private val context: Context) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "readPages") { result.notImplemented(); return }
        val bytes = call.arguments as? ByteArray
        if (bytes == null || bytes.size !in 1..10 * 1024 * 1024) {
            result.error("size", "PDF 文件需在 10 MB 以内。", null)
            return
        }
        try {
            PDFBoxResourceLoader.init(context)
            val memory = MemoryUsageSetting.setupMixed(8L shl 20, 64L shl 20).setTempDir(context.cacheDir)
            PDDocument.load(bytes.inputStream(), memory).use { doc ->
                require(!doc.isEncrypted && doc.currentAccessPermission.canExtractContent()) { "PDF 已加密或限制了文字提取。" }
                require(doc.numberOfPages in 1..200) { "每份 PDF 支持 1 至 200 页。" }
                // One traversal, separated by a private page boundary in the writer.
                val pages = MutableList(doc.numberOfPages) { "" }
                var total = 0
                val stripper = object : PDFTextStripper() {
                    override fun endPage(page: com.tom_roush.pdfbox.pdmodel.PDPage) {
                        super.endPage(page)
                        val writer = output as java.io.StringWriter
                        val text = writer.toString().trim()
                        total += text.codePointCount(0, text.length)
                        require(total <= 20000) { "PDF 正文超过 2 万字，请拆分后导入。" }
                        pages[currentPageNo - 1] = text
                        writer.buffer.setLength(0)
                    }
                }
                stripper.sortByPosition = true
                stripper.writeText(doc, java.io.StringWriter())
                result.success(pages)
            }
        } catch (error: IllegalArgumentException) {
            result.error("pdf_input", error.message ?: "无法读取 PDF。", null)
        } catch (_: Exception) {
            result.error("pdf_read", "无法读取 PDF，请检查文件是否损坏或加密。", null)
        }
    }
}
