// SPDX-License-Identifier: GPL-3.0-only

import Flutter
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
