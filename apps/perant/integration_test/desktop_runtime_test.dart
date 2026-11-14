// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderImage;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:perant/src/application/shared_desktop_service.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant/src/presentation/desktop_screen.dart';
import 'package:perant/src/presentation/theme.dart';
import 'package:perant_gateway/perant_gateway.dart';
import 'package:perant_platform/perant_platform.dart';

/// Genuine Android Xvnc/Xfce, Unix RFB and actual pixels/input.
/// No model, HTTP fixture, default user DB or production credential is used.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'suite': 'android-real-linux-desktop',
    'realDesktopServer': 'Xvnc',
    'realWindowManager': 'Xfwm4',
    'realDesktopShell': 'Xfce panel + Xfdesktop',
    'transport': 'app-private-unix',
    'externalHttpRequests': 0,
    'realModelVerified': false,
    'backgroundOsSchedulingVerified': false,
    'isolationClaim': false,
    'checks': <Map<String, dynamic>>[],
  };
  binding.reportData = report;
  late _DesktopHarness linux;

  setUpAll(() async {
    expect(Platform.isAndroid, isTrue);
    linux = _DesktopHarness(
      PerantPlatformBridge(initializationTimeout: const Duration(minutes: 5)),
    );
    await linux.attach();
    // Never take over or terminate a desktop started outside this test suite.
    expect(
      await linux.bridge.getLinuxDesktopSession(),
      isNull,
      reason: 'Close an existing personal desktop before running integration tests.',
    );
    final status = await linux.bridge.initializeLinux();
    expect(status.supported && status.installed, isTrue, reason: status.reason);
    expect(status.desktopAvailable, isTrue, reason: status.reason);
  });

  setUp(() async {
    expect(await linux.bridge.getLinuxDesktopSession(), isNull);
  });

  tearDown(() async {
    await linux.cleanup();
    expect(linux.streamError, isNull);
  });

  tearDownAll(() => linux.dispose());

  testWidgets(
    'phone Xfce menu and application shortcuts produce a persistent GUI file',
    (tester) async {
      final directory = await linux.createDirectory();
      final marker = '$directory/gui.txt';
      final session = await linux.start(width: 720, height: 1080);
      expect(session.pid, greaterThan(0));
      expect(session.width, 720);
      expect(session.height, 1080);
      final stat = await FileStat.stat(session.socketPath);
      expect(
        stat.mode & 0x1ff,
        0x180,
        reason: 'RFB Unix socket must be mode 0600.',
      );
      DesktopRfbClient? viewer;
      try {
        viewer = await DesktopRfbClient.connectUnix(
          session.socketPath,
          continuous: false,
        );
        final painted = await _paintedDesktop(viewer);
        expect(_palette(painted.rgba), greaterThanOrEqualTo(8));
        expect(painted.rgba.length, 720 * 1080 * 4);
        final settled = await _settledDesktop(viewer, painted);
        // The fixed Xfce panel is 84px tall with its menu at the left end.
        // Exercise that GUI target, rather than invoking a native shell helper.
        await viewer.pointer(x: 42, y: session.height - 42, buttons: 1);
        await viewer.pointer(x: 42, y: session.height - 42);
        final openedMenu = await _windowChanged(
          viewer,
          settled,
          reason:
              'Clicking the native taskbar start button did not open its menu.',
        );
        final menuFrame = await _settledDesktop(viewer, openedMenu);
        final cache = await getTemporaryDirectory();
        final menuArtifact = File(
          '${cache.path}/perant-desktop-menu-${linux.nonce}.png',
        );
        final menuPng = menuFrame.encodePng();
        await menuArtifact.writeAsBytes(menuPng, flush: true);
        _recordPng('MENU', menuPng);
        await _shortcut(viewer, 0xff1b);
        final closedMenu = await _windowChanged(
          viewer,
          menuFrame,
          reason: 'Escape did not close the actual application menu.',
        );
        final closedDesktop = await _settledDesktop(viewer, closedMenu);
        await _shortcut(viewer, 0x65, [0xffeb]); // Super+e: actual Thunar.
        final files = await _windowChanged(
          viewer,
          closedDesktop,
          reason: 'Super+e did not open a visible Thunar window.',
        );
        final filesFrame = await _settledDesktop(viewer, files);
        final filesArtifact = File(
          '${cache.path}/perant-desktop-files-${linux.nonce}.png',
        );
        final filesPng = filesFrame.encodePng();
        await filesArtifact.writeAsBytes(filesPng, flush: true);
        _recordPng('FILES', filesPng);
        await _shortcut(viewer, 0x64, [0xffeb]); // Super+d: show desktop.
        final shownDesktop = await _windowChanged(
          viewer,
          filesFrame,
          reason:
              'Super+d did not hide application windows and show the desktop.',
        );
        final desktop = await _settledDesktop(viewer, shownDesktop);
        await _shortcut(viewer, 0x74, [0xffe3, 0xffe9]); // Ctrl+Alt+t.
        final terminal = await _windowChanged(
          viewer,
          desktop,
          reason: 'Ctrl+Alt+t did not open a new terminal window.',
        );
        await _settledDesktop(viewer, terminal);
        await viewer.text(
          "printf '%s\\n' DESKTOP_GUI_INPUT_OK > ${_quote(marker)}\n",
        );
        await Future<void>.delayed(const Duration(milliseconds: 900));
        final afterInput = await _settledDesktop(
          viewer,
          await viewer.capture(timeout: const Duration(seconds: 15)),
        );
        final png = afterInput.encodePng();
        final codec = await ui.instantiateImageCodec(png);
        final decoded = await codec.getNextFrame();
        expect(decoded.image.width, afterInput.width);
        expect(decoded.image.height, afterInput.height);
        decoded.image.dispose();
        codec.dispose();
        final artifact = File(
          '${cache.path}/perant-desktop-smoke-${linux.nonce}.png',
        );
        await artifact.writeAsBytes(png, flush: true);
        _recordPng('TERMINAL', png);
        report['screenshotAppPath'] = artifact.path;
        await _shortcut(viewer, 0x69, [0xffeb]); // Super+i: Xfce settings.
        final settings = await _windowChanged(
          viewer,
          afterInput,
          reason: 'Super+i did not open a visible Xfce settings window.',
        );
        final settingsFrame = await _settledDesktop(viewer, settings);
        final settingsArtifact = File(
          '${cache.path}/perant-desktop-settings-${linux.nonce}.png',
        );
        final settingsPng = settingsFrame.encodePng();
        await settingsArtifact.writeAsBytes(settingsPng, flush: true);
        _recordPng('SETTINGS', settingsPng);
        await _shortcut(viewer, 0xffc1, [0xffe9]); // Alt+F4: close settings.
        final settingsClosed = await _windowChanged(
          viewer,
          settingsFrame,
          reason: 'Alt+F4 did not close the Xfce settings window.',
        );
        final returnedTerminal = await _settledDesktop(viewer, settingsClosed);
        expect(
          _changedPixels(afterInput, returnedTerminal),
          lessThan(4096),
          reason:
              'Closing settings did not reveal the same terminal underneath; '
              'a shortcut may have opened a chooser or changed application focus.',
        );
        await _shortcut(viewer, 0x6e, [0xffeb]); // Super+n: Mousepad.
        final editor = await _windowChanged(
          viewer,
          returnedTerminal,
          reason: 'Super+n did not open a visible Mousepad editor.',
        );
        final editorFrame = await _settledDesktop(viewer, editor);
        final editorArtifact = File(
          '${cache.path}/perant-desktop-editor-${linux.nonce}.png',
        );
        final editorPng = editorFrame.encodePng();
        await editorArtifact.writeAsBytes(editorPng, flush: true);
        _recordPng('EDITOR', editorPng);
        await _shortcut(viewer, 0xffc1, [
          0xffe9,
        ]); // Alt+F4: close blank editor.
        final editorClosed = await _windowChanged(
          viewer,
          editorFrame,
          reason: 'Alt+F4 did not close the blank Mousepad window.',
        );
        expect(
          _changedPixels(
            afterInput,
            await _settledDesktop(viewer, editorClosed),
          ),
          lessThan(4096),
          reason: 'Closing the editor did not restore the same terminal.',
        );
        await viewer.close();
        expect(viewer.retainedPixelBytes, 0);
        viewer = null;
        // Native file API stays mutually exclusive with the desktop process.
        // Stop the real desktop before reading its GUI-created file.
        await linux.stop(session.sessionId);
        LinuxTextFile actual;
        try {
          actual = await linux.bridge.readLinuxFile(marker);
        } catch (_) {
          // Device integration may uninstall its test APK after completion.
          // Preserve the real post-input framebuffer in the redirected test log
          // so the host can inspect window focus/typing instead of guessing.
          // ignore: avoid_print
          print('DESKTOP_GUI_FAILURE_PNG_BASE64 ${base64Encode(png)}');
          // ignore: avoid_print
          print(
            'DESKTOP_GUI_FAILURE_RUNTIME_LOG ${jsonEncode(linux.desktopOutput(session.sessionId))}',
          );
          rethrow;
        }
        expect(actual.content, 'DESKTOP_GUI_INPUT_OK\n');
        final reopened = await linux.start(width: 720, height: 1080);
        expect(reopened.sessionId, isNot(session.sessionId));
        final reconnected = await DesktopRfbClient.connectUnix(
          reopened.socketPath,
          continuous: false,
        );
        try {
          expect((await reconnected.firstFrame).width, reopened.width);
        } finally {
          await reconnected.close();
        }
        await linux.stop(reopened.sessionId);
        expect(
          (await linux.bridge.readLinuxFile(marker)).content,
          actual.content,
        );
        _record(report, 'real-desktop-gui-input-and-persistence', {
          'width': afterInput.width,
          'height': afterInput.height,
          'observedPalette': _palette(afterInput.rgba),
          'unixSocketMode': '0600',
          'guiShortcut': 'Ctrl+Alt+t',
          'taskbarStartMenuOpenedViaClick': true,
          'taskbarStartMenuClosedViaEscape': true,
          'fileManagerOpenedViaSuperE': true,
          'fileManager': 'Thunar',
          'fileManagerScreenshotAppPath': filesArtifact.path,
          'showDesktopViaSuperDObserved': true,
          'startMenuScreenshotAppPath': menuArtifact.path,
          'settingsWindowOpenedViaSuperI': true,
          'settingsScreenshotAppPath': settingsArtifact.path,
          'settingsClosedViaAltF4': true,
          'sameTerminalRestoredAfterSettings': true,
          'editorOpenedViaSuperN': true,
          'editor': 'Mousepad',
          'editorScreenshotAppPath': editorArtifact.path,
          'editorClosedViaAltF4': true,
          'guiWindowObservedAfterShortcut': true,
          'guiFramesSettledBeforeTyping': true,
          'inputTransport': 'RFB KeyEvent',
          'actualFileReadAfterDesktopStopped': true,
          'artifactText': actual.content.trim(),
          'pngBytes': png.length,
          'pngDecodedByFlutter': true,
          'screenshotAppPath': artifact.path,
          'restartPreservedWorkspaceFile': true,
        });
      } finally {
        await viewer?.close();
        await linux.stop(session.sessionId);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    'hidden service releases viewer pixels and temporary observations keep no live framebuffer',
    (tester) async {
      final service = SharedDesktopService(linux.bridge);
      try {
        final session = await service.start(width: 1024, height: 640);
        linux.ownedSessions.add(session.sessionId);
        await service.setViewerVisible(true);
        expect(service.viewerConnected, isTrue);
        expect(service.frame, isNotNull);
        await service.setViewerVisible(false);
        expect(service.viewerConnected, isFalse);
        expect(service.frame, isNull);
        expect(
          (await linux.bridge.getLinuxDesktopSession())?.sessionId,
          session.sessionId,
        );
        service.takeModelControl();
        final observation = await service.observe();
        expect(observation.png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
        expect(observation.width, 1024);
        expect(service.viewerConnected, isFalse);
        expect(service.frame, isNull);
        // Releasing/cancelling model ownership invalidates every old screenshot.
        service.releaseModelControl();
        await expectLater(
          service.perform(
            observationId: observation.id,
            action: 'click',
            x: 20,
            y: 20,
          ),
          throwsStateError,
        );
        service.takeModelControl();
        await expectLater(
          service.perform(
            observationId: observation.id,
            action: 'click',
            x: 20,
            y: 20,
          ),
          throwsStateError,
        );
        service.releaseModelControl();
        expect(
          (await linux.bridge.getLinuxDesktopSession())?.sessionId,
          session.sessionId,
        );
        _record(report, 'real-desktop-hidden-viewer-and-observation', {
          'hiddenViewerConnected': service.viewerConnected,
          'hiddenLiveFrameRetained': service.frame != null,
          'desktopStillRunning': true,
          'singleObservationPngBytes': observation.png.length,
          'staleObservationRejectedAfterTakeover': true,
          'staleObservationRejectedAfterRegrant': true,
        });
        await service.stop();
        linux.ownedSessions.remove(session.sessionId);
      } finally {
        await service.stop();
        service.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    'desktop screen lifecycle detaches background rendering and reconnects on resume',
    (tester) async {
      final network = _NoCloudClient();
      final controller = WorkspaceController(
        persistence: MemoryWorkspacePersistence(),
        credentials: MemoryCredentialStore(),
        gateway: OpenAiGateway(client: network),
        bridge: linux.bridge,
      );
      try {
        await controller.initialize();
        final initialLifecycle = binding.lifecycleState?.name;
        // The previous native-only cases do not mount a Flutter viewer. State
        // the foreground precondition before checking this viewer's pixels.
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        // ignore: avoid_print
        print(
          'DESKTOP_SCREEN_DIAGNOSTIC ' +
              jsonEncode({
                'phase': 'before-mount',
                'initialLifecycle': initialLifecycle,
                'viewerLifecycle': binding.lifecycleState?.name,
              }),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: perantTheme(),
            home: DesktopScreen(controller: controller),
          ),
        );
        try {
          await _waitUi(
            tester,
            () =>
                controller.desktop.frame != null &&
                _hasLiveDesktopImage(tester),
            reason: 'The actual desktop pixels were not displayed by DesktopScreen.',
          );
        } catch (_) {
          final native = await linux.bridge.getLinuxDesktopSession();
          final status = await linux.bridge.getLinuxStatus();
          // Actual state only; no fallback image or longer timeout on failure.
          // ignore: avoid_print
          print(
            'DESKTOP_SCREEN_DIAGNOSTIC ' +
                jsonEncode({
                  'phase': 'initial-pixels-failed',
                  'initialLifecycle': initialLifecycle,
                  'currentLifecycle': binding.lifecycleState?.name,
                  'desktopError': controller.desktop.error,
                  'busy': controller.desktop.busy,
                  'running': controller.desktop.running,
                  'viewerConnected': controller.desktop.viewerConnected,
                  'hasRgbaFrame': controller.desktop.frame != null,
                  'rawImageWidgets': find.byType(RawImage).evaluate().length,
                  'nativeSessionId': native?.sessionId,
                  'nativeLinuxActive': status.active,
                  'nativeReason': status.reason,
                }),
          );
          rethrow;
        }
        final session = controller.desktop.session!;
        linux.ownedSessions.add(session.sessionId);
        final pausedImage = tester
            .widget<RawImage>(find.byType(RawImage))
            .image!;
        final pausedRenderer = tester.renderObject<RenderImage>(
          find.byType(RawImage),
        );
        final pausedRenderHandle = pausedRenderer.image!;
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        // A paused Flutter engine does not schedule frames. Check both GPU
        // handles synchronously, then only wait for ordinary asynchronous IO;
        // tester.pump here would wait forever for a deliberately disabled frame.
        expect(pausedImage.debugDisposed, isTrue);
        expect(
          pausedRenderHandle.debugDisposed,
          isTrue,
          reason: 'Pausing must dispose the RenderImage clone before any new frame.',
        );
        expect(pausedRenderer.image, isNull);
        await _waitIo(
          () =>
              !controller.desktop.viewerConnected &&
              controller.desktop.frame == null,
          reason: 'The paused desktop screen retained a live viewer/frame.',
        );
        expect(
          pausedImage.debugDisposed,
          isTrue,
          reason: 'Pausing must release the decoded GPU image, not only the service frame.',
        );
        expect(
          (await linux.bridge.getLinuxDesktopSession())?.sessionId,
          session.sessionId,
        );
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await _waitUi(
          tester,
          () =>
              controller.desktop.viewerConnected &&
              controller.desktop.frame != null &&
              _hasLiveDesktopImage(tester),
          reason: 'The desktop viewer did not reconnect after resume.',
        );
        final unmountedImage = tester
            .widget<RawImage>(find.byType(RawImage))
            .image!;
        final unmountedRenderHandle = tester
            .renderObject<RenderImage>(find.byType(RawImage))
            .image!;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await controller.desktop.setViewerVisible(false);
        expect(controller.desktop.viewerConnected, isFalse);
        expect(controller.desktop.frame, isNull);
        expect(
          unmountedImage.debugDisposed,
          isTrue,
          reason: 'Leaving DesktopScreen must release its decoded GPU image.',
        );
        expect(
          unmountedRenderHandle.debugDisposed,
          isTrue,
          reason:
              'Leaving DesktopScreen must also release the RenderImage clone.',
        );
        expect(
          (await linux.bridge.getLinuxDesktopSession())?.sessionId,
          session.sessionId,
        );
        expect(network.requests, 0);
        expect(tester.takeException(), isNull);
        _record(report, 'real-desktop-screen-lifecycle', {
          'actualDesktopRendered': true,
          'pausedViewerReleased': true,
          'pausedGpuImageDisposed': pausedImage.debugDisposed,
          'pausedRenderImageCloneDisposedBeforePump':
              pausedRenderHandle.debugDisposed,
          'resumedViewerReconnected': true,
          'unmountedViewerReleased': true,
          'unmountedGpuImageDisposed': unmountedImage.debugDisposed,
          'unmountedRenderImageCloneDisposed':
              unmountedRenderHandle.debugDisposed,
          'nativeDesktopRetainedWhileViewerHidden': true,
          'lifecycleNotificationSource':
              'injected Flutter binding on Android engine',
          'backgroundOsSchedulingVerified': false,
          'modelHttpRequests': network.requests,
        });
        await controller.desktop.stop();
        linux.ownedSessions.remove(session.sessionId);
      } finally {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await controller.desktop.stop();
        controller.dispose();
        network.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<DesktopFrame> _paintedDesktop(DesktopRfbClient client) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  var frame = await client.firstFrame.timeout(const Duration(seconds: 20));
  while (_palette(frame.rgba) < 8) {
    if (DateTime.now().isAfter(deadline))
      fail('Xvnc connected but no painted application windows appeared.');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    frame = await client.capture(timeout: const Duration(seconds: 15));
  }
  return frame;
}

Future<DesktopFrame> _settledDesktop(
  DesktopRfbClient client,
  DesktopFrame initial,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  final observedFor = Stopwatch()..start();
  var previous = initial;
  var stable = 0;
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final next = await client.capture(timeout: const Duration(seconds: 15));
    // A blinking terminal caret changes a small area. Window mapping/layout
    // changes a much larger region and resets the consecutive-stability count.
    stable = _changedPixels(previous, next) <= 600 ? stable + 1 : 0;
    previous = next;
    if (stable >= 3 &&
        observedFor.elapsed >= const Duration(milliseconds: 1500))
      return next;
  }
  // ignore: avoid_print
  print('DESKTOP_GUI_FAILURE_PNG_BASE64 ${base64Encode(previous.encodePng())}');
  fail('Linux desktop windows did not settle before keyboard input.');
}

Future<DesktopFrame> _windowChanged(
  DesktopRfbClient client,
  DesktopFrame beforeShortcut, {
  String reason =
      'The desktop action did not produce an observed window change.',
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  var observed = beforeShortcut;
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    observed = await client.capture(timeout: const Duration(seconds: 15));
    if (_changedPixels(beforeShortcut, observed) >= 4096) return observed;
  }
  // ignore: avoid_print
  print('DESKTOP_GUI_FAILURE_PNG_BASE64 ${base64Encode(observed.encodePng())}');
  fail(reason);
}

Future<void> _shortcut(
  DesktopRfbClient viewer,
  int keysym, [
  List<int> modifiers = const [],
]) async {
  for (final modifier in modifiers) {
    await viewer.key(keysym: modifier, down: true);
  }
  await viewer.key(keysym: keysym, down: true);
  await viewer.key(keysym: keysym, down: false);
  for (final modifier in modifiers.reversed) {
    await viewer.key(keysym: modifier, down: false);
  }
}

int _changedPixels(DesktopFrame before, DesktopFrame after) {
  if (before.width != after.width || before.height != after.height) return 4096;
  var changed = 0;
  for (var offset = 0; offset < before.rgba.length; offset += 4) {
    if (before.rgba[offset] != after.rgba[offset] ||
        before.rgba[offset + 1] != after.rgba[offset + 1] ||
        before.rgba[offset + 2] != after.rgba[offset + 2]) {
      if (++changed >= 4096) return changed;
    }
  }
  return changed;
}

int _palette(Uint8List rgba) {
  final colors = <int>{};
  final pixels = rgba.length ~/ 4;
  final step = (pixels ~/ 20000).clamp(1, pixels);
  for (var pixel = 0; pixel < pixels; pixel += step) {
    final offset = pixel * 4;
    colors.add(
      (rgba[offset] << 16) | (rgba[offset + 1] << 8) | rgba[offset + 2],
    );
    if (colors.length >= 256) break;
  }
  return colors.length;
}

Future<void> _waitUi(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await tester.pump(const Duration(milliseconds: 100));
  }
  // A live RFB view may keep scheduling frames: do not pumpAndSettle here.
  await tester.pump();
}

bool _hasLiveDesktopImage(WidgetTester tester) {
  final image = find.byType(RawImage);
  if (image.evaluate().length != 1) return false;
  final widgetHandle = tester.widget<RawImage>(image).image;
  final renderHandle = tester.renderObject<RenderImage>(image).image;
  return widgetHandle != null &&
      !widgetHandle.debugDisposed &&
      renderHandle != null &&
      !renderHandle.debugDisposed;
}

Future<void> _waitIo(
  bool Function() condition, {
  required String reason,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void _record(
  Map<String, dynamic> report,
  String check,
  Map<String, dynamic> details,
) {
  final value = <String, dynamic>{'check': check, ...details};
  (report['checks'] as List<Map<String, dynamic>>).add(value);
  // Harmless fixture markers, frame sizes and test-created paths only.
  // ignore: avoid_print
  print('DESKTOP_RUNTIME_RESULT ${jsonEncode(value)}');
}

void _recordPng(String label, Uint8List png) {
  // Only these test-owned desktop frames are exported, so evidence survives
  // integration-test APK uninstall without accessing a user's saved images.
  // ignore: avoid_print
  print('DESKTOP_GUI_${label}_PNG_BASE64 ${base64Encode(png)}');
}

String _quote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

final class _DesktopHarness {
  _DesktopHarness(this.bridge);
  final PerantPlatformBridge bridge;
  final String nonce = DateTime.now().microsecondsSinceEpoch.toString();
  final ownedSessions = <String>{};
  final _directories = <String>[];
  final _commands = <String, Completer<int>>{};
  final _desktopLogs = <String, String>{};
  StreamSubscription<RuntimeEvent>? _events;
  Object? streamError;
  int _sequence = 0;

  Future<void> attach() async {
    _events = bridge.events.listen((event) {
      if (event.type == 'linuxOutput' && ownedSessions.contains(event.taskId)) {
        final id = event.taskId!;
        final text =
            (_desktopLogs[id] ?? '') + (event.payload['text'] as String);
        _desktopLogs[id] = text.length > 8192
            ? text.substring(text.length - 8192)
            : text;
      }
      if (event.type == 'linuxExit') {
        final command = _commands[event.taskId];
        if (command != null && !command.isCompleted)
          command.complete(event.payload['exitCode'] as int);
      }
    }, onError: (Object error) => streamError = error);
    await bridge.ensureRuntimeEventsAttached();
  }

  String desktopOutput(String sessionId) => _desktopLogs[sessionId] ?? '';

  Future<String> createDirectory() async {
    final path = '/workspace/perant-desktop-smoke-$nonce-${_sequence++}';
    _directories.add(path);
    await bridge.createLinuxDirectory(path);
    return path;
  }

  Future<LinuxDesktopSession> start({
    int width = 1024,
    int height = 640,
  }) async {
    final id = 'perant-desktop-smoke-$nonce-${_sequence++}';
    ownedSessions.add(id);
    final session = await bridge.startLinuxDesktop(
      sessionId: id,
      width: width,
      height: height,
    );
    expect(
      session.sessionId,
      id,
      reason: 'Do not attach a test to an unowned desktop.',
    );
    return session;
  }

  Future<void> stop(String sessionId) async {
    if (!ownedSessions.contains(sessionId)) return;
    await bridge.stopLinuxDesktop(sessionId);
    ownedSessions.remove(sessionId);
    expect(await bridge.getLinuxDesktopSession(), isNull);
    expect((await bridge.getLinuxStatus()).active, isFalse);
  }

  Future<void> cleanup() async {
    for (final id in ownedSessions.toList()) {
      await stop(id);
    }
    for (final path in _directories.toList()) {
      if (!RegExp('^/workspace/perant-desktop-smoke-$nonce-[0-9]+\$')
          .hasMatch(path)) {
        throw StateError('Refusing cleanup of an unowned Linux directory.');
      }
      final id = 'desktop-clean-$nonce-${_sequence++}';
      final exit = Completer<int>();
      _commands[id] = exit;
      await bridge.runLinuxCommand(
        taskId: id,
        command: 'rm -rf -- ${_quote(path)}',
      );
      expect(await exit.future.timeout(const Duration(seconds: 20)), 0);
      _commands.remove(id);
      _directories.remove(path);
    }
  }

  Future<void> dispose() async {
    await cleanup();
    await _events?.cancel();
  }
}

final class _NoCloudClient extends http.BaseClient {
  int requests = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    throw StateError('Desktop runtime tests must not issue cloud requests.');
  }
}
