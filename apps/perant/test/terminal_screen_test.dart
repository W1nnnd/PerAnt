// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant/src/presentation/terminal_screen.dart';
import 'package:perant/src/presentation/theme.dart';
import 'package:perant_platform/perant_platform.dart';
import 'package:xterm/xterm.dart';

final class _NativeTerminalFixture {
  static const methods = MethodChannel('dev.perant/test-terminal/methods');
  static const events = EventChannel('dev.perant/test-terminal/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final writes = <String>[];
  final _pending = <Map<String, Object?>>[];
  bool supported = true;
  bool installed = false;
  bool active = false;
  bool listening = false;
  bool initializationFails = false;
  int closeFailures = 0;
  int closeAttempts = 0;
  Completer<void>? closeGate;
  String? sessionId;

  void install() {
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      final args = call.arguments is Map ? call.arguments! as Map : const {};
      switch (call.method) {
        case 'getCapabilities':
          final unavailable = {
            'available': false,
            'reason': 'Not part of this fixture',
          };
          return {
            'schemaVersion': 1,
            'platform': 'android',
            'systemVersion': 'test',
            'nativeBridgeAvailable': true,
            'linux': {
              'available': supported,
              'reason': supported
                  ? 'Fixture provides an offline Alpine runtime.'
                  : '此测试平台没有 Linux 运行时。',
            },
            'localInference': unavailable,
            'backgroundTasks': unavailable,
          };
        case 'getLinuxStatus':
          return status;
        case 'initializeLinux':
          if (initializationFails) {
            throw PlatformException(
              code: 'installation_failed',
              message: 'fixture initialization failed',
            );
          }
          installed = true;
          return status;
        case 'startLinuxSession':
          if (active) {
            throw PlatformException(code: 'busy', message: 'fixture is active');
          }
          sessionId = args['sessionId']! as String;
          active = true;
          await emit('linuxOutput', {
            'sessionId': sessionId,
            'text': 'native-output\r\n',
          });
          return {
            'sessionId': sessionId,
            'pid': 4242,
            'workspace': '/workspace',
          };
        case 'writeLinuxSession':
          writes.add(args['data']! as String);
          return null;
        case 'resizeLinuxSession':
          return null;
        case 'closeLinuxSession':
          closeAttempts++;
          await closeGate?.future;
          if (closeFailures > 0) {
            closeFailures--;
            throw PlatformException(
              code: 'close_failed',
              message: 'fixture close failed',
            );
          }
          if (active && args['sessionId'] != sessionId) {
            throw PlatformException(
              code: 'session_mismatch',
              message: 'fixture belongs to another session',
            );
          }
          active = false;
          return null;
      }
      throw PlatformException(code: 'unexpected', message: call.method);
    });
    messenger.setMockMethodCallHandler(MethodChannel(events.name), (
      call,
    ) async {
      if (call.method == 'listen') {
        listening = true;
        for (final event in List.of(_pending)) {
          await _deliver(event);
        }
        _pending.clear();
      } else if (call.method == 'cancel') {
        listening = false;
      }
      return null;
    });
  }

  Map<String, Object?> get status => {
    'supported': supported,
    'installed': installed,
    'active': active,
    'sessionId': active ? sessionId : null,
    'distribution': 'Alpine',
    'version': supported ? '3.24.4' : 'unavailable',
    'workspace': '/workspace',
    'reason': supported ? '' : '此测试平台没有 Linux 运行时。',
  };

  Future<void> emit(String type, Map<String, Object?> payload) async {
    final event = <String, Object?>{
      'type': type,
      'emittedAtEpochMs': 1,
      'payload': payload,
    };
    if (!listening) {
      _pending.add(event);
      return;
    }
    await _deliver(event);
  }

  Future<void> _deliver(Map<String, Object?> value) async {
    await messenger.handlePlatformMessage(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope(value),
      (_) {},
    );
  }

  void uninstall() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(MethodChannel(events.name), null);
  }
}

final class _PopObserver extends NavigatorObserver {
  int count = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    count++;
    super.didPop(route, previousRoute);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<WorkspaceController> launch(
    WidgetTester tester,
    _NativeTerminalFixture native, {
    NavigatorObserver? observer,
  }) async {
    native.install();
    final controller = WorkspaceController(
      persistence: MemoryWorkspacePersistence(),
      credentials: MemoryCredentialStore(),
      bridge: PerantPlatformBridge(
        methodChannel: _NativeTerminalFixture.methods,
        eventChannel: _NativeTerminalFixture.events,
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      controller.dispose();
      native.uninstall();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: perantTheme(),
        navigatorObservers: [if (observer != null) observer],
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                final lease = controller.acquireManualTerminal();
                unawaited(
                  Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) =>
                          TerminalScreen(controller: controller, lease: lease),
                    ),
                  ),
                );
              },
              child: const Text('open-terminal'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-terminal'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    return controller;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.tap(find.byTooltip('关闭终端'));
    await tester.pump();
    // StreamSubscription.cancel may complete in the real event loop rather
    // than the test clock; wait for its acknowledgment before route animation.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'initializes a native session, renders output and sends terminal keys',
    (tester) async {
      final native = _NativeTerminalFixture();
      final controller = await launch(tester, native);
      expect(find.text('初始化 Linux 环境'), findsOneWidget);
      expect(find.byType(TerminalView), findsNothing);
      expect(controller.manualTerminalActive, isTrue);

      await tester.tap(find.text('初始化 Linux 环境'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final terminal = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .terminal;
      expect(terminal.buffer.getText(), contains('native-output'));
      await native.emit('linuxOutput', {
        'sessionId': 'another-session',
        'text': 'foreign-output\r\n',
      });
      await tester.pump();
      expect(terminal.buffer.getText(), isNot(contains('foreign-output')));
      expect(
        native.calls.any((call) => call.method == 'startLinuxSession'),
        isTrue,
      );

      await tester.tap(find.text('Ctrl-C'));
      await tester.tap(find.text('Tab'));
      await tester.ensureVisible(find.byTooltip('向上'));
      await tester.tap(find.byTooltip('向上'));
      terminal.textInput('pwd\r');
      await tester.pump();
      expect(
        native.writes,
        containsAllInOrder(['\u0003', '\t', '\u001b[A', 'pwd\r']),
      );
      expect(
        native.calls.any((call) => call.method == 'resizeLinuxSession'),
        isTrue,
      );
      expect(tester.takeException(), isNull);

      await close(tester);
      expect(native.active, isFalse);
      expect(native.closeAttempts, 1);
      expect(controller.manualTerminalActive, isFalse);
      expect(find.byType(TerminalScreen), findsNothing);
    },
  );

  testWidgets(
    'unsupported host reports real status and releases the lease on return',
    (tester) async {
      final native = _NativeTerminalFixture()..supported = false;
      final controller = await launch(tester, native);

      expect(find.text('本地环境暂不可用'), findsOneWidget);
      expect(find.text('此测试平台没有 Linux 运行时。'), findsOneWidget);
      expect(find.byType(TerminalView), findsNothing);
      expect(
        native.calls.any((call) => call.method == 'startLinuxSession'),
        isFalse,
      );
      await close(tester);
      expect(controller.manualTerminalActive, isFalse);
      expect(native.closeAttempts, 0);
    },
  );

  testWidgets('phone terminal fits above the software keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final native = _NativeTerminalFixture()..installed = true;
    await launch(tester, native);

    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.byType(TerminalView), findsOneWidget);
    expect(
      tester.getBottomLeft(find.byType(TerminalView)).dy,
      lessThanOrEqualTo(308),
    );
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('native initialization failure does not fabricate a prompt', (
    tester,
  ) async {
    final native = _NativeTerminalFixture()..initializationFails = true;
    final controller = await launch(tester, native);
    await tester.tap(find.text('初始化 Linux 环境'));
    await tester.pumpAndSettle();

    expect(find.text('fixture initialization failed'), findsWidgets);
    expect(find.byType(TerminalView), findsNothing);
    expect(native.active, isFalse);
    expect(controller.manualTerminalActive, isTrue);
    await close(tester);
    expect(controller.manualTerminalActive, isFalse);
  });

  testWidgets(
    'uncertain native close keeps manual ownership until retry succeeds',
    (tester) async {
      final native = _NativeTerminalFixture()
        ..installed = true
        ..closeFailures = 1;
      final controller = await launch(tester, native);

      await tester.tap(find.byTooltip('关闭终端'));
      await tester.pump();
      expect(find.textContaining('尚未确认终端关闭'), findsOneWidget);
      expect(controller.manualTerminalActive, isTrue);
      expect(native.active, isTrue);
      expect(find.byType(TerminalScreen), findsOneWidget);
      await close(tester);
      expect(native.closeAttempts, 2);
      expect(native.active, isFalse);
      expect(controller.manualTerminalActive, isFalse);
    },
  );

  testWidgets('repeated close requests pop only the terminal route', (
    tester,
  ) async {
    final observer = _PopObserver();
    final native = _NativeTerminalFixture()..installed = true;
    final controller = await launch(tester, native, observer: observer);
    await close(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                final lease = controller.acquireManualTerminal();
                unawaited(
                  Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) =>
                          TerminalScreen(controller: controller, lease: lease),
                    ),
                  ),
                );
              },
              child: const Text('nested-terminal-launcher'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('nested-terminal-launcher'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    final gate = Completer<void>();
    native.closeGate = gate;
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final popsBefore = observer.count;
    final closesBefore = native.closeAttempts;
    final button = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == '关闭终端',
      ),
    );
    button.onPressed!();
    button.onPressed!();
    await tester.pump();
    expect(native.closeAttempts, closesBefore + 1);
    expect(controller.manualTerminalActive, isTrue);

    gate.complete();
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(observer.count, popsBefore + 1);
    expect(find.text('nested-terminal-launcher'), findsOneWidget);
    expect(find.byType(TerminalScreen), findsNothing);
    expect(native.active, isFalse);
    expect(controller.manualTerminalActive, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'repeated restart requests share one native replacement session',
    (tester) async {
      final native = _NativeTerminalFixture()..installed = true;
      final controller = await launch(tester, native);
      final oldId = native.sessionId!;
      native.active = false;
      await native.emit('linuxExit', {
        'sessionId': oldId,
        'exitCode': 0,
        'cancelled': false,
        'timedOut': false,
      });
      await tester.pump();

      final gate = Completer<void>();
      native.closeGate = gate;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final restart = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '关闭旧会话并重新打开'),
      );
      // Invoke the same visible callback twice before a rebuild can remove it.
      restart.onPressed!();
      restart.onPressed!();
      await tester.pump();
      expect(native.closeAttempts, 1);
      expect(controller.manualTerminalActive, isTrue);

      gate.complete();
      await tester.pumpAndSettle();
      expect(
        native.calls.where((call) => call.method == 'startLinuxSession'),
        hasLength(2),
      );
      expect(native.active, isTrue);
      expect(native.sessionId, isNot(oldId));
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).readOnly,
        isFalse,
      );

      // The screen must retain the accepted ID, so ordinary close can clean up.
      native.closeGate = null;
      await close(tester);
      expect(native.closeAttempts, 2);
      expect(native.active, isFalse);
      expect(controller.manualTerminalActive, isFalse);
      expect(find.byType(TerminalScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
