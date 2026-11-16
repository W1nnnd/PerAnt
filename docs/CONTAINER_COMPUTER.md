# 容器电脑与模型协作

版本：**0.8.0+2008**。电脑工作区整合 Android 原生 WebView 浏览器、Linux Xfce 图形桌面、LibreOffice、文件、终端与模型操作记录。用户明确选择原生浏览器路线；Linux Firefox 原型失败并已从当前环境移除。**本轮 Android 自动化 19/19、最终 APK 静态与安装一致性已通过，最终人工保存→桌面打开流程未完成**。历史 0.7 和更早记录不代替本轮新增链路，完整 M1-D 仍未完成。

新增浏览器“保存网页文字”与模型 `browser_save_page`，把当前正文、来源和保存时间写成新工作区 Markdown，原桌面窗口保留。新增保存设备 **4/4** 通过，含实际文件读回与独立 guest 摘要；0.8 验收（`artifacts/android-browser-save-v08/VERIFICATION.md`）分别记录本轮 19 项、原生核心 6 项和宿主/JVM 检查。详见[网页文字保存](BROWSER_PAGE_SAVE.md)。

外层保持 nanoMuse 参考的对话优先布局；可视化 Linux 参考[小小容器 Tiny Container](https://github.com/Cateners/tiny_container)。浏览器与 Linux 使用不同显示引擎，但处于同一个电脑工作区和任务授权流程，不需要为浏览网页启动另一套 Linux 浏览器。

文中标注的本地开发证据和构建产物（如 `artifacts/`、`.tooling/` 与生成的运行资源）未随本次源码发布；源码预览的验证范围以文内记录为准。

## 使用流程

1. 点击聊天中的“模型的电脑”、底部电脑按钮或“更多 → 查看模型电脑”进入桌面。电脑状态卡只读取状态，不自动启动桌面或截图。首次 Linux 初始化从 APK 离线安装 v6 Alpine、Python、Xfce 和办公包；已有独立 `/workspace` 保留。
2. 电脑页“应用”面板提供浏览器与办公入口。浏览器也可从聊天“更多”进入，打开同一个原生页面，地址栏支持 HTTP(S) 与 `about:blank`。原生浏览器本身不依赖 Linux/Xvnc 查看器；当前模型容器任务的准备阶段仍要求 Linux 基线就绪。
3. Linux 使用真实 Xfce 菜单、任务栏、Thunar、终端、Mousepad 与设置。Writer、Calc、Impress 使用中文界面和 GTK3；文档保存到 `/workspace`。打开应用面板不会提前启动所有应用，启动和保存是否成功须观察实际窗口与文件，详见[基础应用说明](DESKTOP_APPLICATIONS.md)。
4. 手机首次查看桌面为 720×1080 竖屏或 1120×700 横屏；已有会话不因旋转重启。显示设置可调整分辨率，但须确认停止原桌面，未保存窗口可能丢失。模型独立 `desktop_start` 默认 1024×640。
5. 桌面查看器支持点击、长按右键、拖动、缩放/平移、全屏和键盘快捷操作。离页或后台停止 RFB 连续取帧并释放图像；原来的 Linux 窗口仍保留并占内存。浏览器离页隐藏 viewer、保留同一页面，不持续截图；显式关闭才销毁 WebView 会话。
6. 聊天开启容器协作时，为本次任务授权共享文件、实际桌面/浏览器截图、键鼠输入、工具结果与容器历史发送到选定服务。模型需支持视觉和工具调用；普通聊天不会因此自动获得工具或截图权限。
7. 模型先观察，再用最新 observation ID 操作，动作后重新观察。用户可停止模型并接管；停止模型交回控制，不关闭桌面或浏览器。用户关闭浏览器需确认表单内容可能丢失；模型没有关闭浏览器工具。停止整个 Linux 桌面另行确认。
8. 图形桌面活跃时，通用原生文件 API、手动终端和固定 Python 与 guest 保持互斥；通过 GUI 继续协作，或保存并确认停止桌面后访问文件工作台。专用网页正文导入允许已就绪桌面下创建根目录新文件，不开放通用读取、覆盖或子目录写入。
9. 浏览器加载成功后可点“保存网页文字”，在结果中查看文件路径、字节数和截断提示；从电脑“工作文件”打开新的 Markdown。模型也可在本任务授权下使用最新观察调用 `browser_save_page`。保存正文不等于下载附件或完整网页归档。

不配置 API 也可手动使用浏览器、本地桌面、文件、终端和固定文字工具。Thunar 的“超级账户”提示表示 PRoot guest uid 0，不代表 Android root 权限；PRoot 不构成强隔离。

## 应用与共享文件

| 入口或快捷键 | 操作 |
| --- | --- |
| 电脑“应用” / 聊天“更多”中的浏览器 | 同一 Android 原生 WebView；没有 Linux Firefox / Super+B 入口 |
| Super+空格 / Super+E | Xfce 应用菜单 / `/workspace` 的 Thunar |
| Ctrl+Alt+T | 独立 PerAnt Terminal |
| Super+W / Super+C / Super+P | LibreOffice Writer / Calc / Impress |
| Super+N / Super+I / Super+D | Mousepad / 设置 / 显示桌面 |
| Alt+Tab / Alt+F10 / Alt+F4 | 切换 / 最大化 / 关闭当前 Linux 窗口 |

v6 办公启动器直接调用官方 `soffice.bin`，显式指定 `URE_BOOTSTRAP`、GTK3 与 `SAL_ENABLE_FILE_LOCKING=1`。办公配置在 `/root/.perant-office`，默认文档目录为 `/workspace`；私有配置和恢复信息不作为普通产物发送。Writer 的 ODT/DOCX GUI 编辑、另存新文件、停止后核对和重开追加已通过 2/2；Calc/Impress 等能力仍须另验，安装包和快捷键本身不等于通过。

Writer、Calc、Impress 启动器仅对官方 `NORMAL_RESTART=81` 最多重试两次（总启动次数最多三次），其他退出码原样返回；argv、环境、私有配置和 stdout/stderr 均保留。3 个生成启动器语法检查与 21 个独立 Shell 功能场景已通过，见启动器检查（`artifacts/android-desktop-v07/office-launcher-shell-check.json`）；由新增 2 个 Python unittest 方法覆盖，已纳入 Python 14，不按 21 个场景再次累加，也不代替 GUI 设备验收。

| 文件契约 | 行为 |
| --- | --- |
| 目录与路径 | 同一真实 `/workspace`；拒绝穿越、链接、特殊文件、内部任务目录及工作区外路径 |
| 文本 | 有效 UTF-8、无 NUL、每文件最多 256 KiB；当前文本编辑器不处理办公二进制 |
| 列表 | UI/原生最多 500 项，模型结果最多 100 项，超出明确截断 |
| 新建与修改 | 新建排他；已有文件提交最新整文件 SHA256，冲突保留编辑内容供重新读取/合并 |
| 发布 | 写临时文件并落盘，再原子发布；新建使用 `renameat2(RENAME_NOREPLACE)` 避免覆盖 |
| 并发 | 文件和 Linux 控制共享 FIFO/生命周期锁，guest 活跃时拒绝通用结构化文件请求；专用正文导入只在空闲或桌面已就绪时新建根目录文件 |

编辑页不长期锁住模型；保存时仍核对 SHA256。截断读取、前次任务的旧哈希不能授权覆盖。文件工作台暂不提供删除、重命名、通用二进制导入或成果导出。浏览器正文摘录通过专用根目录新建导入到 `/workspace/web-<UUID>.md`，文件总预算 256 KiB，来源、保存时间和截断说明随文件保留；不接受调用方路径，不覆盖原件。回执仅描述发布字节，不是活跃 Linux 随后修改后的重新读取结果。附件下载和文件选择上传仍未接入。

## 模型工具与协议

| 工具 | 行为 |
| --- | --- |
| `browser_open` | 请求打开或导航共享原生浏览器；仅无内嵌凭据的 HTTP(S) 或 `about:blank`；回执不保证页面已加载 |
| `browser_capture` | 按需取得实际 PNG、URL、标题、revision、loading、error、page_loaded 和 observation ID；并报告截图在页面中的位置：`scroll_top`、`page_height`、`at_top`、`at_bottom`（截图像素） |
| `browser_save_page` | 消费最新观察，把固定提取的当前正文发布为新的 Markdown；返回实际路径、发布字节摘要、大小、来源、时间和截断标志；保留桌面窗口 |
| `browser_action` | 最新观察上的 tap、long_press、scroll、text 或 key；动作消费观察，回执附带约一秒后的新截图和新的 observation ID。滚动量以截图像素计，正值向下 |
| `desktop_start` | 启动或重连真实 Linux 桌面 |
| `desktop_capture` | 同一桌面的实际 PNG 和 observation ID |
| `desktop_action` | 最新观察上的点击、双击、移动、拖动、滚动、文字和按键；回执附带约一秒后的新截图和新的 observation ID |
| `desktop_stop` | 用户确认后关闭桌面与全部 Linux 图形应用 |
| `container_list_files` / `container_read_file` | 真实目录或文本、整文件 SHA256、大小和截断标志 |
| `container_write_file` / `container_make_directory` | 受版本条件约束的文件写入或目录创建，原生成功后才报告完成 |
| `container_run_command` | 逐条确认具体命令，返回真实退出码、输出、取消及超时 |

模型请求是提案，应用只在完整回合后执行经过验证的工具与 call ID。重复 ID、不完整回合、无效参数或过期观察不执行。浏览器动作和正文保存额外绑定 native `expectedRevision`；用户输入、视口或页面变化、接管及取消会使旧观察失效。截图异步完成和后续 HTTP 前再次核对控制权，迟到结果不能重新取得上传或输入权限。正文保存排除表单、可编辑区域和内嵌页面，仍可能截断或省略内容；取消发生时已经发布的文件保留，结果不确定时停止后续请求，不自动重试。

Chat Completions 使用 assistant `tool_calls` 和 `tool_call_id`；Responses 保留 reasoning/function_call，以 `function_call_output.call_id` 回传。实际 PNG 使用 `image_url` 或 `input_image`，带对应工具来源与观察 ID。一个工具批次先完整回传结果，再附最新视觉消息；旧图片清除，SQLite 与跨任务协议历史不存 PNG。

错误页面也会返回实际 PNG；截图回执 `ok` 仅表示捕获成功。`page_loaded` 是观察时 loading 为 false 且没有已报告 error 的状态，不证明网页内容或任务完成。必须检查这些状态与新画面，不能将 browser_open 的请求回执当作加载成功。

网页、文件、截图、标题、文件名、终端输出及错误均是不可信数据，不能产生新授权。公开网页浏览须与用户任务相关；登录、表单提交、上传、发送、付款或权限授予需要用户对具体动作与目的地的明确授权。模型不获得任意 JavaScript API 或 `browser_close`。网页脚本用于页面自身运行，TLS 错误拒绝、混合内容与 file/content 访问关闭；当前相机/麦克风、定位、文件选择、下载与新窗口流程不开放。生产网络策略允许远程 HTTPS，明文 HTTP 仅用于 loopback。

## 显示、观察与资源

| 场景 | 显示与资源行为 |
| --- | --- |
| 用户前台查看 Linux | 持续 RFB 显示实际 Xfce，Flutter 解码图像 |
| Linux 查看页隐藏/后台 | 关闭查看连接，释放 Dart 帧、当前/待回收 ui.Image 及渲染克隆；Linux 进程和窗口保留 |
| 模型观察 Linux | 临时单帧连接后关闭；输入连接不请求像素 |
| 用户前台查看浏览器 | 同一个原生 WebView 挂到 Android 平台视图，直接交互，不使用定时 PNG 流 |
| 模型隐藏观察/操作浏览器 | 要求应用前台 Activity，临时挂载实际 WebView、按需捕获/输入，完成后卸载临时宿主并释放 Bitmap；本轮原生浏览器场景已验证 |
| 浏览器查看页隐藏/后台 | viewer 卸载/暂停，保留同一页面会话；不保证 JavaScript timers、网络停止或 renderer 内存归零 |
| 用户显式关闭浏览器 | 销毁 WebView 会话；未提交内容可能丢失，先确认 |

桌面服务的 PNG 上限 650 KiB，浏览器 PNG 上限 2 MiB。浏览器实际视口与受预算限制、等比缩小的图像尺寸分开，模型坐标按图像映射到真实视口。截图不持续保留 Bitmap，仍不能把隐藏称为后台零内存。Android 可回收进程，本轮不承诺系统后台任务、锁屏续跑或全天守护。

v6 当前固定 **355 个官方签名桌面/办公 APK、375 项运行资源**，含 Python、原始 rootfs、本地库、脚本和单独的 PNG/XPM 兼容库。最终字节数、资源 SHA256、第三方许可及来源核对以冻结 manifest 与交付包体记录为准；不把安装大小当作运行 RSS。来源见[资源说明](LINUX_RUNTIME_SOURCES.md)、[来源锁](../third_party/linux/sources.lock.json)、[包清单](../third_party/linux/desktop-packages.json)和[NOTICE](../third_party/linux/NOTICE.md)。

## 限额与恢复

- 发给模型的截图是高清晰度副本，叠加了每 100 或 200 像素一条、带数字的红色标尺，坐标一律指截图左上角起算的像素。标尺只画在这份副本上，查看器和操作记录里是真实画面。
- 桌面运行期间文件工具和结构化命令不可用。模型应直接调用 `desktop_stop`，由应用请用户确认；确认后继续文件操作。失败的步骤若被之后相同的操作成功重做，任务按完成记录。
- 普通聊天会附带一条固定说明，告诉模型本轮没有任何工具，不得声称已经或将要执行操作。它不随会话保存，也不受界面语气设置影响。
- 每任务最多 12 轮模型请求 / 24 次工具，顺序执行；累计文本工具结果 512 KiB、文本上下文 1 MiB，图片另受上述预算限制。
- 结构化 Shell 最多 16 KiB、超时 1～60 秒，输出有界；GUI 终端输入属于单独明确的桌面控制授权。
- 工具意图先入库，随后记录等待确认、运行、成功、失败、拒绝、取消或中断，绑定会话与任务。
- 停止后等待真实退出或 FIFO 清理确认才释放任务占有；回执不确定时保留记录，不自动重试变更。
- 重开只恢复记录与实际文件，未完成项标为中断，不重放云请求或副作用。失败或拒绝不会回滚此前已经完成的独立步骤。

## 静态预览与验证状态

Markdown 仍由 Flutter 渲染；独立 `dev.perant/html-preview` 只显示传入 HTML 与内联 CSS，禁用 JavaScript、网络、DOM 存储、file/content 与导航。它保持原有行为，不替代交互浏览器，也不作为办公 GUI 的验收。

**0.8.0 当前结果：**Dart 252（核心/网关 38、平台/应用 214）、Python 14、格式与全仓分析通过，另 2 项截图跳过；Android JVM 72/72，独立原生发布核心 probe 6/6。实际 Android **19/19**（保存 4、浏览器 5、容器 7、原生存储/文档 3）和最终包静态/安装一致性均通过，最终人工保存→桌面打开流程未完成。见0.8 总结果（`artifacts/android-browser-save-v08/integration-results.json`）、最终包（`artifacts/apk/PerAnt-0.8.0-debug-arm64.apk`）及验收报告（`artifacts/android-browser-save-v08/VERIFICATION.md`）。本轮不重跑旧 Linux 8、Writer 2 和桌面 3，也不累加旧版通过数。

最终包的人工复核记录（`artifacts/android-browser-save-v08/manual-apk-check.json`）为 `incomplete`，不能宣告保存到桌面完整链路已完成。实际只到达聊天和更多菜单中的空白浏览器，目标网址未能按预期输入/提交，没有成功保存回执或桌面打开证据。键盘/粘贴输入异常、一次 CUA 超时和冷启动 System UI 无响应提示均保留为观察，根因未确认；原始画面（`artifacts/android-browser-save-v08/manual-input-transfer-incomplete.png`）不是成功保存截图。

### 历史 0.7.0+2007

**0.7.0 完整代码检查通过：Dart 223 项、Python 14 项、格式和静态分析，另 2 项可选截图跳过；Android JVM 66/66、浏览器服务/查看器定向 21 项通过。**原生浏览器设备 5/5 通过；Writer ODT/DOCX 2/2、v6 桌面基线 3/3 通过；既有回归 18/18 通过，合计 Android 28/28；最终 APK 静态校验与安装一致性已通过，人工入口与往返复核已通过。浏览器模型协议已用 MockClient 和真实 PNG fixture 验证两种消息格式、过期/撤权/取消，但不证明真实视觉供应商或 WebView 像素。最终结果统一见[开发状态](DEVELOPMENT_STATUS.md)。

自动化原生浏览器 **5/5 通过**，见本轮浏览器证据（`artifacts/android-desktop-v07/native-browser-results.json`）。测试 provider 为 `com.google.android.webview / 145.0.7632.218`，使用本机 loopback 页面，未导航公网或请求真实模型；系统 IME、OS 后台调度与 4 GB 资源不在这次通过范围。

Writer 的 ODT / DOCX 真实 GUI 保存与重开 **2/2 通过**，模板保持不变，停止桌面后核对实际 ZIP/XML 与修改哈希，见办公证据（`artifacts/android-desktop-v07/office-results.json`）。v6 桌面最终基线 **3/3 通过**，见桌面证据（`artifacts/android-desktop-v07/desktop-results.json`）；生命周期由真实 Android 上的 Flutter binding 注入，不证明 OS 后台调度。Calc/Impress、复杂格式与系统中文输入法不在这两项 Writer 通过范围内。

历史 0.7 Android 自动化合计 **28/28 通过**：浏览器 5、Writer 2、桌面 3，加既有回归 18（`artifacts/android-desktop-v07/runtime-regression-results.json`）（容器 7、Linux/Python 8、原生存储/文档 3）。Linux 日志有 9 条检查记录，但对应 8 个测试用例，按 8 项计数；均在实际 Android 上执行，没有真实模型请求。最终 APK 已通过静态校验与安装一致性，人工入口与往返复核已通过。

历史 0.7 冻结交付：ARM64 调试 APK（`artifacts/apk/PerAnt-0.7.0-debug-arm64.apk`）、SHA-256 文件（`artifacts/apk/PerAnt-0.7.0-debug-arm64.apk.sha256`）；自动化总结果（`artifacts/android-desktop-v07/integration-results.json`）、包体校验（`artifacts/android-desktop-v07/apk-verification.json`）、安装一致性（`artifacts/android-desktop-v07/installed-apk-verification.json`）。版本 0.7.0/2007、仅 ARM64、min SDK 29 / target 36、v2 签名；375 项运行资源与 211 项许可/归属文件已逐项核对源码。最终 APK 通过 `--use-application-binary` 启动，设备安装字节摘要与冻结交付一致；人工入口与往返复核已通过。

最终冻结 APK 的人工入口与往返复核（`artifacts/android-desktop-v07/manual-apk-check.json`）已通过：聊天“更多”打开原生浏览器，实际显示 `https://example.org/` 正文；电脑“应用 → 文档”打开“未命名 1 — LibreOffice Writer”；“应用 → 浏览器”恢复同一 URL 和正文，页头返回后自动 RFB 重连到原 Writer。Xvnc/Xfce/Writer 进程保持不变，未修改源码或热更新。三张原始 1080×2400 PNG：聊天浏览器（`artifacts/android-desktop-v07/browser-apk-api37.png`）、Writer 入口（`artifacts/android-desktop-v07/writer-apk-api37.png`）、电脑浏览器（`artifacts/android-desktop-v07/browser-from-computer-apk-api37.png`）。返回 Writer 已实际观察但未另存截图；文档保存证据仍来自独立的两项设备测试。这次公网 HTTPS 人工观察与自动化 loopback 场景分开，不代表真实模型、系统中文 IME、长期后台或低配设备已验收。

浏览器 5 项覆盖真实 JS/输入与像素、平台视图触控/旧 revision 拒绝、隐藏同页捕获和重挂载、长按取消复用、导航历史/尺寸/关闭，以及隐藏弹窗取消和 HTML/空正文 HTTP 404 错误恢复。10 张实际 PNG 随证据保留；不使用宿主浏览器画面代替。

**历史 0.6.0 / v4：**Dart 208、Python 12、JVM 56、API 37 ARM64 设备 21/21（桌面 3、既有回归 18）通过，含菜单、Thunar、终端 GUI 文件、设置、Mousepad、临时观察和图像释放。历史最终 APK 的聊天入口、Thunar 和短时最近任务切换见人工记录（`artifacts/android-desktop-v06/manual-apk-check.json`）、结构化结果（`artifacts/android-desktop-v06/integration-results.json`）与包体校验（`artifacts/android-desktop-v06/apk-verification.json`）。这些结果不证明 0.7 浏览器或办公能力。

可在 `apps/perant` 中复跑对应设备用例，测试使用隔离目录与模拟模型响应；新增浏览器和办公用例的最终命令/证据在开发状态更新。旧记录见0.5 桌面（`artifacts/android-desktop/VERIFICATION.md`）、0.4 文件（`artifacts/android-container/VERIFICATION.md`）、0.3 Python（`artifacts/android-python/VERIFICATION.md`）与0.2 终端（`artifacts/android-linux/VERIFICATION.md`）。真实视觉模型、中文输入法、完整用户/模型协作、iOS、4 GB 设备和后台仍未验收；完整 M1-D 保持未完成。
