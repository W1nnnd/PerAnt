// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/persistence_native.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant/src/presentation/container_screen.dart';
import 'package:perant/src/presentation/theme.dart';
import 'package:perant_core/perant_core.dart';
import 'package:perant_gateway/perant_gateway.dart';
import 'package:perant_platform/perant_platform.dart';
import 'package:sqflite/sqflite.dart';

/// Runs only on an Android Flutter engine. Linux processes, file exchange and
/// SQLite are real. The model service is an in-process scripted MockClient:
/// no public API, production key, user database or user file is accessed.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'suite': 'android-container-workspace',
    'modelService': 'scripted-in-process-http-mock',
    'realProviderVerified': false,
    'externalHttpRequests': 0,
    'isolationClaim': false,
    'checks': <Map<String, dynamic>>[],
  };
  binding.reportData = report;
  late _NativeLinux linux;

  setUpAll(() async {
    expect(Platform.isAndroid, isTrue);
    linux = _NativeLinux(PerantPlatformBridge());
    await linux.attach();
    final status = await linux.bridge.initializeLinux();
    expect(status.supported && status.installed, isTrue, reason: status.reason);
    expect(status.pythonAvailable, isTrue, reason: status.reason);
  });

  tearDown(() async {
    await linux.cleanOwnedResources();
    expect(linux.streamError, isNull);
  });

  tearDownAll(() => linux.dispose());

  testWidgets('native workspace files preserve UTF-8 and detect stale edits', (
    tester,
  ) async {
    final directory = await linux.createDirectory();
    final path = '$directory/会议记录🐜.txt';
    const original = '原始会议记录：你好，世界 🐜\n下一步：核对原文。\n';
    final created = await linux.bridge.writeLinuxFile(
      path: path,
      content: original,
      createOnly: true,
    );
    expect(created.path, path);
    expect(created.content, original);
    expect(created.sizeBytes, utf8.encode(original).length);
    expect(created.sha256, matches(RegExp(r'^[a-f0-9]{64}$')));
    final read = await linux.bridge.readLinuxFile(path);
    expect(read.content, original);
    expect(read.sha256, created.sha256);
    final listing = await linux.bridge.listLinuxDirectory(directory);
    expect(listing.path, directory);
    expect(listing.truncated, isFalse);
    final entry = listing.entries.singleWhere((entry) => entry.path == path);
    expect(entry.name, '会议记录🐜.txt');
    expect(entry.isDirectory, isFalse);
    expect(entry.sizeBytes, created.sizeBytes);
    expect(entry.modifiedAtEpochMs, greaterThan(0));

    await expectLater(
      linux.bridge.writeLinuxFile(
        path: path,
        content: '不得覆盖',
        createOnly: true,
      ),
      throwsA(
        isA<RuntimeBridgeException>().having(
          (error) => error.code,
          'code',
          'file_conflict',
        ),
      ),
    );
    await expectLater(
      linux.bridge.writeLinuxFile(
        path: path,
        content: '不得覆盖',
        expectedSha256: List.filled(64, '0').join(),
      ),
      throwsA(
        isA<RuntimeBridgeException>().having(
          (error) => error.code,
          'code',
          'file_conflict',
        ),
      ),
    );
    expect((await linux.bridge.readLinuxFile(path)).content, original);

    const edited = '$original\n用户补充：已确认材料版本。\n';
    final updated = await linux.bridge.writeLinuxFile(
      path: path,
      content: edited,
      expectedSha256: read.sha256,
    );
    expect(updated.content, edited);
    expect(updated.sha256, isNot(created.sha256));
    final probe = await linux.run('cat -- ${_quote(path)}');
    expect(probe.exitCode, 0, reason: probe.output.toString());
    expect(probe.output.toString(), contains('用户补充：已确认材料版本。'));
    _record(report, 'native-files-utf8-and-conflict', {
      'path': path,
      'utf8Bytes': updated.sizeBytes,
      'staleEditRejected': true,
      'createOnlyOverwriteRejected': true,
      'actualGuestReadExitCode': probe.exitCode,
    });
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('native workspace boundary rejects traversal and symbolic links', (
    tester,
  ) async {
    final directory = await linux.createDirectory();
    final original = '$directory/ordinary.txt';
    final symlink = '$directory/link.txt';
    await linux.bridge.writeLinuxFile(
      path: original,
      content: 'public test file',
      createOnly: true,
    );
    final linked = await linux.run(
      'ln -s -- ${_quote(original)} ${_quote(symlink)}',
    );
    expect(linked.exitCode, 0, reason: linked.output.toString());
    await expectLater(
      linux.bridge.readLinuxFile(symlink),
      throwsA(isA<RuntimeBridgeException>()),
    );
    await expectLater(
      linux.bridge.writeLinuxFile(
        path: symlink,
        content: 'must not follow link',
        createOnly: true,
      ),
      throwsA(isA<RuntimeBridgeException>()),
    );
    expect(
      (await linux.bridge.readLinuxFile(original)).content,
      'public test file',
    );

    // Exercise the real native boundary directly, without Dart path validation
    // rejecting the request before it reaches the Android plugin.
    const native = MethodChannel(PerantPlatformBridge.methodChannelName);
    for (final path in [
      '/workspace/../etc/passwd',
      '/etc/passwd',
      '/workspace/.perant-tasks/private/input.json',
    ]) {
      await expectLater(
        native.invokeMethod<Object?>('readLinuxFile', {'path': path}),
        throwsA(isA<PlatformException>()),
        reason: 'The Android plugin must reject $path.',
      );
    }
    final root = await linux.bridge.listLinuxDirectory('/workspace');
    expect(root.entries.any((entry) => entry.name == '.perant-tasks'), isFalse);
    _record(report, 'native-file-boundary', {
      'traversalRejectedByNative': true,
      'absoluteOutsidePathRejectedByNative': true,
      'internalTaskPathRejectedByNative': true,
      'symbolicReadRejected': true,
      'symbolicWriteRejected': true,
      'originalFileUnchanged': true,
      'strongIsolationProven': false,
    });
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets(
    'native file exchange waits until a real guest process is closed',
    (tester) async {
      final directory = await linux.createDirectory();
      final path = '$directory/busy.txt';
      await linux.bridge.writeLinuxFile(
        path: path,
        content: 'unchanged while Linux is active',
        createOnly: true,
      );
      final process = await linux.start('sleep 30');
      try {
        expect((await linux.bridge.getLinuxStatus()).active, isTrue);
        for (final request in <Future<Object?> Function()>[
          () => linux.bridge.listLinuxDirectory(directory),
          () => linux.bridge.readLinuxFile(path),
          () => linux.bridge.writeLinuxFile(
            path: '$directory/must-not-exist.txt',
            content: 'must not write while active',
            createOnly: true,
          ),
        ]) {
          await expectLater(
            request(),
            throwsA(
              isA<RuntimeBridgeException>().having(
                (error) => error.code,
                'code',
                'busy',
              ),
            ),
          );
        }
      } finally {
        await linux.bridge.cancelTask(process.id);
        await process.exited.future.timeout(const Duration(seconds: 10));
      }
      expect((await linux.bridge.getLinuxStatus()).active, isFalse);
      expect(
        (await linux.bridge.readLinuxFile(path)).content,
        'unchanged while Linux is active',
      );
      final listing = await linux.bridge.listLinuxDirectory(directory);
      expect(
        listing.entries.any((entry) => entry.name == 'must-not-exist.txt'),
        isFalse,
      );
      _record(report, 'native-files-and-guest-mutual-exclusion', {
        'readRejectedWhileGuestActive': true,
        'writeRejectedWhileGuestActive': true,
        'listRejectedWhileGuestActive': true,
        'runtimeReusableAfterCleanup': true,
      });
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets('container file UI saves real HTML and mounts native preview', (
    tester,
  ) async {
    final directory = await linux.createDirectory();
    final directoryName = directory.split('/').last;
    final path = '$directory/preview.html';
    const initial = '<!doctype html><html><body><h1>共享工作区</h1></body></html>';
    const edited =
        '<!doctype html><html lang="zh"><meta charset="utf-8">'
        '<body><h1>用户编辑后的协作页面</h1><p>本机 HTML 静态预览。</p></body></html>';
    final original = await linux.bridge.writeLinuxFile(
      path: path,
      content: initial,
      createOnly: true,
    );
    final databaseName = 'perant.container-ui.${linux.nonce}.sqlite';
    final support = await getApplicationSupportDirectory();
    final databasePath = '${support.path}/$databaseName';
    var unexpectedHttpRequests = 0;
    final client = MockClient((request) async {
      unexpectedHttpRequests++;
      throw StateError(
        'Container UI tests must not issue model HTTP requests.',
      );
    });
    _NativeWorkspace? workspace;
    try {
      workspace = await _NativeWorkspace.open(
        databaseName,
        MemoryCredentialStore(),
        client,
        linux.bridge,
      );
      final controller = workspace.controller;
      expect(controller.profile, isNull);
      await tester.pumpWidget(
        MaterialApp(
          theme: perantTheme(),
          home: ContainerScreen(controller: controller),
        ),
      );
      await _waitForUi(
        tester,
        () => find.text(directoryName).evaluate().isNotEmpty,
        reason: 'The real native workspace directory was not listed.',
      );
      await tester.tap(find.text(directoryName));
      await _waitForUi(
        tester,
        () => find.text('preview.html').evaluate().isNotEmpty,
        reason: 'The container folder did not open.',
      );
      await tester.tap(find.text('preview.html'));
      await _waitForUi(
        tester,
        () => find
            .byKey(const ValueKey('container-file-content'))
            .evaluate()
            .isNotEmpty,
        reason: 'The container file editor did not open.',
      );
      final editor = find.byKey(const ValueKey('container-file-content'));
      expect(tester.widget<TextField>(editor).controller!.text, initial);
      await tester.enterText(editor, edited);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('保存到 Linux'));
      await _waitForUi(
        tester,
        () =>
            !controller.manualTerminalActive &&
            find.text('已保存到 Linux 工作区').evaluate().isNotEmpty,
        reason:
            'The edited HTML file was not saved through the native file API.',
      );
      final saved = await linux.bridge.readLinuxFile(path);
      expect(saved.content, edited);
      expect(saved.sha256, isNot(original.sha256));
      await tester.tap(find.byTooltip('预览文件'));
      await _waitForUi(
        tester,
        () => find.byType(AndroidView).evaluate().isNotEmpty,
        reason: 'The Android HTML preview view was not mounted.',
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      expect(unexpectedHttpRequests, 0);
      _record(report, 'native-container-file-ui', {
        'nativeFileOpenedInEditor': true,
        'editedFileSavedToActualWorkspace': true,
        'artifactBytes': saved.sizeBytes,
        'androidHtmlViewMounted': true,
        'htmlVisualPixelsVerified': false,
        'modelHttpRequests': unexpectedHttpRequests,
      });
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await workspace?.close();
      await deleteDatabase(databasePath);
      client.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  for (final protocol in ApiProtocol.values) {
    testWidgets(
      '${protocol.name} tools operate on real files and persist actions',
      (tester) async {
        final directory = await linux.createDirectory();
        final input = '$directory/协作原文.txt';
        final output = '$directory/产物.md';
        const source = '用户与模型共享工作区。\n请保留中文与表情 🐜。\n';
        final command =
            "printf '%s\\n' '# 协作产物' > ${_quote(output)}; "
            'cat -- ${_quote(input)} >> ${_quote(output)}; '
            "printf '%s\\n' CONTAINER_COMMAND_OK";
        final script = _ModelScript(
          protocol: protocol,
          inputPath: input,
          outputPath: output,
          source: source,
          command: command,
        );
        final databaseName =
            'perant.container-smoke.${linux.nonce}.${protocol.name}.sqlite';
        final support = await getApplicationSupportDirectory();
        final databasePath = '${support.path}/$databaseName';
        final stores = <_NativeWorkspace>[];
        final credentials = MemoryCredentialStore();
        final approvedCommands = <String>[];
        try {
          final first = await _NativeWorkspace.open(
            databaseName,
            credentials,
            script.client,
            linux.bridge,
          );
          stores.add(first);
          await first.controller.configure(
            ProviderProfile(
              id: 'container-smoke-${protocol.name}',
              displayName: 'In-process container test',
              baseUrl: Uri.parse('https://example.invalid/v1/'),
              protocol: protocol,
              modelId: 'scripted-test-model',
              storageKeyRef: 'container.smoke.${linux.nonce}.${protocol.name}',
            ),
            'temporary-in-process-test-key',
          );
          await first.controller.send(
            '在测试目录制作一份 Markdown 产物，并读取确认。',
            cloudApproved: true,
            containerEnabled: true,
            approveContainerCommand: (requested) async {
              approvedCommands.add(requested);
              expect(requested, command);
              return true;
            },
          );
          expect(first.controller.error, isNull);
          expect(first.controller.isSending, isFalse);
          expect(first.controller.isContainerTaskRunning, isFalse);
          expect(first.controller.tasks.single.status, TaskStatus.completed);
          expect(approvedCommands, [command]);
          expect(script.requests, 5);
          expect(script.readResultWasReal, isTrue);
          expect(script.commandResultWasReal, isTrue);
          expect(script.resultReadWasReal, isTrue);
          expect(script.continuationIdsMatched, isTrue);
          final actual = await linux.bridge.readLinuxFile(output);
          expect(actual.content, contains('# 协作产物'));
          expect(actual.content, contains(source));
          final actions = first.controller.containerActions;
          expect(actions, hasLength(4));
          expect(
            actions.every((action) => action.status.name == 'succeeded'),
            isTrue,
          );
          expect(
            actions.every(
              (action) => action.taskId == first.controller.tasks.single.id,
            ),
            isTrue,
          );
          expect(actions.any((action) => action.exitCode == 0), isTrue);
          final conversationId = first.controller.activeConversation.id;
          final taskId = first.controller.tasks.single.id;
          final actionIds = actions.map((action) => action.id).toSet();
          await first.close();

          final second = await _NativeWorkspace.open(
            databaseName,
            credentials,
            script.client,
            linux.bridge,
          );
          stores.add(second);
          expect(second.controller.activeConversation.id, conversationId);
          expect(second.controller.tasks.single.id, taskId);
          expect(second.controller.tasks.single.status, TaskStatus.completed);
          expect(
            second.controller.containerActions
                .map((action) => action.id)
                .toSet(),
            actionIds,
          );
          expect(
            second.controller.containerActions.every(
              (action) => action.status.name == 'succeeded',
            ),
            isTrue,
          );
          expect(
            script.requests,
            5,
            reason: 'Reopening must not replay tools or HTTP.',
          );
          _record(report, 'native-agent-${protocol.name}', {
            'scriptedModelRequests': script.requests,
            'externalHttpRequests': 0,
            'realProviderVerified': false,
            'approvedCommandCount': approvedCommands.length,
            'completedActionCount': actions.length,
            'toolContinuationIdsMatched': script.continuationIdsMatched,
            'actualReadResultReturned': script.readResultWasReal,
            'actualCommandExitCodeReturned': script.commandResultWasReal,
            'actualResultFileReturned': script.resultReadWasReal,
            'artifactBytes': actual.sizeBytes,
            'reopenedSqliteActionsPreserved': true,
            'taskId': taskId,
          });
        } finally {
          for (final store in stores.reversed) {
            await store.close();
          }
          await deleteDatabase(databasePath);
          script.client.close();
        }
        expect(await File(databasePath).exists(), isFalse);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  testWidgets('denied model command never creates a native process artifact', (
    tester,
  ) async {
    final directory = await linux.createDirectory();
    final marker = '$directory/must-not-exist.txt';
    final command = "printf denied-command-ran > ${_quote(marker)}";
    var requests = 0;
    var approvalCount = 0;
    var denialReturned = false;
    final client = MockClient((request) async {
      requests++;
      expect(request.url.host, 'example.invalid');
      if (requests == 1) {
        return http.Response(
          '${_event({
            'choices': [
              {
                'index': 0,
                'delta': {
                  'role': 'assistant',
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'denied-fixture-call',
                      'type': 'function',
                      'function': {
                        'name': 'container_run_command',
                        'arguments': jsonEncode({'command': command}),
                      },
                    },
                  ],
                },
                'finish_reason': 'tool_calls',
              },
            ],
          })}data: [DONE]\n\n',
          200,
          headers: {'content-type': 'text/event-stream; charset=utf-8'},
        );
      }
      expect(requests, 2);
      final payload = jsonDecode(request.body) as Map;
      final input = (payload['messages'] as List).cast<Map>();
      final result = input.lastWhere((entry) => entry['role'] == 'tool');
      expect(result['tool_call_id'], 'denied-fixture-call');
      final data = jsonDecode(result['content'] as String) as Map;
      expect(data['ok'], isFalse);
      expect(data['error'], 'command_denied');
      denialReturned = true;
      return http.Response(
        '${_event({
          'choices': [
            {
              'index': 0,
              'delta': {'role': 'assistant', 'content': '用户拒绝命令，未执行。'},
              'finish_reason': 'stop',
            },
          ],
        })}data: [DONE]\n\n',
        200,
        headers: {'content-type': 'text/event-stream; charset=utf-8'},
      );
    });
    final databaseName = 'perant.container-denial.${linux.nonce}.sqlite';
    final support = await getApplicationSupportDirectory();
    final databasePath = '${support.path}/$databaseName';
    _NativeWorkspace? workspace;
    try {
      workspace = await _NativeWorkspace.open(
        databaseName,
        MemoryCredentialStore(),
        client,
        linux.bridge,
      );
      await workspace.controller.configure(
        ProviderProfile(
          id: 'container-denial',
          displayName: 'In-process denial test',
          baseUrl: Uri.parse('https://example.invalid/v1/'),
          protocol: ApiProtocol.chatCompletions,
          modelId: 'scripted-denial-model',
          storageKeyRef: 'container.smoke.denial.${linux.nonce}',
        ),
        'temporary-in-process-test-key',
      );
      await workspace.controller.send(
        '请求执行一条将被拒绝的测试命令。',
        cloudApproved: true,
        containerEnabled: true,
        approveContainerCommand: (requested) async {
          approvalCount++;
          expect(requested, command);
          return false;
        },
      );
      expect(approvalCount, 1);
      expect(requests, 2);
      expect(denialReturned, isTrue);
      expect(workspace.controller.isSending, isFalse);
      expect(
        workspace.controller.containerActions.single.status.name,
        'denied',
      );
      expect((await linux.bridge.getLinuxStatus()).active, isFalse);
      final listing = await linux.bridge.listLinuxDirectory(directory);
      expect(listing.entries.any((entry) => entry.path == marker), isFalse);
      _record(report, 'native-agent-denied-command', {
        'approvalPrompts': approvalCount,
        'scriptedModelRequests': requests,
        'denialReturnedToModel': denialReturned,
        'commandArtifactPresent': false,
        'nativeRuntimeIdle': true,
        'externalHttpRequests': 0,
      });
    } finally {
      await workspace?.close();
      await deleteDatabase(databasePath);
      client.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<void> _waitForUi(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

void _record(
  Map<String, dynamic> report,
  String check,
  Map<String, dynamic> details,
) {
  final value = <String, dynamic>{'check': check, ...details};
  (report['checks'] as List<Map<String, dynamic>>).add(value);
  // Only harmless fixture text, generated IDs and counters are printed.
  // ignore: avoid_print
  print('CONTAINER_WORKSPACE_RESULT ${jsonEncode(value)}');
}

String _quote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

final class _NativeLinux {
  _NativeLinux(this.bridge);
  final PerantPlatformBridge bridge;
  final String nonce = DateTime.now().microsecondsSinceEpoch.toString();
  final _directories = <String>[];
  final _processes = <String, _NativeProcess>{};
  StreamSubscription<RuntimeEvent>? _subscription;
  Object? streamError;
  int _sequence = 0;

  Future<void> attach() async {
    _subscription = bridge.events.listen((event) {
      final process = _processes[event.taskId];
      if (process == null) return;
      if (event.type == 'linuxOutput') {
        process.output.write(event.payload['text'] as String);
      } else if (event.type == 'linuxExit') {
        process.exitCode = event.payload['exitCode'] as int;
        if (!process.exited.isCompleted) process.exited.complete();
      }
    }, onError: (Object error) => streamError = error);
    await bridge.ensureRuntimeEventsAttached();
  }

  Future<String> createDirectory() async {
    final path = '/workspace/perant-container-smoke-$nonce-${_sequence++}';
    // Register ownership before the native call, so failed/late initialization
    // cannot leave an untracked test-created directory.
    _directories.add(path);
    await bridge.createLinuxDirectory(path);
    return path;
  }

  Future<_NativeProcess> start(String command) async {
    final id = 'container-smoke-$nonce-${_sequence++}';
    final process = _NativeProcess(id);
    _processes[id] = process;
    await bridge.runLinuxCommand(taskId: id, command: command);
    return process;
  }

  Future<_NativeProcess> run(String command) async {
    final process = await start(command);
    await process.exited.future.timeout(const Duration(seconds: 40));
    return process;
  }

  Future<void> cleanOwnedResources() async {
    for (final entry in _processes.entries.toList()) {
      if (!entry.value.exited.isCompleted) await bridge.cancelTask(entry.key);
    }
    for (final path in _directories.toList()) {
      if (!RegExp('^/workspace/perant-container-smoke-$nonce-[0-9]+\$')
          .hasMatch(path)) {
        throw StateError('Refusing cleanup outside the test-owned directory.');
      }
      final removed = await run('rm -rf -- ${_quote(path)}');
      expect(removed.exitCode, 0, reason: removed.output.toString());
      _directories.remove(path);
    }
  }

  Future<void> dispose() async {
    await cleanOwnedResources();
    await _subscription?.cancel();
  }
}

final class _NativeProcess {
  _NativeProcess(this.id);
  final String id;
  final output = StringBuffer();
  final exited = Completer<void>();
  int? exitCode;
}

final class _ClosingPersistence implements WorkspacePersistence {
  _ClosingPersistence(this.delegate);
  final WorkspacePersistence delegate;
  final closed = Completer<void>();
  Future<void>? _closing;
  @override
  String get description => delegate.description;
  @override
  Future<WorkspaceState> load() => delegate.load();
  @override
  Future<void> save(Map<String, Object?> snapshot) => delegate.save(snapshot);
  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    try {
      await delegate.close();
    } finally {
      closed.complete();
    }
  }
}

final class _NativeWorkspace {
  _NativeWorkspace(this.controller, this.persistence);
  final WorkspaceController controller;
  final _ClosingPersistence persistence;
  bool _closed = false;

  static Future<_NativeWorkspace> open(
    String databaseName,
    CredentialStore credentials,
    http.Client client,
    PerantPlatformBridge bridge,
  ) async {
    final persistence = _ClosingPersistence(
      await openPersistence(databaseName: databaseName),
    );
    final controller = WorkspaceController(
      persistence: persistence,
      credentials: credentials,
      gateway: OpenAiGateway(client: client),
      bridge: bridge,
    );
    final workspace = _NativeWorkspace(controller, persistence);
    try {
      await controller.initialize();
      return workspace;
    } catch (_) {
      await workspace.close();
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    controller.dispose();
    await persistence.closed.future;
  }
}

/// This client does not create a socket. It produces complete SSE turns and
/// verifies the next outbound tool result against actual native file/process
/// facts. Transport fidelity to a public provider is not claimed.
final class _ModelScript {
  _ModelScript({
    required this.protocol,
    required this.inputPath,
    required this.outputPath,
    required this.source,
    required this.command,
  }) {
    client = MockClient(_respond);
  }
  final ApiProtocol protocol;
  final String inputPath;
  final String outputPath;
  final String source;
  final String command;
  late final http.Client client;
  int requests = 0;
  bool continuationIdsMatched = false;
  bool readResultWasReal = false;
  bool commandResultWasReal = false;
  bool resultReadWasReal = false;

  Future<http.Response> _respond(http.Request request) async {
    requests++;
    expect(request.url.host, 'example.invalid');
    expect(
      request.headers['Authorization'],
      'Bearer temporary-in-process-test-key',
    );
    final payload = jsonDecode(request.body) as Map<String, dynamic>;
    final tools = payload['tools'] as List;
    expect(tools, isNotEmpty);
    final input =
        (payload[protocol == ApiProtocol.chatCompletions ? 'messages' : 'input']
                as List)
            .cast<Map>();
    if (requests > 1) {
      final expectedId = 'fixture-tool-${requests - 1}';
      final Map result;
      if (protocol == ApiProtocol.chatCompletions) {
        result = input.lastWhere((entry) => entry['role'] == 'tool');
        expect(result['tool_call_id'], expectedId);
        final assistant = input.lastWhere(
          (entry) => entry['role'] == 'assistant',
        );
        expect((assistant['tool_calls'] as List).last['id'], expectedId);
        expect(
          assistant['reasoning_content'],
          'fixture-reasoning-${requests - 1}',
        );
      } else {
        result = input.lastWhere(
          (entry) => entry['type'] == 'function_call_output',
        );
        expect(result['call_id'], expectedId);
        final call = input.lastWhere(
          (entry) => entry['type'] == 'function_call',
        );
        expect(call['call_id'], expectedId);
        expect(
          input.any(
            (item) =>
                item['type'] == 'reasoning' &&
                item['id'] == 'fixture-reasoning-${requests - 1}',
          ),
          isTrue,
        );
      }
      continuationIdsMatched = true;
      final text =
          (result[protocol == ApiProtocol.chatCompletions
                  ? 'content'
                  : 'output']
              as String);
      final output = jsonDecode(text) as Map;
      expect(output['error'], isNull, reason: text);
      if (requests == 3) {
        expect(text, contains('用户与模型共享工作区。'));
        expect(text, contains('🐜'));
        readResultWasReal = true;
      } else if (requests == 4) {
        expect(text, contains('CONTAINER_COMMAND_OK'));
        expect(
          _findField(output, 'exitCode') ?? _findField(output, 'exit_code'),
          0,
        );
        commandResultWasReal = true;
      } else if (requests == 5) {
        expect(text, contains('# 协作产物'));
        expect(text, contains('用户与模型共享工作区。'));
        resultReadWasReal = true;
      }
    }
    final body = switch (requests) {
      1 => _tool('container_write_file', {
        'path': inputPath,
        'content': source,
        'create_only': true,
      }),
      2 => _tool('container_read_file', {'path': inputPath}),
      3 => _tool('container_run_command', {
        'command': command,
        'timeout_seconds': 20,
      }),
      4 => _tool('container_read_file', {'path': outputPath}),
      5 => _text('已在本地工作区生成并读取协作产物。'),
      _ => throw StateError(
        'Unexpected model turn; no request may escape this in-process mock.',
      ),
    };
    return http.Response(
      body,
      200,
      headers: {'content-type': 'text/event-stream; charset=utf-8'},
    );
  }

  String _tool(String name, Map<String, Object?> arguments) {
    final id = 'fixture-tool-$requests';
    final encoded = jsonEncode(arguments);
    if (protocol == ApiProtocol.chatCompletions) {
      return '${_event({
        'choices': [
          {
            'index': 0,
            'delta': {
              'role': 'assistant',
              'reasoning_content': 'fixture-reasoning-$requests',
              'tool_calls': [
                {
                  'index': 0,
                  'id': id,
                  'type': 'function',
                  'function': {'name': name, 'arguments': encoded},
                },
              ],
            },
            'finish_reason': 'tool_calls',
          },
        ],
      })}data: [DONE]\n\n';
    }
    return _event({
      'type': 'response.completed',
      'response': {
        'id': 'fixture-response-$requests',
        'status': 'completed',
        'output': [
          {
            'type': 'reasoning',
            'id': 'fixture-reasoning-$requests',
            'summary': [],
          },
          {
            'type': 'function_call',
            'id': 'fixture-item-$requests',
            'call_id': id,
            'name': name,
            'arguments': encoded,
          },
        ],
      },
    });
  }

  String _text(String text) {
    if (protocol == ApiProtocol.chatCompletions) {
      return '${_event({
        'choices': [
          {
            'index': 0,
            'delta': {'role': 'assistant', 'content': text},
            'finish_reason': 'stop',
          },
        ],
      })}data: [DONE]\n\n';
    }
    return '${_event({'type': 'response.output_text.delta', 'delta': text})}${_event({
      'type': 'response.completed',
      'response': {
        'id': 'fixture-response-final',
        'status': 'completed',
        'output': [
          {
            'id': 'fixture-message-final',
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': text},
            ],
          },
        ],
      },
    })}';
  }
}

Object? _findField(Map value, String key) {
  if (value.containsKey(key)) return value[key];
  for (final nested in value.values.whereType<Map>()) {
    final found = _findField(nested, key);
    if (found != null) return found;
  }
  return null;
}

String _event(Map<String, Object?> value) => 'data: ${jsonEncode(value)}\n\n';
