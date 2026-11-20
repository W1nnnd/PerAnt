// SPDX-License-Identifier: GPL-3.0-only

import Flutter
import PDFKit
import UIKit

/// Native diagnostics only. Execution integrations are explicitly unavailable.
public final class PerantPlatformPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = PerantPlatformPlugin()
        let methods = FlutterMethodChannel(
            name: "dev.perant/runtime",
            binaryMessenger: registrar.messenger()
        )
        let events = FlutterEventChannel(
            name: "dev.perant/runtime/events",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: methods)
        let pdf = FlutterMethodChannel(name: "dev.perant/pdf", binaryMessenger: registrar.messenger())
        pdf.setMethodCallHandler { call, result in
            guard call.method == "readPages" else { result(FlutterMethodNotImplemented); return }
            guard let bytes = call.arguments as? FlutterStandardTypedData,
                  (1...10 * 1024 * 1024).contains(bytes.data.count) else {
                result(FlutterError(code: "size", message: "PDF 文件需在 10 MB 以内。", details: nil))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let reply: Any = autoreleasepool {
                    guard let document = PDFDocument(data: bytes.data), !document.isEncrypted,
                          document.allowsCopying, (1...200).contains(document.pageCount) else {
                        return FlutterError(code: "pdf_input", message: "PDF 已加密、损坏、禁止复制或超过 200 页。", details: nil)
                    }
                    var pages = [String]()
                    var length = 0
                    for number in 0..<document.pageCount {
                        let text = document.page(at: number)?.string ?? ""
                        length += text.unicodeScalars.count
                        guard length <= 20000 else {
                            return FlutterError(code: "size", message: "PDF 正文超过 2 万字，请拆分后导入。", details: nil)
                        }
                        pages.append(text)
                    }
                    return pages
                }
                DispatchQueue.main.async { result(reply) }
            }
        }
        events.setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getCapabilities":
            result(capabilities())
        case "cancelTask":
            guard let arguments = call.arguments as? [String: Any],
                  let taskId = arguments["taskId"] as? String,
                  !taskId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                result(FlutterError(
                    code: "invalid_arguments",
                    message: "taskId must not be empty.",
                    details: nil
                ))
                return
            }
            result([
                "taskId": taskId,
                "status": "notRunning",
                "reason": "尚未接入执行后端，没有已启动的原生任务。"
            ])
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        events([
            "type": "bridgeAttached",
            "emittedAtEpochMs": Int64(Date().timeIntervalSince1970 * 1000),
            "payload": capabilities()
        ])
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    private func capabilities() -> [String: Any] {
        [
            "schemaVersion": 1,
            "platform": "ios",
            "systemVersion": "iOS \(UIDevice.current.systemVersion)",
            "nativeBridgeAvailable": true,
            "linux": unavailable("ARM64 iSH 与 Alpine 环境尚未接入此构建。"),
            "localInference": unavailable("llama.cpp 与本地模型尚未接入此构建。"),
            "backgroundTasks": unavailable("尚未注册和验证 iOS 后台长任务。")
        ]
    }

    private func unavailable(_ reason: String) -> [String: Any] {
        ["available": false, "reason": reason]
    }
}
