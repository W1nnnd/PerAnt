# 小蚁正式界面素材

本目录从 `docs/uiux-demo/assets/perant-companion-v3` 原样复制四张 RGBA PNG 与 `working-anim/working.webp`，没有重新绘制、去背、裁切或修改原图。原始提示词和动画记录分别保存在 `SOURCE_PROMPTS.json`、`ANIMATION_SOURCE_PROMPTS.json` 与 `ANIMATION_SOURCE_REPORT.md`；每个源/目标文件的摘要见 `ASSET_SOURCES.json`。

| 文件 | 尺寸 | 状态用途 |
| --- | --- | --- |
| `welcome.png` | 1254 × 1254 | 待命、欢迎、等待确认 |
| `working.png` | 1254 × 1254 | 工作的静态替代、用户接管 |
| `resting.png` | 1254 × 1254 | 思考、休息、暂停 |
| `celebrating.png` | 1254 × 1254 | 成果完成 |
| `working.webp` | 512 × 512，15 帧 | 正在执行时播放 |

所有图片保留透明背景。四张 PNG 约有 60%–61% 的像素完全透明，但原图有很低 alpha 的边缘像素；不要按“所有 alpha 大于 0 的最外边界”自动裁切。应沿用 Concept 06 圆盘、开放上沿裁切和 146% 图片比例，让头部探出圆环，下半身体沿圆弧裁切。

姿态与真实任务状态对应；暂停、等待确认、用户接管或系统要求减少动态效果时使用静态图。任务进度更新不应重新创建正在播放的动图。
