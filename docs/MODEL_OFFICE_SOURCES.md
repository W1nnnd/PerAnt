# 本机模型与办公依赖

本表对应 PerAnt 0.0.12+2021，用于重建与核对模型、字体、文档导入和导出。Dart 依赖的精确版本与包摘要见 [pubspec.lock](../pubspec.lock)。Android Linux、Alpine、Python 和桌面资源另有[构建与来源清单](LINUX_RUNTIME_SOURCES.md)。

## 按需安装的权重

| 用途 | 固定文件 | 来源和许可记录 |
| --- | --- | --- |
| 中文推理，0.8B | `Qwen3.5-0.8B-Q4_K_M.gguf`，532,517,120 字节，SHA-256 `bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517` | [Qwen 原模型（Apache-2.0）](https://huggingface.co/Qwen/Qwen3.5-0.8B) · [固定量化修订](https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/tree/6ab461498e2023f6e3c1baea90a8f0fe38ab64d0) |
| 中文推理，2B | `Qwen3.5-2B-Q4_K_M.gguf`，1,280,835,840 字节，SHA-256 `aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223` | [Qwen 原模型（Apache-2.0）](https://huggingface.co/Qwen/Qwen3.5-2B) · [固定量化修订](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/tree/f6d5376be1edb4d416d56da11e5397a961aca8ae) |
| 中文检索，BGE-small-zh-v1.5 | 量化 ONNX 24,010,842 字节，配套词表 109,540 字节。两份文件的独立 SHA-256 见[模型清单](../apps/perant/lib/src/data/bge_encoder.dart) | [BAAI 原模型（MIT）](https://huggingface.co/BAAI/bge-small-zh-v1.5) · [固定 ONNX 与词表](https://huggingface.co/Xenova/bge-small-zh-v1.5/tree/75c43b069aac4d136ba6bc1122f995fedcfd2781) |

本地推理权重由应用从固定修订下载或由用户导入，按大小和摘要校验后发布到设备私有目录。具体文件解析与下载行为见 [GGUF 模型清单](../apps/perant/lib/src/data/gguf_models.dart)。

## 随 Android 应用使用的运行时和文档组件

| 用途 | 固定组件 | 许可与核对入口 |
| --- | --- | --- |
| 本机生成 | `llamadart`、`llamadart_llama_cpp_flutter` 0.20.2，CPU 后端 | 两个 Dart 包均随附 MIT。[推理适配器](https://pub.dev/packages/llamadart/versions/0.20.2) · [Flutter 插件](https://pub.dev/packages/llamadart_llama_cpp_flutter/versions/0.20.2) |
| llama.cpp 原生实现 | `llamadart-native v1.0.0-3`，发布提交 `962c7ae5a46ffb1f6bbd39d3b1141901e0248da5`，其中 llama.cpp 提交 `b1b770d90d94cad9e9ea5b993bdbc383a522fb28` | [发布记录及构建出处](https://github.com/leehack/llamadart-native/releases/tag/v1.0.0-3) · [该版 llama.cpp 许可（MIT）](https://github.com/ggml-org/llama.cpp/blob/b1b770d90d94cad9e9ea5b993bdbc383a522fb28/LICENSE) |
| Android 嵌入推理 | `flutter_onnxruntime` 1.9.0，Android 插件声明 `com.microsoft.onnxruntime:onnxruntime-android:1.28.0` | 插件 LICENSE 与原生 Maven POM 均标为 MIT。[Flutter 插件](https://pub.dev/packages/flutter_onnxruntime/versions/1.9.0) · [Android POM](https://repo.maven.apache.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/1.28.0/onnxruntime-android-1.28.0.pom) |
| Word、PPTX 的 ZIP 与 XML 读写 | `archive` 4.7.1、`xml` 7.1.0 | 两个包均随附 MIT。[archive](https://pub.dev/packages/archive/versions/4.7.1) · [xml](https://pub.dev/packages/xml/versions/7.1.0) |
| Markdown 解析、预览和修订比较 | `markdown` 7.3.1、`flutter_markdown_plus` 1.0.12、`diff_match_patch` 0.4.1 | 前两者随附三条款 BSD，差异库随附 Apache-2.0。[解析](https://pub.dev/packages/markdown/versions/7.3.1) · [预览](https://pub.dev/packages/flutter_markdown_plus/versions/1.0.12) · [差异](https://pub.dev/packages/diff_match_patch/versions/0.4.1) |
| PDF 生成与 Android 文字提取 | Dart `pdf` 3.13.1、`com.tom-roush:pdfbox-android:2.0.27.0` | Dart 包 LICENSE 与 Android 构件的 Maven POM 标为 Apache-2.0。[PDF 生成](https://pub.dev/packages/pdf/versions/3.13.1) · [Android POM](https://repo.maven.apache.org/maven2/com/tom-roush/pdfbox-android/2.0.27.0/pdfbox-android-2.0.27.0.pom) |
| 随包中文字体 | 霞鹜文楷 1.530，TTF 的 SHA-256 为 `2d73eea94ad808999d90c0000c239a84a33b09d4bc6ab6c5b8bbf1eda8a7fc8b` | SIL OFL 1.1，保留字体名及附加许可见[随字体分发的原文](../apps/perant/assets/fonts/OFL.txt)。[字体发布](https://github.com/lxgw/LxgwWenKai/releases/tag/v1.530) |

Dart 包的许可标识对照已解析版本的 `LICENSE`，Android 构件对照 Gradle 取得的 POM。iOS 文字 PDF 读取调用系统 PDFKit，Apple 平台的编译和设备验收另行记录。公开新 APK 时，还需按[公开安装包交付说明](PUBLIC_BINARY_RELEASE.md)核对该构建实际包含的二进制、来源与声明。
