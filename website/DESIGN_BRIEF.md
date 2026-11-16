# PerAnt 项目首页 · OpenDesign brief

以这个目录为项目工作目录，在本目录生成可直接部署到 GitHub Pages 的完整中文官网。不要操作父目录，不运行 GitHub CI，不提交 Git。

## 交付

- 纯静态 `index.html`、`styles.css`，可选少量 `script.js`，不要 npm 构建、外部 CDN、数据库、登录或收费服务。
- 发布地址 `https://w1nnnd.github.io/PerAnt/`；所有站内资源使用相对路径，适配 `/PerAnt/` 子路径。
- 页面源码 GPL-3.0-only。保留本 brief，不把 brief 或开发日志当作公开页面内容。
- 桌面 1440、平板 768、手机 390/360 宽度可用，无横向溢出。鼠标、触摸、键盘焦点可见；语义 HTML，正文对比度符合 WCAG AA，支持 reduced motion。

## 品牌

- PerAnt，小蚁是用户的手机个人智能体搭子。真实 Android 开发预览版 0.9.0，尚非完整发布产品。
- 暖白 #F8F8F3、白 #FFFFFF、文字 #252A24、次文 #686F60、鼠尾草绿 #455C3E、深绿 #31452C、浅绿 #EDF1E5、边界 #E7EAE0。
- 现成图标 `assets/app-icon.png`，透明小蚁 `assets/ant-welcome.png`。不要重画品牌或产品界面。
- 三张真实 APK 截图：`app-chat.png`、`app-computer.png`、`app-files.png`，原图保留 Android 状态栏，不伪造成网页运行的 App。
- 排版清爽、亲切、克制，有留白及明确层级，圆角与 App 一致。不要紫蓝渐变、霓虹、玻璃拟态、emoji、假评价、假增长数字、模板等高三卡。

## 建议内容与布局

1. 顶部简洁图标+PerAnt、功能/开发计划锚点、GitHub 入口。首屏左大标题“和小蚁一起，\n把事情做完。”（桌面最多两行）与产品定义“以对话为入口，在手机里与模型共用一台 Linux 电脑。”；右侧展示真实手机对话截图。可用小蚁作有限辅助装饰，不超过截图视觉权重。主按钮“查看 Android 预览版”跳转 #download，次入口“阅读源码”链接真实仓库。标记 Android ARM64 / 0.9.0 开发预览。
2. 通过截图/切换真实图片和简洁文字，解释“从一句话开始”“需要时，打开我们的电脑”“文件与成果留在手边”。三个入口分别为 对话 / 电脑 / 文件。不要创建可输入的假聊天框或假命令结果。
3. 对话 → 明确授权 → 使用 Linux 工具 → 查看并保留成果，四步简短说明。提供用户可接管、命令逐条确认、API 自备 Key 的事实。
4. 当前能力：Android PRoot+Alpine、Python、终端、Xfce、LibreOffice、Android WebView、网页文字保存、SQLite文档版本。桌面仅点击查看时连接取帧；离开查看页停止持续取帧，Linux进程仍可占内存，不承诺后台常驻。
5. `#download` 安装区：目前完整APK为 0.9.0 debug ARM64，最低 Android10/API29，543,584,034字节，SHA256 df28a19867704134053f4d79dd78e10d8d05f18fd25227d2952489b33e06a167。公开二进制下载须待完整Linux对应源码归档完成；当前不要编造APK下载链接。先给“查看发布记录”https://github.com/W1nnnd/PerAnt/releases 和“从源码构建”https://github.com/W1nnnd/PerAnt#从源码构建-android-apk。用自然简短的状态解释，不要死按钮。后续发布时可以更新此区。
6. 开发计划不标假日期：当前0.9界面完成；接下来真实API协作与低内存启动优化、本地小模型、后台恢复、混合检索与记忆、内容工作流、iOS运行时验证。当前iOS仅有共享代码和图标，不提供IPA。
7. 少量真实FAQ：是否完全离线（小模型未接入，云API需用户配置）；是否虚拟机（PRoot用户空间，共用Android内核，非已证明强隔离）；手机支持（ARM64 Android10+，低配真机尚待验收，3GB模拟器冷安装曾超时）；许可（GPL-3.0-only，允许合规商用，不保证禁止套壳销售）。
8. 页脚 GitHub / README / GPL / OpenDesign设计来源署名。

## 可信链接

- https://github.com/W1nnnd/PerAnt
- https://github.com/W1nnnd/PerAnt/releases
- https://github.com/W1nnnd/PerAnt/blob/main/README.md
- https://github.com/W1nnnd/PerAnt/blob/main/TASK_PLAN.md
- https://github.com/W1nnnd/PerAnt/blob/main/LICENSE

只使用这些事实。不要宣称已完成本地模型、后台常驻、全自动任意Shell、iOS运行时或物理4GB手机验收。不要添加分析追踪或第三方外链字体。
