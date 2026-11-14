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
import 'package:perant_core/perant_core.dart';
import 'package:perant_gateway/perant_gateway.dart';
import 'package:perant_platform/perant_platform.dart';

const _command =
    "printf '%s\\n' 'PerAnt exact command approval' > /workspace/approval-test.txt";
const _reply = '未执行这条命令；你可以继续在共享工作区编辑文件。';

String _frame(Map<String, Object?> payload) =>
    'data: ${jsonEncode(payload)}\n\n';
http.Response _sse(String body) => http.Response(
  body,
  200,
  headers: {'content-type': 'text/event-stream; charset=utf-8'},
);

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  String Function()? diagnostic,
}) async {
  for (var index = 0; index < 100 && !condition(); index++) {
    // MockClient's response stream may be created outside Flutter's fake
    // timer zone; yield that zone without making any actual network request.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(
    condition(),
    isTrue,
    reason: diagnostic?.call() ?? 'Expected UI state was not reached.',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'cloud opt-in routes the exact shell proposal to UI and rejection never starts native Linux',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const methods = MethodChannel('dev.perant/test-container-agent-ui');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var nativeStarts = 0;
      messenger.setMockMethodCallHandler(methods, (call) async {
        switch (call.method) {
          case 'getCapabilities':
            return {
              'schemaVersion': 1,
              'platform': 'android',
              'systemVersion': 'UI test fixture',
              'nativeBridgeAvailable': true,
              'linux': {'available': true, 'reason': 'Test fixture'},
              'localInference': {
                'available': false,
                'reason': 'No local model',
              },
              'backgroundTasks': {
                'available': false,
                'reason': 'No background service',
              },
            };
          case 'getLinuxStatus':
            return {
              'supported': true,
              'installed': true,
              'active': false,
              'sessionId': null,
              'distribution': 'Alpine',
              'version': '3.24.4',
              'workspace': '/workspace',
              'reason': 'UI test fixture runtime',
            };
          case 'runLinuxCommand':
            nativeStarts++;
            throw StateError(
              'A denied command must never reach native execution.',
            );
          default:
            throw StateError('Unexpected native call: ${call.method}');
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(methods, null));
      final requests = <Map<String, Object?>>[];
      final client = MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, Object?>);
        if (requests.length == 1) {
          return _sse(
            '${_frame({
              'choices': [
                {
                  'index': 0,
                  'delta': {
                    'role': 'assistant',
                    'tool_calls': [
                      {
                        'index': 0,
                        'id': 'ui-command-1',
                        'type': 'function',
                        'function': {
                          'name': 'container_run_command',
                          'arguments': jsonEncode({'command': _command, 'timeout_seconds': 5}),
                        },
                      },
                    ],
                  },
                  'finish_reason': 'tool_calls',
                },
              ],
            })}data: [DONE]\n\n',
          );
        }
        if (requests.length != 2) throw StateError('Unexpected model retry.');
        return _sse(
          '${_frame({
            'choices': [
              {
                'index': 0,
                'delta': {'role': 'assistant', 'content': _reply},
                'finish_reason': 'stop',
              },
            ],
          })}data: [DONE]\n\n',
        );
      });
      addTearDown(client.close);
      final controller = WorkspaceController(
        persistence: MemoryWorkspacePersistence(),
        credentials: MemoryCredentialStore(),
        gateway: OpenAiGateway(client: client),
        bridge: PerantPlatformBridge(methodChannel: methods),
      );
      await controller.initialize();
      await controller.configure(
        ProviderProfile(
          id: 'ui-test-provider',
          displayName: '测试模型服务',
          baseUrl: Uri.parse('https://example.invalid/v1'),
          protocol: ApiProtocol.chatCompletions,
          modelId: 'ui-test-model',
          storageKeyRef: 'credential:container-ui-test',
        ),
        'test-only-not-a-real-api-key',
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(PerantApp(controller: controller));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '请在容器里执行检查命令');
      await tester.pump();
      await tester.tap(find.byTooltip('发送消息'));
      await tester.pumpAndSettle();
      expect(find.text('允许本次任务使用云端模型？'), findsOneWidget);
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      expect(requests, isEmpty);

      await tester.tap(find.text('允许模型操作容器电脑'));
      await tester.pump();
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isTrue,
      );
      expect(find.textContaining('Linux 应用与浏览器'), findsOneWidget);
      expect(find.textContaining('桌面及网页截图、文件内容、工具输出'), findsOneWidget);
      await tester.tap(find.text('授权并发送'));
      await _pumpUntil(
        tester,
        () => find.text('运行这条 Linux 命令？').evaluate().isNotEmpty,
        diagnostic: () =>
            'requests=${requests.length}, active=${controller.isSending}, error=${controller.error}, task=${controller.tasks.map((task) => task.statusDetail).toList()}, widgets=${tester.takeException()}',
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.widgetWithText(SelectableText, _command), findsOneWidget);
      expect(controller.activeContainerCommand, _command);
      expect(
        controller.containerActions.single.status,
        ContainerActionStatus.awaitingApproval,
      );
      expect(nativeStarts, 0);
      expect(requests, hasLength(1));
      expect(requests.single['tools'], isA<List>());

      await tester.tap(find.text('拒绝'));
      await _pumpUntil(tester, () => !controller.isSending);
      await tester.pumpAndSettle();
      expect(find.text('运行这条 Linux 命令？'), findsNothing);
      expect(find.text(_reply, findRichText: true), findsOneWidget);
      expect(controller.messages.last.text, _reply);
      expect(
        controller.containerActions.single.status,
        ContainerActionStatus.denied,
      );
      expect(
        controller.containerActions.single.output,
        contains('command_denied'),
      );
      expect(controller.tasks.single.status, TaskStatus.failed);
      expect(nativeStarts, 0);
      expect(requests, hasLength(2));
      final messages = requests.last['messages']! as List;
      final result = messages.last as Map;
      expect(result['role'], 'tool');
      expect(result['tool_call_id'], 'ui-command-1');
      expect(result['content'], contains('command_denied'));
      expect(tester.takeException(), isNull);
    },
  );
}
