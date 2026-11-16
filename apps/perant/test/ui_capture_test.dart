// SPDX-License-Identifier: GPL-3.0-only
// Opt-in offline widget renders; no browser or device automation is used.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant/src/perant_app.dart';

const _captureEnabled = bool.fromEnvironment('PERANT_CAPTURE_UI');
const _chineseFontPath = String.fromEnvironment(
  'PERANT_CAPTURE_FONT',
  defaultValue: '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final root = _repositoryRoot();
  const runtimeChannel = MethodChannel('dev.perant/runtime');

  setUpAll(() async {
    if (!_captureEnabled) return;
    // Only this opt-in render replaces the test engine's default Ahem family.
    await _loadFont('PerAntPreview', _chineseFontPath);
    await _loadFont(
      'MaterialIcons',
      '${root.path}/.tooling/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
  });

  for (final capture in [
    (name: 'offline-widget-mobile-chat', size: const Size(390, 844)),
    (name: 'offline-widget-wide-single-column', size: const Size(1440, 960)),
  ]) {
    testWidgets('offline render ${capture.name}', (tester) async {
      tester.view.physicalSize = capture.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            runtimeChannel,
            (call) async => {
              'schemaVersion': 1,
              'platform': 'offline-widget-render',
              'systemVersion': 'Not a device screenshot',
              'nativeBridgeAvailable': false,
              'linux': {'available': false, 'reason': 'Not integrated'},
              'localInference': {
                'available': false,
                'reason': 'Not integrated',
              },
              'backgroundTasks': {
                'available': false,
                'reason': 'Not integrated',
              },
            },
          );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(runtimeChannel, null);
      });
      final controller = WorkspaceController(
        persistence: MemoryWorkspacePersistence(),
        credentials: MemoryCredentialStore(),
      );
      await controller.initialize();
      addTearDown(controller.dispose);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(PerantApp(controller: controller));
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      final productionTheme = app.theme!;
      final previewTheme = productionTheme.copyWith(
        textTheme: productionTheme.textTheme.apply(fontFamily: 'PerAntPreview'),
        primaryTextTheme: productionTheme.primaryTextTheme.apply(
          fontFamily: 'PerAntPreview',
        ),
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            title: app.title,
            debugShowCheckedModeBanner: app.debugShowCheckedModeBanner,
            theme: previewTheme,
            locale: app.locale,
            supportedLocales: app.supportedLocales,
            localizationsDelegates: app.localizationsDelegates,
            home: app.home,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('嗨，我是小蚁。'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Asset codecs complete outside the widget test's fake clock. Wait for
      // the actual providers already mounted by the production avatar before
      // exporting, so an empty ring cannot be accepted as a finished render.
      final mountedImages = tester
          .widgetList<Image>(find.byType(Image))
          .toList();
      expect(mountedImages, isNotEmpty);
      Object? imageFailure;
      final imageContext = tester.element(find.byType(Image).first);
      await tester.runAsync(() async {
        for (final mounted in mountedImages) {
          await precacheImage(
            mounted.image,
            imageContext,
            onError: (error, _) => imageFailure = error,
          );
        }
      });
      await tester.pumpAndSettle();
      expect(
        imageFailure,
        isNull,
        reason: 'Production avatar asset must decode.',
      );

      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          if (bytes == null) throw StateError('PNG encoding failed.');
          final output = File('${root.path}/artifacts/ui/${capture.name}.png');
          await output.parent.create(recursive: true);
          await output.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
        } finally {
          image.dispose();
        }
      });
    }, skip: !_captureEnabled);
  }
}

Future<void> _loadFont(String family, String path) async {
  final file = File(path);
  if (!await file.exists()) {
    throw StateError('Capture font is not installed: $path');
  }
  final data = await file.readAsBytes();
  await (FontLoader(
    family,
  )..addFont(Future.value(ByteData.sublistView(data)))).load();
}

Directory _repositoryRoot() {
  var directory = Directory.current.absolute;
  while (true) {
    if (File('${directory.path}/TASK_PLAN.md').existsSync()) return directory;
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('Run the capture inside the PerAnt repository.');
    }
    directory = parent;
  }
}
