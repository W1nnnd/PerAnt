// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show RenderImage;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perant/src/application/shared_desktop_service.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant/src/presentation/desktop_screen.dart';
import 'package:perant/src/presentation/theme.dart';
import 'package:perant_platform/perant_platform.dart';

/// Service ownership/cancellation tests. Native lifecycle is a MethodChannel
/// fixture; framebuffer/input use a real local Unix socket and a scripted RFB
/// peer. This is not evidence that a Linux/X11 desktop has started on Android.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel(PerantPlatformBridge.methodChannelName);
  const events = MethodChannel(PerantPlatformBridge.eventChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _UnixDesktop server;
  late SharedDesktopService service;
  String? sessionId;
  final desktopStarts = <Map<String, Object?>>[];
  final desktopStops = <String>[];

  setUp(() async {
    sessionId = null;
    desktopStarts.clear();
    desktopStops.clear();
    server = await _UnixDesktop.create();
    Map<String, Object?> session() => {
      'sessionId': sessionId,
      'pid': 42,
      'socketPath': server.path,
      'width': server.width,
      'height': server.height,
      'display': 7,
      'workspace': '/workspace',
    };
    messenger.setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case 'getCapabilities':
          return _capabilities;
        case 'getLinuxStatus':
          return {
            'supported': true,
            'installed': true,
            'active': sessionId != null,
            'distribution': 'Alpine',
            'version': '3.24.4',
            'workspace': '/workspace',
            'reason': 'Test runtime',
            'pythonAvailable': true,
            'pythonVersion': '3.14.10',
            'desktopAvailable': true,
            'desktopVersion': 'test-rfb',
            if (sessionId != null) 'desktopSessionId': sessionId,
          };
        case 'getLinuxDesktopSession':
          return sessionId == null ? null : session();
        case 'startLinuxDesktop':
          final arguments = Map<String, Object?>.from(call.arguments as Map);
          sessionId = arguments['sessionId'] as String;
          server.width = arguments['width'] as int;
          server.height = arguments['height'] as int;
          desktopStarts.add(arguments);
          return session();
        case 'stopLinuxDesktop':
          desktopStops.add((call.arguments as Map)['sessionId'] as String);
          sessionId = null;
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });
    messenger.setMockMethodCallHandler(events, (call) async {
      if (call.method == 'listen') {
        scheduleMicrotask(() {
          unawaited(
            messenger.handlePlatformMessage(
              PerantPlatformBridge.eventChannelName,
              const StandardMethodCodec().encodeSuccessEnvelope({
                'type': 'bridgeAttached',
                'emittedAtEpochMs': 1,
                'payload': _capabilities,
              }),
              (_) {},
            ),
          );
        });
      }
      return null;
    });
    service = SharedDesktopService(PerantPlatformBridge());
    await service.start(width: 640, height: 480);
  });

  tearDown(() async {
    await service.stop();
    service.dispose();
    await server.close();
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  test('hidden observation closes its peer and hidden input requests no framebuffer', () async {
    service.takeModelControl();
    final observation = await service.observe();
    await server.waitFor(() => server.activePeers == 0);
    expect(observation.png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(server.fullRequests, 1);
    expect(service.frame, isNull);
    expect(service.viewerConnected, isFalse);
    await service.perform(
      observationId: observation.id,
      action: 'type',
      text: 'A',
    );
    await server.waitFor(
      () => server.input.length == 2 && server.activePeers == 0,
    );
    expect(server.input, [_key(65, true), _key(65, false)]);
    expect(
      server.fullRequests,
      1,
      reason: 'Input-only connections must not request/render pixels.',
    );
    expect(service.frame, isNull);
    expect(service.viewerConnected, isFalse);
    expect(service.running, isTrue);
  });

  test(
    'release and regrant reject old observations before opening an input peer',
    () async {
      service.takeModelControl();
      final old = await service.observe();
      await server.waitFor(() => server.activePeers == 0);
      final connections = server.connections;
      service.releaseModelControl();
      await expectLater(
        service.perform(observationId: old.id, action: 'key', key: 'a'),
        throwsStateError,
      );
      service.takeModelControl();
      await expectLater(
        service.perform(observationId: old.id, action: 'click', x: 10, y: 10),
        throwsStateError,
      );
      expect(server.connections, connections);
      expect(server.input, isEmpty);
    },
  );

  test(
    'model cancellation during a delayed Unix handshake sends no late keydown',
    () async {
      service.takeModelControl();
      final old = await service.observe();
      await server.waitFor(() => server.activePeers == 0);
      final gate = Completer<void>();
      server.nextHandshakeGate = gate;
      final pending = service.perform(
        observationId: old.id,
        action: 'key',
        key: 's',
        modifiers: const ['Ctrl'],
      );
      final rejected = expectLater(pending, throwsStateError);
      await server.waitFor(() => server.connections == 2);
      service.releaseModelControl();
      service.takeModelControl();
      gate.complete();
      await rejected;
      await server.waitFor(() => server.activePeers == 0);
      expect(server.input, isEmpty);
      expect(server.fullRequests, 1);
    },
  );

  test(
    'a capture finishing after cancellation and regrant is never published',
    () async {
      service.takeModelControl();
      final gate = Completer<void>();
      server.nextFrameGate = gate;
      final pending = service.observe();
      final rejected = expectLater(pending, throwsStateError);
      await server.waitFor(() => server.fullRequests == 1);
      service.releaseModelControl();
      service.takeModelControl();
      gate.complete();
      await rejected;
      await server.waitFor(() => server.activePeers == 0);
      expect(service.frame, isNull);
      expect(service.viewerConnected, isFalse);
      expect(server.input, isEmpty);
    },
  );

  test(
    'manual shortcut releases all keys before the next queued text operation',
    () async {
      await service.setViewerVisible(true);
      server.input.clear();
      final shortcut = service.keyFromUser('a', const ['Ctrl']);
      final text = service.textFromUser('x');
      await Future.wait([shortcut, text]);
      await server.waitFor(() => server.input.length == 6);
      expect(server.input, [
        _key(0xffe3, true),
        _key(97, true),
        _key(97, false),
        _key(0xffe3, false),
        _key(120, true),
        _key(120, false),
      ]);
    },
  );

  test(
    'queued old manual input cannot run after model take/release ownership',
    () async {
      await service.setViewerVisible(true);
      server.input.clear();
      final pointer = service.pointerFromUser(10, 20, 1);
      final text = service.textFromUser('x');
      final shortcut = service.keyFromUser('a', const ['Ctrl']);
      final rejectedKey = expectLater(shortcut, throwsStateError);
      // Change ownership before any queued .then callback can execute.
      service.takeModelControl();
      service.releaseModelControl();
      await Future.wait([pointer, text, rejectedKey]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.input, isEmpty);
    },
  );

  test(
    'taking model control releases a user-held mouse button before observing',
    () async {
      await service.setViewerVisible(true);
      server.input.clear();
      await service.pointerFromUser(12, 23, 1);
      await server.waitFor(() => server.input.length == 1);
      service.takeModelControl();
      await service.observe();
      await server.waitFor(() => server.input.length == 2);
      expect(server.input, [
        {'type': 'pointer', 'x': 12, 'y': 23, 'buttons': 1},
        {'type': 'pointer', 'x': 12, 'y': 23, 'buttons': 0},
      ]);
      await service.setViewerVisible(false);
      await server.waitFor(() => server.activePeers == 0);
      expect(service.frame, isNull);
      expect(service.viewerConnected, isFalse);
      expect(service.running, isTrue);
    },
  );

  testWidgets(
    'portrait desktop fills the phone with a real portrait framebuffer',
    (tester) async {
      await service.stop();
      desktopStarts.clear();
      desktopStops.clear();
      await _setViewerSize(tester, const Size(390, 844));
      addTearDown(() => _resetViewerSize(tester));
      final controller = _viewerController();
      try {
        await _pumpViewer(tester, controller);
        expect(desktopStarts, hasLength(1));
        expect(desktopStarts.single['width'], 720);
        expect(desktopStarts.single['height'], 1080);
        expect(controller.desktop.session!.width, 720);
        expect(controller.desktop.session!.height, 1080);
        final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
        expect(image.width, 720);
        expect(image.height, 1080);
        final displayed = tester.getRect(find.byType(RawImage));
        expect(displayed.width, greaterThanOrEqualTo(350));
        expect(
          displayed.height,
          greaterThan(450),
          reason: 'The phone must not shrink a landscape desktop into a tiny strip.',
        );
        for (final key in const [
          'desktop-open-files',
          'desktop-open-terminal',
          'desktop-open-apps',
          'desktop-switch-window',
          'desktop-toggle-keyboard',
        ]) {
          final target = find.byKey(ValueKey(key));
          expect(target, findsOneWidget);
          final bounds = tester.getRect(target);
          expect(bounds.height, greaterThanOrEqualTo(44), reason: key);
          expect(bounds.width, greaterThanOrEqualTo(44), reason: key);
          expect(bounds.left, greaterThanOrEqualTo(0), reason: key);
          expect(bounds.right, lessThanOrEqualTo(390), reason: key);
        }
        expect(find.text('文件'), findsOneWidget);
        expect(find.text('终端'), findsOneWidget);
        expect(find.text('应用'), findsOneWidget);
        expect(find.text('窗口'), findsOneWidget);
        expect(find.text('键盘'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await _closeViewer(tester, controller);
      }
    },
  );

  testWidgets(
    'landscape desktop starts with a readable landscape framebuffer',
    (tester) async {
      await service.stop();
      desktopStarts.clear();
      desktopStops.clear();
      await _setViewerSize(tester, const Size(844, 390));
      addTearDown(() => _resetViewerSize(tester));
      final controller = _viewerController();
      try {
        await _pumpViewer(tester, controller);
        expect(desktopStarts, hasLength(1));
        expect(desktopStarts.single['width'], 1120);
        expect(desktopStarts.single['height'], 700);
        final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
        expect(image.width, 1120);
        expect(image.height, 700);
        expect(
          find.byKey(const ValueKey('desktop-open-files')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('desktop-open-terminal')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _closeViewer(tester, controller);
      }
    },
  );

  testWidgets(
    'opening and rotating a viewer keeps the existing Linux desktop session',
    (tester) async {
      // The service setUp already owns a live 640x480 session. Viewing it from a
      // phone must preserve its windows instead of silently restarting it.
      final existing = sessionId;
      desktopStarts.clear();
      desktopStops.clear();
      await _setViewerSize(tester, const Size(390, 844));
      addTearDown(() => _resetViewerSize(tester));
      final controller = _viewerController();
      try {
        await _pumpViewer(tester, controller);
        expect(controller.desktop.session!.sessionId, existing);
        expect(controller.desktop.frame!.width, 640);
        expect(controller.desktop.frame!.height, 480);
        await _setViewerSize(tester, const Size(844, 390));
        await tester.pump();
        await _waitForViewerImage(tester);
        expect(controller.desktop.session!.sessionId, existing);
        expect(controller.desktop.frame!.width, 640);
        expect(controller.desktop.frame!.height, 480);
        expect(desktopStarts, isEmpty);
        expect(desktopStops, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await _closeViewer(tester, controller);
      }
    },
  );

  testWidgets(
    'labeled application controls send real RFB shortcuts and respect model ownership',
    (tester) async {
      await _setViewerSize(tester, const Size(390, 844));
      addTearDown(() => _resetViewerSize(tester));
      final controller = _viewerController();
      try {
        await _pumpViewer(tester, controller);
        final shortcuts = <String, List<Map<String, Object?>>>{
          'desktop-open-files': [
            _key(0xffeb, true),
            _key(101, true),
            _key(101, false),
            _key(0xffeb, false),
          ],
          'desktop-open-terminal': [
            _key(0xffe3, true),
            _key(0xffe9, true),
            _key(116, true),
            _key(116, false),
            _key(0xffe9, false),
            _key(0xffe3, false),
          ],
          'desktop-switch-window': [
            _key(0xffe9, true),
            _key(0xff09, true),
            _key(0xff09, false),
            _key(0xffe9, false),
          ],
        };
        for (final entry in shortcuts.entries) {
          server.input.clear();
          await tester.tap(find.byKey(ValueKey(entry.key)));
          await tester.runAsync(
            () =>
                server.waitFor(() => server.input.length >= entry.value.length),
          );
          expect(server.input, entry.value, reason: entry.key);
        }
        controller.desktop.takeModelControl();
        await tester.pump();
        server.input.clear();
        for (final key in shortcuts.keys) {
          await tester.tap(find.byKey(ValueKey(key)), warnIfMissed: false);
        }
        await tester.tap(
          find.byKey(const ValueKey('desktop-open-apps')),
          warnIfMissed: false,
        );
        expect(find.text('电脑应用'), findsNothing);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        expect(server.input, isEmpty);
        controller.desktop.releaseModelControl();
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('desktop-open-files')));
        await tester.runAsync(
          () => server.waitFor(() => server.input.length == 4),
        );
        expect(server.input, shortcuts['desktop-open-files']);
        expect(tester.takeException(), isNull);
      } finally {
        await _closeViewer(tester, controller);
      }
    },
  );

  testWidgets(
    'application picker launches only the selected application through RFB',
    (tester) async {
      await _setViewerSize(tester, const Size(390, 600));
      addTearDown(() => _resetViewerSize(tester));
      final controller = _viewerController();
      try {
        await _pumpViewer(tester, controller);
        for (final app in const {
          'writer': 119,
          'calc': 99,
          'impress': 112,
          'editor': 110,
          'settings': 105,
        }.entries) {
          server.input.clear();
          await tester.tap(find.byKey(const ValueKey('desktop-open-apps')));
          await tester.pumpAndSettle();
          expect(
            server.input,
            isEmpty,
            reason: 'Opening the picker starts no Linux app.',
          );
          final item = find.byKey(ValueKey('desktop-app-${app.key}'));
          await tester.ensureVisible(item);
          await tester.tap(item);
          await tester.pumpAndSettle();
          await tester.runAsync(
            () => server.waitFor(() => server.input.length >= 4),
          );
          expect(server.input, [
            _key(0xffeb, true),
            _key(app.value, true),
            _key(app.value, false),
            _key(0xffeb, false),
          ], reason: app.key);
          expect(tester.takeException(), isNull);
        }
      } finally {
        await _closeViewer(tester, controller);
      }
    },
  );

  testWidgets(
    'software keyboard keeps text and enter reachable without viewport overflow',
    (tester) async {
      await _setViewerSize(tester, const Size(390, 600));
      addTearDown(() => _resetViewerSize(tester));
      final controller = _viewerController();
      try {
        await _pumpViewer(tester, controller);
        final existing = controller.desktop.session!.sessionId;
        desktopStarts.clear();
        desktopStops.clear();
        await tester.tap(find.byKey(const ValueKey('desktop-toggle-keyboard')));
        await tester.pump();
        tester.view.viewInsets = const FakeViewPadding(bottom: 320);
        await tester.pump();
        expect(tester.takeException(), isNull);
        final input = find.byKey(const ValueKey('desktop-text-input'));
        expect(input, findsOneWidget);
        await tester.ensureVisible(input);
        await tester.enterText(input, 'hello');
        server.input.clear();
        final send = find.byTooltip('发送桌面文字');
        await tester.ensureVisible(send);
        await tester.tap(send);
        await tester.runAsync(
          () => server.waitFor(() => server.input.length == 10),
        );
        expect(server.input, [
          for (final rune in 'hello'.runes) ...[
            _key(rune, true),
            _key(rune, false),
          ],
        ]);
        final enter = find.byKey(const ValueKey('desktop-key-enter'));
        await tester.ensureVisible(enter);
        await tester.tap(enter);
        await tester.runAsync(
          () => server.waitFor(() => server.input.length == 12),
        );
        expect(server.input.sublist(10), [
          _key(0xff0d, true),
          _key(0xff0d, false),
        ]);
        expect(tester.takeException(), isNull);
        final hide = find.byTooltip('收起键盘');
        await tester.ensureVisible(hide);
        await tester.tap(hide);
        tester.view.resetViewInsets();
        await tester.pump();
        await _waitForViewerImage(tester);
        expect(find.byKey(const ValueKey('desktop-text-input')), findsNothing);
        expect(controller.desktop.session!.sessionId, existing);
        expect(desktopStarts, isEmpty);
        expect(desktopStops, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        tester.view.resetViewInsets();
        await _closeViewer(tester, controller);
      }
    },
  );

  testWidgets(
    'touch tap and drag preserve desktop coordinates and release the button',
    (tester) async {
      await _setViewerSize(tester, const Size(390, 844));
      addTearDown(() => _resetViewerSize(tester));
      final controller = _viewerController();
      try {
        await _pumpViewer(tester, controller);
        final image = find.byType(RawImage);
        server.input.clear();
        await tester.tap(image);
        await tester.runAsync(
          () => server.waitFor(() => server.input.length >= 2),
        );
        var pointers = server.input
            .where((event) => event['type'] == 'pointer')
            .toList();
        expect(pointers.where((event) => event['buttons'] == 1), hasLength(1));
        expect(pointers.first['x'], closeTo(320, 1));
        expect(pointers.first['y'], closeTo(240, 1));
        expect(pointers.last['buttons'], 0);

        server.input.clear();
        final bounds = tester.getRect(image);
        final start =
            bounds.topLeft + Offset(bounds.width / 4, bounds.height / 4);
        final finish =
            bounds.topLeft +
            Offset(bounds.width * 3 / 4, bounds.height * 3 / 4);
        final gesture = await tester.startGesture(start);
        await gesture.moveTo(finish);
        await tester.pump(const Duration(milliseconds: 20));
        await gesture.up();
        await tester.runAsync(
          () => server.waitFor(() => server.input.length >= 3),
        );
        pointers = server.input
            .where((event) => event['type'] == 'pointer')
            .toList();
        final held = pointers.where((event) => event['buttons'] == 1).toList();
        expect(held.length, greaterThanOrEqualTo(2));
        expect(held.first['x'], closeTo(160, 1));
        expect(held.first['y'], closeTo(120, 1));
        expect(held.last['x'], closeTo(480, 1));
        expect(held.last['y'], closeTo(360, 1));
        expect(pointers.last['buttons'], 0);
        expect(tester.takeException(), isNull);
      } finally {
        await _closeViewer(tester, controller);
      }
    },
  );

  testWidgets(
    'long pressing opens the context menu without first clicking the file',
    (tester) async {
      await _setViewerSize(tester, const Size(390, 844));
      addTearDown(() => _resetViewerSize(tester));
      final controller = _viewerController();
      try {
        await _pumpViewer(tester, controller);
        server.input.clear();
        await tester.longPress(find.byType(RawImage));
        await tester.runAsync(
          () => server.waitFor(
            () => server.input.any((event) => event['buttons'] == 4),
          ),
        );
        final pointerEvents = server.input.where(
          (event) => event['type'] == 'pointer',
        );
        expect(
          pointerEvents.where((event) => event['buttons'] == 4),
          hasLength(1),
        );
        expect(
          pointerEvents.where((event) => event['buttons'] == 1),
          isEmpty,
          reason: 'A long press must not open a single-click file before its context menu.',
        );
        expect(pointerEvents.last['buttons'], 0);
        expect(tester.takeException(), isNull);
      } finally {
        await _closeViewer(tester, controller);
      }
    },
  );

  testWidgets(
    'desktop pause releases both image handles before any paused frame',
    (tester) async {
      final binding = TestWidgetsFlutterBinding.instance;
      final controller = WorkspaceController(
        persistence: MemoryWorkspacePersistence(),
        credentials: MemoryCredentialStore(),
      );
      Future<void> waitForImage() async {
        for (var attempt = 0; attempt < 100; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump();
          if (find.byType(RawImage).evaluate().isNotEmpty) return;
        }
        fail('The fixture framebuffer was not rendered.');
      }

      try {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(
          MaterialApp(
            theme: perantTheme(),
            home: DesktopScreen(controller: controller),
          ),
        );
        await waitForImage();
        final original = tester.widget<RawImage>(find.byType(RawImage)).image!;
        final rendered = tester
            .renderObject<RenderImage>(find.byType(RawImage))
            .image!;
        expect(identical(original, rendered), isFalse);
        expect(original.isCloneOf(rendered), isTrue);

        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        // Do not pump: a background engine need not run another frame.
        expect(original.debugDisposed, isTrue);
        expect(rendered.debugDisposed, isTrue);
        expect(
          tester.renderObject<RenderImage>(find.byType(RawImage)).image,
          isNull,
        );

        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await waitForImage();
        final resumed = tester.widget<RawImage>(find.byType(RawImage)).image!;
        final resumedRenderer = tester
            .renderObject<RenderImage>(find.byType(RawImage))
            .image!;
        expect(resumed.debugDisposed, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(resumed.debugDisposed, isTrue);
        expect(resumedRenderer.debugDisposed, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(controller.desktop.stop);
        controller.dispose();
      }
    },
  );
}

WorkspaceController _viewerController() => WorkspaceController(
  persistence: MemoryWorkspacePersistence(),
  credentials: MemoryCredentialStore(),
);

Future<void> _setViewerSize(WidgetTester tester, Size logicalSize) async {
  // setSurfaceSize alone only changes render constraints. MediaQuery.fromView
  // reads platform view metrics, which must describe the same phone/tablet.
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = logicalSize;
  await tester.binding.setSurfaceSize(logicalSize);
}

Future<void> _resetViewerSize(WidgetTester tester) async {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
  await tester.binding.setSurfaceSize(null);
}

Future<void> _pumpViewer(
  WidgetTester tester,
  WorkspaceController controller,
) async {
  TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
    AppLifecycleState.resumed,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: perantTheme(),
      home: DesktopScreen(controller: controller),
    ),
  );
  await _waitForViewerImage(tester);
}

Future<void> _waitForViewerImage(WidgetTester tester) async {
  for (var attempt = 0; attempt < 150; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
    if (find.byType(RawImage).evaluate().isNotEmpty) {
      final image = tester.widget<RawImage>(find.byType(RawImage)).image;
      if (image != null && !image.debugDisposed) return;
    }
  }
  fail('The actual fixture framebuffer was not displayed by DesktopScreen.');
}

Future<void> _closeViewer(
  WidgetTester tester,
  WorkspaceController controller,
) async {
  TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
    AppLifecycleState.resumed,
  );
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(controller.desktop.stop);
  controller.dispose();
}

Map<String, Object?> _key(int keysym, bool down) => {
  'type': 'key',
  'keysym': keysym,
  'down': down,
};

const _capabilities = <String, Object?>{
  'schemaVersion': 1,
  'platform': 'android',
  'systemVersion': 'Android fixture',
  'nativeBridgeAvailable': true,
  'linux': {'available': true, 'reason': 'Test runtime'},
  'localInference': {'available': false, 'reason': 'Not used'},
  'backgroundTasks': {'available': false, 'reason': 'Not used'},
};

final class _UnixDesktop {
  _UnixDesktop(this.directory, this.listener);
  final Directory directory;
  final ServerSocket listener;
  final input = <Map<String, Object?>>[];
  final _peers = <Socket>{};
  final _tasks = <Future<void>>[];
  StreamSubscription<Socket>? _accepted;
  int connections = 0;
  int fullRequests = 0;
  int width = 640;
  int height = 480;
  Completer<void>? nextHandshakeGate;
  Completer<void>? nextFrameGate;
  String get path => '${directory.path}/rfb.sock';
  int get activePeers => _peers.length;

  static Future<_UnixDesktop> create() async {
    final directory = await Directory('/tmp').createTemp('perant-service-');
    final listener = await ServerSocket.bind(
      InternetAddress(
        '${directory.path}/rfb.sock',
        type: InternetAddressType.unix,
      ),
      0,
    );
    final server = _UnixDesktop(directory, listener);
    server._accepted = listener.listen((socket) {
      final gate = server.nextHandshakeGate;
      server.nextHandshakeGate = null;
      server.connections++;
      server._peers.add(socket);
      final task = server._serve(socket, gate);
      server._tasks.add(task);
    });
    return server;
  }

  Future<void> _serve(Socket socket, Completer<void>? handshakeGate) async {
    final reader = _PeerReader(socket);
    try {
      if (handshakeGate != null) await handshakeGate.future;
      socket.add(ascii.encode('RFB 003.008\n'));
      await socket.flush();
      expect(await reader.exact(12), ascii.encode('RFB 003.008\n'));
      socket.add([1, 1]);
      await socket.flush();
      expect(await reader.exact(1), [1]);
      socket.add([0, 0, 0, 0]);
      await socket.flush();
      await reader.exact(1);
      final initial = ByteData(24)
        ..setUint16(0, width)
        ..setUint16(2, height)
        ..setUint8(4, 32)
        ..setUint8(5, 24)
        ..setUint8(7, 1)
        ..setUint16(8, 255)
        ..setUint16(10, 255)
        ..setUint16(12, 255)
        ..setUint8(14, 16)
        ..setUint8(15, 8)
        ..setUint32(20, 7);
      socket.add(initial.buffer.asUint8List());
      socket.add(ascii.encode('Fixture'));
      await socket.flush();
      while (true) {
        final type = await reader.type();
        if (type == null) return;
        switch (type) {
          case 0:
            await reader.exact(19);
          case 2:
            await reader.exact(1);
            final count = ByteData.sublistView(await reader.exact(2))
                .getUint16(0);
            await reader.exact(count * 4);
          case 3:
            final request = await reader.exact(9);
            if (request[0] == 0) {
              fullRequests++;
              final gate = nextFrameGate;
              nextFrameGate = null;
              if (gate != null) await gate.future;
              final rectangle = ByteData(12)
                ..setUint16(4, width)
                ..setUint16(6, height)
                ..setInt32(8, 0);
              final pixels = Uint8List(width * height * 4);
              for (var offset = 0; offset < pixels.length; offset += 4) {
                pixels[offset] = 32;
                pixels[offset + 1] = 64;
                pixels[offset + 2] = 96;
              }
              socket.add([0, 0, 0, 1]);
              socket.add(rectangle.buffer.asUint8List());
              socket.add(pixels);
              await socket.flush();
            }
          case 4:
            final key = ByteData.sublistView(await reader.exact(7));
            input.add(_key(key.getUint32(3), key.getUint8(0) == 1));
          case 5:
            final pointer = ByteData.sublistView(await reader.exact(5));
            input.add({
              'type': 'pointer',
              'x': pointer.getUint16(1),
              'y': pointer.getUint16(3),
              'buttons': pointer.getUint8(0),
            });
          default:
            throw StateError('Unexpected fixture client message: $type');
        }
      }
    } on SocketException {
      // A cancelled/hidden viewer deliberately disconnects its Unix socket.
    } on _PeerEnded {
      // Closing midway through negotiation is also a normal cancellation path.
    } finally {
      _peers.remove(socket);
      await reader.close();
      socket.destroy();
    }
  }

  Future<void> waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline))
        throw StateError('RFB fixture condition timed out.');
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  Future<void> close() async {
    if (nextHandshakeGate case final gate? when !gate.isCompleted)
      gate.complete();
    if (nextFrameGate case final gate? when !gate.isCompleted) gate.complete();
    for (final socket in _peers.toList()) {
      socket.destroy();
    }
    await _accepted?.cancel();
    await listener.close();
    await Future.wait(_tasks).timeout(const Duration(seconds: 5));
    await directory.delete(recursive: true);
  }
}

final class _PeerEnded implements Exception {}

final class _PeerReader {
  _PeerReader(Stream<Uint8List> stream) : _stream = StreamIterator(stream);
  final StreamIterator<Uint8List> _stream;
  Uint8List _chunk = Uint8List(0);
  int _offset = 0;
  Future<int?> type() async {
    if (_offset == _chunk.length) {
      if (!await _stream.moveNext()) return null;
      _chunk = _stream.current;
      _offset = 0;
    }
    if (_chunk.isEmpty) return type();
    return _chunk[_offset++];
  }

  Future<Uint8List> exact(int count) async {
    final result = Uint8List(count);
    var written = 0;
    while (written < count) {
      if (_offset == _chunk.length) {
        if (!await _stream.moveNext()) throw _PeerEnded();
        _chunk = _stream.current;
        _offset = 0;
      }
      final take = (count - written).clamp(0, _chunk.length - _offset);
      result.setRange(written, written + take, _chunk, _offset);
      _offset += take;
      written += take;
    }
    return result;
  }

  Future<void> close() => _stream.cancel();
}
