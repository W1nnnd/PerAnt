# Android Linux 运行资源

`tool/prepare-linux-runtime` 使用固定源码构建 Android ARM64 PRoot，并准备校验过的 Alpine minirootfs、14 个官方 Python APK、355 个官方桌面／应用 APK 及两个内置工具脚本。当前运行资源版本为 **`perant-alpine-3.24.4-aarch64-v6`**。源码、工具链版本、下载地址与 SHA256 记录在 [sources.lock.json](../third_party/linux/sources.lock.json)。脚本只处理本项目 `.tooling/linux-runtime` 缓存与生成资源，不安装 SDK、不运行 Flutter/Gradle、不触碰设备。

文中标注的本地开发证据和构建产物（如 `artifacts/`、`.tooling/` 与生成的运行资源）未随本次源码发布；源码预览的验证范围以文内记录为准。

```sh
tool/prepare-linux-runtime
# 离线校验已生成资源；不联网、不编译，缺失或不匹配返回非零
tool/prepare-linux-runtime --verify-existing
# 仅下载并校验全部固定输入
tool/prepare-linux-runtime --fetch-only
# 使用相同源版本重新构建的实验 loader；默认仍保留 OpenMinis 固定字节
tool/prepare-linux-runtime --loader rebuilt
```

默认 NDK 路径是 `.tooling/android-sdk/ndk/28.2.13676358`，也支持 `ANDROID_NDK_HOME` 或 `ANDROID_NDK_ROOT`。要求这个精确 NDK 版本、Python 3、GNU make 和可运行的 NDK clang。支持 macOS 与 Linux x86_64 构建宿主；Android 最低 API 29。

首次准备原生 PNG/XPM 兼容库还需要可用的 Docker daemon；ARM64 宿主直接运行，Linux x86_64 宿主需启用 ARM64 QEMU/binfmt。`tool/build-linux-codec` 从已固定 SHA256 的官方 Alpine minirootfs 导入专用 ARM64 builder，不依赖滚动 Docker Hub tag；81 个构建 APK 的版本、摘要和安装脚本均固定，容器禁网安装并编译。构建依赖不进入应用。已缓存匹配产物时可复用；`--verify-existing` 不启动 Docker、不编译，也不依赖该构建缓存。

产物位于 Flutter 插件的 Android 原生资源目录：

- `packages/perant_platform/android/src/main/jniLibs/arm64-v8a/libproot.so`
- `packages/perant_platform/android/src/main/jniLibs/arm64-v8a/libproot-loader.so`
- `packages/perant_platform/android/src/main/assets/perant-linux/rootfs.tar.gz.bin`
- 同目录的 `packages/*.apk.bin`、`tools/text_to_markdown.py`、`tools/start_desktop.sh`、`compat/libgdk_pixbuf-2.0.so.0`、`runtime-manifest.json` 与 `licenses/`

v6 的 manifest 校验 **375 项运行资源**：rootfs、PRoot 与 loader 共 3 项，Python APK 14 项，桌面／应用 APK 355 项，固定脚本 2 项，原生图像兼容库 1 项；manifest 本身与许可来源文件另计。生成的资源目录与 `jniLibs` 二进制被 Git 忽略。源码锁、许可证和本脚本保留在仓库；本地安装 SDK/NDK 后执行完整准备，再进行检查和 APK 构建。仓库不配置 GitHub CI 测试。`--verify-existing` 同时检查 manifest 固定字段、rootfs/ELF/Python 和桌面 APK/工具脚本/兼容库的大小与 SHA256、APK 包身份/依赖/签名 key 名、已审阅安装脚本的名称与内容摘要、ARM64 ELF、16 KB LOAD 对齐、选定 loader 的 POKEDATA stub 偏移，以及 notice/许可证/来源清单副本与仓库原件一致；不依赖 NDK 或下载缓存。实际 APK RSA 签名由设备上的 Alpine 包管理器验证，主机构建检查不冒充设备签名验证。

0.0.13 的 v6 历史冻结资源共 **432,783,532 字节**，准备和独立离线校验均通过；原生浏览器 5 项与 Writer 的 ODT／DOCX 保存重开 2 项设备检查通过，不能把包内存在或静态校验当作其他功能验收：

| 固定项 | 大小 / SHA256 |
| --- | --- |
| `start_desktop.sh` | 30,319 字节；`5a4e3867a63d8256ee380ae75ab71568d4c68fbf759d3e339a3d6241bb84e73d` |
| `runtime-manifest.json` | 99,837 字节；`60ee1f699facf6eb71985de0ca4b082cddd622701a410ccc667bd843bb8c66e6` |
| `compat/libgdk_pixbuf-2.0.so.0` | 198,528 字节；`544c7eaedae251da320d8ee747edc015d2c3cfa6372bae694ad9a6992dbf7d22` |

日志为 `.tooling/desktop-v6-prepare.log` 与 `.tooling/desktop-v6-offline-verification.log`；源脚本和资源变更后必须重新准备，并以新 manifest 摘要为准。

PRoot 与 loader 是 ELF 可执行文件，`.so` 后缀用于让 Android 安装器放入 `nativeLibraryDir`。必须由 APK 安装流程解压到该目录并保留可执行权限；不能复制到应用 `files/` 后再执行。启动器设置 `PROOT_LOADER` 为安装后 loader 的绝对路径，执行真实 Alpine `/bin/sh`。Android 的可写目录执行限制见 [Android 10 官方说明](https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission)。此前 v4 已在 API 37 ARM64 模拟器、target SDK 36 的测试应用验证终端与 Xfce 执行；这不是 v6 原生浏览器／Office 验证，其他设备与 ROM 仍未验证。

Alpine 固定为官方 **3.24.4 / aarch64**，压缩包 4,029,843 字节，SHA256 为 `4b14c18f7e90a063b61462ea1462a5732c154bf6adad594974fe6487cd98a8de`。下载保留官方 `.tar.gz` 文件名；APK asset 使用 `rootfs.tar.gz.bin`，避免 AAPT 自动解压 `.gz` 并改名为 `.tar`。归档 gzip 字节与校验值不变，解包安装器按 manifest 校验。它提供 BusyBox、musl、apk-tools 等最小用户空间，原始归档不含 Python 或桌面。Python 和桌面以独立官方包安装，不改写该 minirootfs 的字节或哈希；当前仍没有编译工具链或独立 Linux 内核。[alpine-packages.json](../third_party/linux/alpine-packages.json) 保留 base 的 16 个包及 Python 闭包的 14 个包；[desktop-packages.json](../third_party/linux/desktop-packages.json) 保留桌面／应用闭包的 355 个包，均标明来源与 aports commit。

## 离线 Python 与环境升级

Python 固定为 **3.14.10-r1**，新增 14 个官方包共 **10,829,637 字节**，包元数据估算增加 32,630,860 安装字节。闭包为 python3、gdbm、libbz2、libexpat、libffi、libgcc、libncursesw、libpanelw、libstdc++、mpdecimal、ncurses-terminfo-base、readline、sqlite-libs 和 xz-libs；其中 terminfo 是 noarch，其余为 aarch64。base 已包含 Mozilla CA bundle 和 OpenSSL 库。不含 pip、编译工具链或 `python3-pyc` 字节码缓存包。

每个 APK 的版本、SHA256、大小、依赖、来源、许可证、aports commit 与签名 key 名均固定在 `sources.lock.json`。Python 和桌面包的签名 key 均为 `alpine-devel@lists.alpinelinux.org-616ae350.rsa.pub`，该公钥已随原始 minirootfs 提供。包保持完整签名字节，asset 后缀为 `.apk.bin`，复制进 staging 后恢复 `.apk` 文件名，由 PRoot 执行：

```text
/sbin/apk add --no-network --no-cache --no-progress <固定的Python与桌面本地APK路径>
```

不允许不受信任签名，不联网更新索引，也不自行拼造 apk 数据库。14 个 Python 包自身无安装脚本；桌面包包含 23 个已审阅的安装脚本/trigger，包括字体、缓存、MIME 更新、私有 D-Bus 用户及 machine-id 初始化和信息提示，名称与脚本内容摘要均固定在源码锁。初始化不启动系统 D-Bus 或网络服务。新增或变更的安装脚本会使准备流程失败；base 中的既有包管理器/trigger 仍属于受信任初始化环境。滚动仓库索引只保存查询时的来源信息，不作为每次构建必须重新下载的输入；若固定 APK 被上游移除或哈希不符，构建明确失败，不自动换版本。

v6 安装先在独立 staging 目录解包，校验并安装 APK、文字工具和图像兼容库，再检查 Python 版本、CA 载入、SQLite、Xvnc 与 Xfce／LibreOffice 实际普通可执行路径，使用真实兼容库解码固定 PNG/XPM，成功后原子发布 ready 标记。从 0.0.14 起，安装身份使用固定桌面脚本描述符后的清单摘要，可直接识别匹配的 0.0.13 安装。包集合、文字工具、loader 和兼容库仍参与安装校验。当前 APK 的桌面脚本每次按清单校验大小和 SHA256 后写入私有会话目录。历史运行时目录与独立 `/workspace` 保留。初始化失败不发布新 ready，输入与已有工作区不被重置。含桌面包的原生离线安装阶段超时为 **240 秒**，Dart 初始化调用默认等待 **300 秒**；Python 与桌面自检分别有独立的 15 秒和 30 秒超时。可执行文件自检不等同于原生浏览器协作或 Office 编辑保存验收。

自研脚本源是 `packages/perant_platform/android/src/main/python/text_to_markdown.py`，构建脚本复制到 generated assets 并记录大小/摘要。任务调用前再次校验已安装脚本；具体输入、文件交换与发布规则见[本地 Python 文本任务](PYTHON_TEXT_TASK.md)。

## 图形桌面与启动权限

桌面使用官方 Alpine v3.24 aarch64/noarch 包：**TigerVNC 1.16.2-r0、Xfce 4.20**，其中 xfce4-session 4.20.2-r0、xfwm4 4.20.0-r1、xfce4-panel 4.20.7-r0、xfdesktop 4.20.1-r0、xfce4-settings 4.20.4-r0、xfconf 4.20.0-r2、Thunar 4.20.8-r0、Xfce Terminal 1.2.0-r0、Mousepad 0.7.0-r0、Application Finder 4.20.0-r0。v6 保留 v4 的全部 178 个固定包版本，并包含 LibreOffice 25.8.7.3-r0 Writer／Calc／Impress、匹配的简体中文和 GTK 集成及依赖，共 **355 个桌面／应用 APK、417,378,446 压缩字节**，声明安装大小 **1,103,522,175 字节**。实验 v5 的 Firefox 及 14 个仅其需要的依赖已从锁、APK 资产与对应来源清单移除，办公／Xfce 所需共享库仍保留。浏览器按用户选择使用 Android 原生引擎，不属于 Linux 包库存。上述数字是完整办公套件的存储规模，不是运行内存测量或低配机性能承诺。没有安装宽泛的 xfce4 或 LibreOffice meta 包；所选应用的实际完整依赖均保留。原有 Openbox/Tint2/PCManFM/Xfe/xterm 仍不重复打包。

中文环境为 `zh_CN.UTF-8`，14 个匹配的 Xfce 官方语言包共 7,274,845 压缩字节；未加入 10 MB 的 GTK 全语言包，少量 GTK 通用控件可回退英文。Mesa/LLVM 仍占主要体积，低配手机的实际内存与启动速度还需实测和精简。

浏览器使用 Android 原生引擎，在同一 PerAnt“模型的电脑”工作区中提供网页入口与模型工具；浏览器下载、上传和文件到共享工作区的传递尚未接入。不保留无效 Linux 浏览器启动器或 MIME 关联。系统浏览器引擎不复制进 Linux 包、不另行运行桌面浏览器进程；使用系统默认渲染隔离与正常 TLS 校验。真实 HTML/JavaScript、输入、隐藏查看、URL 边界和错误恢复的 5 项 Android 设备检查已通过，见本轮浏览器记录（`artifacts/android-desktop-v07/native-browser-results.json`）；不代表全部网站或系统后台已验收。此前 v5 原版 Firefox 151 的 headless 与 X11 试验都在实际 app 中失败；失败证据仅供诊断，不作为 v6 能力。

办公应用为真实 LibreOffice Writer、Calc、Impress，使用官方 `libvclplug_gtk3lo.so` 与 `SAL_USE_VCLPLUGIN=gtk3`，而非 GTK4/GSK 渲染。独立 profile 位于 `/root/.perant-office`，工作目录为 `/workspace`；通过真实 `soffice.bin` 和明确的 `URE_BOOTSTRAP` 启动。官方 oosplash 仅用 `stat(/proc/version)` 的预检在 Android 可能产生假阴性，因此使用同版官方脚本支持的直接 ELF 路径，不改二进制、不关闭安全功能。`/usr/bin/libreoffice` 与 `/usr/bin/soffice` 是官方符号链接；原生严格文件自检使用真实普通文件 `/usr/lib/libreoffice/program/soffice`、`soffice.bin` 及 GTK3 插件。文档创建、格式保存与重开必须通过 GUI 流程和实际输出文件验证；本轮尚未将命令行转换等同于 GUI 编辑通过。

固定启动脚本源为 [start_desktop.sh](../packages/perant_platform/android/src/main/desktop/start_desktop.sh)，由准备脚本复制并将大小和 SHA256 纳入 manifest，每次启动前再次校验。脚本启动真实 Xvnc、私有 session D-Bus 及 **xfce4-session**；会话使用官方 Failsafe 五客户端：xfwm4、xfsettingsd、xfce4-panel、Thunar --daemon、xfdesktop。没有预先打开浏览器或办公窗口，只有点击启动入口才执行应用。compositor 关闭；私有 XDG autostart 覆盖禁用硬件、电源、屏幕锁定、agent、自动挂载与缩略图等非必要自启，不启动 system D-Bus，也不使用 Android root 权限。固定 polkit-noelogind-libs 提供依赖，不安装 elogind 或启动权限服务。

建议竖屏 720×1080、横屏 1120×700。84 像素底栏使用真实 Xfce applicationsmenu、文件/终端/编辑器启动器、任务切换、时钟和显示桌面插件。系统设置与全部应用可从开始菜单打开。PerAnt 原创浅色 Xfwm 主题提供 80×80 像素原生窗口按钮；标题、菜单和正文默认 18pt，桌面图标 80 像素。Thunar 和桌面单击打开，Thunar、新终端和编辑器默认最大化；任务栏通过正常窗口管理协议预留空间。所有外观均由真实 Linux 应用渲染。

快捷键同时配置 Xfce 命令与窗口管理器的 custom provider，并显式设置 override 防止首次启动恢复默认值。xfwm4 按动作选择第一条快捷键，因此显示桌面、切换和最大化先删除同动作的默认旧键，再写目标键，避免旧 Ctrl+Alt+d 抢先于 Super+d：

| 快捷键 | 实际操作 |
| --- | --- |
| Super+空格 | xfce4-popup-applicationsmenu |
| Super+e | Thunar 打开 `/workspace` |
| Ctrl+Alt+t | 独立 Xfce Terminal，工作目录 `/workspace`、标题 `PerAnt Terminal` |
| Super+n | Mousepad 编辑器 |
| Super+w / Super+c / Super+p | LibreOffice Writer／Calc／Impress |
| Super+i | xfce4-settings-manager |
| Super+d | xfwm4 显示桌面 |
| Alt+F10 / Alt+Tab | xfwm4 最大化 / 切换窗口 |

Xfce 启动器、界面配置、GSettings keyfile、图标和窗口主题只写私有会话目录，不向用户 `/workspace` 写配置或快捷方式；Office 使用上述独立 Linux 内 profile；原生浏览器状态由 Android 组件管理。GSettings 使用 keyfile backend，无额外偏好守护进程。图标和窗口 XPM 为 PerAnt 原创，不使用 Apple/Microsoft 资产；固定 XPM 不依赖 Glycin 命名空间解码，也不禁用任何解码器沙箱。工作区图像缩略图关闭。

官方 Alpine GdkPixbuf 2.44.7 APK 使用 Glycin，在本次 PRoot 首启中出现实际 PNG/XPM 不可解码并导致 GTK 面板退出。因此保留官方签名 APK 原字节，另从同版 **2.44.7** 官方未改源码构建仅含标准 PNG/XPM 的兼容库，不退回旧版，也不关闭 Glycin/bubblewrap 沙箱。该库保留原 SONAME，通过 `desktop.codecLibrary` 单独校验、复制到 `/opt/perant/lib`；只有图形会话及其子进程设置相应 guest `LD_LIBRARY_PATH`。JPEG/GIF/TIFF/other/Glycin/Android 解码和缩略图均未编入这个变体，不宣称支持任意图像格式。初始化用实际安装库解码固定 PNG/XPM 并验证像素；Docker 两次全新构建也真实解码两种格式，当前宿主两次输出摘要一致，不据此承诺跨宿主逐字节一致。完整源码、构建包、精确 flags、环境和验证见 [native-codec.json](../third_party/linux/native-codec.json)、[构建配方](../third_party/linux/native-codec/build.sh)与 [build-linux-codec](../tool/build-linux-codec)。

私有 `mimeapps.list` 将 `text/plain` 和 `text/markdown` 关联到官方 `org.xfce.mousepad.desktop`，从文件管理器打开这些文档可直接进入 Mousepad。

Thunar 保留官方的 root 账号提示条。这里的 uid 0 是 PRoot 的 guest 身份，不表示取得 Android root；该版本没有关闭此提示的官方偏好，本项目不隐藏其它系统警告。

桌面启动先等实际 X11 socket，再等待存活的 xfce4-session/xfwm4、实际 EWMH 桌面属性，以及通过各自 PID 验证的可见面板/桌面窗口，才原子写入 `/run/perant-desktop/desktop.ready`，内容为 `perant-desktop-v6\n`。原生端同时检查该普通文件和真实 RFB banner；会话退出清理标记。X11 socket 最多等待 15 秒，Xfce 映射轮询最多 25 秒，原生桌面启动超时 45 秒；不把固定等待时间当作可用证明。

原生宿主创建短随机应用私有目录，分别映射到 guest `/run/perant-desktop` 和 `/tmp`。RFB 只监听权限 **0600** 的文件系统 Unix socket，TCP 关闭；`SecurityTypes None` 仅用于该私有本地传输。X11 同样关闭 TCP，使用原生宿主随机 MIT-MAGIC-COOKIE-1 和权限 0600 的 Xauthority。`umask 077` 不改变 Android 应用权限，guest 的 `/tmp` 权限只作用于应用私有映射目录。PRoot 不提供独立内核或强隔离。

APK 查看器连接同一实际桌面；离页或后台关闭显示连接并清除画面，Linux 会话进程保留，不代表 Android 保证后台续跑。模型按需截图、键鼠协作和授权见[容器电脑说明](CONTAINER_COMPUTER.md)。本机已通过生成配置/原生主题文件/源码声明校验；完整 Xfce 在 Android 设备的实际图标、中文、菜单和命令链路仍以本轮设备验收记录为准。

## PRoot 与 loader 配对

构建参考是 [OpenMinis 固定版脚本](https://github.com/OpenMinis/OpenMinis/blob/1a71df0f381cefde80bf912b723de6f9831bc177/deps/build_proot.sh)，PRoot 源码固定为 `2ca3bae3650988c0e098b4bb7686b79617b64194`。talloc 2.4.2 通过兼容头单独静态编译，不依赖完整 Samba 构建系统。

该脚本明确记录部分 ROM 使用 fork 自编 loader 会出现 guest 首条指令 SEGV，默认采用仓库保留的 Termux 5.1.107-70 loader，SHA256 `44ef39c1e1a18c09f6e4c4b5d6f8bba82d30596598bd155ec162d05c5122ff04`。我们已定位 [Termux 原始构建配方](https://github.com/termux/termux-packages/blob/0ff4d49dad73ed7a62375504cf96326bb835e132/packages/proot/build.sh)，它固定 `termux/proot` 源码 `4dba3afbf3a63af89b4d9c1a59bf2bda10f4d10f`；对应源码 ZIP 的 SHA256 为 `a72668607184f981e44181bfa47f86ef52d52bb237b4012ee94f0dc89cb39211`。

实查两个固定源码版本的 `src/loader/loader.c`、`assembly.S`、`arch.h` 内容一致，因此不能仅凭上游脚本注释认定是缺少 loader 源码补丁。NDK、clang 和链接参数也会改变程序布局。脚本另外编译 Termux 原始源的 loader，保存在 `.tooling/linux-runtime/build/libproot-loader-rebuilt.so`，哈希写入 manifest 供测试；默认不会将它替换进 APK。编译可复现步骤已经固定，尚未承诺跨宿主逐字节一致或跨 ROM 兼容。

脚本还修正了 loader 偏移的宿主差异：上游生成器依赖 GNU awk 的 `\y` 和 `strtonum`，macOS 默认 awk 会产生错误的零偏移。脚本解析选定 loader 的 ELF 执行段，查找上游 `assembly.S` 的固定 POKEDATA stub，按入口地址计算偏移并重链 PRoot。当前默认 loader 偏移为 `0x460`，NDK 重建 loader 为 `0x3f8`；结果写入 manifest，不能交叉替换。它没有改变下载的源码，仅替换构建生成的 `loader-info.c`。

本机已通过 NDK 28.2 编译和 ELF 静态检查：PRoot 为 AArch64 PIE，动态解释器 `/system/bin/linker64`；固定 loader 为无动态解释器的 AArch64 EXEC；两者 LOAD 段按 `0x4000` 对齐。默认 PRoot SHA256 `efaf4f45d281e2d3faf36b8df71b585d7df010e479f9ee7797f27cb6a0c8275b`。这些检查不等价于 Android 设备执行通过。

## 历史终端与 Python 验证

本节保留 v1/v2 的历史基线，不能作为当前图形桌面或最终交付包的验收记录。本轮桌面验证与当前限制见[容器电脑说明](CONTAINER_COMPUTER.md)及对应验收产物。

`apps/perant/integration_test/linux_runtime_test.dart` 在 API 37 ARM64 模拟器、target SDK 36 上 **8/8 通过**，日志 `.tooling/python-linux-device.log`。新增 Python 3.14.10 标准库、CA 载入、SQLite、中文路径、受控文字→MD 与 20,000 个 emoji／80,000 字节输入的结构化传递；Shell 形式原文未执行。此前 5 项 Shell/PTY/持久化/FIFO/取消与超时/受控路径探测全部回归。固定命令见[测试源码](../apps/perant/integration_test/linux_runtime_test.dart)，9 条原生检查记录见本轮结构化证据（`artifacts/android-python/integration-results.json`）；取消和超时分别记录，因此记录数多于测试数。CA 检查未发出公网 HTTPS 请求。

默认保留 PRoot 的 seccomp 优化，不强制设置 `PROOT_NO_SECCOMP=1`。强制关闭时曾在交互会话复现 `getcwd: Function not implemented`；移除覆盖后，上述真实工作目录与整段会话无该警告的断言通过。这个结论限于当前模拟器与固定构建，不代表其他 ROM 的兼容性已验证。

当时应用入口为聊天页 **更多 → 本地终端** 和 **更多 → 本地整理为 Markdown**。0.3.0（2003）独立 APK 已通过构建、v2 调试签名及 18 项包内运行资源哈希校验，并在 API 37 模拟器更新安装；仅 ARM64、min SDK 29 / target SDK 36，见当时验收记录（`artifacts/android-python/VERIFICATION.md`）。当时已目视确认普通应用启动至对话页；新增功能的人工点击流程未完成，原生 UI 集成测试已通过。0.2.0 手动终端验收保留在历史报告（`artifacts/android-linux/VERIFICATION.md`）及截图（`artifacts/android-linux/terminal-keyboard-api37.png`），不替代新增桌面功能或其他设备验收。

## 许可证与对应源码

保留原始版权及许可证，见 [NOTICE](../third_party/linux/NOTICE.md)。新增 Python、bzip2、expat、libffi、ncurses、mpdecimal、SQLite、XZ 和 GCC runtime exception 等文本及固定来源记录已随 APK 打包；见[许可证来源清单](../third_party/linux/licenses/Python-dependency-license-sources.json)。PRoot 源码头允许 GPL-2.0-or-later；静态链接 LGPL-3.0-or-later talloc 的产物按 GPLv3 分发。Alpine 内的 GPL-2.0-only 组件保留其独立许可，作为 rootfs 聚合分发。

桌面包的[许可来源清单](../third_party/linux/licenses/Desktop-package-license-sources.json)保留固定 SPDX 数据版本的 **45 份参考许可文本**、匹配官方文档／运行 APK 提取的 **81 份上游版权/许可文件**、字体原始 OpenType 数据中的 **23 份版权/许可说明**，以及 15 个经固定 SHA512 核验的 Xfce 原始源档和 GdkPixbuf 源档中的 **33 份 COPYING/COPYING.LIB/AUTHORS**；记录原始归档摘要、成员路径与提取来源。兼容库为 **LGPL-2.1-or-later**，原始 COPYING 保留在 `Desktop-source-gdk-pixbuf-2.44.7-COPYING.txt`，自研构建配方与启动脚本为 GPL-3.0-only，不替代该库的 LGPL。参考许可文本不替代各软件自己的版权声明。[desktop-source-recipes.json](../third_party/linux/desktop-source-recipes.json) 固定 **290 个对应 Alpine aports 构建配方**的 commit、路径和 SHA256，来源集合与当前桌面闭包一致，覆盖上游源码 URL、补丁及来源校验值。移除旧桌面归属和 28 个过期下载输入，不继续打包旧组件 APK 或声明。包清单、配方清单、NOTICE、`native-codec.json` 与许可文本均复制到 APK 的 `perant-linux/licenses/`；准备会清理过期副本，离线校验要求文件集合与字节均和仓库原件一致。

公开分发 APK 时，在同一 GitHub Release 附上完整对应源码分卷、校验清单和匹配的 PerAnt 源码版本。旧编号 0.9.0 已补齐并校验固定 Alpine 配方目录、源归档、静态依赖和 Rust 依赖，0.0.1 的运行资源未变，沿用同一套输入并重新绑定到新 APK；清单见 [release-sources.lock.json](../third_party/linux/release-sources.lock.json)，打包与重组方法见[公开安装包与对应源码](PUBLIC_BINARY_RELEASE.md)。发布附件是否已上线，以 Release 实际文件为准；本地生成完成不等于已公开。

LibreOffice 保留自己的 MPL-2.0／第三方许可及品牌，PerAnt 不主张其作者身份；实际安装的 `LICENSE`、`LICENSE.html`、`NOTICE` 另复制进许可来源清单。原生浏览器使用系统提供的 Android 引擎，其二进制不作为 Linux APK 或独立浏览器包重新分发。

历史 0.8 源码预览只有 290 份桌面配方，因此未公开 APK。0.9.0 的发布源码清单覆盖合并库存的 **385 条包记录、309 个独立直接来源**，另保留 BusyBox 精确静态依赖 utmps 0.1.3.2／skalibs 2.14.5.0，共 **311 份完整 aports 目录、799 个 SHA512 校验输入**。官方 aarch64 BusyBox 构建日志记录了这两个静态版本及实际链接参数，随源码包保留。原始 Cargo.lock、Alpine 的 nix 版本补丁和 Mesa Meson wrap 合并为 **573 个 SHA256 校验 Rust 源包**；PRoot、talloc、Termux loader 源码、完整固定 Termux 构建框架及 GdkPixbuf 源码与构建脚本另行提供。

清单核对和依赖闭包审阅见[技术审阅记录](LINUX_SOURCE_CLOSURE_REVIEW.md)。它验证实际收集的源码和构建声明，未宣称独立重建过每个上游二进制，也不承诺跨工具链逐字节重现。`tool/prepare-linux-runtime --fetch-only` 仍仅准备运行资源；发布源码使用独立的 `tool/package-linux-sources --fetch`，不会修改运行资源、应用代码或用户数据。

PRoot 路径映射不是安全沙箱。本轮受控探测只在应用 supportDir 创建无敏感标记，guest 经 `/proc/<宿主PID>/root<标记路径>` 尝试读取，结果为不可读；标记随后删除。单路径结果不证明宿主数据无法通过其他方式访问，不据此启用模型任意 Shell 自动执行。实体手机、其他 ROM、低配资源、后台/锁屏续跑与更完整的访问边界仍待验证。
