# PerAnt 项目首页

这里是用于 GitHub Pages 的独立静态项目首页，不是 Flutter 应用的网页版本，也不作为 Android 功能验收。

页面由本机 **OpenDesign 0.27.1** 根据 [DESIGN_BRIEF.md](DESIGN_BRIEF.md) 和正式 App 的真实截图生成，再核对文案、链接与响应式布局。品牌资产来自项目现有小蚁与 App 图标，来源及提示词见 [角色记录](../apps/perant/assets/companion/README.md)和[图标记录](../apps/perant/assets/branding/README.md)。截图副本来自 [Android 截图记录](../docs/images/README.md)。

- 目标地址：<https://w1nnnd.github.io/PerAnt/>
- 无外部字体、CDN、分析追踪、服务器与构建依赖。
- 相对资源路径兼容 `/PerAnt/` 子路径。
- 自研页面源码遵循项目 GPL-3.0-only。

## 本地查看

从仓库根目录执行：

```sh
python3 -m http.server 8765 --directory website --bind 127.0.0.1
```

浏览器打开 `http://127.0.0.1:8765/`。这里只检查项目介绍页；App 必须使用 APK 在 Android 设备或模拟器中检查。

## 发布

页面与应用源码一起提交到 `main` 后，把 `website/` 的已提交树发布到专用 `gh-pages` 分支。GitHub Pages 使用“从分支部署”，来源为 `gh-pages` 的根目录。`.nojekyll` 使页面按静态文件处理，不引入 Jekyll 配置。

```sh
git subtree push --prefix website origin gh-pages
```

不添加项目 CI 或测试 workflow。GitHub 自身的 Pages 发布任务只用于静态页面托管。更新安装包入口时，先核对 GitHub Release 附件与对应源码实际存在，再更新 `index.html`；不将本地 `artifacts/` 路径写成公开下载地址。
