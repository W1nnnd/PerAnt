# 本地 Python 文本任务

Android 0.3.0 原型把文字交给随 APK 固定的 Python 脚本，生成真实 Markdown 文件，再保存为应用中的草稿。它保留原文、规范换行与段落，并转义原文中的 Markdown/HTML 标记；不生成会议摘要，不推断负责人或日期，也不调用模型 API。

文中标注的本地开发证据和构建产物（如 `artifacts/`、`.tooling/` 与生成的运行资源）未随本次源码发布；源码预览的验证范围以文内记录为准。

## 使用

1. 在聊天页选择 **更多 → 本地整理为 Markdown**，填写标题并粘贴原文。
2. 选择“在本地整理”。首次使用时，应用从 APK 内离线准备 Alpine/Python 环境，显示真实任务进度。
3. 生成成功后，从会话回执打开文档，查看、编辑并确认具体版本。后续修改会使旧确认失效。

未配置 API 时仍可使用。任务执行期间占用本地工作区，手动终端、云请求和工作区修改与它互斥。任务输入先保存到会话和任务记录；应用中断后显示中断状态，不自动重放写操作。

## 输入与文件契约

| 项目 | 当前限制 |
| --- | --- |
| 任务 ID | 应用生成；1～96 个 ASCII 字符，仅字母、数字、点、下划线和短横线，首字符为字母或数字；不复用已存在 ID |
| 标题 | 非空，最多 80 个 Unicode 码点；禁止 C0/C1 控制字符及 Unicode 行/段分隔符 |
| 原文 | 非空，最多 20,000 个 Unicode 码点、128 KiB UTF-8，不含 NUL；拒绝损坏的 Unicode |
| JSON 文件 | 最多 192 KiB，含转义开销；`schemaVersion` 必须为整数 `1` |
| Markdown 输出 | 非空、严格 UTF-8、最多 256 KiB |
| 脚本超时 | 应用默认 30 秒；平台契约允许 1～300,000 毫秒 |

Android 原生桥接把结构化输入写入独立的新目录：

```text
/workspace/.perant-tasks/<taskId>/input.json
/workspace/.perant-tasks/<taskId>/output.md
```

宿主位置为应用私有 `files/linux-runtime/workspace/.perant-tasks/<taskId>/`。每个任务使用新目录，原文不会作为 Shell 参数或命令拼接，也不能指定可执行脚本或输出路径。应用调用固定脚本 `/opt/perant/tools/text_to_markdown.py`；该脚本的 SHA256 与大小在资源 manifest 中校验。

输入内容示例：

```json
{"schemaVersion":1,"taskId":"local-text-example","title":"会议原文","text":"议题一\n讨论内容\n\n待确认事项"}
```

脚本先写 `output.md.part`，同步文件后替换为 `output.md`，输出不含原文的完成标记。原生读取仅接受本任务目录中的普通输出文件，拒绝符号链接、硬链接、损坏 UTF-8 和超限结果。应用等待相同任务 ID 的退出码 `0` 且未取消/超时，再读取实际文件；文档、完成任务和会话回执在同一次 SQLite 快照中发布。

## 取消和失败

取消、超时、非零退出、事件流中断、输出无效或保存失败时，不发布为完成文档。若未确认原生进程已经停止，工作区继续占用，并允许重试停止。开始最终的短事务提交后，取消不能撤销已提交文档。

输入和执行尝试可能保留在独立任务目录，便于核对中断；当前没有任务文件自动清理或通用导出/迁移界面。手动终端可以访问同一工作区，因此 PRoot 路径映射不等于强安全隔离。当前自动入口只运行该内置工具，模型任意脚本和 Shell 自动执行仍未开放。

## 资源与验证

Python **3.14.10-r1** 及 13 个运行依赖随 APK 以官方 Alpine 签名包携带，额外压缩体积 10,829,637 字节。原始 Alpine 3.24.4 minirootfs 保持不变。新环境使用 `perant-alpine-3.24.4-aarch64-v2` 目录，安装成功和 Python/CA/SQLite 自检通过后才发布 ready 标记；旧版目录和独立工作区保留。无 pip、编译工具链或 Python 预编译字节码包。固定来源、许可证与重建方式见 [Linux 运行资源说明](LINUX_RUNTIME_SOURCES.md)。

在 `apps/perant` 下复跑真实 Android 检查：

```sh
../../tool/flutterw test integration_test/linux_runtime_test.dart -d <设备ID> --no-pub
../../tool/flutterw test integration_test/native_smoke_test.dart -d <设备ID> --no-pub
```

本轮 Linux 原生集成测试在 API 37 ARM64 模拟器、target SDK 36 上 **8/8 通过**，日志 `.tooling/python-linux-device.log`。新增覆盖 Python 标准库/CA 载入/SQLite/中文路径、受控文字任务，以及 20,000 个 emoji（80 KB UTF-8）通过结构化输入文件传递；原文中的 Shell 形式内容未执行。应用原生 `native_smoke_test.dart` **3/3 通过**，含真实 Python 生成、编辑并确认 revision 2、SQLite 关闭重开后读取，云请求数为 0。Dart **125 项**、宿主 Python **12 项**、Android JVM **36 项**通过，见本轮结构化证据（`artifacts/android-python/integration-results.json`）。0.3.0（2003）独立 APK 已通过构建、v2 调试签名、18 项运行资源哈希和 API 37 更新安装，见本轮验收记录（`artifacts/android-python/VERIFICATION.md`）；已目视确认普通应用启动至对话页；新增功能的人工点击流程未完成，原生 UI 集成测试已通过。

该结果不表示公网 HTTPS、iOS、本地主模型、语义摘要、后台续跑、真机或 4 GB 性能已验收。
