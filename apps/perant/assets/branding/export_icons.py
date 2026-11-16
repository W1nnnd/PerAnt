#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Export platform sizes from the original generated PerAnt portrait.

This is deterministic resource export only: transparent-margin trim, uniform
scaling/padding, flat launcher background, and platform size conversion. It does
not redraw or modify the character identity, colors, expression, or texture.
"""
from pathlib import Path
from PIL import Image
import hashlib
import json
import math

HERE = Path(__file__).resolve().parent
APP = HERE.parents[1]
RES = APP / 'android/app/src/main/res'
IOS = APP / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
BACKGROUND = (248, 248, 243, 255)
SOURCE = HERE / 'perant-launcher-head-source-v2.png'


def fit_portrait(source, side, radius):
    alpha = source.getchannel('A')
    # Very faint alpha outliers are ignored only for layout measurements. All
    # actual source pixels in the resulting trim are retained in the export.
    bounds = alpha.point(lambda value: 255 if value > 8 else 0).getbbox()
    portrait = source.crop(bounds)
    alpha = portrait.getchannel('A')
    center_x, center_y = portrait.width / 2, portrait.height / 2
    max_radius = max(
        math.hypot(x + 0.5 - center_x, y + 0.5 - center_y)
        for y in range(portrait.height)
        for x in range(portrait.width)
        if alpha.getpixel((x, y)) > 8
    )
    scale = radius / max_radius
    size = (round(portrait.width * scale), round(portrait.height * scale))
    resized = portrait.resize(size, Image.Resampling.LANCZOS)
    canvas = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    canvas.alpha_composite(resized, ((side - size[0]) // 2, (side - size[1]) // 2))
    return canvas, bounds


def image_record(path):
    data = path.read_bytes()
    with Image.open(path) as image:
        return {'path': str(path.relative_to(APP)), 'size': list(image.size),
                'mode': image.mode, 'bytes': len(data),
                'sha256': hashlib.sha256(data).hexdigest()}


def main():
    with Image.open(SOURCE) as image:
        source = image.convert('RGBA')
    outputs = []
    # Android adaptive foreground coordinates represent a 108dp canvas. Keep
    # all meaningful alpha within the central 66dp-diameter safe circle.
    foreground, bounds = fit_portrait(source, 432, 124)
    foreground_path = RES / 'drawable-nodpi/perant_launcher_foreground.png'
    foreground_path.parent.mkdir(parents=True, exist_ok=True)
    foreground.save(foreground_path, optimize=True)
    outputs.append(foreground_path)
    monochrome = Image.new('RGBA', foreground.size, (255, 255, 255, 0))
    monochrome.putalpha(foreground.getchannel('A'))
    monochrome_path = RES / 'drawable-nodpi/perant_launcher_monochrome.png'
    monochrome.save(monochrome_path, optimize=True)
    outputs.append(monochrome_path)

    # Legacy and iOS use opaque square assets; the OS supplies the final mask.
    portrait, _ = fit_portrait(source, 1024, 480)
    opaque = Image.new('RGBA', portrait.size, BACKGROUND)
    opaque.alpha_composite(portrait)
    opaque = opaque.convert('RGB')
    icon_path = HERE / 'perant-launcher-icon-1024.png'
    opaque.save(icon_path, optimize=True)
    outputs.append(icon_path)
    preview_path = HERE / 'perant-launcher-preview-64.png'
    opaque.resize((64, 64), Image.Resampling.LANCZOS).save(preview_path)
    outputs.append(preview_path)

    for density, side in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96),
                          ('xxhdpi', 144), ('xxxhdpi', 192)]:
        path = RES / f'mipmap-{density}/ic_launcher.png'
        path.parent.mkdir(parents=True, exist_ok=True)
        opaque.resize((side, side), Image.Resampling.LANCZOS).save(path, optimize=True)
        outputs.append(path)

    contents = json.loads((IOS / 'Contents.json').read_text())
    exported = set()
    for item in contents['images']:
        name = item['filename']
        side = round(float(item['size'].split('x')[0]) * float(item['scale'][:-1]))
        path = IOS / name
        if name not in exported:
            opaque.resize((side, side), Image.Resampling.LANCZOS).save(path, optimize=True)
            outputs.append(path)
            exported.add(name)

    # A platform-mask preview, not a launcher source. Android masks the central
    # 72dp viewport out of the 108dp foreground canvas.
    adaptive = Image.new('RGBA', (432, 432), BACKGROUND)
    adaptive.alpha_composite(foreground)
    adaptive = adaptive.crop((72, 72, 360, 360)).resize((192, 192), Image.Resampling.LANCZOS)
    from PIL import ImageDraw
    mask = Image.new('L', adaptive.size, 0)
    ImageDraw.Draw(mask).ellipse((0, 0, 191, 191), fill=255)
    adaptive.putalpha(mask)
    adaptive_path = HERE / 'perant-launcher-adaptive-circle-preview.png'
    adaptive.save(adaptive_path, optimize=True)
    outputs.append(adaptive_path)

    alpha = foreground.getchannel('A')
    furthest = max(math.hypot(x + 0.5 - 216, y + 0.5 - 216)
                   for y in range(432) for x in range(432)
                   if alpha.getpixel((x, y)) > 8)
    assert furthest <= 132, 'Adaptive meaningful-alpha shape exceeded 66dp safe circle.'
    assert not any(Image.open(path).mode != 'RGB' for path in outputs if path.parent == IOS)
    record = {'source': image_record(SOURCE), 'sourceLayoutBoundsAlphaAbove8': list(bounds),
              'backgroundRgba': list(BACKGROUND), 'creativeGeneration': 'Built-in image_gen; see PROMPTS.json',
              'exportOperations': 'trim transparent margins, scale uniformly, pad, flatten on one solid color; no character redraw',
              'androidAdaptive': {'canvasPixels': 432, 'canvasDp': 108,
                                  'safeCircleDiameterDp': 66, 'meaningfulAlphaThreshold': 8,
                                  'maximumMeaningfulAlphaRadiusPixels': furthest,
                                  'safeCircleRadiusPixels': 132},
              'iosPngOpaqueRgb': True, 'iosUniquePngFiles': len(exported),
              'outputs': [image_record(path) for path in outputs]}
    (HERE / 'ICON_EXPORTS.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'exportedPngFiles': len(outputs), 'iosUniquePngFiles': len(exported),
                      'safeRadiusPixels': furthest, 'preview': str(icon_path.relative_to(APP))}))


if __name__ == '__main__':
    main()
