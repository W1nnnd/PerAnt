# perant_platform

PerAnt 的原生运行时边界，自研代码使用 GPL-3.0-only。此包提供 Android/iOS 平台诊断与类型化通道，以及 Android PRoot/Alpine 终端、离线 Python、共享文件、Xfce 桌面和原生浏览器。它不执行模型推理，也不提供后台任务服务。当前能力与授权范围见[容器电脑](../../docs/CONTAINER_COMPUTER.md)。

## 已实现

- `PerantPlatformBridge.getCapabilities()` 返回真实的宿主系统与版本，以及各执行能力的接入状态。
- `cancelTask(taskId)` 校验任务 ID；未启动的任务明确返回 `notRunning`，不会伪装为取消了一个已运行任务。
- `events` 在原生桥接连接时报告 `bridgeAttached` 诊断事件。Web、桌面和测试环境没有原生插件时，能力显示不可用，事件流为空。
- Android Linux 提供初始化、手动会话、PTY 输入/调整尺寸、单命令与取消通道；事件包含真实进程输出和退出状态。
- `startLinuxTextTask` 将有界标题/原文写入 JSON，执行固定 Python 脚本；成功退出后通过 `readLinuxTextTaskResult` 读取本任务固定路径的实际 Markdown 文件。原文不拼入 Shell，不运行模型或生成语义摘要。
- Android v2 embedding、JNI PTY 与 PRoot/Alpine 终端桥接，以及 iOS Swift 诊断插件；支持 Swift Package Manager 和 CocoaPods。

## 公共 API

```dart
import 'package:perant_platform/perant_platform.dart';

final bridge = PerantPlatformBridge();
final capabilities = await bridge.getCapabilities();
if (!capabilities.linux.available) {
  print(capabilities.linux.reason);
}
```

方法通道为 `dev.perant/runtime`，事件通道为 `dev.perant/runtime/events`，当前线协议 `schemaVersion` 为 `1`。能力消息、取消结果及事件在 Dart 侧校验。未知原生错误保留错误码，损坏响应转为 `RuntimeBridgeException`；缺失插件单独处理为不可用状态。

## 接入边界

Android 资源是固定 PRoot、匹配 loader、Alpine 3.24.4 aarch64、Python 3.14.10 和桌面应用闭包，当前运行资源为 v6。官方签名 APK 离线安装，旧版目录和独立工作区保留。构建前从项目根目录运行 `tool/prepare-linux-runtime`；`--verify-existing` 支持离线完整性校验。源码、许可证和重建说明见 [Linux 运行资源说明](../../docs/LINUX_RUNTIME_SOURCES.md)。第三方组件保留原始版权；生成的二进制与 rootfs 不提交 Git。

PRoot 不提供强隔离。API 37 ARM64 模拟器上已验证取消、文件持久化和一次受控宿主路径探测；标记本次不可读不证明任意代码无法访问宿主，不据此启用模型自主执行。iOS iSH、本地推理与后台服务尚未接入，当前不承诺后台或锁屏续跑。

Android 最低 API 29、compile SDK 36、Java 17；Gradle/Kotlin 版本与创建框架时的 Flutter SDK 模板保持一致（AGP 9.3.1 内置 Kotlin，KGP 2.4.20）。iOS 最低 26.0。SPM 的本地 `FlutterFramework` 由 Flutter 工具链在构建时提供。

测试使用 Flutter 标准测试框架：

```sh
flutter test packages/perant_platform/test
```

历史 0.3 基线的 Android JVM **36/36**、Linux 集成 **8/8** 通过；Linux 使用 API 37 ARM64 模拟器、target SDK 36。验证了 Python 标准库/CA/SQLite/中文路径、真实文字任务、原文不执行和 2 万 emoji／80 KB 输入，以及 Shell/PTY/取消/持久化。历史本地记录为 `artifacts/android-python/integration-results.json`，未随源码发布；当前 0.8 检查范围及未完成项见[开发状态](../../docs/DEVELOPMENT_STATUS.md)。CA 载入不是公网 HTTPS 请求验收。运行方式（从 `apps/perant`）：

```sh
../../tool/flutterw test integration_test/linux_runtime_test.dart -d <设备ID> --no-pub
```

应用入口为聊天页 **更多 → 本地终端** 或 **更多 → 本地整理为 Markdown**；输入/输出限制及发布条件见[工具契约](../../docs/PYTHON_TEXT_TASK.md)。默认保留 PRoot seccomp 优化，不设置 `PROOT_NO_SECCOMP=1`；本轮交互输出未出现 `getcwd` 警告。真机、其他 ROM、后台、推理性能及 4 GB 手机资源占用尚未验证。
