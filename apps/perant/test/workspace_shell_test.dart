// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant/src/perant_app.dart';
import 'package:perant/src/presentation/desktop_screen.dart';
import 'package:perant_core/perant_core.dart';
import 'package:perant_gateway/perant_gateway.dart';

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
    OpenAiGateway? gateway,
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
      gateway: gateway,
    );
    await controller.initialize();
    addTearDown(controller.dispose);
    await tester.pumpWidget(PerantApp(controller: controller));
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> openMenuItem(WidgetTester tester, String title) async {
    await tester.tap(find.byTooltip('菜单'));
    await tester.pumpAndSettle();
    final item = find.text(title);
    await tester.ensureVisible(item);
    await tester.tap(item);
    await tester.pumpAndSettle();
  }

  for (final width in [320.0, 360.0, 390.0, 430.0, 1024.0, 1440.0]) {
    testWidgets('single-column three-navigation workbench fits width $width', (
      tester,
    ) async {
      await launch(tester, Size(width, 900));
      expect(find.text('嗨，我是小蚁。'), findsOneWidget);
      expect(find.byTooltip('发送消息'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('文件'));
      await tester.pumpAndSettle();
      expect(find.text('还没有资料'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('电脑'));
      await tester.pumpAndSettle();
      expect(find.text('我们的工作区'), findsOneWidget);
      expect(find.text('点击查看 Linux 桌面'), findsOneWidget);
      expect(
        runtimeCalls.where((method) => method.contains('Desktop')),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await openMenuItem(tester, '任务与操作记录');
      expect(find.text('还没有任务记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await openMenuItem(tester, '模型与偏好设置');
      expect(find.text('连接你的模型'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('对话'));
      await tester.pumpAndSettle();
      expect(find.text('嗨，我是小蚁。'), findsOneWidget);
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
    expect(find.byKey(const ValueKey('nav-0')), findsNothing);
    expect(find.byKey(const ValueKey('nav-1')), findsNothing);
    expect(find.byKey(const ValueKey('nav-2')), findsNothing);
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byKey(const ValueKey('chat-composer'))).bottom,
      lessThanOrEqualTo(844 - 300),
    );
  });

  testWidgets(
    'dismissing the IME restores navigation without discarding a focused draft',
    (tester) async {
      await launch(tester, const Size(390, 844));
      await tester.enterText(
        find.byKey(const ValueKey('chat-composer')),
        '保留这段草稿',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(find.byTooltip('文件'), findsNothing);
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      expect(find.byTooltip('对话'), findsOneWidget);
      expect(find.byTooltip('电脑'), findsOneWidget);
      expect(find.byTooltip('文件'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('chat-composer')))
            .controller!
            .text,
        '保留这段草稿',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'short landscape keyboard keeps the composer reachable inside SafeArea',
    (tester) async {
      tester.view.padding = const FakeViewPadding(top: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 24);
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await launch(tester, const Size(844, 390));
      await tester.enterText(
        find.byKey(const ValueKey('chat-composer')),
        '横屏输入仍然可用',
      );
      await tester.pumpAndSettle();
      final send = find.byTooltip('发送消息');
      expect(send.hitTestable(), findsOneWidget);
      expect(tester.getRect(send).top, greaterThanOrEqualTo(24));
      expect(tester.getRect(send).bottom, lessThanOrEqualTo(390 - 240));
      expect(find.byKey(const ValueKey('nav-0')), findsNothing);
      expect(find.byKey(const ValueKey('nav-1')), findsNothing);
      expect(find.byKey(const ValueKey('nav-2')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'computer navigation shows status without starting or observing a desktop',
    (tester) async {
      final controller = await launch(tester, const Size(320, 700));
      expect(find.byTooltip('电脑'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('nav-1'))).shortestSide,
        greaterThanOrEqualTo(48),
      );
      final before = List<String>.of(runtimeCalls);
      await tester.tap(find.byTooltip('电脑'));
      await tester.pumpAndSettle();
      expect(find.text('我们的工作区'), findsOneWidget);
      expect(find.byType(DesktopScreen), findsNothing);
      expect(controller.desktop.running, isFalse);
      expect(controller.desktop.viewerConnected, isFalse);
      expect(controller.desktop.frame, isNull);
      await tester.pump(const Duration(seconds: 30));
      expect(runtimeCalls, before);
      await tester.tap(find.byTooltip('文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('对话'));
      await tester.pumpAndSettle();
      expect(
        runtimeCalls.where((method) => method.contains('Desktop')),
        isEmpty,
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('nav-1')), findsNothing);
      expect(find.byTooltip('发送消息'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final entry in ['chat shortcut', 'computer workspace']) {
    testWidgets(
      'explicit desktop view from $entry safely notifies the listening shell',
      (tester) async {
        final controller = await launch(tester, const Size(390, 844));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        // Keep the real listening shell mounted beneath the pushed route.
        // A standalone DesktopScreen fixture cannot reproduce this assertion.
        if (entry == 'chat shortcut') {
          await tester.tap(find.byTooltip('快捷指令'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('查看电脑'));
          await tester.tap(find.text('查看电脑'));
        } else {
          await tester.tap(find.byTooltip('电脑'));
          await tester.pumpAndSettle();
          expect(runtimeCalls, isNot(contains('getLinuxStatus')));
          await tester.tap(
            find.byKey(const ValueKey('computer-workspace-view-desktop')),
          );
        }
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
        expect(
          find.text(entry == 'chat shortcut' ? '嗨，我是小蚁。' : '我们的工作区'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'menu sheet creates a new chat and preserves its previous conversation',
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
      await tester.tap(find.byTooltip('菜单'));
      await tester.pumpAndSettle();
      expect(find.text('需求讨论'), findsOneWidget);
      await tester.tap(find.text('开始新对话'));
      await tester.pumpAndSettle();
      expect(controller.conversations, hasLength(2));
      expect(controller.activeConversation.id, isNot('main'));
      expect(controller.messages, isEmpty);
      expect(controller.state.messages, hasLength(1));
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('嗨，我是小蚁。'), findsOneWidget);
      await tester.tap(find.byTooltip('菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('需求讨论'));
      await tester.pumpAndSettle();
      expect(controller.activeConversation.id, 'main');
      expect(find.text('这段旧会话需要保留。'), findsOneWidget);
      expect(controller.conversations, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'back closes the sheet before leaving a page or closing shortcuts',
    (tester) async {
      await launch(tester, const Size(390, 844));
      await tester.tap(find.byTooltip('电脑'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('菜单'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('我们的工作区'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('嗨，我是小蚁。'), findsOneWidget);
      await tester.tap(find.byTooltip('快捷指令'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('关闭快捷指令'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byTooltip('关闭快捷指令'), findsNothing);
      expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
      expect(
        runtimeCalls.where((method) => method.contains('Desktop')),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a saved companion name updates the greeting and survives reopening',
    (tester) async {
      final controller = await launch(tester, const Size(390, 844));
      await openMenuItem(tester, '认识小蚁');
      final nameField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == '怎么称呼小蚁',
      );
      await tester.ensureVisible(nameField);
      await tester.enterText(nameField, '阿蚁');
      await tester.tap(find.text('就这样认识你'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350));
      expect(controller.state.companionName, '阿蚁');
      expect(find.text('嗨，我是阿蚁。'), findsOneWidget);
      final snapshot = await controller.persistence.load();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final reopened = await launch(
        tester,
        const Size(390, 844),
        initialState: snapshot,
      );
      expect(reopened.state.companionName, '阿蚁');
      expect(find.text('嗨，我是阿蚁。'), findsOneWidget);
      await openMenuItem(tester, '认识小蚁');
      expect(tester.widget<TextField>(nameField).controller!.text, '阿蚁');
      await tester.tap(find.byTooltip('关闭弹层'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'persona save recovers automatically when an in-flight reply completes',
    (tester) async {
      final reply = Completer<http.Response>();
      var requests = 0;
      final response = http.Response(
        'data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"完成了。"}}]}\n\n'
        'data: [DONE]\n\n',
        200,
        headers: {'content-type': 'text/event-stream; charset=utf-8'},
      );
      addTearDown(() {
        if (!reply.isCompleted) reply.complete(response);
      });
      final controller = await launch(
        tester,
        const Size(390, 844),
        gateway: OpenAiGateway(
          client: MockClient((_) {
            requests++;
            return reply.future;
          }),
        ),
      );
      await controller.configure(
        ProviderProfile(
          id: 'persona-busy-fixture',
          displayName: '离线测试服务',
          baseUrl: Uri.parse('https://example.invalid/v1'),
          protocol: ApiProtocol.chatCompletions,
          modelId: 'fixture-model',
          storageKeyRef: 'credential:persona-busy-fixture',
        ),
        'test-only-not-a-real-api-key',
      );
      final sending = controller.send('等待这条模拟回复', cloudApproved: true);
      await tester.pumpAndSettle();
      expect(controller.isSending, isTrue);
      expect(requests, 1);
      await openMenuItem(tester, '认识小蚁');
      final save = find.widgetWithText(FilledButton, '就这样认识你');
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == '怎么称呼小蚁',
        ),
        '忙后小蚁',
      );
      await tester.pump();
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      reply.complete(response);
      for (var attempt = 0; attempt < 100 && controller.isSending; attempt++) {
        // MockClient's stream completion can cross the fake clock boundary.
        // Keep pumping the modal's real controller notifications while it ends.
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(controller.isSending, isFalse);
      await sending;
      await tester.pumpAndSettle();
      expect(controller.messages.last.text, '完成了。');
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      await tester.tap(save);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350));
      expect(controller.state.companionName, '忙后小蚁');
      expect(find.byType(BottomSheet), findsNothing);
      expect(requests, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('create, edit, confirm and preview an actual document', (
    tester,
  ) async {
    final controller = await launch(tester, const Size(390, 900));
    await tester.tap(find.byTooltip('文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建'));
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
    final confirmedSnapshot = await controller.persistence.load();
    expect(confirmedSnapshot.documents.single.isConfirmed, isTrue);
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
    final editedSnapshot = await controller.persistence.load();
    final reopenedDocument = editedSnapshot.documents.single;
    expect(reopenedDocument.isConfirmed, isFalse);
    expect(reopenedDocument.revision, controller.documents.single.revision);
    expect(reopenedDocument.markdown, '# 工作记录\n\n已更新的会议内容。');
    await tester.tap(find.byTooltip('版本历史与差异'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('版本 $confirmedRevision'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('将此版本载入草稿'));
    await tester.pumpAndSettle();
    expect(find.text('有未保存修改 · 确认将失效'), findsOneWidget);
    expect(controller.documents.single.markdown, reopenedDocument.markdown);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '导出 PDF'))
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
}
