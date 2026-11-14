// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant/src/presentation/container_screen.dart';
import 'package:perant/src/presentation/theme.dart';
import 'package:perant_platform/perant_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.perant/container-ui-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late String content;
  late String hash;
  late List<MethodCall> calls;

  Map<String, Object?> file() => {
    'path': '/workspace/notes.md',
    'content': content,
    'sha256': hash,
    'sizeBytes': utf8.encode(content).length,
  };

  setUp(() {
    content = '# Original';
    hash = 'a' * 64;
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final args = call.arguments is Map ? call.arguments! as Map : const {};
      switch (call.method) {
        case 'getCapabilities':
          final available = {'available': true, 'reason': 'fixture'};
          return {
            'schemaVersion': 1,
            'platform': 'android',
            'systemVersion': 'fixture',
            'nativeBridgeAvailable': true,
            'linux': available,
            'localInference': {'available': false, 'reason': 'fixture'},
            'backgroundTasks': {'available': false, 'reason': 'fixture'},
          };
        case 'getLinuxStatus':
          return {
            'supported': true,
            'installed': true,
            'active': false,
            'distribution': 'Alpine',
            'version': 'fixture',
            'workspace': '/workspace',
            'reason': 'fixture',
            'pythonAvailable': true,
            'pythonVersion': '3.14.10',
          };
        case 'listLinuxDirectory':
          return {
            'path': '/workspace',
            'truncated': false,
            'entries': [
              {
                'name': 'notes.md',
                'path': '/workspace/notes.md',
                'isDirectory': false,
                'sizeBytes': utf8.encode(content).length,
                'modifiedAtEpochMs': 1,
              },
            ],
          };
        case 'readLinuxFile':
          return file();
        case 'writeLinuxFile':
          if (args['expectedSha256'] != hash) {
            throw PlatformException(
              code: 'file_conflict',
              message: '文件已被修改，请重新读取后合并更改。',
            );
          }
          content = args['content']! as String;
          hash = 'c' * 64;
          return file();
        case 'createLinuxDirectory':
          return null;
      }
      throw PlatformException(code: 'unexpected', message: call.method);
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<WorkspaceController> launch(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = WorkspaceController(
      persistence: MemoryWorkspacePersistence(),
      credentials: MemoryCredentialStore(),
      bridge: PerantPlatformBridge(methodChannel: channel),
    );
    await controller.initialize();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: perantTheme(),
        home: ContainerScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  for (final width in [320.0, 390.0, 800.0]) {
    testWidgets('container file workspace fits Android width $width', (
      tester,
    ) async {
      await launch(tester, width);
      expect(find.text('notes.md'), findsOneWidget);
      expect(find.text('与模型共用 /workspace'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('操作记录'));
      await tester.pumpAndSettle();
      expect(find.textContaining('模型的文件操作和命令会记录在这里'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'user save uses the original file digest and preserves changes on conflict',
    (tester) async {
      final controller = await launch(tester, 390);
      await tester.tap(find.text('notes.md'));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('container-file-content'));
      await tester.enterText(field, '# My unsaved work');
      await tester.pump();
      // A model changed the file after it was opened; never overwrite silently.
      content = '# Updated by model';
      hash = 'b' * 64;
      await tester.tap(find.byTooltip('保存到 Linux'));
      await tester.pumpAndSettle();
      expect(content, '# Updated by model');
      expect(find.textContaining('当前编辑内容已保留'), findsOneWidget);
      expect(
        tester.widget<TextField>(field).controller!.text,
        '# My unsaved work',
      );
      expect(controller.manualTerminalActive, isFalse);
      final write = calls.lastWhere((call) => call.method == 'writeLinuxFile');
      expect((write.arguments as Map)['expectedSha256'], 'a' * 64);
      await tester.tap(find.text('读取最新版本').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '读取最新版本'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field).controller!.text,
        '# Updated by model',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('editing and Markdown preview use the same actual file content', (
    tester,
  ) async {
    await launch(tester, 390);
    await tester.tap(find.text('notes.md'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('container-file-content')),
      '# Shared edit\n\nHello',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('保存到 Linux'));
    await tester.pumpAndSettle();
    expect(content, '# Shared edit\n\nHello');
    await tester.tap(find.byTooltip('预览文件'));
    await tester.pumpAndSettle();
    expect(find.text('Shared edit'), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
