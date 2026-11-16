# PerAnt 启动图标

图标沿用 Concept 06 的“小蚁”身份：鼠尾草绿毛毡、奶油白脸部、棕色眼睛、微笑与两根触角；不含文字。新的头像由本次会话内置 `image_gen` 以既有 `welcome.png` 为身份参考生成，未调用 CLI 或外部 API Key。工具没有返回具体模型名称，不能据此标注一个未确认的模型。

- `perant-launcher-head-source-v2.png`：最终选用的原创透明源图，保留生成时的原始字节。
- `PROMPTS.json`：完整提示词、参考关系、工具模式，以及弃用首版长半身构图的原因。
- `perant-launcher-icon-1024.png`：用于平台导出的奶油白底、无圆角、不透明 RGB 主图。
- `perant-launcher-preview-64.png`：64px 缩小预览。
- `perant-launcher-adaptive-circle-preview.png`：Android 中央 72dp 视口的圆形遮罩预览，不是运行时前景。
- `ICON_EXPORTS.json`：源图及平台导出的尺寸、字节数、SHA256 与安全区检查。

`export_icons.py` 只进行标准资源导出：透明留白裁切、等比缩放/补边、填充统一背景色、单色 alpha 导出与平台尺寸转换，不重画角色、不改表情或颜色。Android 自适应前景使用 108dp 画布，alpha 大于 8 的可见主体完全位于中央直径 66dp 的安全圆内；背景为 `#F8F8F3`。Android 常规图标覆盖 mdpi 至 xxxhdpi；iOS 按现有 AppIcon Contents 清单导出全部 15 个文件，均不含 alpha。

在项目根目录、已安装 Pillow 的 Python 环境中可重复导出：

```sh
python3 apps/perant/assets/branding/export_icons.py
```

只有 `assets/companion` 下列出的五个角色图像加入 Flutter 的资源清单；此目录的源图、提示词和导出脚本不作为 Flutter 运行时图片打包。Android/iOS 图标由平台自己的资源目录使用。
