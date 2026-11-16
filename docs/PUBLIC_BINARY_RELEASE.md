# 公开安装包与对应源码

0.0.1 Android 预览包使用现有完整 ARM64 Linux／Office 运行资源，与旧编号 0.9.0 的运行资源逐字节相同（v6，内嵌 manifest 一致）；应用部分的差别见 [0.0.1 说明](releases/0.0.1.md)。公开分发时，将 APK、以下 Linux 对应源码分卷、校验清单与匹配的 PerAnt 源码版本放在同一 GitHub Release。附件生成和上传是两个独立步骤；上传完成前，不把本地文件说成已提供公开下载。

安装包为 `PerAnt-0.0.1-debug-arm64.apk`，543,615,667 字节，SHA256：

```text
aa5e7a9f79c4f00abe5ba78d7a319b60e1a364657c8c566ab47a56ee310e916b
```

这是 Android 10／API 29 及以上的 ARM64 调试预览包。功能和设备验证边界见 [README](../README.md) 与[开发状态](DEVELOPMENT_STATUS.md)。沿用与 0.9.0 相同的本地调试签名，可覆盖安装 0.9.0（构建号 2009 → 2010）；安装前按系统提示授权；云端调用使用用户配置的 API，可能产生供应商正常费用。源码收集不改变应用行为，也不增加功能验收结果。

## 下载与校验

Release 提供以下文件。Linux 源码分为不超过 1,000,000,000 字节的卷，以满足单附件大小要求：

- `PerAnt-0.0.1-debug-arm64.apk`：直接安装的应用。
- `PerAnt-0.0.1-linux-sources.tar.part01`、`.part02`、`.part03`：按顺序重组的 Linux 对应源码。
- `PerAnt-0.0.1-linux-sources-manifest.json`：APK、运行资源 manifest、源码锁、主仓提交与各分卷的绑定关系。
- `SHA256SUMS`：APK 与各源码分卷的 SHA256。
- GitHub 自动生成的 Source code：该 Release 标签所指向的 PerAnt 源码。

普通安装只需下载 APK。需要审阅、重建或再分发时，还可下载全部源码卷和同版本 PerAnt 源码。macOS／Linux 在同一目录执行：

```sh
shasum -a 256 -c SHA256SUMS
cat PerAnt-0.0.1-linux-sources.tar.part01 \
    PerAnt-0.0.1-linux-sources.tar.part02 \
    PerAnt-0.0.1-linux-sources.tar.part03 > PerAnt-0.0.1-linux-sources.tar
tar -xf PerAnt-0.0.1-linux-sources.tar
```

只下载 APK 时可用 `shasum -a 256 PerAnt-0.0.1-debug-arm64.apk` 与上面的固定摘要比较。Windows 可用 PowerShell 的 `Get-FileHash -Algorithm SHA256` 核对单文件摘要；分卷不是可分别解压的压缩包，需要先按序拼接。

## 收集与内容

[release-sources.lock.json](../third_party/linux/release-sources.lock.json) 固定源码输入的原始地址和摘要，而非只链接上游首页。清单包含：

| 内容 | 数量与依据 |
| --- | --- |
| 完整 aports 源目录 | 311 份：309 个直接来源，另加 BusyBox 的两项静态来源；保留 APKBUILD、补丁、配置及安装脚本 |
| 配方声明的源输入 | 799 项；逐项 SHA512 核对，含 LibreOffice core、dictionaries、translations 与内嵌第三方源归档 |
| Rust registry／Meson wrap 源包 | 573 项；SHA256 核对，覆盖原锁、固定 nix 补丁与 Mesa wrap 的保守超集 |
| 原生构建源输入 | 7 项：PRoot、talloc、Termux PRoot 源码、两份原始配方、GdkPixbuf、完整固定 Termux 构建框架 |
| PerAnt 构建说明与脚本 | 匹配的运行资源锁、许可证、原生兼容配方、文本任务和桌面启动脚本 |
| 来源证据 | 官方 BusyBox 构建日志，显示实际 utmps／skalibs 静态版本与链接参数 |

Rust 保守超集含上游旧版本与固定补丁／wrap 替换版本，不将旧锁误认为唯一实际输入。Glycin、librsvg、Mesa、GStreamer 和 LibreOffice 的额外来源检查见[技术闭包审阅](LINUX_SOURCE_CLOSURE_REVIEW.md)。此审阅未发现仍缺少的具体源归档；它不替代独立的全量清洁重建，也不承诺不同编译器产生相同字节。

## 维护者流程

所有步骤在本地执行，不创建或运行 GitHub CI：

```sh
# 仅校验已缓存的全部固定源输入；不联网、不编译、不操作设备。
tool/package-linux-sources

# 缺失时从锁定地址下载并核对原始字节；不执行 APKBUILD。
tool/package-linux-sources --fetch

# 先准备运行资源并确认 APK 与最终主仓源码相匹配。
tool/prepare-linux-runtime --verify-existing

# SOURCE_COMMIT 替换为与该 APK 对应的完整 40 位主仓提交。
tool/package-linux-sources \
  --apk artifacts/apk/PerAnt-0.0.1-debug-arm64.apk \
  --revision SOURCE_COMMIT \
  --output artifacts/release-0.0.1
```

默认缓存是 `.tooling/linux-sources-v09`（源码输入自旧编号 0.9.0 起未变，缓存沿用），默认产物目录是被忽略的 `artifacts/release-v09`；0.0.1 使用 `--output artifacts/release-0.0.1`。`--cache` 和 `--output` 可指定其它路径。工具先校验所有源文件和配方归档，再比对固定 APK SHA256 与真实内嵌运行资源 manifest；任一不匹配都会失败。它生成 `.tar`、分卷、外部 manifest 和 SHA256SUMS，不上传文件，不替维护者自动判定新运行资源的闭包完整性。

源码目录保留原始归档；`distfiles/<sha512>/<文件名>` 按摘要分隔，避免不同来源的同名补丁互相覆盖。重建某个 aports 时，从其 manifest 的 source 列表把输入放到该配方的 `SRCDEST`，按完整 APKBUILD 使用匹配的 Alpine aarch64／abuild 和构建依赖。先应用原有补丁，再使用对应 Cargo／Meson 源包。PRoot、loader、talloc 和 PNG／XPM 兼容库的精确构建入口、flags 与工具链版本见 [Linux 运行资源](LINUX_RUNTIME_SOURCES.md)。一般编译器和系统工具按这些步骤安装；它们的二进制不冒充本包的源码。

运行资源包、静态依赖、源码补丁或 Cargo／Meson 引用变化时，重新收集并审阅，再更新源码锁。每个公开 APK 都要重新生成并绑定自己的源码包：0.0.1 的运行资源和源码输入与 0.9.0 相同，但 manifest、源码锁中的版本与 APK 摘要、主仓提交均已重新绑定，不能把 0.9.0 的分卷当作 0.0.1 的对应源码。所有上游组件保留原许可及版权；PerAnt 的 GPL-3.0-only 不替换它们各自的许可。
