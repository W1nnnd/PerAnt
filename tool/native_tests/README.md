# Android 原生导入检查

`workspace_import_probe.c` 直接调用正式 JNI 所使用的 `workspace_import.h` 核心。它在 `/data/local/tmp` 新建独立测试目录，验证完整 UTF-8 字节、既有文件和符号链接不被覆盖、失败暂存清理、预存暂存文件不被误删，以及工作区与暂存目录别名拒绝；结束时清理自己的测试目录。它不读取或修改 PerAnt 的应用数据，不代表 Flutter UI 或模型任务验收。

在项目根目录编译 ARM64 / Android API 29 可执行文件：

```sh
.tooling/android-sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android29-clang -std=c11 -Wall -Wextra -Werror -O2 tool/native_tests/workspace_import_probe.c -o .tooling/workspace-import-probe-arm64
```

连接 ARM64 Android 设备后执行；多台设备时为每条 `adb` 命令添加同一 `-s` 设备 ID：

```sh
.tooling/android-sdk/platform-tools/adb push .tooling/workspace-import-probe-arm64 /data/local/tmp/perant-workspace-import-probe
.tooling/android-sdk/platform-tools/adb shell chmod 700 /data/local/tmp/perant-workspace-import-probe
.tooling/android-sdk/platform-tools/adb shell /data/local/tmp/perant-workspace-import-probe
.tooling/android-sdk/platform-tools/adb shell rm /data/local/tmp/perant-workspace-import-probe
```

成功时退出码为 0，标准输出一份 JSON：`passed: 6`、`failed: 0`、`testDirectoryRemoved: true`、`appDataAccessed: false`。此处六项是独立原生检查，不并入 Flutter 集成测试或 Android JVM 的测试计数。
