// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:perant/src/application/container_browser_agent.dart';
import 'package:perant/src/application/container_task_runner.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant_core/perant_core.dart';
import 'package:perant_gateway/perant_gateway.dart';
import 'package:perant_platform/perant_platform.dart';

// A real 1x1 PNG fixture, not evidence of an Android WebView capture. Native
// device integration is responsible for verifying the genuine browser pixels.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jqQAAAABJRU5ErkJggg==',
);

final class _Browser implements ContainerBrowserAgent {
  @override
  bool modelHasControl = false;
  bool running = false;
  bool pageLoading = false;
  String pageError = '';
  int grants = 0, releases = 0, captures = 0, inputs = 0, saves = 0;
  final urls = <String>[];
  String? observationId;
  Uint8List? frameOverride;
  Completer<void>? captureGate;
  final captureEntered = Completer<void>();
  Completer<void>? saveGate;
  final saveEntered = Completer<void>();
  RuntimeBridgeException? saveFailure;
  @override
  void takeModelControl() {
    modelHasControl = true;
    observationId = null;
    grants++;
  }

  @override
  void releaseModelControl() {
    modelHasControl = false;
    observationId = null;
    releases++;
  }

  int scrollTop = 0;
  int pageHeight = 0;

  @override
  Future<void> open({required String url}) async {
    if (!modelHasControl) throw StateError('No browser grant');
    running = true;
    urls.add(url);
    observationId = null;
  }

  @override
  Future<ContainerBrowserObservation> observe() async {
    if (!modelHasControl || !running) throw StateError('No shared browser');
    captures++;
    if (!captureEntered.isCompleted) captureEntered.complete();
    await captureGate?.future;
    // Deliberately return a late frame even after takeover: runner must perform
    // its own post-await grant/cancellation check, beyond the real service's.
    observationId = 'browser-fixture-$captures';
    return ContainerBrowserObservation(
      id: observationId!,
      browserId: 'shared-browser',
      url: urls.isEmpty ? 'about:blank' : urls.last,
      title: 'Fixture page',
      revision: captures,
      width: 1,
      height: 1,
      png: frameOverride ?? _png,
      capturedAt: DateTime.now(),
      loading: pageLoading,
      error: pageError,
      scrollTop: scrollTop,
      pageHeight: pageHeight,
    );
  }

  @override
  Future<Map<String, Object?>> perform({
    required String observationId,
    required String action,
    int? x,
    int? y,
    int? deltaY,
    String? text,
    String? key,
    List<String> modifiers = const [],
  }) async {
    if (!modelHasControl || this.observationId != observationId) {
      throw StateError('Browser observation is stale or permission revoked');
    }
    inputs++;
    this.observationId = null;
    return {'url': urls.last, 'title': 'Fixture page', 'loading': false};
  }

  @override
  Future<Map<String, Object?>> savePage({required String observationId}) async {
    if (!modelHasControl || this.observationId != observationId) {
      throw StateError('Browser observation is stale or permission revoked');
    }
    this.observationId = null;
    if (!saveEntered.isCompleted) saveEntered.complete();
    await saveGate?.future;
    if (!modelHasControl) throw StateError('Browser permission revoked');
    if (saveFailure != null) throw saveFailure!;
    saves++;
    return {
      'path': '/workspace/web-11111111-2222-4333-8444-555555555555.md',
      'sha256': 'a' * 64,
      'size_bytes': 321,
      'source_url': urls.isEmpty ? 'https://example.invalid/page' : urls.last,
      'title': 'Fixture page',
      'truncated': true,
      'saved_at': '2026-11-14T01:00:00.000Z',
      'message': '已创建网页正文资料，不是完整归档或附件下载。',
    };
  }
}

final class _Persistence implements WorkspacePersistence {
  final memory = MemoryWorkspacePersistence();
  void Function(Map<String, Object?>)? onSave;
  @override
  String get description => memory.description;
  @override
  Future<WorkspaceState> load() => memory.load();
  @override
  Future<void> save(Map<String, Object?> snapshot) async {
    onSave?.call(snapshot);
    await memory.save(snapshot);
  }

  @override
  Future<void> close() => memory.close();
}

String _frame(Map<String, Object?> value) => 'data: ${jsonEncode(value)}\n\n';
http.Response _response(String body) => http.Response(
  body,
  200,
  headers: {'content-type': 'text/event-stream; charset=utf-8'},
);
String _turn(
  ApiProtocol protocol, {
  String? id,
  String? tool,
  Map<String, Object?> arguments = const {},
}) {
  if (protocol == ApiProtocol.chatCompletions) {
    return '${_frame({
      'choices': [
        {
          'index': 0,
          'delta': tool == null ? {'role': 'assistant', 'content': '请核对浏览器实际页面。'} : {
                  'role': 'assistant',
                  'reasoning_content': 'fixture-reasoning',
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': id,
                      'type': 'function',
                      'function': {'name': tool, 'arguments': jsonEncode(arguments)},
                    },
                  ],
                },
          'finish_reason': tool == null ? 'stop' : 'tool_calls',
        },
      ],
    })}data: [DONE]\n\n';
  }
  return _frame({
    'type': 'response.completed',
    'response': {
      'id': 'response-${id ?? 'final'}',
      'status': 'completed',
      'output': tool == null
          ? [
              {
                'id': 'final-message',
                'type': 'message',
                'role': 'assistant',
                'content': [
                  {'type': 'output_text', 'text': '请核对浏览器实际页面。'},
                ],
              },
            ]
          : [
              {
                'id': 'reasoning-$id',
                'type': 'reasoning',
                'summary': [],
                'encrypted_content': 'fixture-reasoning',
              },
              {
                'id': 'item-$id',
                'type': 'function_call',
                'call_id': id,
                'name': tool,
                'arguments': jsonEncode(arguments),
              },
            ],
    },
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var channel = 0;
  Future<WorkspaceController> launch(
    _Browser browser,
    http.Client client, {
    ApiProtocol protocol = ApiProtocol.chatCompletions,
    WorkspacePersistence? persistence,
  }) async {
    final methods = MethodChannel('dev.perant/browser-agent-test-${channel++}');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'getCapabilities')
        return {
          'schemaVersion': 1,
          'platform': 'android',
          'systemVersion': 'fixture',
          'nativeBridgeAvailable': true,
          'linux': {'available': true, 'reason': 'Fixture Linux baseline'},
          'localInference': {'available': false, 'reason': 'Not connected'},
          'backgroundTasks': {'available': false, 'reason': 'Not connected'},
        };
      if (call.method == 'getLinuxStatus')
        return {
          'supported': true,
          'installed': true,
          'active': false,
          'sessionId': null,
          'desktopSessionId': null,
          'desktopAvailable': false,
          'desktopVersion': 'not connected',
          'distribution': 'Alpine',
          'version': '3.24.4',
          'workspace': '/workspace',
          'reason': 'Fixture baseline',
        };
      throw StateError('No real native request expected: ${call.method}');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(methods, null));
    final controller = WorkspaceController(
      persistence: persistence ?? MemoryWorkspacePersistence(),
      credentials: MemoryCredentialStore(),
      gateway: OpenAiGateway(client: client),
      bridge: PerantPlatformBridge(methodChannel: methods),
      containerBrowser: browser,
    );
    await controller.initialize();
    await controller.configure(
      ProviderProfile(
        id: 'browser-provider',
        displayName: 'Fixture provider',
        baseUrl: Uri.parse('https://example.invalid/v1'),
        protocol: protocol,
        modelId: 'fixture-vision',
        storageKeyRef: 'credential:fixture-browser',
      ),
      'fixture-not-a-real-api-key',
    );
    addTearDown(controller.dispose);
    addTearDown(client.close);
    return controller;
  }

  for (final protocol in ApiProtocol.values) {
    test(
      '$protocol browser uses PNG vision input and preserves receipts',
      () async {
        final browser = _Browser();
        final payloads = <Map<String, Object?>>[];
        var requests = 0;
        final controller = await launch(
          browser,
          MockClient((request) async {
            payloads.add(jsonDecode(request.body) as Map<String, Object?>);
            return _response(switch (requests++) {
              0 => _turn(
                protocol,
                id: 'open',
                tool: 'browser_open',
                arguments: {'url': 'https://example.invalid/page'},
              ),
              1 => _turn(protocol, id: 'capture-1', tool: 'browser_capture'),
              2 => _turn(
                protocol,
                id: 'tap',
                tool: 'browser_action',
                arguments: {
                  'observation_id': 'browser-fixture-1',
                  'action': 'tap',
                  'x': 0,
                  'y': 0,
                },
              ),
              3 => _turn(protocol, id: 'capture-2', tool: 'browser_capture'),
              _ => _turn(protocol),
            });
          }),
          protocol: protocol,
        );
        await controller.send(
          'browser-private-task 读取公开网页',
          cloudApproved: true,
          containerEnabled: true,
        );
        expect(requests, 5);
        expect(browser.urls, ['https://example.invalid/page']);
        expect(browser.inputs, 1);
        // The input receipt carries its own follow-up observation, so the
        // scripted second capture is the third one taken.
        expect(browser.captures, 3);
        expect(jsonEncode(payloads[3]), contains('随附约一秒后的新画面'));
        expect(browser.running, isTrue);
        expect(browser.modelHasControl, isFalse);
        expect(browser.grants, 1);
        expect(controller.tasks.single.status, TaskStatus.completed);
        expect(
          controller.containerActions.every(
            (a) => a.status == ContainerActionStatus.succeeded,
          ),
          isTrue,
        );
        final inputKey = protocol == ApiProtocol.responses
            ? 'input'
            : 'messages';
        final imageType = protocol == ApiProtocol.responses
            ? 'input_image'
            : 'image_url';
        List<Map> pictures(Map<String, Object?> payload) =>
            (payload[inputKey]! as List)
                .whereType<Map>()
                .expand(
                  (m) => m['content'] is List ? m['content'] as List : const [],
                )
                .whereType<Map>()
                .where((part) => part['type'] == imageType)
                .toList();
        final first = pictures(payloads[2]).single;
        final url = protocol == ApiProtocol.responses
            ? first['image_url']
            : (first['image_url'] as Map)['url'];
        expect(url, 'data:image/png;base64,${base64Encode(_png)}');
        expect(
          jsonEncode(payloads[2]),
          contains('Tool observation data from browser_capture;'),
        );
        expect(
          jsonEncode(payloads[2]),
          isNot(contains('Tool observation data from desktop_capture;')),
        );
        expect(pictures(payloads[4]), hasLength(1));
        final finalInput = payloads[4][inputKey]! as List;
        final imageMessage = finalInput.whereType<Map>().singleWhere(
          (m) =>
              m['content'] is List &&
              (m['content'] as List).whereType<Map>().any(
                (p) => p['type'] == imageType,
              ),
        );
        expect(jsonEncode(imageMessage), contains('browser-fixture-3'));
        expect(jsonEncode(imageMessage), isNot(contains('browser-fixture-1')));
        final receiptKey = protocol == ApiProtocol.responses
            ? 'call_id'
            : 'tool_call_id';
        for (final id in ['capture-1', 'capture-2']) {
          expect(
            finalInput.whereType<Map>().where(
              (m) =>
                  m[receiptKey] == id &&
                  (m['role'] == 'tool' || m['type'] == 'function_call_output'),
            ),
            hasLength(1),
          );
        }
        expect(jsonEncode(finalInput), contains('fixture-reasoning'));
        expect(
          jsonEncode(controller.state.toJson()),
          isNot(contains('data:image/png')),
        );
        await controller.send('普通聊天', cloudApproved: true);
        expect(jsonEncode(payloads.last), isNot(contains('data:image/png')));
        expect(
          jsonEncode(payloads.last),
          isNot(contains('browser-private-task')),
        );
        expect(browser.grants, 1);
      },
    );
  }

  for (final protocol in ApiProtocol.values) {
    test(
      '$protocol saves a page and durably preserves the actual file receipt',
      () async {
        final browser = _Browser()..running = true;
        final persistence = MemoryWorkspacePersistence();
        final payloads = <Map<String, Object?>>[];
        var requests = 0;
        final controller = await launch(
          browser,
          MockClient((request) async {
            payloads.add(jsonDecode(request.body) as Map<String, Object?>);
            return _response(switch (requests++) {
              0 => _turn(
                protocol,
                id: 'observe-for-save',
                tool: 'browser_capture',
              ),
              1 => _turn(
                protocol,
                id: 'save-page',
                tool: 'browser_save_page',
                arguments: {'observation_id': 'browser-fixture-1'},
              ),
              _ => _turn(protocol),
            });
          }),
          protocol: protocol,
          persistence: persistence,
        );
        await controller.send(
          '将当前网页整理为本地参考资料',
          cloudApproved: true,
          containerEnabled: true,
        );
        expect(requests, 3);
        expect(browser.saves, 1);
        expect(browser.inputs, 0);
        expect(browser.running, isTrue);
        expect(controller.tasks.single.status, TaskStatus.completed);
        final inputKey = protocol == ApiProtocol.responses
            ? 'input'
            : 'messages';
        final receiptKey = protocol == ApiProtocol.responses
            ? 'call_id'
            : 'tool_call_id';
        final resultKey = protocol == ApiProtocol.responses
            ? 'output'
            : 'content';
        final receiptMessage = (payloads.last[inputKey] as List)
            .whereType<Map>()
            .singleWhere(
              (message) =>
                  message[receiptKey] == 'save-page' &&
                  (message['role'] == 'tool' ||
                      message['type'] == 'function_call_output'),
            );
        final receipt = jsonDecode(receiptMessage[resultKey] as String) as Map;
        expect(receipt['ok'], isTrue);
        expect(
          receipt['path'],
          '/workspace/web-11111111-2222-4333-8444-555555555555.md',
        );
        expect(receipt['size_bytes'], 321);
        expect(receipt['sha256'], 'a' * 64);
        expect(receipt['truncated'], isTrue);
        expect(receipt['source_url'], 'https://example.invalid/page');
        expect(receipt, isNot(contains('text')));
        final loaded = await persistence.load();
        final savedAction = loaded.containerActions.singleWhere(
          (a) => a.tool == 'browser_save_page',
        );
        expect(savedAction.status, ContainerActionStatus.succeeded);
        expect(jsonDecode(savedAction.output!)['path'], receipt['path']);
        expect(jsonDecode(savedAction.output!)['sha256'], receipt['sha256']);
        final savedStep = loaded.tasks.single.steps.singleWhere(
          (s) => s.id == savedAction.id,
        );
        expect(savedStep.hasSideEffects, isTrue);
        final tool = containerTools.singleWhere(
          (tool) => tool.name == 'browser_save_page',
        );
        expect((tool.parameters['properties'] as Map).keys, ['observation_id']);
        expect(tool.parameters['additionalProperties'], isFalse);
      },
    );
  }

  test(
    'error page PNG is an observation, not a successful navigation receipt',
    () async {
      final browser = _Browser()..pageError = '网页证书校验失败。';
      final payloads = <Map<String, Object?>>[];
      var requests = 0;
      final protocol = ApiProtocol.chatCompletions;
      final controller = await launch(
        browser,
        MockClient((request) async {
          payloads.add(jsonDecode(request.body) as Map<String, Object?>);
          return _response(switch (requests++) {
            0 => _turn(
              protocol,
              id: 'open-error-page',
              tool: 'browser_open',
              arguments: {'url': 'https://example.invalid/error'},
            ),
            1 => _turn(
              protocol,
              id: 'observe-error-page',
              tool: 'browser_capture',
            ),
            _ => _turn(protocol),
          });
        }),
      );
      await controller.send(
        '检查网页是否能打开',
        cloudApproved: true,
        containerEnabled: true,
      );
      Map<String, Object?> receipt(Map<String, Object?> request, String id) {
        final message = (request['messages']! as List)
            .whereType<Map>()
            .singleWhere(
              (message) =>
                  message['role'] == 'tool' && message['tool_call_id'] == id,
            );
        return jsonDecode(message['content']! as String)
            as Map<String, Object?>;
      }

      final opened = receipt(payloads[1], 'open-error-page');
      expect(opened['navigation_requested'], isTrue);
      expect(opened['message'], contains('不表示页面已加载'));
      final observed = receipt(payloads[2], 'observe-error-page');
      expect(observed['ok'], isTrue); // The screenshot itself succeeded.
      expect(observed['error'], '网页证书校验失败。');
      expect(observed['loading'], isFalse);
      expect(observed['page_loaded'], isFalse);
      expect(observed['message'], contains('仅表示已取得截图'));
      expect(
        jsonEncode(payloads[2]),
        contains('data:image/png;base64,${base64Encode(_png)}'),
      );
      expect(browser.captures, 1);
    },
  );

  test('ordinary chat cannot grant browser tools', () async {
    final browser = _Browser();
    final controller = await launch(
      browser,
      MockClient(
        (_) async => _response(
          _turn(
            ApiProtocol.chatCompletions,
            id: 'unrequested',
            tool: 'browser_save_page',
            arguments: {'observation_id': 'unsolicited'},
          ),
        ),
      ),
    );
    await controller.send('普通问题', cloudApproved: true);
    expect(browser.grants, 0);
    expect(browser.captures, 0);
    expect(browser.saves, 0);
    expect(controller.containerActions, isEmpty);
  });

  test('page save task without explicit cloud approval has no native or API effects', () async {
    final browser = _Browser()..running = true;
    var requests = 0;
    final controller = await launch(
      browser,
      MockClient((_) async {
        requests++;
        return _response(_turn(ApiProtocol.chatCompletions));
      }),
    );
    await expectLater(
      controller.send('保存当前网页', cloudApproved: false, containerEnabled: true),
      throwsStateError,
    );
    expect(requests, 0);
    expect(browser.grants, 0);
    expect(browser.captures, 0);
    expect(browser.saves, 0);
    expect(controller.containerActions, isEmpty);
  });

  test(
    'page save rejects stale, repeated and extra-argument observations',
    () async {
      final browser = _Browser()..running = true;
      final runner = ContainerTaskRunner(
        PerantPlatformBridge(),
        browser: browser,
      );
      runner.takeModelControl();
      addTearDown(runner.dispose);
      Future<ContainerToolResult> execute(
        String name,
        Map<String, Object?> arguments,
      ) => runner.execute(
        call: GatewayToolCall(
          id: 'save-validation',
          name: name,
          arguments: jsonEncode(arguments),
        ),
        executionId: 'unused',
        cancellation: GatewayCancellation(),
        approveCommand: null,
        onPhase: (_) async {},
      );
      await execute('browser_capture', {});
      for (final arguments in [
        <String, Object?>{},
        {'observation_id': ''},
        {'observation_id': 'x' * 161},
        {
          'observation_id': 'browser-fixture-1',
          'path': '/workspace/replace.md',
        },
      ]) {
        await expectLater(
          execute('browser_save_page', arguments),
          throwsA(isA<ContainerTaskFailure>()),
        );
      }
      await expectLater(
        execute('browser_save_page', {'observation_id': 'old-page'}),
        throwsStateError,
      );
      expect(browser.saves, 0);
      final saved = await execute('browser_save_page', {
        'observation_id': 'browser-fixture-1',
      });
      expect(saved.data['ok'], isTrue);
      expect(browser.saves, 1);
      await expectLater(
        execute('browser_save_page', {'observation_id': 'browser-fixture-1'}),
        throwsStateError,
      );
      expect(browser.saves, 1);
      expect(browser.running, isTrue);
    },
  );

  test('stale observation cannot send browser input', () async {
    final browser = _Browser()..running = true;
    var requests = 0;
    final controller = await launch(
      browser,
      MockClient(
        (_) async => _response(switch (requests++) {
          0 => _turn(
            ApiProtocol.chatCompletions,
            id: 'capture',
            tool: 'browser_capture',
          ),
          1 => _turn(
            ApiProtocol.chatCompletions,
            id: 'stale',
            tool: 'browser_action',
            arguments: {
              'observation_id': 'old-page',
              'action': 'key',
              'key': 'enter',
            },
          ),
          _ => _turn(ApiProtocol.chatCompletions),
        }),
      ),
    );
    await controller.send('读取页面', cloudApproved: true, containerEnabled: true);
    expect(browser.inputs, 0);
    expect(controller.tasks.single.status, TaskStatus.failed);
    expect(
      controller.containerActions.first.status,
      ContainerActionStatus.failed,
    );
  });

  for (final cancelTask in [true, false]) {
    test(
      '${cancelTask ? 'cancellation' : 'takeover'} blocks a pending page save before file creation',
      () async {
        final browser = _Browser()
          ..running = true
          ..saveGate = Completer<void>();
        var requests = 0;
        final controller = await launch(
          browser,
          MockClient(
            (_) async => _response(switch (requests++) {
              0 => _turn(
                ApiProtocol.chatCompletions,
                id: 'observe',
                tool: 'browser_capture',
              ),
              1 => _turn(
                ApiProtocol.chatCompletions,
                id: 'pending-save',
                tool: 'browser_save_page',
                arguments: {'observation_id': 'browser-fixture-1'},
              ),
              _ => _turn(ApiProtocol.chatCompletions),
            }),
          ),
        );
        final sending = controller.send(
          '保存网页',
          cloudApproved: true,
          containerEnabled: true,
        );
        await browser.saveEntered.future;
        if (cancelTask) {
          controller.cancelActiveTask();
        } else {
          browser.releaseModelControl();
        }
        browser.saveGate!.complete();
        await sending;
        expect(requests, 2);
        expect(browser.saves, 0);
        expect(browser.running, isTrue);
        expect(browser.modelHasControl, isFalse);
        expect(controller.tasks.single.status, TaskStatus.cancelled);
      },
    );
  }

  test('a page save with an uncertain native result waits for FIFO and never retries', () async {
    final browser = _Browser()
      ..running = true
      ..saveFailure = const RuntimeBridgeException(
        code: 'timeout',
        message: 'Fixture native import timed out',
      );
    final methods = MethodChannel(
      'dev.perant/browser-save-uncertain-${channel++}',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var barriers = 0;
    messenger.setMockMethodCallHandler(methods, (call) async {
      expect(call.method, 'listLinuxDirectory');
      barriers++;
      throw PlatformException(
        code: 'busy',
        message: 'Desktop remains active; prior queued import completed.',
      );
    });
    addTearDown(() => messenger.setMockMethodCallHandler(methods, null));
    final runner = ContainerTaskRunner(
      PerantPlatformBridge(methodChannel: methods),
      browser: browser,
    );
    runner.takeModelControl();
    addTearDown(runner.dispose);
    final observation = await browser.observe();
    await expectLater(
      runner.execute(
        call: GatewayToolCall(
          id: 'uncertain-save',
          name: 'browser_save_page',
          arguments: jsonEncode({'observation_id': observation.id}),
        ),
        executionId: 'unused',
        cancellation: GatewayCancellation(),
        approveCommand: null,
        onPhase: (_) async {},
      ),
      throwsA(
        isA<ContainerTaskFailure>().having(
          (failure) => failure.uncertain,
          'uncertain',
          isTrue,
        ),
      ),
    );
    expect(barriers, 1);
    expect(browser.saves, 0);
    expect(browser.observationId, isNull);
    expect(browser.running, isTrue);
  });

  test('failed page-save receipt persistence stops HTTP without retrying the created file', () async {
    final browser = _Browser()..running = true;
    final persistence = _Persistence();
    var requests = 0;
    final controller = await launch(
      browser,
      MockClient(
        (_) async => _response(switch (requests++) {
          0 => _turn(
            ApiProtocol.chatCompletions,
            id: 'observe',
            tool: 'browser_capture',
          ),
          1 => _turn(
            ApiProtocol.chatCompletions,
            id: 'save-page',
            tool: 'browser_save_page',
            arguments: {'observation_id': 'browser-fixture-1'},
          ),
          _ => _turn(ApiProtocol.chatCompletions),
        }),
      ),
      persistence: persistence,
    );
    persistence.onSave = (snapshot) {
      if (jsonEncode(snapshot)
          .contains('/workspace/web-11111111-2222-4333-8444-555555555555.md')) {
        throw StateError('Fixture SQLite write failed after file creation');
      }
    };
    await controller.send('保存网页', cloudApproved: true, containerEnabled: true);
    expect(browser.saves, 1);
    expect(requests, 2);
    expect(browser.running, isTrue);
    expect(controller.tasks.single.status, isNot(TaskStatus.completed));
    expect(controller.error, contains('本地保存失败'));
  });

  for (final cancelTask in [true, false]) {
    test(
      '${cancelTask ? 'cancellation' : 'takeover'} blocks a late browser capture before HTTP',
      () async {
        final browser = _Browser()
          ..running = true
          ..captureGate = Completer<void>();
        var requests = 0;
        final controller = await launch(
          browser,
          MockClient((_) async {
            requests++;
            return _response(
              _turn(
                ApiProtocol.chatCompletions,
                id: 'capture',
                tool: 'browser_capture',
              ),
            );
          }),
        );
        final sending = controller.send(
          '临时观察',
          cloudApproved: true,
          containerEnabled: true,
        );
        await browser.captureEntered.future;
        if (cancelTask) {
          controller.cancelActiveTask();
        } else {
          browser.releaseModelControl();
        }
        browser.captureGate!.complete();
        await sending;
        expect(requests, 1);
        expect(browser.inputs, 0);
        expect(browser.running, isTrue);
        expect(browser.modelHasControl, isFalse);
        expect(controller.tasks.single.status, TaskStatus.cancelled);
      },
    );
  }

  test(
    'takeover during receipt persistence prevents screenshot upload',
    () async {
      final browser = _Browser()..running = true;
      final persistence = _Persistence();
      var requests = 0, revocations = 0;
      final controller = await launch(
        browser,
        MockClient((_) async {
          requests++;
          return _response(
            _turn(
              ApiProtocol.chatCompletions,
              id: 'capture',
              tool: 'browser_capture',
            ),
          );
        }),
        persistence: persistence,
      );
      persistence.onSave = (snapshot) {
        if (revocations == 0 &&
            jsonEncode(snapshot).contains('image_follows')) {
          revocations++;
          browser.releaseModelControl();
        }
      };
      await controller.send(
        '观察页面',
        cloudApproved: true,
        containerEnabled: true,
      );
      expect(revocations, 1);
      expect(requests, 1);
      expect(controller.tasks.single.status, TaskStatus.cancelled);
    },
  );

  test('browser URL and image validation reject unsupported inputs before side effects', () async {
    final browser = _Browser()..running = true;
    final runner = ContainerTaskRunner(
      PerantPlatformBridge(),
      browser: browser,
    );
    runner.takeModelControl();
    addTearDown(runner.dispose);
    Future<ContainerToolResult> execute(
      String name,
      Map<String, Object?> args,
    ) => runner.execute(
      call: GatewayToolCall(
        id: 'validation',
        name: name,
        arguments: jsonEncode(args),
      ),
      executionId: 'unused',
      cancellation: GatewayCancellation(),
      approveCommand: null,
      onPhase: (_) async {},
    );
    for (final url in [
      'javascript:alert(1)',
      'file:///workspace/private',
      'data:text/html,hello',
      'https://user:password@example.invalid',
      'http://@example.invalid',
      'https://example.invalid/\n',
      'about:config',
    ]) {
      await expectLater(
        execute('browser_open', {'url': url}),
        throwsA(isA<ContainerTaskFailure>()),
      );
    }
    expect(browser.urls, isEmpty);
    await execute('browser_open', {'url': 'about:blank'});
    expect(browser.urls, ['about:blank']);
    browser.frameOverride = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
    await expectLater(
      execute('browser_capture', {}),
      throwsA(isA<ContainerTaskFailure>()),
    );
    browser.frameOverride = Uint8List(2097153)..setRange(0, 8, _png);
    await expectLater(
      execute('browser_capture', {}),
      throwsA(isA<ContainerTaskFailure>()),
    );
    await expectLater(
      execute('browser_close', {}),
      throwsA(isA<ContainerTaskFailure>()),
    );
    expect(browser.running, isTrue);
  });
  test('browser screenshots report where they sit in the page', () async {
    for (final known in [true, false]) {
      final browser = _Browser()
        ..running = true
        ..scrollTop = known ? 7800 : 0
        ..pageHeight = known ? 7801 : 0;
      final payloads = <Map<String, Object?>>[];
      var requests = 0;
      final controller = await launch(
        browser,
        MockClient((request) async {
          payloads.add(jsonDecode(request.body) as Map<String, Object?>);
          return _response(switch (requests++) {
            0 => _turn(
              ApiProtocol.chatCompletions,
              id: 'capture',
              tool: 'browser_capture',
            ),
            _ => _turn(ApiProtocol.chatCompletions),
          });
        }),
      );
      await controller.send(
        '看一下页面',
        cloudApproved: true,
        containerEnabled: true,
      );
      final receipt = (payloads.last['messages']! as List)
          .whereType<Map>()
          .lastWhere((message) => message['role'] == 'tool');
      final data = jsonDecode(receipt['content'] as String) as Map;
      if (known) {
        expect(data['scroll_top'], 7800);
        expect(data['page_height'], 7801);
        expect(data['at_top'], isFalse);
        // The one-pixel fixture frame ends at the last page pixel.
        expect(data['at_bottom'], isTrue);
      } else {
        // Unknown geometry is omitted, never reported as "at the top".
        for (final key in [
          'scroll_top',
          'page_height',
          'at_top',
          'at_bottom',
        ]) {
          expect(data.containsKey(key), isFalse);
        }
      }
    }
  });
}
