// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant_core/perant_core.dart';
import 'package:perant_gateway/perant_gateway.dart';
import 'package:perant_platform/perant_platform.dart';

String _event(Map<String, Object?> value) => 'data: ${jsonEncode(value)}\n\n';
http.Response _response(String body) => http.Response(
  body,
  200,
  headers: {'content-type': 'text/event-stream; charset=utf-8'},
);
String _tools(
  ApiProtocol protocol,
  List<({String id, String name, String arguments})> calls, {
  bool complete = true,
  String? finish = 'tool_calls',
}) {
  if (protocol == ApiProtocol.chatCompletions) {
    return '${_event({
      'choices': [
        {
          'index': 0,
          'delta': {
            'role': 'assistant',
            'reasoning_content': 'provider-required-reasoning',
            'tool_calls': calls.indexed.map((row) => {
              'index': row.$1,
              'id': row.$2.id,
              'type': 'function',
              'function': {'name': row.$2.name, 'arguments': row.$2.arguments},
            }).toList(),
          },
          if (complete) 'finish_reason': finish,
        },
      ],
    })}${complete ? 'data: [DONE]\n\n' : ''}';
  }
  final output = <Map<String, Object?>>[
    {
      'id': 'reasoning-${calls.first.id}',
      'type': 'reasoning',
      'summary': [],
      'encrypted_content': 'provider-required-reasoning',
    },
    ...calls.map(
      (call) => {
        'id': 'item-${call.id}',
        'type': 'function_call',
        'call_id': call.id,
        'name': call.name,
        'arguments': call.arguments,
      },
    ),
  ];
  return complete
      ? _event({
          'type': 'response.completed',
          'response': {
            'id': 'resp-${calls.first.id}',
            'status': 'completed',
            'output': output,
          },
        })
      : _event({
          'type': 'response.output_item.added',
          'output_index': 1,
          'item': output[1],
        });
}

String _text(ApiProtocol protocol, [String text = '实际文件已更新，请在容器工作区查看。']) =>
    protocol == ApiProtocol.chatCompletions
    ? '${_event({
        'choices': [
          {
            'index': 0,
            'delta': {'role': 'assistant', 'content': text},
            'finish_reason': 'stop',
          },
        ],
      })}data: [DONE]\n\n'
    : '${_event({'type': 'response.output_text.delta', 'delta': text})}${_event({
        'type': 'response.completed',
        'response': {
          'id': 'response-final',
          'status': 'completed',
          'output': [
            {
              'id': 'message-final',
              'type': 'message',
              'role': 'assistant',
              'content': [
                {'type': 'output_text', 'text': text},
              ],
            },
          ],
        },
      })}';
({String id, String name, String arguments}) _call(
  String id,
  String name,
  Map<String, Object?> args,
) => (id: id, name: name, arguments: jsonEncode(args));
ProviderProfile _profile(ApiProtocol protocol) => ProviderProfile(
  id: 'container-test-provider',
  displayName: '测试接口',
  baseUrl: Uri.parse('https://example.invalid/v1'),
  protocol: protocol,
  modelId: 'test-model',
  storageKeyRef: 'credential:container-test-provider',
);

final class _Native {
  static int sequence = 0;
  _Native() : name = 'dev.perant/container-test-${sequence++}';
  final String name;
  late final methods = MethodChannel('$name/methods');
  late final events = EventChannel('$name/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final files = <String, String>{};
  final calls = <String>[];
  bool supported = true;
  bool installed = true;
  bool active = false;
  bool autoExit = true;
  bool cancelFails = false;
  bool loseWriteResponseOnce = false;
  Completer<void>? fileBarrierGate;
  String? fileBarrierErrorCode;
  final fileBarrierEntered = Completer<void>();
  int starts = 0;
  int writes = 0;
  int initializations = 0;
  String? owner;
  Completer<void>? initializationGate;
  Completer<void>? cancelGate;
  final initializationEntered = Completer<void>();
  final commandStarted = Completer<void>();
  final cancelEntered = Completer<void>();
  Map<String, Object?> get capabilities => {
    'schemaVersion': 1,
    'platform': 'android',
    'systemVersion': 'test fixture',
    'nativeBridgeAvailable': true,
    'linux': {'available': supported, 'reason': 'Test fixture'},
    'localInference': {'available': false, 'reason': 'No model'},
    'backgroundTasks': {'available': false, 'reason': 'No background service'},
  };
  Map<String, Object?> get status => {
    'supported': supported,
    'installed': installed && supported,
    'active': active,
    'sessionId': null,
    'distribution': 'Alpine',
    'version': '3.24.4',
    'workspace': '/workspace',
    'reason': 'Test fixture runtime',
  };
  Map<String, Object?> file(String path) => {
    'path': path,
    'content': files[path]!,
    'sizeBytes': utf8.encode(files[path]!).length,
    'sha256': 'a' * 64,
  };
  void install() {
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call.method);
      final args = call.arguments is Map ? call.arguments! as Map : const {};
      switch (call.method) {
        case 'getCapabilities':
          return capabilities;
        case 'getLinuxStatus':
          return status;
        case 'initializeLinux':
          initializations++;
          if (!initializationEntered.isCompleted)
            initializationEntered.complete();
          await initializationGate?.future;
          installed = true;
          return status;
        case 'listLinuxDirectory':
          if (!fileBarrierEntered.isCompleted) fileBarrierEntered.complete();
          await fileBarrierGate?.future;
          if (fileBarrierErrorCode case final code?) {
            throw PlatformException(
              code: code,
              message: 'Fixture native FIFO file listing failure',
            );
          }
          return {
            'path': args['path'],
            'entries': <Map<String, Object?>>[],
            'truncated': false,
          };
        case 'writeLinuxFile':
          writes++;
          files[args['path']! as String] = args['content']! as String;
          if (loseWriteResponseOnce) {
            loseWriteResponseOnce = false;
            throw PlatformException(
              code: 'timeout',
              message: 'Fixture response lost after the real file write',
            );
          }
          return file(args['path']! as String);
        case 'readLinuxFile':
          return file(args['path']! as String);
        case 'createLinuxDirectory':
          return null;
        case 'runLinuxCommand':
          starts++;
          owner = args['taskId']! as String;
          active = true;
          if (!commandStarted.isCompleted) commandStarted.complete();
          await emit('linuxOutput', {'text': 'native 中文\r\n'});
          if (autoExit) await exit();
          return {'taskId': owner, 'pid': 42};
        case 'cancelTask':
          if (!cancelEntered.isCompleted) cancelEntered.complete();
          await cancelGate?.future;
          if (cancelFails)
            throw PlatformException(
              code: 'timeout',
              message: 'Fixture cancel not confirmed',
            );
          if (active) await exit(cancelled: true, code: 143);
          return {
            'taskId': args['taskId'],
            'status': 'cancelled',
            'reason': 'Fixture cleaned',
          };
        default:
          throw StateError('Unexpected native method ${call.method}');
      }
    });
    messenger.setMockMethodCallHandler(MethodChannel(events.name), (
      call,
    ) async {
      if (call.method == 'listen')
        scheduleMicrotask(
          () => emit('bridgeAttached', capabilities, ownerId: null),
        );
      return null;
    });
  }

  Future<void> emit(
    String type,
    Map<String, Object?> payload, {
    String? ownerId,
  }) => messenger.handlePlatformMessage(
    events.name,
    const StandardMethodCodec().encodeSuccessEnvelope({
      'type': type,
      'emittedAtEpochMs': DateTime.now().millisecondsSinceEpoch,
      if (ownerId != null || owner != null) 'taskId': ownerId ?? owner,
      'payload': payload,
    }),
    (_) {},
  );
  Future<void> exit({int code = 0, bool cancelled = false}) async {
    active = false;
    await emit('linuxExit', {
      'exitCode': code,
      'cancelled': cancelled,
      'timedOut': false,
    });
  }

  void uninstall() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(MethodChannel(events.name), null);
  }
}

final class _ReceiptFailurePersistence implements WorkspacePersistence {
  final _inner = MemoryWorkspacePersistence();
  bool failSuccessOnce = true;
  @override
  String get description => 'One failed success receipt';
  @override
  Future<WorkspaceState> load() => _inner.load();
  @override
  Future<void> close() => _inner.close();
  @override
  Future<void> save(Map<String, Object?> snapshot) async {
    final actions = snapshot['containerActions']! as List;
    if (failSuccessOnce &&
        actions.any((value) => (value as Map)['status'] == 'succeeded')) {
      failSuccessOnce = false;
      throw StateError('Fixture SQLite receipt failure after native mutation');
    }
    await _inner.save(snapshot);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<WorkspaceController> launch(
    _Native native,
    http.Client client, {
    ApiProtocol protocol = ApiProtocol.chatCompletions,
    WorkspacePersistence? persistence,
    bool autoDispose = true,
  }) async {
    native.install();
    final controller = WorkspaceController(
      persistence: persistence ?? MemoryWorkspacePersistence(),
      credentials: MemoryCredentialStore(),
      gateway: OpenAiGateway(client: client),
      bridge: PerantPlatformBridge(
        methodChannel: native.methods,
        eventChannel: native.events,
      ),
    );
    await controller.initialize();
    await controller.configure(_profile(protocol), 'test-only-not-a-real-key');
    if (autoDispose) addTearDown(controller.dispose);
    addTearDown(client.close);
    addTearDown(native.uninstall);
    return controller;
  }

  for (final protocol in ApiProtocol.values) {
    test(
      '$protocol sends real file/tool results and retains provider continuation',
      () async {
        final native = _Native();
        final payloads = <Map<String, Object?>>[];
        final responses = [
          _tools(protocol, [
            _call('write-1', 'container_write_file', {
              'path': '/workspace/shared.md',
              'content': 'container-private-file-content 中文',
              'create_only': true,
            }),
          ]),
          _tools(protocol, [
            _call('read-1', 'container_read_file', {
              'path': '/workspace/shared.md',
            }),
          ]),
          _tools(protocol, [
            _call('shell-1', 'container_run_command', {
              'command': 'printf native',
              'timeout_seconds': 5,
            }),
          ]),
          _text(protocol),
        ];
        final persistence = MemoryWorkspacePersistence();
        final controller = await launch(
          native,
          MockClient((request) async {
            payloads.add(jsonDecode(request.body) as Map<String, Object?>);
            return _response(
              responses.isEmpty ? _text(protocol) : responses.removeAt(0),
            );
          }),
          protocol: protocol,
          persistence: persistence,
        );
        final approvals = <String>[];
        await controller.send(
          '请创建共享笔记并验证',
          cloudApproved: true,
          containerEnabled: true,
          approveContainerCommand: (command) async {
            approvals.add(command);
            return true;
          },
        );

        expect(payloads, hasLength(4));
        expect(
          native.files['/workspace/shared.md'],
          'container-private-file-content 中文',
        );
        expect(native.starts, 1);
        expect(approvals, ['printf native']);
        expect(controller.tasks.single.status, TaskStatus.completed);
        expect(controller.tasks.single.cloudAuthorization!.isRevoked, isTrue);
        expect(controller.containerActions, hasLength(3));
        expect(
          controller.containerActions.every(
            (action) => action.status == ContainerActionStatus.succeeded,
          ),
          isTrue,
        );
        expect(controller.containerActions.first.output, contains('native 中文'));
        expect(controller.containerActions.first.exitCode, 0);
        expect(
          controller.messages.every(
            (message) => message.source == ChatEntrySource.container,
          ),
          isTrue,
        );
        final restored = await persistence.load();
        expect(restored.containerActions, hasLength(3));
        expect(
          restored.containerActions.first.taskId,
          controller.tasks.single.id,
        );
        final historyKey = protocol == ApiProtocol.responses
            ? 'input'
            : 'messages';
        final second = payloads[1][historyKey]! as List;
        expect(jsonEncode(second), contains('provider-required-reasoning'));
        final result = second.last as Map;
        expect(
          result[protocol == ApiProtocol.responses
              ? 'call_id'
              : 'tool_call_id'],
          'write-1',
        );
        expect(
          result[protocol == ApiProtocol.responses ? 'output' : 'content'],
          contains('"ok":true'),
        );
        expect(
          jsonEncode(payloads[2]),
          contains('container-private-file-content 中文'),
        );
        expect(jsonEncode(payloads[3]), contains('native 中文'));

        // A plain chat grant does not disclose prior file results or container
        // user/reply context. Container opt-in can resume its separate history.
        await controller.send('普通聊天', cloudApproved: true);
        expect(
          jsonEncode(payloads.last),
          isNot(contains('container-private-file-content')),
        );
        expect(payloads.last.containsKey('tools'), isFalse);
        await controller.send(
          '继续容器协作',
          cloudApproved: true,
          containerEnabled: true,
        );
        expect(
          jsonEncode(payloads.last),
          contains('container-private-file-content'),
        );
        expect(jsonEncode(payloads.last), isNot(contains('普通聊天')));
      },
    );
  }

  test('ordinary chat never executes unsolicited container tools', () async {
    final native = _Native();
    final controller = await launch(
      native,
      MockClient(
        (_) async => _response(
          _tools(ApiProtocol.chatCompletions, [
            _call('write-1', 'container_write_file', {
              'path': '/workspace/no.md',
              'content': 'no',
            }),
          ]),
        ),
      ),
    );
    await controller.send('普通问题', cloudApproved: true);
    expect(native.writes, 0);
    expect(controller.containerActions, isEmpty);
    expect(controller.tasks.single.status, TaskStatus.failed);
  });

  test('denied exact shell proposal produces an honest tool result without a process', () async {
    final native = _Native();
    final payloads = <String>[];
    final controller = await launch(
      native,
      MockClient((request) async {
        payloads.add(request.body);
        return _response(
          payloads.length == 1
              ? _tools(ApiProtocol.chatCompletions, [
                  _call('shell-1', 'container_run_command', {
                    'command': 'printf denied',
                  }),
                ])
              : _text(ApiProtocol.chatCompletions),
        );
      }),
    );
    await controller.send(
      '需要命令',
      cloudApproved: true,
      containerEnabled: true,
      approveContainerCommand: (_) async => false,
    );
    expect(native.starts, 0);
    expect(
      controller.containerActions.single.status,
      ContainerActionStatus.denied,
    );
    expect(payloads.last, contains('command_denied'));
    expect(controller.isSending, isFalse);
  });

  test(
    'malformed arguments and unknown tools do not invoke the host',
    () async {
      final native = _Native();
      var requests = 0;
      final controller = await launch(
        native,
        MockClient(
          (_) async => _response(
            requests++ == 0
                ? _tools(ApiProtocol.chatCompletions, [
                    (
                      id: 'invalid-1',
                      name: 'container_write_file',
                      arguments: '{"path":',
                    ),
                    _call('unknown-1', 'unknown_tool', {}),
                  ])
                : _text(ApiProtocol.chatCompletions),
          ),
        ),
      );
      await controller.send(
        '无效调用',
        cloudApproved: true,
        containerEnabled: true,
      );
      expect(native.writes, 0);
      expect(native.starts, 0);
      expect(controller.containerActions, hasLength(2));
      expect(
        controller.containerActions.every(
          (action) => action.status == ContainerActionStatus.failed,
        ),
        isTrue,
      );
    },
  );

  test(
    'an incomplete model stream never executes a partial tool proposal',
    () async {
      final native = _Native();
      final controller = await launch(
        native,
        MockClient(
          (_) async => _response(
            _tools(ApiProtocol.chatCompletions, [
              _call('write-1', 'container_write_file', {
                'path': '/workspace/no.md',
                'content': 'no',
              }),
            ], complete: false),
          ),
        ),
      );
      await controller.send(
        '中断提案',
        cloudApproved: true,
        containerEnabled: true,
      );
      expect(native.writes, 0);
      expect(controller.containerActions, isEmpty);
      expect(controller.tasks.single.status, TaskStatus.interrupted);
    },
  );

  test(
    'a tool proposal with no tool_calls finish reason is not executed',
    () async {
      final native = _Native();
      final controller = await launch(
        native,
        MockClient(
          (_) async => _response(
            _tools(ApiProtocol.chatCompletions, [
              _call('write-1', 'container_write_file', {
                'path': '/workspace/no.md',
                'content': 'no',
              }),
            ], finish: 'stop'),
          ),
        ),
      );
      await controller.send(
        '错误结束状态',
        cloudApproved: true,
        containerEnabled: true,
      );
      expect(native.writes, 0);
      expect(controller.tasks.single.status, TaskStatus.failed);
    },
  );

  test(
    'duplicate call IDs reject the whole batch before side effects',
    () async {
      final native = _Native();
      final controller = await launch(
        native,
        MockClient(
          (_) async => _response(
            _tools(ApiProtocol.chatCompletions, [
              _call('same', 'container_write_file', {
                'path': '/workspace/one.md',
                'content': 'one',
              }),
              _call('same', 'container_write_file', {
                'path': '/workspace/two.md',
                'content': 'two',
              }),
            ]),
          ),
        ),
      );
      await controller.send(
        '重复提案',
        cloudApproved: true,
        containerEnabled: true,
      );
      expect(native.writes, 0);
      expect(controller.containerActions, isEmpty);
      expect(controller.tasks.single.status, TaskStatus.failed);
    },
  );

  test('cancellation during shell approval prevents a late positive answer from starting', () async {
    final native = _Native();
    final asked = Completer<void>();
    final answer = Completer<bool>();
    var requests = 0;
    final controller = await launch(
      native,
      MockClient((_) async {
        requests++;
        return _response(
          _tools(ApiProtocol.chatCompletions, [
            _call('shell-1', 'container_run_command', {
              'command': 'printf late',
            }),
          ]),
        );
      }),
    );
    final sending = controller.send(
      '命令待确认',
      cloudApproved: true,
      containerEnabled: true,
      approveContainerCommand: (_) {
        asked.complete();
        return answer.future;
      },
    );
    await asked.future;
    expect(controller.activeContainerCommand, 'printf late');
    controller.cancelActiveTask();
    await sending;
    answer.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(native.starts, 0);
    expect(requests, 1);
    expect(controller.tasks.single.status, TaskStatus.cancelled);
    expect(
      controller.containerActions.single.status,
      ContainerActionStatus.cancelled,
    );
  });

  test(
    'workspace stays busy until a running shell acknowledges cleanup',
    () async {
      final native = _Native()
        ..autoExit = false
        ..cancelGate = Completer<void>();
      var requests = 0;
      final controller = await launch(
        native,
        MockClient((_) async {
          requests++;
          return _response(
            _tools(ApiProtocol.chatCompletions, [
              _call('shell-1', 'container_run_command', {
                'command': 'sleep 20',
              }),
            ]),
          );
        }),
      );
      final sending = controller.send(
        '长命令',
        cloudApproved: true,
        containerEnabled: true,
        approveContainerCommand: (_) async => true,
      );
      await native.commandStarted.future;
      controller.cancelActiveTask();
      await native.cancelEntered.future;
      expect(controller.isSending, isTrue);
      expect(controller.isContainerTaskRunning, isTrue);
      expect(controller.acquireManualTerminal, throwsStateError);
      await expectLater(controller.createDocument(), throwsStateError);
      native.cancelGate!.complete();
      await sending;
      expect(controller.isSending, isFalse);
      expect(native.active, isFalse);
      expect(native.starts, 1);
      expect(requests, 1);
      expect(
        controller.containerActions.single.status,
        ContainerActionStatus.cancelled,
      );
      expect(controller.containerActions.single.exitCode, 143);
    },
  );

  test(
    'disposing while initialization is pending prevents a late HTTP request',
    () async {
      final native = _Native()
        ..installed = false
        ..initializationGate = Completer<void>();
      var requests = 0;
      final controller = await launch(
        native,
        MockClient((_) async {
          requests++;
          return _response(_text(ApiProtocol.chatCompletions));
        }),
        autoDispose: false,
      );
      final sending = controller.send(
        '初始化',
        cloudApproved: true,
        containerEnabled: true,
      );
      await native.initializationEntered.future;
      controller.dispose();
      native.initializationGate!.complete();
      await sending;
      expect(requests, 0);
      expect(native.starts, 0);
      expect(native.writes, 0);
    },
  );

  test('unsupported or already occupied native runtime fails before sending to the cloud', () async {
    for (final occupied in [false, true]) {
      final native = _Native()
        ..supported = occupied
        ..active = occupied;
      var requests = 0;
      final controller = await launch(
        native,
        MockClient((_) async {
          requests++;
          return _response(_text(ApiProtocol.chatCompletions));
        }),
      );
      await controller.send(
        '检查容器',
        cloudApproved: true,
        containerEnabled: true,
      );
      expect(requests, 0);
      expect(controller.tasks.single.status, TaskStatus.failed);
      expect(native.starts, 0);
    }
  });

  test(
    'restored nonterminal actions are interrupted and never replayed',
    () async {
      final native = _Native();
      final persistence = MemoryWorkspacePersistence();
      final now = DateTime.now();
      await persistence.save(
        WorkspaceState(
          containerActions: [
            ContainerAction(
              id: 'old-action',
              taskId: 'old-task',
              conversationId: 'main',
              tool: 'container_run_command',
              summary: 'sleep 10',
              status: ContainerActionStatus.awaitingApproval,
              createdAt: now,
              updatedAt: now,
            ),
          ],
        ).toJson(),
      );
      final controller = await launch(
        native,
        MockClient((_) async => throw StateError('Unexpected HTTP')),
        persistence: persistence,
      );
      expect(
        controller.containerActions.single.status,
        ContainerActionStatus.interrupted,
      );
      expect(native.starts, 0);
      expect(controller.containerActions.single.output, contains('不会自动重放'));
    },
  );
  test(
    'a truncated read cannot authorize overwriting the unseen remainder',
    () async {
      final native = _Native()
        ..files['/workspace/large.md'] = '${'x' * 60000}KEEP_UNSEEN_END';
      var requests = 0;
      final payloads = <Map<String, Object?>>[];
      final controller = await launch(
        native,
        MockClient((request) async {
          payloads.add(jsonDecode(request.body) as Map<String, Object?>);
          return _response(switch (requests++) {
            0 => _tools(ApiProtocol.chatCompletions, [
              _call('read-large', 'container_read_file', {
                'path': '/workspace/large.md',
              }),
            ]),
            1 => _tools(ApiProtocol.chatCompletions, [
              _call('bad-overwrite', 'container_write_file', {
                'path': '/workspace/large.md',
                'content': 'only prefix',
                'expected_sha256': 'a' * 64,
              }),
            ]),
            _ => _text(ApiProtocol.chatCompletions),
          });
        }),
      );
      await controller.send(
        '编辑长文件',
        cloudApproved: true,
        containerEnabled: true,
      );
      expect(native.writes, 0);
      expect(native.files['/workspace/large.md'], endsWith('KEEP_UNSEEN_END'));
      expect(
        controller.containerActions.first.status,
        ContainerActionStatus.failed,
      );
      expect(controller.containerActions.first.output, contains('完整读取'));
      expect(jsonEncode(payloads[1]), contains('truncated'));
      expect(jsonEncode(payloads[1]), isNot(contains('KEEP_UNSEEN_END')));
    },
  );

  test('a full read hash from a prior task does not authorize a new task overwrite', () async {
    final native = _Native()..files['/workspace/shared.md'] = 'keep original';
    var requests = 0;
    final controller = await launch(
      native,
      MockClient(
        (_) async => _response(switch (requests++) {
          0 => _tools(ApiProtocol.chatCompletions, [
            _call('read', 'container_read_file', {
              'path': '/workspace/shared.md',
            }),
          ]),
          2 => _tools(ApiProtocol.chatCompletions, [
            _call('write', 'container_write_file', {
              'path': '/workspace/shared.md',
              'content': 'stale overwrite',
              'expected_sha256': 'a' * 64,
            }),
          ]),
          _ => _text(ApiProtocol.chatCompletions),
        }),
      ),
    );
    await controller.send('先读取', cloudApproved: true, containerEnabled: true);
    await controller.send(
      '下个任务直接用旧hash',
      cloudApproved: true,
      containerEnabled: true,
    );
    expect(native.writes, 0);
    expect(native.files['/workspace/shared.md'], 'keep original');
    expect(
      controller.containerActions.first.status,
      ContainerActionStatus.failed,
    );
  });

  test('success receipt save failure stops the task without telling the model to retry', () async {
    final native = _Native();
    final persistence = _ReceiptFailurePersistence();
    var requests = 0;
    final controller = await launch(
      native,
      MockClient((_) async {
        requests++;
        return _response(
          _tools(ApiProtocol.chatCompletions, [
            _call('write', 'container_write_file', {
              'path': '/workspace/durable.md',
              'content': 'actual saved file',
              'create_only': true,
            }),
          ]),
        );
      }),
      persistence: persistence,
    );
    await controller.send('写文件', cloudApproved: true, containerEnabled: true);
    expect(native.writes, 1);
    expect(native.files['/workspace/durable.md'], 'actual saved file');
    expect(requests, 1);
    expect(controller.tasks.single.status, TaskStatus.failed);
    expect(
      controller.containerActions.single.status,
      ContainerActionStatus.succeeded,
    );
    expect(controller.containerActions.single.output, contains('"ok":true'));
  });

  test('the twelfth model round cannot initiate more side effects', () async {
    final native = _Native();
    var requests = 0;
    final controller = await launch(
      native,
      MockClient((_) async {
        requests++;
        return _response(
          _tools(ApiProtocol.chatCompletions, [
            _call('loop-$requests', 'container_make_directory', {
              'path': '/workspace/directory-$requests',
            }),
          ]),
        );
      }),
    );
    await controller.send('循环请求', cloudApproved: true, containerEnabled: true);
    expect(requests, 12);
    expect(
      native.calls.where((method) => method == 'createLinuxDirectory'),
      hasLength(11),
    );
    expect(controller.tasks.single.status, TaskStatus.failed);
    expect(controller.error, contains('上限'));
  });
  test('an uncertain native write waits for a FIFO barrier and never asks the model to retry', () async {
    final native = _Native()
      ..loseWriteResponseOnce = true
      ..fileBarrierGate = Completer<void>();
    var requests = 0;
    final controller = await launch(
      native,
      MockClient((_) async {
        requests++;
        return _response(
          _tools(ApiProtocol.chatCompletions, [
            _call('uncertain-write', 'container_write_file', {
              'path': '/workspace/actual.md',
              'content': 'committed once',
              'create_only': true,
            }),
          ]),
        );
      }),
    );
    final sending = controller.send(
      '提交文件',
      cloudApproved: true,
      containerEnabled: true,
    );
    await native.fileBarrierEntered.future;
    expect(controller.isSending, isTrue);
    expect(controller.acquireManualTerminal, throwsStateError);
    expect(requests, 1);
    expect(native.writes, 1);
    native.fileBarrierGate!.complete();
    await sending;
    expect(native.files['/workspace/actual.md'], 'committed once');
    expect(native.writes, 1);
    expect(requests, 1);
    expect(
      controller.containerActions.single.status,
      ContainerActionStatus.interrupted,
    );
    expect(controller.tasks.single.status, TaskStatus.failed);
    expect(controller.tasks.single.hasUncertainSteps, isTrue);
    expect(controller.error, contains('核对实际工作区'));
  });
  for (final errorCode in [
    'linux_error',
    'busy',
    'storage_error',
    'invalid_path',
  ]) {
    test(
      'native FIFO barrier $errorCode acknowledges an uncertain write without retrying',
      () async {
        final native = _Native()
          ..loseWriteResponseOnce = true
          ..fileBarrierErrorCode = errorCode;
        var requests = 0;
        final controller = await launch(
          native,
          MockClient((_) async {
            requests++;
            return _response(
              _tools(ApiProtocol.chatCompletions, [
                _call('uncertain-write', 'container_write_file', {
                  'path': '/workspace/actual.md',
                  'content': 'committed once',
                  'create_only': true,
                }),
              ]),
            );
          }),
        );
        await controller
            .send('提交文件', cloudApproved: true, containerEnabled: true)
            .timeout(const Duration(seconds: 2));
        expect(native.files['/workspace/actual.md'], 'committed once');
        expect(native.writes, 1);
        expect(
          native.calls.where((method) => method == 'listLinuxDirectory'),
          hasLength(1),
        );
        expect(requests, 1);
        expect(
          controller.containerActions.single.status,
          ContainerActionStatus.interrupted,
        );
        expect(controller.tasks.single.status, TaskStatus.failed);
        expect(controller.tasks.single.hasUncertainSteps, isTrue);
        expect(controller.error, contains('核对实际工作区'));
        expect(controller.isSending, isFalse);
        expect(controller.isContainerTaskRunning, isFalse);
        final lease = controller.acquireManualTerminal();
        controller.releaseManualTerminal(lease);
      },
    );
  }
}
