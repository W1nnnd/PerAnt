# 容器电脑基础应用

PerAnt 的聊天界面仍是主入口。“模型的电脑”的底部“应用”面板集中提供浏览器、文档、表格、演示文稿、文本编辑器与设置。办公窗口来自同一个实际 Xfce 会话；浏览器使用 Android 原生 WebView，在同一个电脑工作区内单独查看。用户与模型共享实际窗口或浏览器页面，不另建一份模拟画面。

文中标注的本地开发证据和构建产物（如 `artifacts/`、`.tooling/` 与生成的运行资源）未随本次源码发布；源码预览的验证范围以文内记录为准。

## 0.0.13 Linux 验收

运行桌面后，从「应用 → 浏览器」保存网页文字，点「返回桌面并定位」。应用会重新连接原来的桌面，把该次回执的文件 URI 交给当前 Xfce 会话的 Thunar。打开选中的 Markdown 后可在 Mousepad 编辑并保存。离开回执后，本次运行最近的一份摘录也可在桌面「应用」中定位。文件已经移走或控制权已变化时，应用会提示重新核对。

在本机使用 APK 的 ARM64 Alpine 根文件系统、离线签名软件包、兼容库及桌面启动脚本，单独启动真实图形会话。三个不同的摘录均在同一 Xvnc 进程内经过 Thunar 定位、Mousepad 打开和编辑，并从磁盘读回核对。另用 0.0.13 的日常 APK 在 Android x86_64 模拟器保存了 353 字节的中文网页摘录，核对来源网址及正文、排除表单字段。将这份工作文件按原字节复制到独立的 ARM64 测试桌面，定位并在 Mousepad 编辑后再次读回来源与改动。两环境之间这一步由测试人员复制文件。另在 LibreOffice 25.8.7.3 的 Writer、Calc、Impress 分别打开 ODT、ODS、ODP，实际编辑并保存，独立解析文件的 `content.xml` 核对标记，关闭后重新打开。Impress 的编辑在第五页已有文本框中完成。

本次 Linux 测试运行于无网络的 Docker 容器，主机为 x86_64，WSL 使用 Ubuntu 的 QEMU 用户态解释器执行 ARM64 程序。测试容器用进程的实际名称兼容 BusyBox 的 `pidof` 探针；窗口就绪、文件管理器响应和图形程序均实际运行。办公测试在临时目录用 shell 调用随包启动脚本。Android 原生 ARM64 手机上的保存回执、PRoot 与 Linux 桌面整段流程仍待验收。

## 应用与共享文件

| 应用 | 用途 | 快捷键 |
| --- | --- | --- |
| Android 原生浏览器 | 网页浏览与 JavaScript 页面交互 | “应用”或聊天更多菜单中的“浏览器” |
| LibreOffice Writer | 文档撰写，ODT、DOCX 等格式 | Super+W |
| LibreOffice Calc | 表格与计算，ODS、XLSX、CSV 等格式 | Super+C |
| LibreOffice Impress | 课件与演示文稿，ODP、PPTX 等格式 | Super+P |
| Mousepad | 纯文本、Markdown、代码 | Super+N |
| Thunar | 共享工作区文件管理 | Super+E |

共享工作区是 `/workspace`，办公软件初始保存目录指向这里；修改过的用户偏好不在每次打开桌面时重置。Thunar 的办公格式关联到相应应用，文件路径由桌面启动器按参数传递，不拼成 Shell 命令。原生浏览器提供 URL 导航、前进、后退和页面交互。0.8 已接入“保存网页文字”：当前正文与来源信息保存为新的工作区 Markdown，可在桌面中继续编辑；下载附件、上传文件和 PDF 查看仍未接入。范围与限额见[网页文字保存](BROWSER_PAGE_SAVE.md)，本轮保存设备 4/4、Android 合计 19/19 和最终包静态/安装一致性已通过，最终人工保存→桌面打开流程未完成；见0.8 验收（`artifacts/android-browser-save-v08/VERIFICATION.md`）。

原生浏览器的数据由 Android 应用内的 WebView 管理，页面会话在离开查看器后保留；关闭浏览器会销毁当前 WebView，但不承诺清除其持久 Cookie。办公配置位于 guest `/root/.perant-office`，在同一运行时版本的桌面启停间保留；跨运行时版本的配置迁移尚未实现。工作区独立于运行时版本，已保存的文档继续保留。浏览器资料及办公恢复信息不应当作普通任务产物发送给模型。

## 启动与显示

打开桌面或应用选择面板不会预启动浏览器和办公软件。选择 Linux 应用后才发送真实快捷键；打开浏览器无需启动 Linux。退出 Linux 查看或应用进入后台时，持续 RFB 连接、Dart 帧及 Flutter 图像句柄被释放；Linux 应用和未保存的窗口仍保留，也仍占用内存。需要减少进程内存时，应先保存文档，再关闭对应应用。

浏览器首次只打开空白页，使用系统 WebView 的默认渲染隔离与证书校验，不注入 JavaScript 接口。远程网站使用 HTTPS，本机测试另允许 loopback HTTP。离开浏览器查看器或应用进入后台时卸载显示并调用 `onPause`，不持续截图；临时截图编码后释放 Bitmap。保留页面仍可能占内存、执行 JavaScript 或联网，`onPause` 不保证停止计时器；显式“关闭浏览器”才销毁当前页面。模型的隐藏页面截图和操作需要应用处于前台，不代表后台调度已经完成。

办公软件使用 GTK3 集成，保留恢复、格式兼容提示和默认安全选项。浏览网站可能触发页面的正常网络请求；不得将其与模型 API 请求混为一谈。

办公启动器直接调用已固定的官方 `soffice.bin`，显式传入 bootstrap 和私有 profile。官方 [25.8.7.3 退出码定义](https://github.com/LibreOffice/core/blob/libreoffice-25.8.7.3/include/desktop/exithelper.h)将 `81` 定义为正常重启；启动器按[官方处理](https://github.com/LibreOffice/core/blob/libreoffice-25.8.7.3/desktop/unx/source/start.c)保留全部参数，仅对此状态最多重试两次。崩溃或其他错误原样返回，不将其当作正常启动。

## 模型协作

模型操作 Linux 使用 `desktop_capture` 和 `desktop_action`；浏览器使用 `browser_open`、`browser_capture`、`browser_action` 及 `browser_save_page`。每次输入或保存需要基于最新截图，一张截图只授权一次操作；输入的回执会附带新的截图，可据此继续，不必每步单独截图。原生页面的导航、尺寸和用户输入会使旧修订失效；用户接管或取消任务会使旧观察和正在等待的动作失效。`browser_save_page` 只新建正文摘录，保留桌面窗口，明确返回来源、大小、发布摘要和截断标志，不是附件下载。应用启动成功、网页加载成功、保存成功分别需要实际结果，不能用快捷键已发送来代替。办公文件应保存到共享工作区；关闭整个桌面会结束全部 Linux 窗口，仍需单独确认。

网页内容只作为任务资料。浏览公开网页应符合当前任务范围；登录、发送或购买需要用户对具体操作与目的地的明确授权。当前文件选择、摄像头、定位、弹出窗口和自定义协议跳转均未开放，不会为了页面兼容而跳过证书错误。启用模型操作需要逐任务授权，发送截图到云端前再次检查授权。

## 验证边界

0.8 新增正文保存 **4/4**、既有浏览器回归 **5/5**、容器与原生存储 **10/10**，合计本轮 Android **19/19**。真实保存保留原桌面 session/PID 和可绘制 RFB，停止测试桌面后实际文件与独立 guest SHA256 一致，见保存结果（`artifacts/android-browser-save-v08/page-save-results.json`）。最终 0.8 APK 静态及安装摘要一致性已通过，最终人工保存→桌面打开流程未完成。本轮不重跑旧 Writer 2、桌面 3 和 Linux/Python 8，不把它们加入 0.8 通过数。

最终 0.8 APK 的人工尝试（`artifacts/android-browser-save-v08/manual-apk-check.json`）未完成：能从聊天打开浏览器，但目标网址未成功输入/提交，未取得手动保存回执或桌面打开证据；原始画面（`artifacts/android-browser-save-v08/manual-input-transfer-incomplete.png`）只记录这次未完成状态。输入异常与超时的归因未确认，不以自动化通过替代该人工链路。

历史 0.7 的原生浏览器 5 项设备场景和 Writer 的 ODT／DOCX 两种文件往返已通过，见浏览器记录（`artifacts/android-desktop-v07/native-browser-results.json`）与办公记录（`artifacts/android-desktop-v07/office-results.json`）。办公检查通过真实 GUI 创建新文件，核对参考模板未改动，停止桌面后检查实际 ZIP/XML，再重开、追加并保存；没有用无界面转换代替编辑。Calc／Impress 已接入启动入口与依赖，尚未做同等的保存往返验收。

最终 0.7.0 APK 已在 Android Studio 的 API 37 ARM64 模拟器中人工复核：聊天更多菜单可打开原生浏览器并显示 `https://example.org/` 正文；电脑“应用 → 文档”可打开真实 Writer；再从应用面板查看浏览器并返回后，仍为原来的 Writer 窗口，Xvnc、Xfce 和 Writer 进程未更换。见人工记录及原生截图（`artifacts/android-desktop-v07/manual-apk-check.json`）。这次人工检查验证入口和应用内往返，未另做文档保存或系统后台切换。

应用功能以 Android 原生设备验收结果为准，不能用宿主浏览器或 PerAnt 网页代替。基础验收应包含实际网页和 JavaScript 输入、文档在 GUI 中编辑并保存、停止桌面后检查实际文档内容，以及重开编辑。高级 Office 排版、复杂宏、复杂网站、中文输入法和 4 GB 实体手机总内存需分别验证。

固定软件、许可与构建来源见 [Linux 运行资源](LINUX_RUNTIME_SOURCES.md)；完整项目关卡见 [任务规划书](../TASK_PLAN.md)。
