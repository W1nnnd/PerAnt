# Concept 06 移动端界面迁移

Concept 06 的对话优先布局已接入 Flutter 移动应用。原型用于确定视觉与交互方向；实际结果来自现有控制器、平台桥接和持久化服务。
本说明记录当前实现边界；本轮检查结果与适用范围见文末。

## 已接入的界面

- 首页采用小蚁角色、问候、开场建议与底部输入框；“聊一会儿 / 一起做事”切换建议内容。
- 底部导航保留“对话、电脑、文件”。新会话使用“新对话”；菜单承载最近对话、任务记录、模型与偏好设置。
- 对话展示真实消息、流式回复、本地工具回执和文档入口；回复可复制或保存为本机 Markdown 文档。
- 电脑页读取真实运行时状态，连接既有 Linux 桌面、浏览器、终端与工作文件入口；进入电脑页本身不会启动或观察桌面。
- 文件页支持本机 TXT / Markdown 资料的创建、导入、搜索、编辑及版本确认，并保留独立的电脑工作区入口。
- 设置沿用真实供应商配置、凭据存储与连接测试，不使用原型中的模拟配置结果。
- “添加文件与工具”底部弹层连接导入、新建文档、本地整理与终端；本地整理执行现有 Python 链路并发布可编辑文档。

界面入口见 [WorkspaceShell](../apps/perant/lib/src/presentation/workspace_shell.dart)、[电脑页](../apps/perant/lib/src/presentation/computer_workspace_page.dart)、[文档编辑器](../apps/perant/lib/src/presentation/document_editor.dart)与[模型设置](../apps/perant/lib/src/presentation/provider_settings.dart)。
应用装配与样式分别见 [PerantApp](../apps/perant/lib/src/perant_app.dart)和[主题](../apps/perant/lib/src/presentation/theme.dart)。

## 角色与本机偏好

- 小蚁的待命、思考、工作、等待确认、完成及用户接管姿态，依据当前会话任务和控制器状态切换。
- “坐一会儿”只改变空闲界面状态；它不暂停进程，也不提供任务恢复承诺。实际取消、中断与接管仍使用既有任务机制。
- 角色点击使用本机轻互动文案；开场建议填入请求或打开真实工具，不生成预写模型回复。
- 昵称默认“小蚁”，去除首尾空白后接受有效的短昵称；语气提供“随和搭子、利落助手、脑洞伙伴”，震动反馈默认开启。
- 昵称、语气、震动开关保存在工作区快照；旧快照缺少这些字段时使用默认值，保留原有资料和会话。
- 保存先写入候选快照，成功后更新界面状态；忙碌或写入失败会明确返回错误，不显示虚假的保存成功。
- 界面语气仅影响本机问候与轻互动文案，不修改模型 system prompt，不改变模型能力、网关或权限规则。

实现见 [角色组件](../apps/perant/lib/src/presentation/companion_avatar.dart)、[工作区状态](../apps/perant/lib/src/data/workspace_state.dart)与[工作区控制器](../apps/perant/lib/src/application/workspace_controller.dart)。

## 请求、授权与真实能力

- 普通聊天通过用户配置的真实 API 发起；未配置模型时引导配置并保留输入，不以固定文本冒充模型回复。
- 授权弹层显示供应商、模型、服务地址、待发送文字与数据范围。普通聊天可选择记住授权，但仅限当前运行、同一会话、同一 profile；可在界面撤销。
- 切换会话或模型不会把上述聊天授权扩展到其他任务。容器电脑协作每次单独授权，不能继承普通聊天的记住选项。
- 电脑协作沿用真实桌面、浏览器与文件工具；Shell 命令和关闭桌面另行确认。界面不把本次授权解释为任意登录、上传或提交许可。
- 任务记录展示实际状态、工具输出和中断原因；没有实现的后台续跑、本地模型、长期记忆与语义检索不因界面迁移而变为可用。
- 电脑卡片没有预制桌面截图。用户点击查看 Linux 桌面后才连接查看器；隐藏或进入后台时停止界面帧解码与查看连接，保留既有运行时生命周期约束。
- 本机文档资料与 Linux `/workspace` 仍分别存储。浏览器保存的网页正文进入电脑工作区，不自动成为文档资料库条目。

执行边界见 [容器任务执行器](../apps/perant/lib/src/application/container_task_runner.dart)、[共享桌面服务](../apps/perant/lib/src/application/shared_desktop_service.dart)、[浏览器服务](../apps/perant/lib/src/application/computer_browser_service.dart)和[本地整理执行器](../apps/perant/lib/src/application/local_text_task_runner.dart)。

## 素材与图标

角色沿用 Concept 06 原图与工作动图，保留透明背景、开放上沿与圆弧下沿构图。源文件、提示词和摘要见[角色素材说明](../apps/perant/assets/companion/README.md)。
启动图标使用同一角色身份生成并导出平台资源；来源、导出脚本与校验清单见[图标说明](../apps/perant/assets/branding/README.md)。
iOS 已导出图标资源；本次迁移不构成 iOS 设备运行、原生插件或运行时验收。

## 移动端验收范围

- 手机参考尺寸为 360 × 740、390 × 844、430 × 932；检查首页层级、卡片换行、底部输入框和导航可达性，不出现横向溢出。
- 输入时界面缩小角色，隐藏底部导航等辅助区域，输入框保持在键盘上方；短屏内容可滚动。
- 返回操作先遵循输入法和当前弹层的关闭顺序，再处理快捷指令、文档编辑与页面返回；未保存文档沿用原编辑器确认流程。
- 授权、菜单和偏好弹层支持关闭及滚动；连续打开、关闭后不能误弹出应用或遗失当前输入。
- 应用不在前台或系统要求减少动态效果时，工作姿态使用静态图；不可据此宣称后台任务永远运行或内存已满足低配手机目标。
- 离线界面回归覆盖导航、键盘、返回、授权和保存偏好；它们不能替代 Android 原生存储、凭据与 Linux 执行验证。

界面检查入口见 [WorkspaceShell 测试](../apps/perant/test/workspace_shell_test.dart)、[偏好与状态测试](../apps/perant/test/workspace_state_test.dart)、[控制器测试](../apps/perant/test/workspace_controller_test.dart)和[本地整理测试](../apps/perant/test/local_text_task_test.dart)。

## 本地验证命令

从项目根目录执行基础检查；这些命令在本机运行，不依赖 GitHub CI：

```sh
tool/flutterw pub get
tool/check
tool/flutterw devices
```

将 `PERANT_ANDROID_DEVICE_ID` 设为上一步列出的真实 Android 设备或模拟器 ID，再执行原生集成检查：

```sh
cd apps/perant
../../tool/flutterw test integration_test/native_smoke_test.dart \
  -d "${PERANT_ANDROID_DEVICE_ID:?请先设置真实 Android 设备 ID}" --no-pub
```

[原生 smoke 检查](../apps/perant/integration_test/native_smoke_test.dart)使用独立临时 SQLite 数据库与凭据引用，验证真实平台桥接、保存重开和本地 Python 文档链路，并禁止云端 HTTP 请求。
最终 APK 的安装、手机尺寸、键盘与返回交互应以 Android 设备运行记录为准，不使用网页原型作为通过依据。

## 2026-11-15 本轮检查

- 本地 `tool/check` 通过：Dart 280（核心/网关 38，平台/应用 242）、Python 14、格式与静态分析；另 2 项可选离线截图跳过，不计作设备结果。
- API 36 ARM64、4 GB / 4 核 / 宿主 GPU 模拟器原生 smoke 3/3 通过：真实凭据、隔离 SQLite 重开、Python 文档编辑确认；确认版本为 v2，云请求为 0。
- 3 GB / 2 核 / 软件渲染配置先发生测试窗口超时，按既有 300 秒桥接约定调整等待后仍发生原生冷安装超时；失败记录保留，不计作通过。4 GB 配置同时改变内存、核心数和渲染方式，不能据此归因于某一个因素。
- 最终 APK 已实装，360 × 740 / 390 × 844 / 430 × 932 原始截图与原生控件位置已核对；最小屏休息入口可点击高度大于 40dp。
- 实际输入后按 Android 返回：三导航恢复，草稿保留。文件分区、菜单返回、角色弹层及系统 App 信息中的新图标已核对；最终恢复模拟器显示设置并留在首页。
- 原生工作流检查之后仅收尾了空输入占位、键盘显示判断、文件标签及边框等表现层，其交互由最终本地回归与最终安装包复核覆盖。
- 本轮未运行 GitHub CI。尚未完成实体低配手机、系统中文输入法、iOS 设备、真实模型、长期后台与本地模型验收。

本机记录为 `artifacts/android-uiux-v09/`，包含源码摘要、APK 校验、原生尝试、原始截图与界面遍历结果；原始日志在 `.tooling/uiux-v09/`，不作为源码分发。
