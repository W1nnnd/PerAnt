// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant/src/perant_app.dart';
import 'package:perant/src/presentation/workspace_shell.dart';
import 'package:perant_core/perant_core.dart';
import 'package:perant_gateway/perant_gateway.dart';
import 'package:perant_platform/perant_platform.dart';

const _authorizationTitle = '允许本次任务使用云端模型？';
const _rememberLabel = '这次对话里的聊天，不用每次问我';
const _revokeLabel = '本次对话的聊天已授权 · 撤销';
const _containerPrompt = '请在电脑的 /workspace 中创建 hello.py，输出一条问候，再运行并检查结果。';

ProviderProfile _profile() => ProviderProfile(
  id: 'concept6-authorization-fixture',
  displayName: '离线授权测试服务',
  baseUrl: Uri.parse('https://example.invalid/v1'),
  protocol: ApiProtocol.chatCompletions,
  modelId: 'offline-test-model',
  storageKeyRef: 'credential:concept6-authorization-fixture',
);

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var index = 0; index < 100 && !condition(); index++) {
    // Yield the HTTP package's response-stream zone without real networking.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(
    condition(),
    isTrue,
    reason: 'Expected authorization state not reached.',
  );
}

final class _Fixture {
  _Fixture({
    required this.controller,
    required this.persistence,
    required this.requests,
    required this.nativeCalls,
  });

  final WorkspaceController controller;
  final MemoryWorkspacePersistence persistence;
  final List<Map<String, Object?>> requests;
  final List<String> nativeCalls;

  Future<void> expectStoredChatTasks(int count) async {
    final restored = await persistence.load();
    expect(restored.tasks, hasLength(count));
    expect(restored.tasks.map((task) => task.id).toSet(), hasLength(count));
    expect(
      restored.tasks.map((task) => task.id).toSet(),
      controller.tasks.map((task) => task.id).toSet(),
    );
    for (final task in controller.tasks) {
      expect(task.status, TaskStatus.completed);
      final grant = task.cloudAuthorization!;
      expect(grant.taskId, task.id);
      expect(grant.providerProfileId, controller.profile!.id);
      expect(grant.providerEndpoint, controller.profile!.apiEndpoint);
      expect(grant.modelId, controller.profile!.modelId);
      expect(grant.currentSources, isNotEmpty);
      expect(grant.isRevoked, isTrue);
    }
    // Runtime grants do not survive snapshot reload. The task log survives,
    // but reopening it must never grant new cloud access.
    expect(
      restored.tasks.every((task) => task.cloudAuthorization == null),
      isTrue,
    );
    expect(restored.containerActions, isEmpty);
    expect(
      restored.messages.every(
        (message) => message.source == ChatEntrySource.cloud,
      ),
      isTrue,
    );
    expect(requests.every((request) => !request.containsKey('tools')), isTrue);
  }
}

Future<_Fixture> _launch(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);

  const channel = MethodChannel('dev.perant/test-concept6-authorization');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final nativeCalls = <String>[];
  messenger.setMockMethodCallHandler(channel, (call) async {
    nativeCalls.add(call.method);
    if (call.method == 'getCapabilities') {
      return {
        'schemaVersion': 1,
        'platform': 'android',
        'systemVersion': 'Offline authorization UI fixture',
        'nativeBridgeAvailable': true,
        'linux': {'available': true, 'reason': 'Fixture only'},
        'localInference': {'available': false, 'reason': 'No model'},
        'backgroundTasks': {'available': false, 'reason': 'No service'},
      };
    }
    if (call.method == 'getLinuxStatus') {
      return {
        'supported': true,
        'installed': true,
        'active': false,
        'sessionId': null,
        'distribution': 'Alpine',
        'version': 'fixture',
        'workspace': '/workspace',
        'reason': 'No native commands are permitted by this fixture',
      };
    }
    throw StateError('Unexpected native operation: ${call.method}');
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

  final requests = <Map<String, Object?>>[];
  final client = MockClient((request) async {
    expect(request.url.host, 'example.invalid');
    expect(request.url.path, '/v1/chat/completions');
    requests.add(jsonDecode(request.body) as Map<String, Object?>);
    final payload = {
      'choices': [
        {
          'index': 0,
          'delta': {
            'role': 'assistant',
            'content': '离线模拟回复 ${requests.length}',
          },
          'finish_reason': 'stop',
        },
      ],
    };
    return http.Response(
      'data: ${jsonEncode(payload)}\n\ndata: [DONE]\n\n',
      200,
      headers: {'content-type': 'text/event-stream; charset=utf-8'},
    );
  });
  final persistence = MemoryWorkspacePersistence();
  final controller = WorkspaceController(
    persistence: persistence,
    credentials: MemoryCredentialStore(),
    gateway: OpenAiGateway(client: client),
    bridge: PerantPlatformBridge(methodChannel: channel),
  );
  addTearDown(controller.dispose);
  await controller.initialize();
  await controller.configure(_profile(), 'test-only-not-a-real-api-key');
  await tester.pumpWidget(PerantApp(controller: controller));
  await tester.pumpAndSettle();
  expect(find.byType(WorkspaceShell), findsOneWidget);
  return _Fixture(
    controller: controller,
    persistence: persistence,
    requests: requests,
    nativeCalls: nativeCalls,
  );
}

Finder get _composer => find.byKey(const ValueKey('chat-composer'));

String _composerText(WidgetTester tester) =>
    tester.widget<TextField>(_composer).controller!.text;

Future<void> _composeAndSend(WidgetTester tester, String text) async {
  await tester.enterText(_composer, text);
  await tester.pump();
  await tester.tap(find.byTooltip('发送消息'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _approve(
  WidgetTester tester,
  _Fixture fixture, {
  bool remember = false,
}) async {
  expect(find.text(_authorizationTitle), findsOneWidget);
  if (remember) {
    await tester.ensureVisible(find.text(_rememberLabel));
    await tester.tap(find.text(_rememberLabel));
    await tester.pump();
    final checkbox = find.ancestor(
      of: find.text(_rememberLabel),
      matching: find.byType(CheckboxListTile),
    );
    expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
  }
  final expectedCount = fixture.requests.length + 1;
  await tester.tap(find.text('授权并发送'));
  await _pumpUntil(
    tester,
    () =>
        fixture.requests.length == expectedCount &&
        !fixture.controller.isSending,
  );
  await tester.pumpAndSettle();
  expect(find.text(_authorizationTitle), findsNothing);
  expect(_composerText(tester), isEmpty);
  expect(tester.takeException(), isNull);
}

Future<void> _rememberFirstChat(WidgetTester tester, _Fixture fixture) async {
  await _composeAndSend(tester, '先聊一件简单的小事');
  expect(fixture.requests, isEmpty);
  await _approve(tester, fixture, remember: true);
  expect(find.text(_revokeLabel), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cancel cloud authorization retains input and sends no HTTP', (
    tester,
  ) async {
    final fixture = await _launch(tester);
    const text = '先保留这段内容，我还没有决定发送';
    await _composeAndSend(tester, text);
    expect(find.text(_authorizationTitle), findsOneWidget);
    expect(fixture.requests, isEmpty);
    await tester.tap(find.text('改一改再发'));
    await tester.pumpAndSettle();
    expect(find.text(_authorizationTitle), findsNothing);
    expect(_composerText(tester), text);
    expect(fixture.requests, isEmpty);
    expect(fixture.controller.tasks, isEmpty);
    final stored = await fixture.persistence.load();
    expect(stored.tasks, isEmpty);
    expect(stored.messages, isEmpty);
    expect(fixture.nativeCalls, ['getCapabilities']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'remembered ordinary chat reuses only this profile and conversation',
    (tester) async {
      final fixture = await _launch(tester);
      final profile = fixture.controller.profile;
      final conversationId = fixture.controller.activeConversation.id;
      await _rememberFirstChat(tester, fixture);
      await _composeAndSend(tester, '继续刚才的话题');
      await _pumpUntil(
        tester,
        () => fixture.requests.length == 2 && !fixture.controller.isSending,
      );
      await tester.pumpAndSettle();
      expect(find.text(_authorizationTitle), findsNothing);
      expect(find.text(_revokeLabel), findsOneWidget);
      expect(identical(fixture.controller.profile, profile), isTrue);
      expect(fixture.controller.activeConversation.id, conversationId);
      expect(fixture.controller.messages, hasLength(4));
      final secondMessages = fixture.requests.last['messages']! as List;
      expect(
        secondMessages.whereType<Map>().map((message) => message['content']),
        containsAll(['先聊一件简单的小事', '离线模拟回复 1', '继续刚才的话题']),
      );
      await fixture.expectStoredChatTasks(2);
      expect(fixture.nativeCalls, ['getCapabilities']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'revoking remembered chat requires a new grant before more HTTP',
    (tester) async {
      final fixture = await _launch(tester);
      await _rememberFirstChat(tester, fixture);
      await tester.tap(find.text(_revokeLabel));
      await tester.pumpAndSettle();
      expect(find.text(_revokeLabel), findsNothing);
      await _composeAndSend(tester, '撤销之后的新消息');
      expect(find.text(_authorizationTitle), findsOneWidget);
      expect(fixture.requests, hasLength(1));
      expect(_composerText(tester), '撤销之后的新消息');
      await _approve(tester, fixture);
      expect(fixture.requests, hasLength(2));
      await fixture.expectStoredChatTasks(2);
      expect(find.text(_revokeLabel), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a new conversation cannot reuse the previous chat grant', (
    tester,
  ) async {
    final fixture = await _launch(tester);
    await _rememberFirstChat(tester, fixture);
    final oldConversation = fixture.controller.activeConversation.id;
    await tester.tap(find.byTooltip('菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始新对话'));
    await tester.pumpAndSettle();
    expect(fixture.controller.activeConversation.id, isNot(oldConversation));
    expect(fixture.controller.profile, isNotNull);
    expect(find.text(_revokeLabel), findsNothing);
    await _composeAndSend(tester, '新对话中的未授权消息');
    expect(find.text(_authorizationTitle), findsOneWidget);
    expect(fixture.requests, hasLength(1));
    expect(fixture.controller.messages, isEmpty);
    expect(fixture.controller.state.messages, hasLength(2));
    await tester.tap(find.text('改一改再发'));
    await tester.pumpAndSettle();
    expect(_composerText(tester), '新对话中的未授权消息');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reconfiguration with equal values but a new profile revokes reuse',
    (tester) async {
      final fixture = await _launch(tester);
      await _rememberFirstChat(tester, fixture);
      final previous = fixture.controller.profile!;
      final replacement = _profile();
      expect(replacement.toJson(), previous.toJson());
      expect(identical(replacement, previous), isFalse);
      await fixture.controller.configure(replacement, '');
      await tester.pumpAndSettle();
      expect(identical(fixture.controller.profile, replacement), isTrue);
      expect(find.text(_revokeLabel), findsNothing);
      await _composeAndSend(tester, '重新配置后需要确认');
      expect(find.text(_authorizationTitle), findsOneWidget);
      expect(fixture.requests, hasLength(1));
      expect(_composerText(tester), '重新配置后需要确认');
      await tester.tap(find.text('改一改再发'));
      await tester.pumpAndSettle();
      expect(fixture.controller.tasks, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('remembered chat cannot authorize a container task implicitly', (
    tester,
  ) async {
    final fixture = await _launch(tester);
    await _rememberFirstChat(tester, fixture);
    final profile = fixture.controller.profile;
    final conversationId = fixture.controller.activeConversation.id;
    // Clearing messages exposes the real task starter without changing the
    // profile or conversation that currently holds the remembered chat grant.
    await fixture.controller.clearConversation();
    await tester.pumpAndSettle();
    expect(fixture.controller.activeConversation.id, conversationId);
    expect(identical(fixture.controller.profile, profile), isTrue);
    expect(find.text(_revokeLabel), findsOneWidget);
    await tester.tap(find.text('一起做事'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('一起写个小脚本'));
    await tester.tap(find.text('一起写个小脚本'));
    await tester.pumpAndSettle();
    expect(find.text(_authorizationTitle), findsOneWidget);
    expect(find.text(_rememberLabel), findsNothing);
    final permission = find.ancestor(
      of: find.text('允许模型操作容器电脑'),
      matching: find.byType(CheckboxListTile),
    );
    expect(tester.widget<CheckboxListTile>(permission).value, isTrue);
    expect(find.textContaining('桌面及网页截图、文件内容、工具输出'), findsOneWidget);
    expect(fixture.requests, hasLength(1));
    expect(fixture.nativeCalls, ['getCapabilities']);
    expect(fixture.controller.containerActions, isEmpty);
    expect(fixture.controller.desktop.modelHasControl, isFalse);
    expect(fixture.controller.browser.modelHasControl, isFalse);
    await tester.tap(find.text('改一改再发'));
    await tester.pumpAndSettle();
    expect(_composerText(tester), _containerPrompt);
    expect(fixture.requests, hasLength(1));
    expect(fixture.nativeCalls, ['getCapabilities']);

    // Explicitly select the task starter again. Cancelling its previous grant
    // must not leave computer mode attached to the retained editable text.
    await tester.ensureVisible(find.text('一起写个小脚本'));
    await tester.tap(find.text('一起写个小脚本'));
    await tester.pumpAndSettle();
    expect(find.text(_authorizationTitle), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(permission).value, isTrue);
    expect(fixture.requests, hasLength(1));
    await _approve(tester, fixture);
    expect(fixture.requests, hasLength(2));
    expect(fixture.requests.last['tools'], isA<List>());
    expect(fixture.nativeCalls, ['getCapabilities', 'getLinuxStatus']);
    expect(fixture.controller.tasks.first.title, startsWith('容器协作：'));
    final stored = await fixture.persistence.load();
    expect(stored.tasks, hasLength(2));
    final containerGrant = fixture.controller.tasks.first.cloudAuthorization!;
    expect(containerGrant.taskId, fixture.controller.tasks.first.id);
    expect(containerGrant.isRevoked, isTrue);
    expect(
      stored.tasks.every((task) => task.cloudAuthorization == null),
      isTrue,
    );
    expect(
      stored.messages.every(
        (entry) => entry.source == ChatEntrySource.container,
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cancelled container starter does not grant tools to edited chat',
    (tester) async {
      final fixture = await _launch(tester);
      await _rememberFirstChat(tester, fixture);
      final profile = fixture.controller.profile;
      final conversationId = fixture.controller.activeConversation.id;
      await fixture.controller.clearConversation();
      await tester.pumpAndSettle();
      expect(find.text(_revokeLabel), findsOneWidget);
      await tester.tap(find.text('一起做事'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('一起写个小脚本'));
      await tester.tap(find.text('一起写个小脚本'));
      await tester.pumpAndSettle();
      expect(find.text(_authorizationTitle), findsOneWidget);
      final permission = find.ancestor(
        of: find.text('允许模型操作容器电脑'),
        matching: find.byType(CheckboxListTile),
      );
      expect(tester.widget<CheckboxListTile>(permission).value, isTrue);
      expect(fixture.requests, hasLength(1));
      expect(fixture.nativeCalls, ['getCapabilities']);
      await tester.tap(find.text('改一改再发'));
      await tester.pumpAndSettle();
      expect(_composerText(tester), _containerPrompt);

      const text = '先不用电脑了，陪我聊聊今天的心情';
      await _composeAndSend(tester, text);
      await _pumpUntil(
        tester,
        () => fixture.requests.length == 2 && !fixture.controller.isSending,
      );
      await tester.pumpAndSettle();
      expect(find.text(_authorizationTitle), findsNothing);
      expect(find.text(_revokeLabel), findsOneWidget);
      expect(identical(fixture.controller.profile, profile), isTrue);
      expect(fixture.controller.activeConversation.id, conversationId);
      expect(fixture.nativeCalls, ['getCapabilities']);
      expect(fixture.controller.containerActions, isEmpty);
      expect(fixture.controller.desktop.modelHasControl, isFalse);
      expect(fixture.controller.browser.modelHasControl, isFalse);
      expect(fixture.requests.last.containsKey('tools'), isFalse);
      final messages = fixture.requests.last['messages']! as List;
      final userTexts = messages
          .whereType<Map>()
          .where((message) => message['role'] == 'user')
          .map((message) => message['content']);
      expect(userTexts, [text]);
      expect(
        jsonEncode(fixture.requests.last),
        isNot(contains(_containerPrompt)),
      );
      await fixture.expectStoredChatTasks(2);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'the computer button requests the computer for typed text, even while chat is remembered',
    (tester) async {
      final fixture = await _launch(tester);
      final button = find.byKey(const ValueKey('composer-use-computer'));
      expect(tester.widget<IconButton>(button).onPressed, isNull);
      await _rememberFirstChat(tester, fixture);
      expect(fixture.requests, hasLength(1));
      const text = '帮我在电脑里建一个文件';
      await tester.enterText(_composer, text);
      await tester.pump();
      expect(tester.widget<IconButton>(button).onPressed, isNotNull);
      await tester.tap(find.byTooltip('用电脑做这件事'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text(_authorizationTitle), findsOneWidget);
      final permission = find.ancestor(
        of: find.text('允许模型操作容器电脑'),
        matching: find.byType(CheckboxListTile),
      );
      expect(tester.widget<CheckboxListTile>(permission).value, isTrue);
      expect(find.text(_rememberLabel), findsNothing);
      expect(fixture.requests, hasLength(1));
      expect(fixture.controller.containerActions, isEmpty);

      // Declining keeps the text and leaves no computer grant behind.
      await tester.tap(find.text('改一改再发'));
      await tester.pumpAndSettle();
      expect(_composerText(tester), text);
      await tester.tap(find.byTooltip('发送消息'));
      await _pumpUntil(
        tester,
        () => fixture.requests.length == 2 && !fixture.controller.isSending,
      );
      await tester.pumpAndSettle();
      expect(fixture.requests.last.containsKey('tools'), isFalse);
      expect(fixture.controller.containerActions, isEmpty);

      // Accepting sends the same typed text as a computer task.
      await tester.enterText(_composer, text);
      await tester.pump();
      await tester.tap(find.byTooltip('用电脑做这件事'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.widget<CheckboxListTile>(permission).value, isTrue);
      await _approve(tester, fixture);
      expect(fixture.requests, hasLength(3));
      expect(fixture.requests.last['tools'], isA<List>());
      expect(fixture.controller.tasks.first.title, startsWith('容器协作：'));
      expect(tester.takeException(), isNull);
    },
  );
}
