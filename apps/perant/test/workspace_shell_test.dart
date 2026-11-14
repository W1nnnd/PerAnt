// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant/src/perant_app.dart';
import 'package:perant/src/presentation/desktop_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final runtimeCalls = <String>[];
  const capabilities = {
    'schemaVersion': 1,
    'platform': 'test',
    'systemVersion': 'test',
    'nativeBridgeAvailable': true,
    'linux': {'available': false, 'reason': 'Not connected in this test'},
    'localInference': {
      'available': false,
      'reason': 'Not connected in this test',
    },
    'backgroundTasks': {
      'available': false,
      'reason': 'Not connected in this test',
    },
  };
  const unavailableReason = 'Linux is unavailable in the navigation fixture';
  setUp(() {
    runtimeCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dev.perant/runtime'), (
          call,
        ) async {
          runtimeCalls.add(call.method);
          if (call.method == 'getLinuxStatus') {
            return {
              'supported': false,
              'installed': false,
              'active': false,
              'distribution': 'unavailable',
              'version': 'unavailable',
              'workspace': '/workspace',
              'reason': unavailableReason,
            };
          }
          if (call.method == 'stopLinuxDesktop') return null;
          return capabilities;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.perant/runtime/events'),
          (call) async {
            if (call.method == 'listen') {
              scheduleMicrotask(() {
                unawaited(
                  TestDefaultBinaryMessengerBinding
                      .instance
                      .defaultBinaryMessenger
                      .handlePlatformMessage(
                        'dev.perant/runtime/events',
                        const StandardMethodCodec().encodeSuccessEnvelope({
                          'type': 'bridgeAttached',
                          'emittedAtEpochMs': 1,
                          'payload': capabilities,
                        }),
                        (_) {},
                      ),
                );
              });
            }
            return null;
          },
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.perant/runtime'),
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.perant/runtime/events'),
          null,
        );
  });
  Future<WorkspaceController> launch(
    WidgetTester tester,
    Size size, {
    WorkspaceState? initialState,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final persistence = MemoryWorkspacePersistence();
    if (initialState != null) persistence.snapshot = initialState.toJson();
    final controller = WorkspaceController(
      persistence: persistence,
      credentials: MemoryCredentialStore(),
    );
    await controller.initialize();
    addTearDown(controller.dispose);
    await tester.pumpWidget(PerantApp(controller: controller));
    await tester.pumpAndSettle();
    return controller;
  }

  for (final width in [320.0, 390.0, 1024.0, 1440.0]) {
    testWidgets('conversation-first workbench fits width $width', (
      tester,
    ) async {
      await launch(tester, Size(width, 900));
      expect(find.text('有什么想聊的，\n或者想交给我做的？'), findsOneWidget);
      expect(find.text('从一份材料，\n开始一项任务。'), findsNothing);
      expect(find.byTooltip('发送消息'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('资源库'));
      await tester.pumpAndSettle();
      expect(find.text('还没有资料'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('任务'));
      await tester.pumpAndSettle();
      expect(find.text('还没有任务记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('连接你的模型'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('聊天'));
      await tester.pumpAndSettle();
      expect(find.text('有什么想聊的，\n或者想交给我做的？'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('phone composer stays above the keyboard without navigation', (
    tester,
  ) async {
    await launch(tester, const Size(390, 844));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(find.byTooltip('发送消息'), findsOneWidget);
    expect(find.byTooltip('资源库'), findsNothing);
    expect(find.byTooltip('任务'), findsNothing);
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byType(TextField)).bottom,
      lessThanOrEqualTo(844 - 300),
    );
  });

  testWidgets('chat shows the computer entry without starting a desktop', (
    tester,
  ) async {
    await launch(tester, const Size(320, 700));
    expect(find.text('模型的电脑'), findsOneWidget);
    expect(find.byTooltip('模型的电脑'), findsOneWidget);
    expect(
      tester.getSize(find.byTooltip('模型的电脑')).shortestSide,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(find.byTooltip('资源库'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('聊天'));
    await tester.pumpAndSettle();
    expect(runtimeCalls.where((method) => method.contains('Desktop')), isEmpty);
    // The card yields space to typing on a small phone. Navigation returns
    // when the keyboard closes, without attaching a background framebuffer.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(find.text('模型的电脑'), findsNothing);
    expect(find.byTooltip('发送消息'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final entry in ['chat card', 'bottom navigation']) {
    testWidgets(
      'opening desktop from $entry does not notify the chat card during build',
      (tester) async {
        final controller = await launch(tester, const Size(390, 844));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        // Keep the real listening chat card mounted beneath the pushed route.
        // A standalone DesktopScreen fixture cannot reproduce this assertion.
        expect(find.text('模型的电脑'), findsOneWidget);
        await tester.tap(
          entry == 'chat card' ? find.text('模型的电脑') : find.byTooltip('模型的电脑'),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(DesktopScreen), findsOneWidget);
        expect(runtimeCalls, contains('getLinuxStatus'));
        expect(controller.desktop.busy, isFalse);
        expect(controller.desktop.error, unavailableReason);
        expect(controller.desktop.viewerConnected, isFalse);
        expect(runtimeCalls, isNot(contains('startLinuxDesktop')));
        Navigator.of(tester.element(find.byType(DesktopScreen))).pop();
        await tester.pumpAndSettle();
        expect(find.byType(DesktopScreen), findsNothing);
        expect(find.text('模型的电脑'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'drawer creates a new chat and preserves its previous conversation',
    (tester) async {
      final now = DateTime.utc(2026, 11, 13, 8);
      final controller = await launch(
        tester,
        const Size(390, 900),
        initialState: WorkspaceState(
          onboardingDismissed: true,
          conversations: [
            ConversationThread(id: 'main', title: '需求讨论', createdAt: now),
          ],
          messages: [
            ChatEntry(
              id: 'previous-message',
              role: ChatRole.user,
              text: '这段旧会话需要保留。',
              createdAt: now,
            ),
          ],
        ),
      );
      expect(find.text('这段旧会话需要保留。'), findsOneWidget);
      await tester.tap(find.byTooltip('会话'));
      await tester.pumpAndSettle();
      expect(find.text('需求讨论'), findsOneWidget);
      await tester.tap(find.byTooltip('新聊天'));
      await tester.pumpAndSettle();
      expect(controller.conversations, hasLength(2));
      expect(controller.activeConversation.id, isNot('main'));
      expect(controller.messages, isEmpty);
      expect(controller.state.messages, hasLength(1));
      expect(
        tester.state<ScaffoldState>(find.byType(Scaffold)).isDrawerOpen,
        isFalse,
      );
      expect(find.text('有什么想聊的，\n或者想交给我做的？'), findsOneWidget);
      await tester.tap(find.byTooltip('会话'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('需求讨论'));
      await tester.pumpAndSettle();
      expect(controller.activeConversation.id, 'main');
      expect(find.text('这段旧会话需要保留。'), findsOneWidget);
      expect(controller.conversations, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('create, edit, confirm and preview an actual document', (
    tester,
  ) async {
    final controller = await launch(tester, const Size(390, 900));
    await tester.tap(find.byTooltip('资源库'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建文档'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '工作记录');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      '# 工作记录\n\n- 确认需求\n- [ ] 下一步\n\n| 项目 | 状态 |\n| --- | --- |\n| 框架 | 完成 |',
    );
    await tester.pump();
    await tester.tap(find.text('保存并确认'));
    await tester.pumpAndSettle();
    expect(controller.documents.single.isConfirmed, isTrue);
    final confirmedRevision = controller.documents.single.revision;
    await tester.tap(find.byTooltip('预览 Markdown'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('版本已确认'), findsOneWidget);
    await tester.tap(find.byTooltip('继续编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '# 工作记录\n\n已更新的会议内容。');
    await tester.pump();
    expect(find.text('有未保存修改 · 确认将失效'), findsOneWidget);
    await tester.tap(find.byTooltip('保存文档'));
    await tester.pumpAndSettle();
    expect(controller.documents.single.isConfirmed, isFalse);
    expect(
      controller.documents.single.revision,
      greaterThan(confirmedRevision),
    );
    expect(tester.takeException(), isNull);
  });
}
