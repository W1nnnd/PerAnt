// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant/src/presentation/computer_workspace_page.dart';
import 'package:perant/src/presentation/theme.dart';
import 'package:perant_platform/perant_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const runtimeChannel = MethodChannel('dev.perant/computer-page-test');
  const browserChannel = MethodChannel(ComputerBrowserBridge.methodChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final nativeCalls = <String>[];

  setUp(() {
    nativeCalls.clear();
    for (final channel in [runtimeChannel, browserChannel]) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        nativeCalls.add('${channel.name}:${call.method}');
        throw PlatformException(
          code: 'unexpected_native_call',
          message: call.method,
        );
      });
    }
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(runtimeChannel, null);
    messenger.setMockMethodCallHandler(browserChannel, null);
  });

  WorkspaceController createController() {
    final controller = WorkspaceController(
      persistence: MemoryWorkspacePersistence(),
      credentials: MemoryCredentialStore(),
      bridge: PerantPlatformBridge(methodChannel: runtimeChannel),
    );
    addTearDown(() {
      // These optional sessions are fixture metadata, never native processes.
      controller.desktop.session = null;
      controller.browser.state = null;
      controller.dispose();
    });
    return controller;
  }

  Future<void> showPage(
    WidgetTester tester,
    WorkspaceController controller, {
    double width = 390,
    double height = 760,
    TextScaler textScaler = TextScaler.noScaling,
    VoidCallback? onViewDesktop,
    VoidCallback? onOpenBrowser,
    VoidCallback? onOpenTerminal,
    VoidCallback? onOpenFiles,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: perantTheme(),
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, height),
            textScaler: textScaler,
          ),
          child: Scaffold(
            body: ComputerWorkspacePage(
              controller: controller,
              onViewDesktop: onViewDesktop ?? () {},
              onOpenBrowser: onOpenBrowser ?? () {},
              onOpenTerminal: onOpenTerminal ?? () {},
              onOpenFiles: onOpenFiles ?? () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'opening and revisiting the page never starts or observes a runtime',
    (tester) async {
      final controller = createController();
      for (var visit = 0; visit < 2; visit++) {
        await showPage(tester, controller);
        await tester.pump(const Duration(seconds: 30));
        expect(find.text('等待打开本地电脑'), findsOneWidget);
        expect(find.text('点击查看 Linux 桌面'), findsOneWidget);
        expect(controller.desktop.running, isFalse);
        expect(controller.desktop.viewerConnected, isFalse);
        expect(controller.desktop.frame, isNull);
        expect(controller.desktop.modelHasControl, isFalse);
        expect(controller.browser.running, isFalse);
        expect(controller.browser.modelHasControl, isFalse);
        expect(nativeCalls, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
      expect(nativeCalls, isEmpty);
    },
  );

  for (final width in [320.0, 390.0]) {
    testWidgets('all real entry callbacks stay reachable at width $width', (
      tester,
    ) async {
      final controller = createController();
      final actions = <String>[];
      await showPage(
        tester,
        controller,
        width: width,
        height: 640,
        onViewDesktop: () => actions.add('desktop'),
        onOpenBrowser: () => actions.add('browser'),
        onOpenTerminal: () => actions.add('terminal'),
        onOpenFiles: () => actions.add('files'),
      );
      for (final entry in ['view-desktop', 'browser', 'terminal', 'files']) {
        final target = find.byKey(ValueKey('computer-workspace-$entry'));
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pump();
      }
      expect(actions, ['desktop', 'browser', 'terminal', 'files']);
      expect(nativeCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'desktop and browser ownership are observed without changing control',
    (tester) async {
      final controller = createController();
      await showPage(tester, controller);
      controller.desktop.takeModelControl();
      await tester.pump();
      expect(find.text('模型正在操作'), findsOneWidget);
      expect(controller.desktop.modelHasControl, isTrue);
      controller.desktop.releaseModelControl();
      controller.browser.takeModelControl();
      await tester.pump();
      expect(find.text('模型正在操作'), findsNWidgets(2));
      expect(controller.browser.modelHasControl, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(controller.browser.modelHasControl, isTrue);
      expect(nativeCalls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'terminal conflicts do not block viewing or release the active lease',
    (tester) async {
      final controller = createController();
      final actions = <String>[];
      await showPage(
        tester,
        controller,
        onViewDesktop: () => actions.add('desktop'),
        onOpenBrowser: () => actions.add('browser'),
        onOpenTerminal: () => actions.add('terminal'),
        onOpenFiles: () => actions.add('files'),
      );
      final lease = controller.acquireManualTerminal();
      await tester.pump();
      expect(find.text('终端正在使用'), findsNWidgets(2));
      for (final entry in ['view-desktop', 'browser', 'terminal', 'files']) {
        final target = find.byKey(ValueKey('computer-workspace-$entry'));
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pump();
      }
      expect(actions, ['desktop', 'browser', 'files']);
      expect(controller.manualTerminalActive, isTrue);
      expect(nativeCalls, isEmpty);
      controller.releaseManualTerminal(lease);
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('computer-workspace-terminal')),
      );
      expect(actions.last, 'terminal');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unavailable Linux stays truthful and large text remains scrollable',
    (tester) async {
      final controller = createController();
      controller.capabilities = PlatformCapabilities.unsupported(
        platform: 'ios',
        reason: 'Fixture has no Linux runtime.',
      );
      await showPage(
        tester,
        controller,
        width: 320,
        height: 640,
        textScaler: const TextScaler.linear(1.5),
      );
      expect(find.text('当前平台暂不支持 Linux'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('computer-workspace-files')),
      );
      expect(nativeCalls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
