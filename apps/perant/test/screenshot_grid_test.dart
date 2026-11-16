// SPDX-License-Identifier: GPL-3.0-only
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:perant/src/application/screenshot_grid.dart';

Future<Uint8List> _solidPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF204060),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

Future<ui.Image> _decode(Uint8List png) async =>
    (await (await ui.instantiateImageCodec(png)).getNextFrame()).image;

Future<List<int>> _pixel(ui.Image image, int x, int y) async {
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final offset = (y * image.width + x) * 4;
  return [
    data.getUint8(offset),
    data.getUint8(offset + 1),
    data.getUint8(offset + 2),
  ];
}

void main() {
  test('spacing widens for large browser screenshots', () {
    expect(screenshotGridSpacing(720, 1080), 100);
    expect(screenshotGridSpacing(1280, 800), 100);
    expect(screenshotGridSpacing(1080, 2400), 200);
  });

  test('a desktop frame keeps its size and gains ruler lines', () async {
    final source = await _solidPng(720, 1080);
    final result = await gridScreenshotAnnotator(source);
    expect(result.gridSpacing, 100);
    expect(result.png, isNot(source));
    final image = await _decode(result.png);
    expect([image.width, image.height], [720, 1080]);
    // On a vertical and a horizontal line, away from the labels.
    for (final point in const [(300, 555), (555, 300)]) {
      final rgb = await _pixel(image, point.$1, point.$2);
      expect(rgb[0], greaterThan(150), reason: 'red line at $point');
      expect(rgb[2], lessThan(90));
    }
    // Between lines the real screen is untouched.
    expect(await _pixel(image, 350, 550), [0x20, 0x40, 0x60]);
    image.dispose();
  });

  test('tiny or undecodable images are returned unchanged', () async {
    final tiny = await _solidPng(40, 40);
    final small = await gridScreenshotAnnotator(tiny);
    expect(small.gridSpacing, isNull);
    expect(small.png, same(tiny));
    final broken = Uint8List.fromList([1, 2, 3, 4]);
    final failed = await gridScreenshotAnnotator(broken);
    expect(failed.gridSpacing, isNull);
    expect(failed.png, same(broken));
    expect((await plainScreenshot(tiny)).gridSpacing, isNull);
  });
}
