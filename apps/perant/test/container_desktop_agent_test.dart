// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:perant/src/application/container_desktop_agent.dart';
import 'package:perant/src/application/screenshot_grid.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant_core/perant_core.dart';
import 'package:perant_gateway/perant_gateway.dart';
import 'package:perant_platform/perant_platform.dart';

// This is a fixture PNG, not evidence of a real Android Xvnc screen. Device
// integration verifies the genuine RFB framebuffer independently.
final _fixturePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jqQAAAABJRU5ErkJggg==',
);

final class _Desktop implements ContainerDesktopAgent {
  @override
  bool modelHasControl = false;
  bool running = true;
  int starts = 0;
  int stops = 0;
  int captures = 0;
  int inputSent = 0;
  int grants = 0;
  int releases = 0;
  String? observation;
  Completer<void>? inputGate;
  final inputEntered = Completer<void>();
  final actions = <String>[];
  @override
  void takeModelControl() {
    modelHasControl = true;
    grants++;
    observation = null;
  }

  @override
  void releaseModelControl() {
    modelHasControl = false;
    releases++;
    observation = null;
  }

  @override
  Future<LinuxDesktopSession> start({
    int width = 1024,
    int height = 640,
  }) async {
    if (!modelHasControl) throw StateError('No desktop permission');
    starts++;
    running = true;
    return LinuxDesktopSession(
      sessionId: 'fixture-desktop',
      pid: 42,
      socketPath: '/data/user/0/dev.perant.perant/cache/g/aabbccdd/rfb.sock',
      width: width,
      height: height,
      display: 1234,
    );
  }

  @override
  Future<ContainerDesktopObservation> observe() async {
    if (!modelHasControl || !running) throw StateError('No live desktop');
    observation = 'fixture-observation-${++captures}';
    return ContainerDesktopObservation(
      id: observation!,
      width: 1024,
      height: 640,
      png: Uint8List.fromList(_fixturePng),
      capturedAt: DateTime.utc(2026, 11, 13, 8, captures),
    );
  }

  @override
  Future<Map<String, Object?>> perform({
    required String observationId,
    required String action,
    int? x,
    int? y,
    int? toX,
    int? toY,
    String? text,
    String? key,
    List<String> modifiers = const [],
    String button = 'left',
  }) async {
    if (!modelHasControl || observation != observationId)
      throw StateError('Observation is stale or user took control');
    if (!inputEntered.isCompleted) inputEntered.complete();
    await inputGate?.future;
    // A pending connection/gesture must check the current grant again after
    // asynchronous work. A cancelled task cannot acquire late input rights.
    if (!modelHasControl || observation != observationId)
      throw StateError('Input permission revoked');
    inputSent++;
    actions.add(action);
    observation = null;
    return {'ok': true, 'action': action, 'observation_id': observationId};
  }

  @override
  Future<void> stop() async {
    if (!modelHasControl) throw StateError('No desktop permission');
    stops++;
    running = false;
    observation = null;
  }
}

String _frame(Map<String, Object?> data) => 'data: ${jsonEncode(data)}\n\n';
http.Response _response(String body) => http.Response(
  body,
  200,
  headers: {'content-type': 'text/event-stream; charset=utf-8'},
);
String _tool(
  ApiProtocol protocol,
  String id,
  String name,
  Map<String, Object?> args,
) {
  final arguments = jsonEncode(args);
  return protocol == ApiProtocol.chatCompletions
      ? '${_frame({
          'choices': [
            {
              'index': 0,
              'delta': {
                'role': 'assistant',
                'reasoning_content': 'preserve-reasoning',
                'tool_calls': [
                  {
                    'index': 0,
                    'id': id,
                    'type': 'function',
                    'function': {'name': name, 'arguments': arguments},
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        })}data: [DONE]\n\n'
      : _frame({
          'type': 'response.completed',
          'response': {
            'id': 'response-$id',
            'status': 'completed',
            'output': [
              {
                'id': 'reasoning-$id',
                'type': 'reasoning',
                'summary': [],
                'encrypted_content': 'preserve-reasoning',
              },
              {
                'id': 'item-$id',
                'type': 'function_call',
                'call_id': id,
                'name': name,
                'arguments': arguments,
              },
            ],
          },
        });
}

String _text(ApiProtocol protocol) => protocol == ApiProtocol.chatCompletions
    ? '${_frame({
        'choices': [
          {
            'index': 0,
            'delta': {'role': 'assistant', 'content': '桌面操作已结束，请核对实际画面。'},
            'finish_reason': 'stop',
          },
        ],
      })}data: [DONE]\n\n'
    : '${_frame({'type': 'response.output_text.delta', 'delta': '桌面操作已结束，请核对实际画面。'})}${_frame({
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
                {'type': 'output_text', 'text': '桌面操作已结束，请核对实际画面。'},
              ],
            },
          ],
        },
      })}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var sequence = 0;
  Future<WorkspaceController> launch(
    _Desktop desktop,
    http.Client client, {
    ApiProtocol protocol = ApiProtocol.chatCompletions,
    ScreenshotAnnotator annotator = plainScreenshot,
  }) async {
    final methods = MethodChannel(
      'dev.perant/desktop-agent-test-${sequence++}',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case 'getCapabilities':
          return {
            'schemaVersion': 1,
            'platform': 'android',
            'systemVersion': 'test fixture',
            'nativeBridgeAvailable': true,
            'linux': {'available': true, 'reason': 'Test fixture'},
            'localInference': {'available': false, 'reason': 'Not connected'},
            'backgroundTasks': {'available': false, 'reason': 'Not connected'},
          };
        case 'listLinuxDirectory':
          throw PlatformException(
            code: 'busy',
            message: 'Fixture desktop owns the shared workspace.',
          );
        case 'getLinuxStatus':
          return {
            'supported': true,
            'installed': true,
            'active': desktop.running,
            'sessionId': null,
            'desktopAvailable': true,
            'desktopVersion': 'Fixture Xvnc',
            'desktopSessionId': desktop.running ? 'fixture-desktop' : null,
            'distribution': 'Alpine',
            'version': '3.24.4',
            'workspace': '/workspace',
            'reason': 'Test fixture',
          };
        default:
          throw StateError(
            'No native process should be started by the fixture: ${call.method}',
          );
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(methods, null));
    final controller = WorkspaceController(
      persistence: MemoryWorkspacePersistence(),
      credentials: MemoryCredentialStore(),
      gateway: OpenAiGateway(client: client),
      bridge: PerantPlatformBridge(methodChannel: methods),
      containerDesktop: desktop,
      screenshotAnnotator: annotator,
    );
    await controller.initialize();
    await controller.configure(
      ProviderProfile(
        id: 'desktop-provider',
        displayName: 'Fixture provider',
        baseUrl: Uri.parse('https://example.invalid/v1'),
        protocol: protocol,
        modelId: 'fixture-vision-model',
        storageKeyRef: 'credential:fixture-desktop',
      ),
      'test-only-not-a-real-key',
    );
    addTearDown(controller.dispose);
    addTearDown(client.close);
    return controller;
  }

  for (final protocol in ApiProtocol.values) {
    test(
      '$protocol emits true vision image input, retains call receipts and drops old screenshots',
      () async {
        final desktop = _Desktop();
        final payloads = <Map<String, Object?>>[];
        var requests = 0;
        final controller = await launch(
          desktop,
          MockClient((request) async {
            payloads.add(jsonDecode(request.body) as Map<String, Object?>);
            return _response(switch (requests++) {
              0 => _tool(protocol, 'start-1', 'desktop_start', {}),
              1 => _tool(protocol, 'capture-1', 'desktop_capture', {}),
              2 => _tool(protocol, 'action-1', 'desktop_action', {
                'observation_id': 'fixture-observation-1',
                'action': 'click',
                'x': 25,
                'y': 42,
              }),
              3 => _tool(protocol, 'capture-2', 'desktop_capture', {}),
              _ => _text(protocol),
            });
          }),
          protocol: protocol,
        );
        await controller.send(
          'desktop-private-task 请操作图形桌面',
          cloudApproved: true,
          containerEnabled: true,
          approveContainerCommand: (_) async => throw StateError(
            'Task-authorized GUI input must not invoke the arbitrary-shell callback',
          ),
        );
        expect(payloads, hasLength(5));
        expect(desktop.starts, 1);
        // The input receipt carries its own follow-up observation, so the
        // scripted second capture is the third one taken.
        expect(desktop.captures, 3);
        expect(jsonEncode(payloads[3]), contains('随附约一秒后的新画面'));
        expect(desktop.inputSent, 1);
        expect(desktop.actions, ['click']);
        expect(desktop.running, isTrue);
        expect(desktop.modelHasControl, isFalse);
        expect(desktop.grants, 1);
        expect(controller.tasks.single.status, TaskStatus.completed);
        expect(controller.containerActions, hasLength(4));
        expect(
          controller.containerActions.every(
            (action) => action.status == ContainerActionStatus.succeeded,
          ),
          isTrue,
        );
        final inputKey = protocol == ApiProtocol.responses
            ? 'input'
            : 'messages';
        final expectedType = protocol == ApiProtocol.responses
            ? 'input_image'
            : 'image_url';
        List<Map> imageParts(Map<String, Object?> payload) =>
            (payload[inputKey]! as List)
                .whereType<Map>()
                .expand(
                  (message) => message['content'] is List
                      ? message['content'] as List
                      : const [],
                )
                .whereType<Map>()
                .where((part) => part['type'] == expectedType)
                .toList();
        final firstImage = imageParts(payloads[2]).single;
        final imageUrl = protocol == ApiProtocol.responses
            ? firstImage['image_url']
            : (firstImage['image_url'] as Map)['url'];
        expect(imageUrl, 'data:image/png;base64,${base64Encode(_fixturePng)}');
        expect(jsonEncode(payloads[2]), contains('fixture-observation-1'));
        expect(imageParts(payloads[4]), hasLength(1));
        final finalInput = payloads[4][inputKey]! as List;
        final imageMessage = finalInput.whereType<Map>().singleWhere(
          (message) =>
              message['content'] is List &&
              (message['content'] as List).whereType<Map>().any(
                (part) => part['type'] == expectedType,
              ),
        );
        expect(jsonEncode(imageMessage), contains('fixture-observation-3'));
        expect(
          jsonEncode(imageMessage),
          isNot(contains('fixture-observation-1')),
        );
        final receiptKey = protocol == ApiProtocol.responses
            ? 'call_id'
            : 'tool_call_id';
        expect(
          finalInput.whereType<Map>().where(
            (message) =>
                message[receiptKey] == 'capture-1' &&
                (message['role'] == 'tool' ||
                    message['type'] == 'function_call_output'),
          ),
          hasLength(1),
        );
        expect(
          finalInput.whereType<Map>().where(
            (message) =>
                message[receiptKey] == 'capture-2' &&
                (message['role'] == 'tool' ||
                    message['type'] == 'function_call_output'),
          ),
          hasLength(1),
        );
        expect(jsonEncode(finalInput), contains('preserve-reasoning'));
        expect(
          jsonEncode(controller.state.toJson()),
          isNot(contains('data:image/png')),
        );
        await controller.send('普通聊天', cloudApproved: true);
        expect(jsonEncode(payloads.last), isNot(contains('data:image/png')));
        expect(
          jsonEncode(payloads.last),
          isNot(contains('desktop-private-task')),
        );
        expect(payloads.last.containsKey('tools'), isFalse);
        await controller.send(
          '另一个授权桌面任务',
          cloudApproved: true,
          containerEnabled: true,
        );
        expect(jsonEncode(payloads.last), isNot(contains('data:image/png')));
      },
    );
  }

  test(
    'ordinary chat never grants desktop control or captures a screen',
    () async {
      final desktop = _Desktop();
      final controller = await launch(
        desktop,
        MockClient(
          (_) async => _response(
            _tool(
              ApiProtocol.chatCompletions,
              'unsolicited',
              'desktop_capture',
              {},
            ),
          ),
        ),
      );
      await controller.send('普通问题', cloudApproved: true);
      expect(desktop.grants, 0);
      expect(desktop.captures, 0);
      expect(desktop.inputSent, 0);
      expect(controller.containerActions, isEmpty);
      expect(controller.tasks.single.status, TaskStatus.failed);
    },
  );

  test('cancellation revokes a pending GUI input before connection completion and leaves desktop running', () async {
    final desktop = _Desktop()..inputGate = Completer<void>();
    var requests = 0;
    final controller = await launch(
      desktop,
      MockClient(
        (_) async => _response(switch (requests++) {
          0 => _tool(
            ApiProtocol.chatCompletions,
            'capture',
            'desktop_capture',
            {},
          ),
          _ => _tool(ApiProtocol.chatCompletions, 'type', 'desktop_action', {
            'observation_id': 'fixture-observation-1',
            'action': 'type',
            'text': 'must-not-type-after-cancel',
          }),
        }),
      ),
    );
    final sending = controller.send(
      '临时操作',
      cloudApproved: true,
      containerEnabled: true,
    );
    await desktop.inputEntered.future;
    controller.cancelActiveTask();
    expect(desktop.modelHasControl, isFalse);
    expect(controller.isSending, isTrue);
    desktop.inputGate!.complete();
    await sending;
    expect(desktop.inputSent, 0);
    expect(desktop.running, isTrue);
    expect(desktop.stops, 0);
    expect(requests, 2);
    expect(controller.tasks.single.status, TaskStatus.cancelled);
    expect(
      controller.containerActions.first.status,
      ContainerActionStatus.cancelled,
    );
  });

  test('stale screenshot identifiers cannot authorize GUI input', () async {
    final desktop = _Desktop();
    var requests = 0;
    final controller = await launch(
      desktop,
      MockClient(
        (_) async => _response(switch (requests++) {
          0 => _tool(
            ApiProtocol.chatCompletions,
            'capture',
            'desktop_capture',
            {},
          ),
          1 => _tool(ApiProtocol.chatCompletions, 'stale', 'desktop_action', {
            'observation_id': 'previous-task-picture',
            'action': 'key',
            'key': 'Return',
          }),
          _ => _text(ApiProtocol.chatCompletions),
        }),
      ),
    );
    await controller.send('过期画面', cloudApproved: true, containerEnabled: true);
    expect(desktop.inputSent, 0);
    expect(
      controller.containerActions.first.status,
      ContainerActionStatus.failed,
    );
    expect(controller.tasks.single.status, TaskStatus.failed);
  });

  test('desktop stop requires a concrete shutdown confirmation and denial retains live applications', () async {
    final desktop = _Desktop();
    var requests = 0;
    String? prompt;
    final controller = await launch(
      desktop,
      MockClient(
        (_) async => _response(
          requests++ == 0
              ? _tool(ApiProtocol.chatCompletions, 'stop', 'desktop_stop', {})
              : _text(ApiProtocol.chatCompletions),
        ),
      ),
    );
    await controller.send(
      '关闭桌面',
      cloudApproved: true,
      containerEnabled: true,
      approveContainerCommand: (warning) async {
        prompt = warning;
        return false;
      },
    );
    expect(prompt, contains('未保存内容可能丢失'));
    expect(desktop.running, isTrue);
    expect(desktop.stops, 0);
    expect(
      controller.containerActions.single.status,
      ContainerActionStatus.denied,
    );
  });
  for (final protocol in ApiProtocol.values) {
    test('$protocol appends batch screenshots only after every tool result', () async {
      final desktop = _Desktop();
      final payloads = <Map<String, Object?>>[];
      final calls = [
        {'id': 'batch-capture', 'name': 'desktop_capture', 'arguments': '{}'},
        {
          'id': 'batch-list',
          'name': 'container_list_files',
          'arguments': jsonEncode({'path': '/workspace'}),
        },
      ];
      final batch = protocol == ApiProtocol.chatCompletions
          ? '${_frame({
              'choices': [
                {
                  'index': 0,
                  'delta': {
                    'role': 'assistant',
                    'tool_calls': calls.indexed.map((entry) => {
                      'index': entry.$1,
                      'id': entry.$2['id'],
                      'type': 'function',
                      'function': {'name': entry.$2['name'], 'arguments': entry.$2['arguments']},
                    }).toList(),
                  },
                  'finish_reason': 'tool_calls',
                },
              ],
            })}data: [DONE]\n\n'
          : _frame({
              'type': 'response.completed',
              'response': {
                'id': 'batch-response',
                'status': 'completed',
                'output': calls
                    .map(
                      (call) => {
                        'id': 'item-${call['id']}',
                        'type': 'function_call',
                        'call_id': call['id'],
                        'name': call['name'],
                        'arguments': call['arguments'],
                      },
                    )
                    .toList(),
              },
            });
      final controller = await launch(
        desktop,
        MockClient((request) async {
          payloads.add(jsonDecode(request.body) as Map<String, Object?>);
          return _response(payloads.length == 1 ? batch : _text(protocol));
        }),
        protocol: protocol,
      );
      await controller.send(
        '同轮观察桌面并尝试列目录',
        cloudApproved: true,
        containerEnabled: true,
      );
      expect(payloads, hasLength(2));
      expect(desktop.captures, 1);
      final input =
          payloads.last[protocol == ApiProtocol.responses
                  ? 'input'
                  : 'messages']!
              as List;
      final receiptType = protocol == ApiProtocol.responses
          ? 'function_call_output'
          : 'tool';
      final roleKey = protocol == ApiProtocol.responses ? 'type' : 'role';
      final idKey = protocol == ApiProtocol.responses
          ? 'call_id'
          : 'tool_call_id';
      final first = input.indexWhere(
        (item) =>
            item is Map &&
            item[roleKey] == receiptType &&
            item[idKey] == 'batch-capture',
      );
      expect(first, greaterThanOrEqualTo(0));
      final capture = input[first] as Map;
      final list = input[first + 1] as Map;
      final picture = input[first + 2] as Map;
      expect(capture[idKey], 'batch-capture');
      expect(list[roleKey], receiptType);
      expect(list[idKey], 'batch-list');
      // A running real desktop makes file tools busy. Even that error receipt
      // must directly follow the assistant's tool batch before the PNG message.
      expect(jsonEncode(list), contains('tool_failed'));
      expect(picture['role'], 'user');
      final parts = picture['content']! as List;
      final image = parts.whereType<Map>().singleWhere(
        (part) =>
            part['type'] ==
            (protocol == ApiProtocol.responses ? 'input_image' : 'image_url'),
      );
      expect(
        jsonEncode(image),
        contains('data:image/png;base64,${base64Encode(_fixturePng)}'),
      );
      expect(jsonEncode(picture), contains('fixture-observation-1'));
      expect(controller.tasks.single.status, TaskStatus.failed);
      expect(controller.containerActions, hasLength(2));
      expect(
        controller.containerActions.last.status,
        ContainerActionStatus.succeeded,
      );
    });
  }
  for (final protocol in ApiProtocol.values) {
    test(
      '$protocol sends the ruled copy at high detail and states the pixel contract',
      () async {
        final ruled = Uint8List.fromList([..._fixturePng, 0, 1, 2, 3]);
        for (final spacing in <int?>[100, null]) {
          final desktop = _Desktop();
          final payloads = <Map<String, Object?>>[];
          var requests = 0;
          final seen = <Uint8List>[];
          final controller = await launch(
            desktop,
            MockClient((request) async {
              payloads.add(jsonDecode(request.body) as Map<String, Object?>);
              return _response(switch (requests++) {
                0 => _tool(protocol, 'start-1', 'desktop_start', {}),
                1 => _tool(protocol, 'capture-1', 'desktop_capture', {}),
                _ => _text(protocol),
              });
            }),
            protocol: protocol,
            annotator: (png) async {
              seen.add(png);
              return spacing == null
                  ? AnnotatedScreenshot(png)
                  : AnnotatedScreenshot(ruled, gridSpacing: spacing);
            },
          );
          await controller.send(
            '请看一下桌面',
            cloudApproved: true,
            containerEnabled: true,
          );
          expect(payloads, hasLength(3));
          expect(seen.single, _fixturePng);
          final encoded = jsonEncode(payloads[2]);
          expect(
            encoded,
            contains(
              'data:image/png;base64,${base64Encode(spacing == null ? _fixturePng : ruled)}',
            ),
          );
          expect(encoded, contains('"detail":"high"'));
          expect(encoded, isNot(contains('"detail":"low"')));
          expect(
            encoded,
            contains('integer pixels measured from its top-left'),
          );
          expect(
            encoded.contains('a ruler PerAnt drew every 100 pixels'),
            spacing != null,
          );
          // The real screen, not the ruled copy, stays the owned observation.
          expect(controller.tasks.single.status, TaskStatus.completed);
        }
      },
    );
  }
  test(
    'the observation returned with an input receipt authorizes the next input',
    () async {
      final desktop = _Desktop();
      final payloads = <Map<String, Object?>>[];
      var requests = 0;
      final controller = await launch(
        desktop,
        MockClient((request) async {
          payloads.add(jsonDecode(request.body) as Map<String, Object?>);
          return _response(switch (requests++) {
            0 => _tool(ApiProtocol.chatCompletions, 's', 'desktop_start', {}),
            1 => _tool(ApiProtocol.chatCompletions, 'c', 'desktop_capture', {}),
            2 => _tool(ApiProtocol.chatCompletions, 'a1', 'desktop_action', {
              'observation_id': 'fixture-observation-1',
              'action': 'click',
              'x': 25,
              'y': 42,
            }),
            // No capture in between: the receipt already carried frame 2.
            3 => _tool(ApiProtocol.chatCompletions, 'a2', 'desktop_action', {
              'observation_id': 'fixture-observation-2',
              'action': 'click',
              'x': 30,
              'y': 44,
            }),
            _ => _text(ApiProtocol.chatCompletions),
          });
        }),
      );
      await controller.send(
        '连续点两下',
        cloudApproved: true,
        containerEnabled: true,
      );
      expect(payloads, hasLength(5));
      expect(desktop.inputSent, 2);
      expect(desktop.captures, 3);
      expect(controller.tasks.single.status, TaskStatus.completed);
      final afterFirst = jsonEncode(payloads[3]);
      expect(afterFirst, contains('observation_id=fixture-observation-2'));
      expect(
        afterFirst,
        isNot(contains('observation_id=fixture-observation-1')),
      );
      // The receipt names the frame it carries; the stale id it consumed is
      // not presented as current.
      final receipt = (payloads[3]['messages']! as List)
          .whereType<Map>()
          .lastWhere((message) => message['role'] == 'tool');
      final data = jsonDecode(receipt['content'] as String) as Map;
      expect(data['observation_id'], 'fixture-observation-2');
      expect(data['image_follows'], isTrue);
      expect(data['action'], 'click');
    },
  );
}
