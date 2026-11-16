# PerAnt 小蚁 working animation

Completed inside this folder only. App integration remains for the integrating agent.

Tool: **built-in image_gen (model undisclosed)**. Four independent identity-preserving edits, each attached to the supplied `../working.png` as the primary reference. No CLI/API fallback and no named model claim. `neutral` is an unchanged copy of the supplied pose. Exact prompts, references, generated-output provenance, raw SHA-256 hashes, processing details, timeline, sizes and verification are in [PROMPTS.json](PROMPTS.json).

All generated frames returned native RGBA transparency. No opaque-background regeneration or chroma key was necessary for any frame. Kept raw outputs are unchanged in `frames-raw/`. During assembly, very low-alpha isolated speckles were removed and saturated edge pixels despilled using nearby felt color. Native soft alpha was preserved. All frames use the full shared 1254×1254 source canvas, bounded subpixel translation alignment, then premultiplied-alpha LANCZOS downscaling to 512×512. The GIF is fully matted on exact #F8F8F3 with a shared palette.

Distinct frames: `type-left`, `type-right`, `neutral`, `blink`, `glance`. The optional antenna-bob was omitted. **No frames needed regeneration.** Visual review of every frame and the final contact sheet found consistent character identity, scarf, pocket and laptop; exactly two antennae, two mitten hands and two feet; no extra limbs, mandibles, laptop text, letters or logos.

Timeline, **15 encoded frames / 2,560 ms / forever loop**:

`[type-left 140 ms → type-right 140 ms] ×3 → neutral 180 ms → blink 120 ms → neutral 180 ms → glance 500 ms → neutral 180 ms → [type-left 140 ms → type-right 140 ms] ×2 → loop`

The last type-right continues into the first type-left. The poster is the exact first delivered frame for reduced-motion use.

Maximum measured residual laptop/body translation after alignment: **0.428172 px at 512×512**, below the 2 px limit. The body/feet alpha maximum was 0.169262 px; laptop luminance-gradient maximum was 0.428172 px. Registration was re-estimated across all ten distinct-frame pairs in each region, twenty comparisons in total. Local identity and geometry were also visually reviewed.

Decoded verification passed: WebP is animated RGBA with alpha in all 15 frames; GIF has 15 frames and opaque matte; both store loop `0` and exactly match all timeline durations. Every GIF frame has exact #F8F8F3 at the background corner. Poster is RGBA 512×512. Contact sheet is RGB 2560×550 with all five distinct frames labeled. WebP uses quality 80. WebP and GIF meet their respective 900,000-byte and 1,500,000-byte limits.

**Known source discrepancy:** Both supplied mascot references contain six visible cream pocket dots, arranged 1 + 2 + 3. The written description says seven. The animation preserves the supplied pocket consistently, so the written seven-dot target is not met. No other target was missed.

Rebuild with installed Pillow, numpy and scipy, from the repository root:

```sh
python3 docs/uiux-demo/assets/perant-companion-v3/working-anim/assemble.py
```

The rebuild script only writes into this folder and does not call image generation.

All created files are listed below. Byte sizes are exact; raw PNGs are 1254×1254 RGBA, registered PNGs are 512×512 RGBA.

| File | Bytes |
| --- | ---: |
| `PROMPTS.json` | 27,964 |
| `assemble.py` | 13,712 |
| `frames-raw/blink.png` | 1,316,424 |
| `frames-raw/glance.png` | 1,282,006 |
| `frames-raw/neutral.png` | 1,431,324 |
| `frames-raw/type-left.png` | 1,307,518 |
| `frames-raw/type-right.png` | 1,333,717 |
| `frames-registered/blink.png` | 239,499 |
| `frames-registered/glance.png` | 235,337 |
| `frames-registered/neutral.png` | 243,950 |
| `frames-registered/type-left.png` | 240,029 |
| `frames-registered/type-right.png` | 241,147 |
| `working-contact-sheet.png` | 994,603 |
| `working-poster.png` | 240,029 |
| `working.gif` | 1,353,365 |
| `working.webp` | 475,188 |
| `REPORT.md` | 4,036 |
