# 开发状态

**0.0.13+2022 · Linux 桌面验收版。** 浏览器保存网页后可返回原 Xfce 桌面，由 Thunar 定位到回执的具体文件。Linux 端只接收当前会话中生成的摘录路径；切换控制权或文件消失时会报告失败。点击定位不会重复创建摘录，用户在文件管理器里打开选中的文件即可编辑。

项目实际的 ARM64 Alpine 桌面组件在隔离的 Linux 环境中完成三轮摘录定位、打开、编辑和磁盘核对，Xvnc 始终为同一个进程。Writer、Calc 和 Impress 各完成一次原生文档编辑、保存和重开。宿主通过 323 项 Dart/Flutter、14 项 Python、72 项 Android JVM，另有两项可选截图跳过。环境差异、应用入口及待完成的手机验收见[桌面应用记录](DESKTOP_APPLICATIONS.md)。

**0.0.12+2021** 修复了本机会议纪要中无来源的决定、负责人和日期。0.0.11 的日常使用包在 4 GB Android 模拟器上收到单句 `PerAnt offline office roundtrip 011` 后，生成了原文中没有的“技术团队”和“2024-10-27”。新版本逐段请求模型选择原文编号，逐层汇总时继续从已有引文中选择。应用只根据原资料和所选编号写入正文，每条引文附资料修订对应的 Unicode 字位。连续长句需要截取时另有标记。编号不合法时按原文顺序保留摘录，并在草稿中说明。

本机两台 Android API 37 x86_64 模拟器都以 Qwen3.5-0.8B、2K 上下文跑完五份合计 20,000 字的重复主题样本。4 GiB 用时 730.545 秒，3 GiB 用时 735.300 秒。后者逐条核对草稿中 113 处引用，涵盖全部五份资料，文本与所列字位完全一致。另测单句、已决定与明确待定三种输入，原文均得到保留。该结果验证出处准确性，真实会议的重点取舍仍待人工验收。

内存记录更正：原测试 AVD 请求 3072 MiB，但模拟器把配置提升到 4096 MiB，Android 报告 MemTotal 4,007,044 KiB。0.0.8 的 249 毫秒和 0.0.10 的首次十轮恢复均按 4 GiB 记录。显式限制 QEMU 内存后，Android 报告 3,041,164 KiB；在该配置下复跑 0.0.10 的十轮进程中断（含五次熄屏/唤醒），恢复十份已确认资料，自动请求为零，每次启动均验证测试库满额后的事务回滚及重试。

日常 APK 覆盖安装时保留了旧版中断任务选择的两份资料。点击继续后从原文重新选句，只产生当前草稿且清除该任务的进度；随后用 0.0.11 的单句复现材料再次生成，重点及分段两处均逐字保留原句。宿主检查通过 320 项 Dart/Flutter 和 14 项 Python，另有两项可选截图跳过。

0.0.11 未完成的任务会保留资料选择、模型和上下文。首次继续时重新核对来源指纹并从原文选句。已保存为文档的历史草稿仍按原修订保存，用户可以回到原资料重新整理。

**0.0.11+2020** 支持从已完成的步骤继续本机会议纪要。在「文件 → 整理纪要」可以看到上次选中的资料、模型、上下文和已保存步数，也可确认清除进度。每个完整分段或汇总结果保存到本机 SQLite；最终草稿与清除进度一起提交。资料的内容或修订、模型权重、上下文和算法版本必须匹配。未完成的私有进度不进入备份。

4 GB Android API 37 x86_64 模拟器、Qwen3.5-0.8B、2K 上下文：两份中文资料共四段。两段已保存时从模拟器外终止应用进程，重开后实际复用两步，完成六步生成，数据库只出现一份 482 字的纪要草稿。宿主回归另覆盖在汇总阶段中断、修改来源、迟到写入、重复发布及手工清除。该次设备验证覆盖离线推理，不涉及真实云服务的断点续接。

同一场景在模拟器开启飞行模式并关闭 Wi-Fi、移动数据后再次通过。运行前后 Android 均报告没有默认网络。复测后还原了模拟器网络设置。

在归纳第二段时，用 Android Activity Manager 向当前进程发送 `RUNNING_CRITICAL` 低内存通知。应用停止当前归纳、释放真实推理引擎、保留已完成的第一步；用户再次点击加载后引擎就绪，SQLite 中的进度相同。该测试验证系统通知的处理，实际内存耗尽和厂商后台策略仍需真机验证。

复测使用专用 AVD 和已校验的 0.8B 模型。安装由 `integration_test/meeting_recovery_test.dart` 和 `--dart-define=PERANT_KILL_MEETING=true` 构建的 APK，运行 `tool/android-model-recovery.ps1 -Target <模拟器序列号> -Probe Meeting`。低内存用例改用 `integration_test/local_model_pressure_test.dart`、`--dart-define=PERANT_EXTERNAL_MEMORY=true` 和 `-Probe Memory`。

**0.0.10+2019** 在首次初始化 Linux、安装中文推理模型与嵌入模型前显示存储估算。Android 从应用私有目录所在分区读取当前可用字节。GGUF 续传会扣除已下载部分，空间不足时在发起 HTTP 前报告缺口，保留断点。

4 GiB Android API 37 x86_64 模拟器完成十轮后台、终止 PerAnt 测试进程并从冷启动恢复，其中五轮包含系统熄屏、唤醒和解锁。每轮在已经确认的中文文档保存完成、固定回环请求开始后终止进程；重开后十份文档逐字一致，十个任务均显示中断，旧授权不可复用，自动发起请求数为零。每次启动还对独立 SQLite 数据库设置页数上限，实际触发 SQLITE_FULL，检查失败编辑没有产生新修订或新检索结果，解除上限后成功保存。该方法限定测试库，不占满设备分区。系统自行回收、物理断电和实体机厂商策略仍待验证。

复现时在专用 Android 模拟器安装由 `integration_test/storage_pressure_test.dart` 和 `--dart-define=PERANT_PROCESS_PROBE=true` 构建的调试包，运行 `tool/android-recovery-stress.ps1 -Target <模拟器序列号>`。脚本只在测试进程发出就绪信号后终止该应用。

**0.0.9+2018** 的模型设置可在首次保存前向指定服务获取模型列表，也支持手填 ID。已保存的配置可分别编辑、切换和删除 Key。保存或切换本身无需网络，切换后重新建立协议上下文。服务、模型、采样参数或凭据变化后重置验证状态。基础测试发送固定短文本，工具测试以两轮固定消息检查 echo 参数、调用身份及最终 PONG 回复。两个协议均支持选填 temperature 和 top_p。

Android API 37 x86_64 的回环测试覆盖目录去重、两个独立凭据、关闭并重开 SQLite 后切换配置、双协议工具回合、错误参数中止及备份排除凭据。测试在独立数据库运行。宿主静态分析通过，314 项 Dart/Flutter、14 项 Python 通过，另有两项可选截图跳过。该回合验证本地实现；真实供应商记录仍以 0.0.1 的 DeepSeek 实测为准。

**0.0.8+2017** 为 SQLite 增加按需读取的资料目录。列表保留修订身份，打开编辑器、版本差异或记忆出处时加载所选正文。引用预览和发送前核对只读取指定修订中的局部片段。备份显式遍历全部修订，未浏览的正文随导出读取，不加入界面缓存。旧快照仍可打开；首次缺少提取记录时逐份检查已确认资料的偏好语句。数据库代数发生变化时，过期实例拒绝读取旧引用和覆盖新数据。

4 GiB Android API 37 x86_64 模拟器用 1,000 份资料和 1,001 个修订冷启动，249 毫秒完成初始化。启动、查询和引用核对累计载入完整正文 0 份，打开当前文档及旧版本后为 2 份，编辑并导出全库备份后为 3 份。另一组 500 万字、18,500 个片段的 FTS4 测试中，50 个关键词全部命中前五，查询 P50/P90 为 2.447/12.033 毫秒。六个设备用例还覆盖了旧大快照迁移、30 个修订、PDF 分页、记忆编辑与删除、重开和回环服务的引用问答。宿主回归通过 312 项 Dart/Flutter、14 项 Python，另有 2 项可选截图跳过。

**0.0.7+2016** 把 Qwen3.5 文本推理接到设备 CPU。两款 Q4_K_M 文件可下载或从系统文件选择器导入，校验字节数和 SHA-256 后发布到应用私有目录。下载中断时保留断点，服务器忽略 Range 时重新接收并校验。模型文件单独安装。Android 应用选用 llamadart 0.20.2 的 llama.cpp 原生发行 v1.0.0-3，Apple 工程声明同版 SwiftPM 插件。两种模型分别占 532,517,120 和 1,280,835,840 字节。源模型为 Apache-2.0，量化文件分别固定在 [0.8B 修订](https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/tree/6ab461498e2023f6e3c1baea90a8f0fe38ab64d0) 和 [2B 修订](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/tree/f6d5376be1edb4d416d56da11e5397a961aca8ae)。[推理适配器](https://pub.dev/packages/llamadart/versions/0.20.2) · [原生构建来源](https://github.com/leehack/llamadart-native/releases/tag/v1.0.0-3)

「本地中文模型」支持直接提问、查已有文档和创建新笔记。模型只决定建议的操作类别，查找词或笔记文字取自用户指定的「原文」，执行前会显示供确认。支持 Linux 的设备还可选择用既有固定 Python 程序整理笔记。编辑器可对选中的 1–320 字生成润色建议，显示逐字差异，接受后进入编辑草稿。已确认修订可以另存为 UTF-8 Markdown。会议纪要支持 1–5 份资料，合计最多 20,000 个 Unicode 码点，按最多 480 字一段归纳，再分层汇总，各段附资料版本和字位。取消、写入冲突和输出达到上限会中止发布。

Android API 37 x86_64 模拟器配置 4 GB，CPU 推理使用 2 个线程。每组包含 20 条查资料、20 条建笔记与 10 条超出范围的指令。正确项计入精确参数和合理拒绝，其中 10 条显式超范围指令由应用先行识别。P50/P90 为从提交到建议或澄清的用时，样本含拒绝，正式动作仍需用户确认。两款模型均实际生成了含「北京」的中文回答。观测窗内应用进程的最大采样 PSS 分别为 1,014,715 和 1,665,257 KiB。

| 模型 | 上下文 | 正确 | 加载 / 加载后首条 | 已加载 P50 / P90 |
| --- | ---: | ---: | ---: | ---: |
| 0.8B | 2K | 49/50 | 1.448 / 3.094 秒 | 2.773 / 2.817 秒 |
| 0.8B | 4K | 49/50 | 0.367 / 2.842 秒 | 2.796 / 2.877 秒 |
| 2B | 2K | 50/50 | 2.198 / 7.190 秒 | 7.158 / 7.669 秒 |
| 2B | 4K | 50/50 | 0.372 / 7.321 秒 | 7.231 / 7.417 秒 |

各配置之间卸载原生引擎，操作系统文件缓存可能仍有效。调整前同一题集为 43/50 和 38/50，调整后的成绩适用于这组回归题。默认使用 0.8B、2K。2B 未达到约 5 秒目标，实体机成绩待测。

同一 4 GB 模拟器以 0.8B 处理五份共 20,000 字的合成会议资料，45 个来源片段、四轮汇总用时 727.907 秒，生成 3,520 字草稿。测试核对五份资料的身份与版本、五组字位、预算和期限，随后实际润色选中文字并取消另一次流式生成。每份样本重复一个主题，真实会议的归纳质量仍需独立评审。宿主通过 312 项 Dart/Flutter 和 14 项 Python，另有两项可选截图跳过。

**0.0.6+2015** 提供可暂停、可继续的设备端语义索引。原文更新或删除会退役对应向量，重复片段共享向量。模型与词表按固定 SHA-256 校验，支持网络下载和本机文件导入。「引用本机资料提问」仅发送本轮问题、所选片段标题、引用编号与正文，本地任务记录保存来源修订和位置。后续普通消息不会复用这次引用问答的请求或回复。双协议的请求边界经测试端点验证。

Android API 37 x86_64 上，BGE INT8 的 50 道同义改写题 Top-5 为 49/50，5 道无答案题均未返回资料。千份语料包含重复文档，共 500 万字符、18,575 个片段，去重后 92 个向量；建向量用时 19.202 秒，查询 P50/P90 为 376/388 毫秒。该结果不能外推到 18,575 份互异片段或低配真机。宿主 CPU 另用同一组 50 道改写题对比：原精度、INT8 的 Top-1 分别为 40、41，Top-5 均为 49。设备实验采用公开转换的固定版本与原配词表，ONNX Runtime 由 flutter_onnxruntime 1.9.0 提供。[原始模型](https://huggingface.co/BAAI/bge-small-zh-v1.5) · [固定 ONNX 版本](https://huggingface.co/Xenova/bge-small-zh-v1.5/tree/75c43b069aac4d136ba6bc1122f995fedcfd2781) · [移动端插件](https://pub.dev/packages/flutter_onnxruntime/versions/1.9.0)

**0.0.5+2014** 在「文件」中搜索资料名称和正文，点击片段会打开当前修订并选中关键词。本地长期记忆保存来源与修订，允许修改、删除及暂停自动提取。工作区备份同时保存记忆和删除抑制记录。Android API 37 x86_64 的 SQLite FTS4 压测采用 1,000 份、500 万字符的合成语料。数据库 44,183,552 字节，首次保存及建索引 3.206 秒，重开并载入工作区 240 毫秒。50 个标注关键词均在前五条中命中。查询调用耗时 P50 为 2.679 毫秒，P90 为 4.061 毫秒，最长 6.664 毫秒。该计时不含界面绘制，语义改写另行验收。

**0.0.4+2013** 从已确认的资料生成独立课件大纲。用户编辑和确认大纲后，可将它导出为含原生文本框的 PPTX。「PerAnt 入门」五页样本已用 Microsoft PowerPoint 16.0 验证可编辑、可另存和重开。相同资料可以导出静态 HTML，Android 工作文件编辑器可预览和修改生成的页面。导出文件无需连接模型服务。

**0.0.3+2012（2026-11-20）** 已能从文件页导入 Word 和文字 PDF，从最多五份资料生成带行号和版本引用的本机会议草稿。编辑器可比较历史，恢复后另存新修订，确认后导出。工作区备份保留正文与历史、对话、任务与偏好，恢复前确认整体替换，诊断文件按字段清单输出计数及最近状态。Android API 37 x86_64 实测了中文 PDF 按页提取、超过 2 MB 的旧 SQLite 快照迁移、连续 30 个修订写入、重开及删除。独立 PDF 阅读库验证了 6 页 A4 的中文长段、跨页表格与文字边界。Android 系统文件选择器已实测导入 DOCX 和文字 PDF，确认后另存两种格式，取回文件后均能读回最后一段。Microsoft Word 16.0 打开了 8 页 DOCX，修改 74 行表格中的单元格后另存并重开成功。iOS 端尚待编译与设备验收。

PDF 使用随应用分发的霞鹜文楷 1.530。原版 TTF 的 SHA-256 为 `2d73eea94ad808999d90c0000c239a84a33b09d4bc6ab6c5b8bbf1eda8a7fc8b`，OFL 许可随字体打包。Android 的 PDF 文字提取采用 PdfBox-Android 2.0.27.0。[字体来源](https://github.com/lxgw/LxgwWenKai/releases/tag/v1.530) · [PdfBox-Android](https://github.com/TomRoush/PdfBox-Android)

**0.0.2+2011 历史记录。** Android 工作文件与网页保存可在首次安装 Linux 前使用。Android API 37 x86_64 模拟器上的 10 个业务用例中通过 9 个：WebView 与工作区 7 个、原生安全存储 1 个、SQLite 文档编辑与重开 1 个。文件流程的单个用例连续运行了 30 轮。离线 Python 文档用例在架构检查处失败，设备明确提示需要原生 ARM64。宿主 Python 14 项、Dart 与 Flutter 共 293 项、Android JVM 72 项通过，另外 2 项可选截图用例跳过。复测方法与 Writer 验收条件见[开发计划](../TASK_PLAN.md#第一轮的交付与验收)。

**0.0.1+2010（2026-11-16）历史记录。** 版本号自本版起从 0.0.1 重新计算，构建号继续递增；下文的 0.6～0.9 均为旧编号。本版第一次用真实 DeepSeek API 在 4 GB 模拟器上实测，修复了普通聊天假装执行、电脑入口不可达、截图坐标偏差、滚动后截图空白、网页首次保存失败等问题。普通聊天、模型写文件、模型操作桌面终端、模型打开网页点击链接并保存（最终构建连续 5 次）、手动浏览保存、本地整理和终端通过。Python 14、Dart 292、Android JVM 72 通过。逐项记录与未验证范围见 [0.0.1 说明](releases/0.0.1.md)。

**以下为旧编号 0.9 的记录。** 0.9.0+2009 为 Concept 06 移动端界面与图标迁移。三导航、圆框小蚁、真实授权与本机偏好已接入。本地 Dart 280 / Python 14、格式/静态分析通过；4 GB / 宿主 GPU 的 API 36 ARM64 原生 smoke 3/3 通过。最终 APK 的三尺寸布局、键盘返回和系统图标已核对，3 GB 软件渲染冷安装超时保留为失败。范围见 [迁移与验收说明](UI_CONCEPT06_IMPLEMENTATION.md)。

**以下为 0.8 的历史基线，独立计数，不作为 0.9 新增通过项。** 0.8.0+2008 实现网页正文保存到共享工作区。其 `tool/check`、Android JVM 72/72、共享 C 发布核心 probe 6/6、Android 集成 19/19 及 0.8 APK 静态/安装一致性均已通过；人工保存→桌面打开流程未完成。历史 0.7 的 28 项设备结果不累加为 0.8 通过数。M0 双端与完整 M1-D 关卡仍未完成。

文中标注的本地开发证据和构建产物（如 `artifacts/`、`.tooling/` 与生成的运行资源）未随本次源码发布；源码预览的验证范围以文内记录为准。

## 当前实现

| 部分 | 当前内容 | 验证边界 |
| --- | --- | --- |
| 工作区与许可 | Flutter 共享应用、三个包、SDK 包装器、GPL-3.0-only | 本地开发，远端发布结果另记 |
| 对话与模型配置 | nanoMuse 参考、多会话、可跳过 API、预设与凭据引用；两种 OpenAI 格式协议 | 未用真实用户 Key 验证所有供应商 |
| Linux / Python | PRoot/匹配 loader、Alpine 3.24.4、Python 3.14.10、JNI PTY、独立 `/workspace` | Android ARM64；iOS、实体低配手机和其他 ROM 待测 |
| Linux 桌面与办公 | Xvnc/Xfce、Thunar、终端、Mousepad、设置；LibreOffice Writer/Calc/Impress、zh_CN、GTK3、私有办公配置 | 历史 0.7 v6 桌面 3/3、Writer ODT/DOCX 2/2；本轮未重跑，Calc/Impress 和复杂格式未验 |
| 原生浏览器 | 同一电脑工作区内的 Android WebView；地址、历史导航、网页交互与接管；电脑应用面板/聊天更多入口 | 用户明确选择原生浏览器路线；Linux Firefox 原型失败并已移除；历史 0.7 原生设备 5/5；本轮 0.8 浏览器回归 5/5 |
| 按需显示 | 桌面前台连续 RFB、隐藏释放帧和图像；浏览器按需捕获 PNG、临时挂载与 Bitmap 释放 | 保留 X server/窗口和 WebView 会话仍占内存；隐藏不保证 JS timers 或网络停止 |
| 模型协作 | 文件、Shell、desktop 工具及 browser_open/capture/action/save_page；最新观察/revision、控制权与取消检查；截图副本叠加像素标尺，输入回执附带新截图 | 协议测试使用 fixture PNG / MockClient；0.0.1 用 DeepSeek `deepseek-chat` 在模拟器上实测了桌面终端与一个网页任务，其他供应商未测 |
| 网页正文资料 | 用户“保存网页文字”、模型 `browser_save_page`；固定 DOM 提取、来源/时间、明确截断、256 KiB Markdown、根目录新建 | 本轮 Android 保存 4/4、最终 APK/安装一致性通过；最终人工保存→桌面打开流程未完成，不等于下载附件或上传 |
| 文件与产物预览 | `/workspace` UTF-8 编辑、SHA256 冲突、Markdown、独立静态 HTML WebView | 通用文件 API 与活跃 guest/桌面互斥；专用正文导入允许已就绪桌面；静态预览继续禁脚本、禁网络 |
| 数据与恢复 | SQLite 文档/任务/会话/操作，凭据存储；取消及重开不重放；PNG 不入库 | 不含向量索引、长期记忆、完整备份或跨进程恢复 |
| 本地文字整理 | 固定 Python、真实 Markdown 草稿、编辑和确认 | 保留原文并规范排版，不生成语义摘要 |

## 0.8.0 本轮状态

| 检查 | 当前结果 |
| --- | --- |
| 格式、静态分析、完整宿主测试 | **通过：Dart 252**（核心/网关 38、平台/应用 214）、**Python 14**，全格式与静态分析通过；另 2 项可选截图跳过 |
| 模型浏览器协议 | **17/17 通过**；含 Chat/Responses 保存回执持久化、单次观察、无云授权拒绝、取消/接管、未知结果屏障和回执保存失败后不重试；属于模拟 API/桥接测试 |
| Android JVM | **72/72 通过**，不代替真实 WebView、JNI 或应用端到端结果 |
| Android 原生共享发布核心 | **6/6 通过**；实际 API 36 ARM64 probe 使用生产 JNI 同一 `workspace_import.h`，测试独立临时目录，未访问应用数据；结果（`artifacts/android-browser-save-v08/native-workspace-import-probe.json`）与来源摘要（`artifacts/android-browser-save-v08/native-workspace-import-provenance.json`） |
| 本轮 Android 集成 | **19/19 通过**：网页保存 4、既有浏览器 5、容器 7、原生存储/文档 3；见汇总（`artifacts/android-browser-save-v08/integration-results.json`） |
| 最终 0.8 APK / 安装一致性 | **通过**：冻结包（`artifacts/apk/PerAnt-0.8.0-debug-arm64.apk`）、SHA-256（`artifacts/apk/PerAnt-0.8.0-debug-arm64.apk.sha256`）、静态核验（`artifacts/android-browser-save-v08/apk-verification.json`）与安装记录（`artifacts/android-browser-save-v08/installed-apk-verification.json`）；0.8.0/2008、ARM64、min29/target36、v2 |
| 最终 0.8 APK 人工入口 | **未完成**，状态 `incomplete`；人工记录（`artifacts/android-browser-save-v08/manual-apk-check.json`）及原始画面（`artifacts/android-browser-save-v08/manual-input-transfer-incomplete.png`）。未成功输入/提交目标网址，未取得保存回执或桌面编辑证据 |

本轮选择独立测试 AVD `emulator-5556`：API 36、ARM64、配置 3072 MiB / 2 核，实际 WebView `com.google.android.webview / 133.0.6943.137`，系统报告 MemTotal 3,047,188 KiB。原有 `emulator-5554` 的个人桌面与窗口保留；先前停止该会话的自动审批未通过，采用独立 AVD 继续验证。这个模拟器配置不是 4 GB 实体低配手机资源验收。

原生核心 probe 6 项与已通过的 Flutter 集成 19 项分别计数；本轮不重跑旧 Linux/Python 8、Writer 2 和桌面 3，不把历史通过数加成 0.8 设备总数。原生核心探针不证明完整应用链路，JVM 不证明实际 JNI 发布。最终记录集中在0.8 验收报告（`artifacts/android-browser-save-v08/VERIFICATION.md`）。

网页保存 4/4（`artifacts/android-browser-save-v08/page-save-results.json`）覆盖真实 DOM 排除、SPA 导航使旧 revision 失效、超限明确截断（最终 Markdown 262,142 字节）、已就绪桌面下发布并保留同 session/PID 6041 与可绘制 RFB，以及普通终端忙时拒绝导入。最终成功用例文件 343 字节，停止测试桌面后实际读回 SHA256 与独立 guest `sha256sum` 一致；这份读回证据与仅描述发布字节的正常工具回执分开。另浏览器 5/5（`artifacts/android-browser-save-v08/native-browser-results.json`）和容器/原生存储 10/10（`artifacts/android-browser-save-v08/runtime-regression-results.json`）均通过。

冻结 0.8 APK 为 **503,977,705 字节（480.63 MiB）**，SHA-256：`d2209156497c5e8f194719426c9e46987bf82649535098fef5dc305aced4a649`。375 项资源、211 项归属与源码匹配，包内新增 JNI 动态符号已核验，17 项生产来源摘要与已完成宿主检查匹配；通过 `--use-application-binary` 启动的设备安装字节摘要一致，未重建或热更新。

测试过程中保留失败及重试记录。只修改了测试 PTY 事件归属和轮询方式，未修改生产初始化、放宽断言、预热或延长原有 100 秒完成等待；最终冷路径通过。调度竞争仍只是推测，不写成已确认原因。见尝试记录（`artifacts/android-browser-save-v08/test-attempts.json`）及测试源码检查（`artifacts/android-browser-save-v08/fixture-source-checks.json`）。

最终包在 Android Studio 嵌入的测试模拟器中启动到对话主界面，“更多 → 浏览器”打开 `about:blank`，保存按钮存在且处于禁用状态。人工尝试中宿主键盘/粘贴未按预期填入地址，软键盘输入出现丢字和重音字符，一次 CUA 调用超时；冷启动后曾出现 System UI 无响应提示并选择 Wait。上述观察不证明具体根因，也不是成功导航或保存。没有实际保存回执和在 Linux 编辑器打开文件的人工证据，人工链路仍未完成；自动化 19/19 与包体/安装一致性保持各自通过范围。

新增功能契约见[网页文字保存](BROWSER_PAGE_SAVE.md)：文件回执描述发布字节，不是活跃 Linux 后续修改后的读回；不覆盖原件，不下载附件或上传，不停止原桌面，取消后已发布文件可能保留。

## 历史 0.7.0+2007 验收

以下结果只证明该版冻结 APK 和当时的 v6 资源，不代替新增网页保存或本轮回归。

| 检查 | 当前结果 |
| --- | --- |
| 格式、静态分析、完整宿主测试 | **通过：Dart 223 项**（核心/网关 38、平台/应用 185）、**Python 14 项**、格式与全仓静态分析；另 2 项可选截图跳过。浏览器服务/查看器定向 **21 项**通过；使用模拟桥接/API，不等于设备或真实供应商验收 |
| 新增浏览器模型协议 | 9 项通过：Chat/Responses PNG 多模态、错误页 PNG 与加载状态回执、工具回执与来源标签、普通聊天无授权、过期观察、取消/接管后迟到截图、回执保存期间撤权、URL 与图片预算拒绝 |
| Android JVM | **66/66 通过**；属于原生契约与组件测试，不证明 WebView 实际渲染或办公 GUI 可用 |
| v6 原生桌面基线 | **3/3 通过**：真实菜单/Thunar/终端/设置/编辑器和文件持久化、隐藏单帧观察、paused 双图像句柄同步释放/恢复与 unmount 清理。见证据（`artifacts/android-desktop-v07/desktop-results.json`）；生命周期由 binding 注入 |
| 原生浏览器 | **5/5 通过**，含真实 JS/输入/像素、真实平台视图触控及旧 revision 拒绝、隐藏同页观察/重挂载、长按取消、历史/尺寸/关闭、弹窗取消、HTML 与空正文 HTTP 404 错误保留和恢复；见证据（`artifacts/android-desktop-v07/native-browser-results.json`） |
| 既有 Android 回归 | **18/18 通过**：容器 7、Linux/Python 8、原生存储/文档 3，见本轮结果（`artifacts/android-desktop-v07/runtime-regression-results.json`）；Linux 9 条记录属于 8 个用例，不按记录数累加 |
| Android 自动化合计 | **28/28 通过**：浏览器 5 + Writer 2 + 桌面 3 + 容器 7 + Linux/Python 8 + 原生存储/文档 3；均为实际 Android，未请求真实模型 |
| Office 启动器兼容 | 仅重试 `NORMAL_RESTART=81`，最多总计 3 次；3 个生成脚本语法检查与 21 个独立 Shell 功能场景通过，保留参数、环境、profile 和 stdout/stderr，其他错误码不重试。见证据（`artifacts/android-desktop-v07/office-launcher-shell-check.json`）；由新增 2 个 Python unittest 方法覆盖并纳入 Python 14，不按 21 个场景再次累加 |
| LibreOffice Writer | **2/2 通过**：ODT、DOCX 从测试模板经 GUI Save As 创建新文件，原模板不变；停止桌面后核对 ZIP/XML，重开追加保存后哈希改变且原文保留。DOCX 两次真实点击“使用 Word 2007 格式”，不使用 Alt+U。见证据（`artifacts/android-desktop-v07/office-results.json`） |
| 运行资源 | v6 冻结 manifest：355 个官方签名桌面/办公 APK、375 项运行资源，合计 **432,783,532 字节**；375 项资源与 211 项许可/归属文件已按最终 APK 逐项核对源码 |
| 0.7.0 APK | 冻结 APK（`artifacts/apk/PerAnt-0.7.0-debug-arm64.apk`） / SHA-256（`artifacts/apk/PerAnt-0.7.0-debug-arm64.apk.sha256`） 已通过 ZIP/签名/manifest/资源/许可校验，0.7.0/2007、ARM64、min29/target36、v2；设备安装摘要与交付一致。见包体（`artifacts/android-desktop-v07/apk-verification.json`）和安装记录（`artifacts/android-desktop-v07/installed-apk-verification.json`） |
| 人工入口复核 | **通过**；同一冻结 APK 的聊天/电脑浏览器、正式 Writer 入口与浏览器返回原 Writer 均已实际观察。见人工记录（`artifacts/android-desktop-v07/manual-apk-check.json`），状态 `passed`；Mac 解锁阻塞已解除 |

人工复核使用原冻结 APK，没有源码修改或热更新。浏览器返回后自动重连同一 Writer；Xvnc 30411、Xfce 30415、Writer 31023 前后保持不变。入口与往返不等于再次执行保存测试，保存/重开以独立的两项 Writer 设备结果为准。

冻结资源 manifest SHA-256 为 `60ee1f699facf6eb71985de0ca4b082cddd622701a410ccc667bd843bb8c66e6`。manifest 大小为 **99,837 字节**；对应启动脚本 **30,319 字节**，SHA-256 为 `5a4e3867a63d8256ee380ae75ab71568d4c68fbf759d3e339a3d6241bb84e73d`。这是资源清单及脚本摘要，不是 APK 摘要；最终交付包大小、摘要与签名已由包体记录确认，设备安装字节摘要一致。

LibreOffice 启动器直接使用官方 `soffice.bin`、显式 `URE_BOOTSTRAP`、GTK3 与 `SAL_ENABLE_FILE_LOCKING=1`；私有配置位于 `/root/.perant-office`，文档在 `/workspace`。浏览器采用独立 Android WebView，不依赖 Linux Firefox 或桌面查看器；没有模型 JS/关闭工具，也不开放网页下载、文件选择上传或权限授予流程。应用与使用入口见[基础应用说明](DESKTOP_APPLICATIONS.md)。

`browser_open` 回执只表示已请求打开。观察携带实际 PNG、`loading`、`error` 与 `page_loaded`；错误页截图仍可成功返回，`page_loaded` 只表示观察时加载已结束且无已知错误，不等于任务或内容成功。HTTP 404（有正文及空正文）错误保留与恢复、隐藏 alert/confirm/prompt 取消、远程明文地址导航前拒绝已纳入本轮 5/5；公网网站与 TLS 服务兼容性未在 loopback 场景中验收。

浏览器需要前台 Activity 才能按需观察和操作；隐藏查看页时卸载 viewer、停止连续截图并释放 Bitmap，保留同一页面会话。`onPause` / 隐藏不保证 JavaScript timers、网页网络或 Chromium renderer 内存归零，显式关闭才销毁会话。桌面隐藏也不终止 Linux 应用。后台常驻与锁屏续跑未实现。

自动化原生浏览器 **5/5 通过**，见本轮浏览器证据（`artifacts/android-desktop-v07/native-browser-results.json`）。测试 provider 为 `com.google.android.webview / 145.0.7632.218`，使用本机 loopback 页面，未导航公网或请求真实模型；系统 IME、OS 后台调度与 4 GB 资源不在这次通过范围。

Writer 的 ODT / DOCX 真实 GUI 保存与重开 **2/2 通过**，模板保持不变，停止桌面后核对实际 ZIP/XML 与修改哈希，见办公证据（`artifacts/android-desktop-v07/office-results.json`）。v6 桌面最终基线 **3/3 通过**，见桌面证据（`artifacts/android-desktop-v07/desktop-results.json`）；生命周期由真实 Android 上的 Flutter binding 注入，不证明 OS 后台调度。Calc/Impress、复杂格式与系统中文输入法不在这两项 Writer 通过范围内。

历史 0.7 Android 自动化合计 **28/28 通过**：浏览器 5、Writer 2、桌面 3，加既有回归 18（`artifacts/android-desktop-v07/runtime-regression-results.json`）（容器 7、Linux/Python 8、原生存储/文档 3）。Linux 日志有 9 条检查记录，但对应 8 个测试用例，按 8 项计数；均在实际 Android 上执行，没有真实模型请求。最终 APK 已通过静态校验与安装一致性，人工入口与往返复核已通过。

历史 0.7 冻结交付：ARM64 调试 APK（`artifacts/apk/PerAnt-0.7.0-debug-arm64.apk`）、SHA-256 文件（`artifacts/apk/PerAnt-0.7.0-debug-arm64.apk.sha256`）；自动化总结果（`artifacts/android-desktop-v07/integration-results.json`）、包体校验（`artifacts/android-desktop-v07/apk-verification.json`）、安装一致性（`artifacts/android-desktop-v07/installed-apk-verification.json`）。版本 0.7.0/2007、仅 ARM64、min SDK 29 / target 36、v2 签名；375 项运行资源与 211 项许可/归属文件已逐项核对源码。最终 APK 通过 `--use-application-binary` 启动，设备安装字节摘要与冻结交付一致；人工入口与往返复核已通过。

最终冻结 APK 的人工入口与往返复核（`artifacts/android-desktop-v07/manual-apk-check.json`）已通过：聊天“更多”打开原生浏览器，实际显示 `https://example.org/` 正文；电脑“应用 → 文档”打开“未命名 1 — LibreOffice Writer”；“应用 → 浏览器”恢复同一 URL 和正文，页头返回后自动 RFB 重连到原 Writer。Xvnc/Xfce/Writer 进程保持不变，未修改源码或热更新。三张原始 1080×2400 PNG：聊天浏览器（`artifacts/android-desktop-v07/browser-apk-api37.png`）、Writer 入口（`artifacts/android-desktop-v07/writer-apk-api37.png`）、电脑浏览器（`artifacts/android-desktop-v07/browser-from-computer-apk-api37.png`）。返回 Writer 已实际观察但未另存截图；文档保存证据仍来自独立的两项设备测试。这次公网 HTTPS 人工观察与自动化 loopback 场景分开，不代表真实模型、系统中文 IME、长期后台或低配设备已验收。

本轮浏览器保留 10 张原生 PNG 证据，包括隐藏 JS 结果（`artifacts/android-desktop-v07/browser-native-hidden-js-result.png`）、同页重挂载（`artifacts/android-desktop-v07/browser-native-remounted-same-page.png`）和空正文 HTTP 404（`artifacts/android-desktop-v07/browser-native-real-http404-empty.png`）。设备日志明确未验证系统 IME 注入或实际 OS 后台切换，不能扩大为已完成中文输入或系统续跑。

## 历史 0.6.0+2006

以下只证明 **v4 Xfce 核心桌面与当时最终 APK**，不代替 0.7.0 浏览器、办公应用或 v6 环境验收。

| 检查 | 0.6 历史结果 |
| --- | --- |
| 完整 `tool/check` | Dart 208（核心/网关 38、平台/应用 170）、Python 12，格式与静态分析通过；另 2 项截图默认跳过 |
| Android JVM | 56/56 通过 |
| API 37 ARM64 原生集成 | 21/21：Xfce 桌面 3、既有回归 18（容器 7、Linux/Python 8、存储/文档 3） |
| 历史资源 | 198 项运行资源、152 项许可/来源文件、178 个桌面 APK、144 个桌面源码来源及配方已核对 |
| 历史人工复核 | 聊天电脑卡进入 Xfce、Thunar、短时最近任务切换后恢复同一窗口；不证明长期后台、锁屏或 4 GB 目标 |

记录见结构化结果（`artifacts/android-desktop-v06/integration-results.json`）、验收报告（`artifacts/android-desktop-v06/VERIFICATION.md`）、人工记录（`artifacts/android-desktop-v06/manual-apk-check.json`）和包体校验（`artifacts/android-desktop-v06/apk-verification.json`）。绑定注入的生命周期事件不等于系统后台任务调度；当时也未发送真实模型请求。

## 更早的历史证据

| 版本 | 记录与限制 |
| --- | --- |
| 0.5.0 图形桌面 | Dart 198、Python 12、JVM 51；桌面 3/3 与既有回归 18/18。见历史报告（`artifacts/android-desktop/VERIFICATION.md`）与包体校验（`artifacts/android-desktop/apk-verification.json`），不证明后续 Xfce/办公/浏览器 |
| 0.4.0 文件工作台 | Dart 160、Python 12、JVM 47；设备 18/18，最终 APK HTML 编辑/静态预览记录见历史报告（`artifacts/android-container/VERIFICATION.md`） |
| 0.3.0 Python | Linux 8/8、原生存储/文档 3/3；Dart 125、Python 12、JVM 36。见历史报告（`artifacts/android-python/VERIFICATION.md`） |
| 0.2.0 终端 | APK 安装、手动终端与键盘 smoke，见历史报告（`artifacts/android-linux/VERIFICATION.md`） |
| iOS 早期模拟器构建 | 曾完成 Debug 编译；未接 iSH、本地推理或本轮浏览器，不能代替双端验收 |

## 仍需完成

- **完整共控：**真实视觉供应商、中文输入法、模型制作文件→GUI 打开→用户修改→模型重新观察继续，以及浏览器与办公混合任务。
- **本地模型与低配：**llama.cpp、候选模型、下载与调度，4 GB 整机内存和约 5 秒基础响应均未实测。
- **双端与后台：**iSH、iPhone 真机、Android 前台服务、锁屏、回收与步骤恢复；查看器释放不能替代这些关卡。
- **文档与知识：**iOS 导入导出的设备验收、语义检索真机与跨设备迁移；LibreOffice GUI 不是宿主文档导出服务的替代验收。
- **分发与边界：**完整对应源码分发包、其他设备/ROM、PRoot 权限边界与任意 Shell 行为；不把文件 API 的路径拒绝称为强隔离。

所有移动运行结论以对应版本的原生 APK 和设备证据为准。M0 与完整 M1-D 保持未完成，直到取得各项要求的数据。
