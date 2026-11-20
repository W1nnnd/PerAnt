// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant/src/presentation/computer_browser_screen.dart';
import 'package:perant/src/presentation/theme.dart';
import 'package:perant_platform/perant_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const browser = MethodChannel('dev.perant/browser');
  const runtime = MethodChannel('dev.perant/runtime');
  const savedPath = '/workspace/web-12345678-1234-1234-1234-123456789abc.md';
  var saves = 0;
  late Map<String, Object?> native;
  setUp(() {
    saves = 0;
    native = {
      'id': 'test',
      'url': 'https://example.com/article',
      'title': '测试网页',
      'loading': false,
      'canGoBack': false,
      'canGoForward': false,
      'width': 640,
      'height': 480,
      'visible': false,
      'attached': false,
      'provider': 'test fixture',
      'revision': 1,
    };
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(browser, (call) async {
      final args = Map<String, Object?>.from(call.arguments as Map);
      switch (call.method) {
        case 'open':
          native = {...native, 'id': args['id']};
          return native;
        case 'state':
        case 'visible':
          return native;
        case 'readPage':
          return {
            'id': native['id'],
            'url': native['url'],
            'title': native['title'],
            'revision': native['revision'],
            'text': '正文资料',
            'truncated': true,
          };
        case 'cancel':
        case 'close':
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });
    messenger.setMockMethodCallHandler(runtime, (call) async {
      if (call.method == 'stopLinuxDesktop') return null;
      if (call.method != 'importLinuxTextFile')
        throw MissingPluginException(call.method);
      saves++;
      final content = (call.arguments as Map)['content'] as String;
      return {
        'path': savedPath,
        'sha256': List.filled(64, 'a').join(),
        'sizeBytes': utf8.encode(content).length,
      };
    });
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(browser, null);
    messenger.setMockMethodCallHandler(runtime, null);
  });
  testWidgets(
    'return to desktop hands back the exact published file without saving twice',
    (tester) async {
      final controller = WorkspaceController(
        persistence: MemoryWorkspacePersistence(),
        credentials: MemoryCredentialStore(),
      );
      LinuxFileImport? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: perantTheme(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<LinuxFileImport>(
                  MaterialPageRoute(
                    builder: (_) => ComputerBrowserScreen(
                      controller: controller,
                      returnToDesktop: true,
                    ),
                  ),
                );
              },
              child: const Text('打开测试浏览器'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开测试浏览器'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('保存网页文字'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('返回桌面并定位'));
      await tester.pumpAndSettle();
      expect(result?.path, savedPath);
      expect(controller.browser.lastSavedFile, same(result));
      expect(saves, 1);
      controller.dispose();
    },
  );
  for (final width in [320.0, 390.0, 1024.0]) {
    testWidgets('save page receipt and truncation notice fit width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final controller = WorkspaceController(
        persistence: MemoryWorkspacePersistence(),
        credentials: MemoryCredentialStore(),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: perantTheme(),
          home: ComputerBrowserScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('保存网页文字'));
      await tester.pumpAndSettle();
      expect(saves, 1);
      expect(find.text('已保存网页文字'), findsOneWidget);
      expect(find.text(savedPath), findsOneWidget);
      expect(find.text('正文已截断，请回到网页核对剩余内容。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.text('已保存到工作区 · 查看文件路径'), findsOneWidget);
      controller.browser.takeModelControl();
      await tester.pump();
      final button = tester.widget<IconButton>(
        find.byKey(const ValueKey('computer-browser-save-page')),
      );
      expect(button.onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.pump();
    });
  }
  testWidgets('entering the address bar selects the current address', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final controller = WorkspaceController(
      persistence: MemoryWorkspacePersistence(),
      credentials: MemoryCredentialStore(),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: perantTheme(),
        home: ComputerBrowserScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('computer-browser-address'));
    final address = tester.widget<TextField>(field).controller!;
    expect(address.text, isNotEmpty);
    await tester.tap(field);
    await tester.pumpAndSettle();
    expect(address.selection.start, 0);
    expect(address.selection.end, address.text.length);
    // A second tap while editing places the caret instead of reselecting.
    await tester.tapAt(tester.getTopLeft(field) + const Offset(14, 14));
    await tester.pumpAndSettle();
    expect(address.selection.isCollapsed, isTrue);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.pump();
  });
}
