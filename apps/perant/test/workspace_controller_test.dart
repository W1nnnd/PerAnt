// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant_core/perant_core.dart';
import 'package:perant_gateway/perant_gateway.dart';

const _testKey = 'test-only-not-a-real-api-key';

ProviderProfile _profile({
  ApiProtocol protocol = ApiProtocol.chatCompletions,
}) => ProviderProfile(
  id: 'test-provider',
  displayName: '测试接口',
  baseUrl: Uri.parse('https://example.invalid/v1/'),
  protocol: protocol,
  modelId: 'test-model',
  storageKeyRef: 'credential:test-provider',
);

String _event(Map<String, Object?> value) => 'data: ${jsonEncode(value)}\n\n';

String _chatText(String text) => _event({
  'choices': [
    {
      'index': 0,
      'delta': {'role': 'assistant', 'content': text},
    },
  ],
});

String _completeResponse(ApiProtocol protocol, String text) =>
    switch (protocol) {
      ApiProtocol.chatCompletions => '${_chatText(text)}data: [DONE]\n\n',
      ApiProtocol.responses =>
        '${_event({'type': 'response.output_text.delta', 'delta': text})}'
            '${_event({
              'type': 'response.completed',
              'response': {
                'id': 'response-1',
                'status': 'completed',
                'output': [
                  {
                    'id': 'assistant-1',
                    'type': 'message',
                    'role': 'assistant',
                    'content': [
                      {'type': 'output_text', 'text': text},
                    ],
                  },
                ],
              },
            })}',
    };

http.Response _response(String body) => http.Response(
  body,
  200,
  headers: {'content-type': 'text/event-stream; charset=utf-8'},
);

final class _ControlledPersistence implements WorkspacePersistence {
  _ControlledPersistence([WorkspaceState? initial])
    : snapshot = (initial ?? WorkspaceState()).toJson();

  Map<String, Object?> snapshot;
  bool failSaves = false;
  int failuresRemaining = 0;
  Completer<void>? saveGate;
  Completer<void>? saveEntered;

  @override
  String get description => '测试存储';

  @override
  Future<WorkspaceState> load() async => WorkspaceState.fromJson(
    jsonDecode(jsonEncode(snapshot)) as Map<String, Object?>,
  );

  @override
  Future<void> save(Map<String, Object?> value) async {
    final entered = saveEntered;
    if (entered != null && !entered.isCompleted) entered.complete();
    final gate = saveGate;
    if (gate != null) await gate.future;
    if (failSaves || failuresRemaining > 0) {
      if (failuresRemaining > 0) failuresRemaining--;
      throw StateError('test-storage-failure');
    }
    snapshot = jsonDecode(jsonEncode(value)) as Map<String, Object?>;
  }

  @override
  Future<void> close() async {}
}

final class _ControlledCredentialStore implements CredentialStore {
  final values = <String, String>{};
  int writeFailuresRemaining = 0;
  Completer<void>? writeGate;
  Completer<void>? writeEntered;

  @override
  Future<String?> read(String reference) async => values[reference];

  @override
  Future<void> write(String reference, String value) async {
    final entered = writeEntered;
    if (entered != null && !entered.isCompleted) entered.complete();
    final gate = writeGate;
    if (gate != null) await gate.future;
    values[reference] = value;
    if (writeFailuresRemaining > 0) {
      writeFailuresRemaining--;
      throw StateError('test-credential-write-failure');
    }
  }

  @override
  Future<void> delete(String reference) async => values.remove(reference);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  WorkspaceController controllerFor(
    _ControlledPersistence persistence,
    http.Client client, {
    CredentialStore? credentials,
  }) {
    final controller = WorkspaceController(
      persistence: persistence,
      credentials: credentials ?? MemoryCredentialStore(),
      gateway: OpenAiGateway(client: client),
    );
    addTearDown(controller.dispose);
    addTearDown(client.close);
    return controller;
  }

  test(
    'document edits persist and a changed draft needs confirmation again',
    () async {
      final persistence = _ControlledPersistence();
      final controller = controllerFor(
        persistence,
        MockClient((_) async => _response('')),
      );
      await controller.initialize();
      final document = await controller.createDocument(
        title: '会议纪要',
        markdown: '# 初稿',
      );
      final confirmed = await controller.saveDocument(
        document.id,
        '# 经查看的纪要',
        confirm: true,
      );
      expect(confirmed.isConfirmed, isTrue);

      final edited = await controller.saveDocument(document.id, '# 再次修改');
      final restored = await persistence.load();

      expect(edited.isConfirmed, isFalse);
      expect(restored.documents.single.markdown, '# 再次修改');
      expect(restored.documents.single.revision, edited.revision);
      expect(restored.documents.single.isConfirmed, isFalse);
    },
  );

  test(
    'configuration puts the key in credential storage, never metadata',
    () async {
      final persistence = _ControlledPersistence();
      final credentials = MemoryCredentialStore();
      final controller = controllerFor(
        persistence,
        MockClient((_) async => _response('')),
        credentials: credentials,
      );

      await controller.configure(_profile(), '  $_testKey  ');

      expect(await credentials.read('credential:test-provider'), _testKey);
      expect(controller.canChat, isTrue);
      expect(jsonEncode(persistence.snapshot), isNot(contains(_testKey)));
      expect(
        (persistence.snapshot['profile']! as Map)['storageKeyRef'],
        'credential:test-provider',
      );
      await controller.removeCredential();
      expect(await credentials.read('credential:test-provider'), isNull);
      expect(controller.canChat, isFalse);
    },
  );

  test('manual terminal lease blocks cloud calls and workspace writes until release', () async {
    var requests = 0;
    final controller = controllerFor(
      _ControlledPersistence(),
      MockClient((_) async {
        requests++;
        return _response(_completeResponse(ApiProtocol.chatCompletions, '回复'));
      }),
    );
    await controller.configure(_profile(), _testKey);
    final document = await controller.createDocument(markdown: '保留的原内容');
    final lease = controller.acquireManualTerminal();

    expect(controller.manualTerminalActive, isTrue);
    expect(controller.canChat, isFalse);
    expect(controller.acquireManualTerminal, throwsStateError);
    await expectLater(
      controller.send('暂不发送', cloudApproved: true),
      throwsStateError,
    );
    await controller.testConnection();
    await expectLater(controller.configure(_profile(), ''), throwsStateError);
    await expectLater(controller.removeCredential(), throwsStateError);
    await expectLater(controller.createDocument(), throwsStateError);
    await expectLater(
      controller.saveDocument(document.id, '不能覆盖'),
      throwsStateError,
    );
    await expectLater(controller.deleteDocument(document.id), throwsStateError);
    expect(controller.documents.single.markdown, '保留的原内容');
    expect(controller.messages, isEmpty);
    expect(requests, 0);

    controller.releaseManualTerminal(lease);
    final nextLease = controller.acquireManualTerminal();
    controller.releaseManualTerminal(lease);
    expect(controller.manualTerminalActive, isTrue);
    controller.releaseManualTerminal(nextLease);
    expect(controller.manualTerminalActive, isFalse);
    expect(controller.canChat, isTrue);
    await controller.send('关闭终端后发送', cloudApproved: true);
    expect(requests, 1);
    expect(controller.tasks.single.status, TaskStatus.completed);
  });

  test('connection testing holds off manual terminal acquisition', () async {
    final started = Completer<void>();
    final completed = Completer<void>();
    final controller = controllerFor(
      _ControlledPersistence(),
      MockClient((_) async {
        started.complete();
        await completed.future;
        return _response(_completeResponse(ApiProtocol.chatCompletions, 'OK'));
      }),
    );
    await controller.configure(_profile(), _testKey);
    final testing = controller.testConnection();
    await started.future;

    expect(controller.isTesting, isTrue);
    expect(controller.acquireManualTerminal, throwsStateError);
    expect(controller.manualTerminalActive, isFalse);
    completed.complete();
    await testing;
    final lease = controller.acquireManualTerminal();
    expect(controller.manualTerminalActive, isTrue);
    controller.releaseManualTerminal(lease);
  });

  test(
    'changing endpoint cannot silently reuse an old key via an empty field',
    () async {
      final credentials = MemoryCredentialStore();
      final controller = controllerFor(
        _ControlledPersistence(),
        MockClient((_) async => _response('')),
        credentials: credentials,
      );
      final original = _profile();
      await controller.configure(original, _testKey);
      final differentEndpoint = ProviderProfile(
        id: original.id,
        displayName: original.displayName,
        baseUrl: Uri.parse('https://another-provider.invalid/v1/'),
        protocol: original.protocol,
        modelId: original.modelId,
        storageKeyRef: original.storageKeyRef,
      );

      await expectLater(
        controller.configure(differentEndpoint, ''),
        throwsA(anyOf(isA<ArgumentError>(), isA<StateError>())),
      );

      expect(controller.profile!.baseUrl, original.baseUrl);
      expect(await credentials.read(original.storageKeyRef!), _testKey);
    },
  );

  test(
    'failed configuration metadata rolls back key and keeps model context',
    () async {
      final payloads = <Map<String, Object?>>[];
      final persistence = _ControlledPersistence();
      final credentials = MemoryCredentialStore();
      final controller = controllerFor(
        persistence,
        MockClient((request) async {
          payloads.add(jsonDecode(request.body) as Map<String, Object?>);
          return _response(
            _completeResponse(ApiProtocol.chatCompletions, '已有回复'),
          );
        }),
        credentials: credentials,
      );
      final original = _profile();
      await controller.configure(original, _testKey);
      await controller.send('之前的材料', cloudApproved: true);
      final replacement = ProviderProfile(
        id: original.id,
        displayName: original.displayName,
        baseUrl: original.baseUrl,
        protocol: original.protocol,
        modelId: 'replacement-model',
        storageKeyRef: original.storageKeyRef,
      );
      persistence.failuresRemaining = 1;

      await expectLater(
        controller.configure(replacement, 'replacement-key'),
        throwsStateError,
      );

      expect(controller.profile, same(original));
      expect(controller.isConfiguring, isFalse);
      expect(controller.hasKey, isTrue);
      expect(controller.canChat, isTrue);
      expect(await credentials.read(original.storageKeyRef!), _testKey);
      expect((await persistence.load()).profile!.modelId, original.modelId);
      await controller.send('继续之前的讨论', cloudApproved: true);
      expect(payloads.last['messages']! as List, hasLength(3));
      expect(jsonEncode(payloads.last), contains('之前的材料'));
      expect(payloads.last['model'], original.modelId);
    },
  );

  test(
    'failed initial configuration removes the new key and unlocks retry',
    () async {
      final persistence = _ControlledPersistence()..failSaves = true;
      final credentials = MemoryCredentialStore();
      final controller = controllerFor(
        persistence,
        MockClient((_) async => _response('')),
        credentials: credentials,
      );

      await expectLater(
        controller.configure(_profile(), _testKey),
        throwsStateError,
      );

      expect(controller.profile, isNull);
      expect(controller.state.onboardingDismissed, isFalse);
      expect(controller.isConfiguring, isFalse);
      expect(controller.canChat, isFalse);
      expect(controller.hasKey, isFalse);
      expect(await credentials.read('credential:test-provider'), isNull);
      expect((await persistence.load()).profile, isNull);

      persistence.failSaves = false;
      await controller.configure(_profile(), _testKey);
      expect(controller.canChat, isTrue);
      expect(controller.isConfiguring, isFalse);
    },
  );

  test(
    'credential write failure restores an overwritten existing key',
    () async {
      final persistence = _ControlledPersistence();
      final credentials = _ControlledCredentialStore();
      final controller = controllerFor(
        persistence,
        MockClient((_) async => _response('')),
        credentials: credentials,
      );
      final original = _profile();
      await controller.configure(original, _testKey);
      credentials.writeFailuresRemaining = 1;

      await expectLater(
        controller.configure(_profile(), 'unsaved-key'),
        throwsStateError,
      );

      expect(controller.profile, same(original));
      expect(await credentials.read(original.storageKeyRef!), _testKey);
      expect(controller.isConfiguring, isFalse);
      expect(controller.hasKey, isTrue);
      expect(controller.canChat, isTrue);
      expect((await persistence.load()).profile!.modelId, original.modelId);
    },
  );

  test(
    'failed credential rollback disables requests but releases the lock',
    () async {
      final credentials = _ControlledCredentialStore();
      final controller = controllerFor(
        _ControlledPersistence(),
        MockClient((_) async => _response('')),
        credentials: credentials,
      );
      final original = _profile();
      await controller.configure(original, _testKey);
      credentials.writeFailuresRemaining = 2;

      await expectLater(
        controller.configure(_profile(), 'unsaved-key'),
        throwsStateError,
      );

      expect(controller.profile, same(original));
      expect(controller.isConfiguring, isFalse);
      expect(controller.hasKey, isFalse);
      expect(controller.canChat, isFalse);
      await controller.configure(_profile(), _testKey);
      expect(controller.canChat, isTrue);
    },
  );

  test(
    'configuration lock prevents request and snapshot mutations until commit',
    () async {
      var requests = 0;
      final credentials = _ControlledCredentialStore();
      final controller = controllerFor(
        _ControlledPersistence(),
        MockClient((_) async {
          requests++;
          return _response('');
        }),
        credentials: credentials,
      );
      final original = _profile();
      await controller.configure(original, _testKey);
      final document = await controller.createDocument(markdown: '原内容');
      final originalConversation = controller.activeConversation.id;
      final entered = Completer<void>();
      final gate = Completer<void>();
      credentials.writeEntered = entered;
      credentials.writeGate = gate;
      final replacement = ProviderProfile(
        id: original.id,
        displayName: original.displayName,
        baseUrl: original.baseUrl,
        protocol: original.protocol,
        modelId: 'next-model',
        storageKeyRef: original.storageKeyRef,
      );

      final saving = controller.configure(replacement, 'next-key');
      await entered.future;
      expect(controller.isConfiguring, isTrue);
      expect(controller.canChat, isFalse);
      expect(controller.acquireManualTerminal, throwsStateError);
      expect(controller.profile, same(original));
      await expectLater(
        controller.send('不得发送', cloudApproved: true),
        throwsStateError,
      );
      await controller.testConnection();
      await expectLater(controller.removeCredential(), throwsStateError);
      await expectLater(controller.configure(_profile(), ''), throwsStateError);
      await expectLater(controller.newConversation(), throwsStateError);
      await expectLater(
        controller.selectConversation(originalConversation),
        throwsStateError,
      );
      await expectLater(controller.clearConversation(), throwsStateError);
      await expectLater(controller.createDocument(), throwsStateError);
      await expectLater(
        controller.saveDocument(document.id, '不能覆盖'),
        throwsStateError,
      );
      await expectLater(
        controller.deleteDocument(document.id),
        throwsStateError,
      );
      expect(requests, 0);
      expect(controller.messages, isEmpty);
      expect(controller.tasks, isEmpty);
      expect(controller.documents.single.markdown, '原内容');

      credentials.writeGate = null;
      gate.complete();
      await saving;
      expect(controller.isConfiguring, isFalse);
      expect(controller.canChat, isTrue);
      expect(controller.profile!.modelId, 'next-model');
      expect(await credentials.read(original.storageKeyRef!), 'next-key');
    },
  );

  test(
    'startup interrupts started tasks and never automatically sends requests',
    () async {
      final now = DateTime.utc(2026, 11, 13);
      final statuses = [
        TaskStatus.queued,
        TaskStatus.running,
        TaskStatus.awaitingAuthorization,
        TaskStatus.awaitingNetwork,
        TaskStatus.awaitingForeground,
        TaskStatus.manualControl,
        TaskStatus.completed,
      ];
      final persistence = _ControlledPersistence(
        WorkspaceState(
          tasks: [
            for (final status in statuses)
              TaskRecord(
                id: status.name,
                title: status.label,
                status: status,
                createdAt: now,
                steps: status == TaskStatus.running
                    ? const [
                        TaskStep(
                          id: 'active-step',
                          title: '未核对的操作',
                          status: TaskStepStatus.running,
                          hasSideEffects: true,
                        ),
                      ]
                    : const [],
              ),
          ],
        ),
      );
      var requests = 0;
      final controller = controllerFor(
        persistence,
        MockClient((_) async {
          requests++;
          return _response('');
        }),
      );

      await controller.initialize();

      final byId = {for (final task in controller.tasks) task.id: task};
      expect(byId['queued']!.status, TaskStatus.queued);
      expect(byId['completed']!.status, TaskStatus.completed);
      for (final status in statuses.where(
        (value) => value != TaskStatus.queued && !value.isTerminal,
      )) {
        expect(byId[status.name]!.status, TaskStatus.interrupted);
      }
      expect(byId['running']!.steps.single.status, TaskStepStatus.uncertain);
      expect(requests, 0);
      expect(controller.isSending, isFalse);
    },
  );

  test(
    'unapproved cloud task does not mutate conversation or issue HTTP',
    () async {
      var requests = 0;
      final controller = controllerFor(
        _ControlledPersistence(),
        MockClient((_) async {
          requests++;
          return _response('');
        }),
      );
      await controller.configure(_profile(), _testKey);

      await expectLater(
        controller.send('私人会议材料', cloudApproved: false),
        throwsStateError,
      );

      expect(requests, 0);
      expect(controller.messages, isEmpty);
      expect(controller.tasks, isEmpty);
    },
  );

  test('a failed preflight save prevents the cloud request', () async {
    final persistence = _ControlledPersistence();
    var requests = 0;
    final controller = controllerFor(
      persistence,
      MockClient((_) async {
        requests++;
        return _response('');
      }),
    );
    await controller.configure(_profile(), _testKey);
    persistence.failSaves = true;

    await controller.send('请整理这份记录', cloudApproved: true);

    expect(requests, 0);
    expect(controller.canChat, isFalse);
    expect(controller.isSending, isFalse);
    expect(controller.tasks.single.status, TaskStatus.failed);
    expect(controller.messages.first.text, '请整理这份记录');
    expect(controller.error, contains('保存失败'));
  });

  for (final protocol in ApiProtocol.values) {
    test(
      '${protocol.label} completion persists the real text and finishes task',
      () async {
        final persistence = _ControlledPersistence();
        final payloads = <Map<String, Object?>>[];
        final controller = controllerFor(
          persistence,
          MockClient((request) async {
            payloads.add(jsonDecode(request.body) as Map<String, Object?>);
            return _response(_completeResponse(protocol, '实际模型回复'));
          }),
        );
        await controller.configure(_profile(protocol: protocol), _testKey);

        await controller.send('请整理材料', cloudApproved: true);

        expect(payloads, hasLength(1));
        expect(payloads.single['model'], 'test-model');
        expect(
          payloads.single[protocol == ApiProtocol.responses
              ? 'input'
              : 'messages'],
          isA<List>(),
        );
        expect(controller.messages.last.text, '实际模型回复');
        expect(controller.tasks.single.status, TaskStatus.completed);
        expect(controller.tasks.single.cloudAuthorization!.isRevoked, isTrue);
        expect(controller.isSending, isFalse);
        final restored = await persistence.load();
        expect(restored.messages.last.text, '实际模型回复');
        expect(restored.tasks.single.status, TaskStatus.completed);
      },
    );
  }

  test('a later chat turn preserves required provider reasoning context', () async {
    final payloads = <Map<String, Object?>>[];
    final controller = controllerFor(
      _ControlledPersistence(),
      MockClient((request) async {
        payloads.add(jsonDecode(request.body) as Map<String, Object?>);
        return _response(
          '${_event({
            'choices': [
              {
                'index': 0,
                'delta': {'role': 'assistant', 'content': '第一轮回复', 'reasoning_content': '服务要求保留的上下文'},
              },
            ],
          })}data: [DONE]\n\n',
        );
      }),
    );
    await controller.configure(_profile(), _testKey);

    await controller.send('第一轮材料', cloudApproved: true);
    await controller.send('继续整理', cloudApproved: true);

    expect(payloads, hasLength(2));
    final history = payloads.last['messages']! as List;
    expect(history, hasLength(3));
    expect((history[1] as Map)['reasoning_content'], '服务要求保留的上下文');
  });

  for (final protocol in ApiProtocol.values) {
    test(
      '${protocol.label} keeps messages and model context isolated by thread',
      () async {
        final payloads = <Map<String, Object?>>[];
        final controller = controllerFor(
          _ControlledPersistence(),
          MockClient((request) async {
            payloads.add(jsonDecode(request.body) as Map<String, Object?>);
            return _response(
              _completeResponse(protocol, '回复 ${payloads.length}'),
            );
          }),
        );
        await controller.configure(_profile(protocol: protocol), _testKey);
        final firstConversationId = controller.activeConversation.id;

        await controller.send('第一会话的私有材料', cloudApproved: true);
        expect(controller.activeConversation.title, '第一会话的私有材料');
        final secondConversation = await controller.newConversation();
        expect(controller.messages, isEmpty);
        expect(controller.conversations.first.id, secondConversation.id);
        await controller.send('第二会话的独立材料', cloudApproved: true);
        expect(controller.messages.first.text, '第二会话的独立材料');
        expect(controller.messages.last.text, '回复 2');

        final key = protocol == ApiProtocol.responses ? 'input' : 'messages';
        expect(payloads[1][key]! as List, hasLength(1));
        expect(jsonEncode(payloads[1]), isNot(contains('第一会话的私有材料')));
        await controller.selectConversation(firstConversationId);
        expect(controller.messages.first.text, '第一会话的私有材料');
        expect(controller.messages.last.text, '回复 1');
        await controller.send('继续第一会话', cloudApproved: true);

        expect(payloads.last[key]! as List, hasLength(3));
        expect(jsonEncode(payloads.last), contains('第一会话的私有材料'));
        expect(jsonEncode(payloads.last), isNot(contains('第二会话的独立材料')));
        expect(jsonEncode(payloads.last), isNot(contains('回复 2')));
        expect(controller.messages, hasLength(4));
        expect(controller.state.messages, hasLength(6));
        expect(
          controller.tasks.first.cloudAuthorization!.currentSources,
          hasLength(2),
        );
      },
    );
  }

  test(
    'restart restores the selected conversation without replaying old context',
    () async {
      final persistence = _ControlledPersistence();
      final credentials = MemoryCredentialStore();
      final controller = controllerFor(
        persistence,
        MockClient(
          (_) async => _response(
            _completeResponse(ApiProtocol.chatCompletions, '保存的回复'),
          ),
        ),
        credentials: credentials,
      );
      await controller.configure(_profile(), _testKey);
      await controller.send('旧会话消息', cloudApproved: true);
      final selected = await controller.newConversation();
      await controller.send('选中会话消息', cloudApproved: true);

      final afterRestartPayloads = <Map<String, Object?>>[];
      final restored = controllerFor(
        persistence,
        MockClient((request) async {
          afterRestartPayloads.add(
            jsonDecode(request.body) as Map<String, Object?>,
          );
          return _response(
            _completeResponse(ApiProtocol.chatCompletions, '新回复'),
          );
        }),
        credentials: credentials,
      );
      await restored.initialize();

      expect(restored.activeConversation.id, selected.id);
      expect(restored.activeConversation.title, '选中会话消息');
      expect(restored.messages.first.text, '选中会话消息');
      expect(restored.state.messages, hasLength(4));
      expect(afterRestartPayloads, isEmpty);
      await restored.send('重启后的新授权消息', cloudApproved: true);
      expect(afterRestartPayloads.single['messages']! as List, hasLength(1));
      expect(jsonEncode(afterRestartPayloads.single), isNot(contains('旧会话消息')));
    },
  );

  test(
    'clearing a conversation preserves other history and its model context',
    () async {
      final payloads = <Map<String, Object?>>[];
      final controller = controllerFor(
        _ControlledPersistence(),
        MockClient((request) async {
          payloads.add(jsonDecode(request.body) as Map<String, Object?>);
          return _response(
            _completeResponse(ApiProtocol.chatCompletions, '回复'),
          );
        }),
      );
      await controller.configure(_profile(), _testKey);
      final firstId = controller.activeConversation.id;
      await controller.send('保留的会话材料', cloudApproved: true);
      await controller.newConversation();
      await controller.send('准备清除的会话材料', cloudApproved: true);

      await controller.clearConversation();

      expect(controller.messages, isEmpty);
      expect(controller.activeConversation.title, '新对话');
      expect(controller.state.messages, hasLength(2));
      await controller.send('清除后的新材料', cloudApproved: true);
      expect(payloads.last['messages']! as List, hasLength(1));
      await controller.selectConversation(firstId);
      await controller.send('继续保留的会话', cloudApproved: true);
      expect(payloads.last['messages']! as List, hasLength(3));
      expect(jsonEncode(payloads.last), contains('保留的会话材料'));
      expect(jsonEncode(payloads.last), isNot(contains('准备清除的会话材料')));
    },
  );

  test(
    'model reconfiguration clears protocol contexts for every conversation',
    () async {
      final payloads = <Map<String, Object?>>[];
      final controller = controllerFor(
        _ControlledPersistence(),
        MockClient((request) async {
          payloads.add(jsonDecode(request.body) as Map<String, Object?>);
          return _response(
            _completeResponse(ApiProtocol.chatCompletions, '历史回复'),
          );
        }),
      );
      await controller.configure(_profile(), _testKey);
      final firstId = controller.activeConversation.id;
      await controller.send('第一会话旧模型内容', cloudApproved: true);
      final second = await controller.newConversation();
      await controller.send('第二会话旧模型内容', cloudApproved: true);

      await controller.configure(_profile(), '');
      await controller.selectConversation(firstId);
      await controller.send('新配置下第一条', cloudApproved: true);
      expect(payloads.last['messages']! as List, hasLength(1));
      await controller.selectConversation(second.id);
      await controller.send('新配置下另一会话', cloudApproved: true);
      expect(payloads.last['messages']! as List, hasLength(1));
      expect(controller.state.messages, hasLength(8));
    },
  );

  test(
    'truncated stream keeps received text and records interruption',
    () async {
      final persistence = _ControlledPersistence();
      var requests = 0;
      final controller = controllerFor(
        persistence,
        MockClient((_) async {
          requests++;
          return _response(_chatText('已经收到的部分纪要'));
        }),
      );
      await controller.configure(_profile(), _testKey);

      await controller.send('请整理会议', cloudApproved: true);

      expect(requests, 1);
      expect(controller.messages.last.text, '已经收到的部分纪要');
      expect(controller.tasks.single.status, TaskStatus.interrupted);
      expect(controller.isSending, isFalse);
      expect(controller.error, contains('中断'));
      expect((await persistence.load()).messages.last.text, '已经收到的部分纪要');
    },
  );

  test(
    'cancelling a live request retains partial text without a retry',
    () async {
      final responseBody = StreamController<List<int>>();
      final requestStarted = Completer<void>();
      final partialVisible = Completer<void>();
      var requests = 0;
      final controller = controllerFor(
        _ControlledPersistence(),
        MockClient.streaming((_, body) async {
          await body.drain<void>();
          requests++;
          requestStarted.complete();
          return http.StreamedResponse(
            responseBody.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      addTearDown(responseBody.close);
      await controller.configure(_profile(), _testKey);
      controller.addListener(() {
        if (!partialVisible.isCompleted &&
            controller.messages.isNotEmpty &&
            controller.messages.last.text == '已生成的草稿') {
          partialVisible.complete();
        }
      });

      final sending = controller.send('请继续整理', cloudApproved: true);
      await requestStarted.future;
      responseBody.add(utf8.encode(_chatText('已生成的草稿')));
      await partialVisible.future;
      final activeConversationId = controller.activeConversation.id;
      final conversationCount = controller.conversations.length;
      expect(controller.acquireManualTerminal, throwsStateError);
      await expectLater(controller.newConversation(), throwsStateError);
      await expectLater(
        controller.selectConversation(activeConversationId),
        throwsStateError,
      );
      expect(controller.conversations, hasLength(conversationCount));
      expect(controller.activeConversation.id, activeConversationId);
      controller.cancelActiveTask();
      await sending;

      expect(requests, 1);
      expect(controller.tasks.single.status, TaskStatus.cancelled);
      expect(controller.messages.last.text, '已生成的草稿');
      expect(controller.isSending, isFalse);
      expect(controller.tasks.single.cloudAuthorization!.isRevoked, isTrue);
    },
  );

  test(
    'cancellation during preflight persistence prevents any HTTP request',
    () async {
      final persistence = _ControlledPersistence();
      var requests = 0;
      final controller = controllerFor(
        persistence,
        MockClient((_) async {
          requests++;
          return _response(
            _completeResponse(ApiProtocol.chatCompletions, '回复'),
          );
        }),
      );
      await controller.configure(_profile(), _testKey);
      final saveGate = Completer<void>();
      persistence.saveGate = saveGate;
      final saveEntered = Completer<void>();
      persistence.saveEntered = saveEntered;

      final sending = controller.send('暂不发送的材料', cloudApproved: true);
      await saveEntered.future;
      expect(controller.isSending, isTrue);
      controller.cancelActiveTask();
      persistence.saveGate = null;
      saveGate.complete();
      await sending;

      expect(requests, 0);
      expect(controller.tasks.single.status, TaskStatus.cancelled);
      expect(controller.isSending, isFalse);
    },
  );
}
