// SPDX-License-Identifier: GPL-3.0-only
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// A screenshot as it is sent to the model. [gridSpacing] is null when the
/// image is unchanged, so the accompanying text never describes a ruler that
/// is not actually in the picture.
final class AnnotatedScreenshot {
  const AnnotatedScreenshot(this.png, {this.gridSpacing});
  final Uint8List png;
  final int? gridSpacing;
}

typedef ScreenshotAnnotator = Future<AnnotatedScreenshot> Function(
  Uint8List png,
);

Future<AnnotatedScreenshot> plainScreenshot(Uint8List png) async =>
    AnnotatedScreenshot(png);

int screenshotGridSpacing(int width, int height) =>
    math.max(width, height) > 1300 ? 200 : 100;

/// Draws a labelled pixel ruler over the screenshot. Vision models resize
/// images internally and then report positions in their own scale; reading a
/// position against printed coordinates keeps clicks on the intended target.
/// Only the copy sent to the model is changed; the viewer and stored records
/// keep the real screen. Any failure returns the original image.
Future<AnnotatedScreenshot> gridScreenshotAnnotator(Uint8List png) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(png);
    image = (await codec.getNextFrame()).image;
    final width = image.width, height = image.height;
    if (width < 200 || height < 200) return AnnotatedScreenshot(png);
    final spacing = screenshotGridSpacing(width, height);
    final large = spacing >= 200;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..drawImage(image, ui.Offset.zero, ui.Paint());
    final line = ui.Paint()
      ..color = const ui.Color(0xB3FF0000)
      ..isAntiAlias = false;
    final backdrop = ui.Paint()..color = const ui.Color(0xE6FFFFFF);
    void label(int value, double x, double y) {
      final builder =
          ui.ParagraphBuilder(
              ui.ParagraphStyle(fontSize: large ? 24 : 13, height: 1.1),
            )
            ..pushStyle(
              ui.TextStyle(
                color: const ui.Color(0xFFD00000),
                fontWeight: ui.FontWeight.w700,
              ),
            )
            ..addText('$value');
      final paragraph = builder.build()
        ..layout(const ui.ParagraphConstraints(width: 240));
      canvas
        ..drawRect(
          ui.Rect.fromLTWH(
            x,
            y,
            paragraph.maxIntrinsicWidth + 4,
            paragraph.height + 2,
          ),
          backdrop,
        )
        ..drawParagraph(paragraph, ui.Offset(x + 2, y + 1));
      paragraph.dispose();
    }

    // Filled, pixel-aligned bars: a stroked line would be split over two
    // half-covered pixel columns and come out faint.
    final thickness = large ? 2.0 : 1.0;
    for (var x = spacing; x < width; x += spacing) {
      canvas.drawRect(
        ui.Rect.fromLTWH(x.toDouble(), 0, thickness, height.toDouble()),
        line,
      );
    }
    for (var y = spacing; y < height; y += spacing) {
      canvas.drawRect(
        ui.Rect.fromLTWH(0, y.toDouble(), width.toDouble(), thickness),
        line,
      );
    }
    // Labels go on after every line so no line crosses a number.
    for (var x = spacing; x < width; x += spacing) {
      label(x, x + 2.0, 2);
    }
    for (var y = spacing; y < height; y += spacing) {
      label(y, 2, y + 2.0);
    }
    final picture = recorder.endRecording();
    final rendered = await picture.toImage(width, height);
    picture.dispose();
    final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
    rendered.dispose();
    if (bytes == null) return AnnotatedScreenshot(png);
    return AnnotatedScreenshot(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      gridSpacing: spacing,
    );
  } catch (_) {
    return AnnotatedScreenshot(png);
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}
