// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/persistence_native.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant/src/perant_app.dart';
import 'package:perant_gateway/perant_gateway.dart';
import 'package:perant_core/perant_core.dart';
import 'package:perant_platform/perant_platform.dart';
import 'package:sqflite/sqflite.dart';

/// These tests intentionally require an Android Flutter engine and real plugins.
/// No channel mocks, memory stores, production database, or user API keys are used.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android bridge and secure storage use real native plugins', (
    tester,
  ) async {
    expect(
      Platform.isAndroid,
      isTrue,
      reason: 'Run this smoke test on an Android device or emulator.',
    );
    final capabilities = await PerantPlatformBridge().getCapabilities();
    expect(capabilities.platform, 'android');
    expect(capabilities.nativeBridgeAvailable, isTrue);
    expect(capabilities.systemVersion, contains('Android'));

    final reference =
        'perant.integration.smoke.${DateTime.now().microsecondsSinceEpoch}';
    final value = 'temporary-native-smoke-value-$reference';
    const credentials = PlatformCredentialStore();
    try {
      expect(await credentials.read(reference), isNull);
      await credentials.write(reference, value);
      expect(await credentials.read(reference), value);
      await credentials.delete(reference);
      expect(await credentials.read(reference), isNull);
    } finally {
      await credentials.delete(reference);
    }
  });

  testWidgets(
    'mobile document workflow survives closing and reopening an isolated SQLite DB',
    (tester) async {
      expect(
        Platform.isAndroid,
        isTrue,
        reason: 'Run this smoke test on an Android device or emulator.',
      );
      final databaseName =
          'perant.integration-smoke.${DateTime.now().microsecondsSinceEpoch}.sqlite';
      final directory = await getApplicationSupportDirectory();
      final databasePath = '${directory.path}/$databaseName';
      expect(databaseName, isNot('perant.sqlite'));
      final workspaces = <_NativeSmokeWorkspace>[];
      final network = _NoNetworkClient();
      const title = 'Android 本地验证记录';
      const markdown =
          '# Android 本地验证\n\n'
          '- 真实 SQLite 保存\n'
          '- 关闭数据库后重新读取\n'
          '- 不发送云端请求';

      try {
        final first = await _NativeSmokeWorkspace.open(databaseName, network);
        workspaces.add(first);
        expect(first.controller.capabilities!.nativeBridgeAvailable, isTrue);
        expect(first.controller.profile, isNull);
        await tester.pumpWidget(PerantApp(controller: first.controller));
        await tester.pumpAndSettle();

        expect(find.byTooltip('发送消息'), findsOneWidget);
        await tester.tap(find.byTooltip('文件'));
        await tester.pumpAndSettle();
        expect(find.text('我的文件'), findsOneWidget);
        await tester.tap(find.text('新建'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField), title);
        await tester.tap(find.text('创建'));
        await _waitUntil(
          tester,
          () =>
              first.controller.documents.length == 1 &&
              find.byTooltip('保存文档').evaluate().isNotEmpty,
          reason:
              'The document editor did not open after native SQLite creation.',
        );
        await tester.enterText(find.byType(TextField), markdown);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.tap(find.text('保存并确认'));
        await _waitUntil(
          tester,
          () => first.controller.documents.single.isConfirmed,
          reason: 'The confirmed Markdown revision was not saved to SQLite.',
        );
        final confirmedRevision = first.controller.documents.single.revision;
        expect(first.controller.documents.single.markdown, markdown);
        expect(await File(databasePath).exists(), isTrue);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('菜单'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('任务与操作记录'));
        await tester.pumpAndSettle();
        expect(find.text('还没有任务记录'), findsOneWidget);
        await tester.tap(find.byTooltip('对话'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('新对话'));
        await _waitUntil(
          tester,
          () => first.controller.conversations.length == 2,
          reason:
              'The new conversation button did not create a persisted thread.',
        );
        final activeConversationId = first.controller.activeConversation.id;

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await first.close();
        final second = await _NativeSmokeWorkspace.open(databaseName, network);
        workspaces.add(second);
        expect(second.controller.documents, hasLength(1));
        expect(second.controller.documents.single.title, title);
        expect(second.controller.documents.single.markdown, markdown);
        expect(second.controller.documents.single.revision, confirmedRevision);
        expect(second.controller.documents.single.isConfirmed, isTrue);
        expect(second.controller.activeConversation.id, activeConversationId);
        expect(second.controller.conversations, hasLength(2));
        await tester.pumpWidget(PerantApp(controller: second.controller));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('文件'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
        expect(find.text('版本已确认'), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          markdown,
        );
        expect(network.requestCount, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        for (final workspace in workspaces.reversed) {
          await workspace.close();
        }
        await deleteDatabase(databasePath);
        network.close();
      }
      expect(await File(databasePath).exists(), isFalse);
    },
  );

  testWidgets('real Python task publishes an editable confirmed document durably', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue);
    final nonce = DateTime.now().microsecondsSinceEpoch;
    final databaseName = 'perant.local-text-smoke.$nonce.sqlite';
    final directory = await getApplicationSupportDirectory();
    final databasePath = '${directory.path}/$databaseName';
    final network = _NoNetworkClient();
    final workspaces = <_NativeSmokeWorkspace>[];
    final ownedTasks = <String>[];
    const title = '本地会议原文验证';
    const source = '项目讨论：保留会议原文 🐜\r\n\r\n负责人：李华\n下一步：周五提交初稿。';
    String? edited;
    String? documentId;
    try {
      final first = await _NativeSmokeWorkspace.open(databaseName, network);
      workspaces.add(first);
      expect(first.controller.profile, isNull);
      await tester.pumpWidget(PerantApp(controller: first.controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('添加文件与工具'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本地整理为 Markdown'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local-text-title')),
        title,
      );
      await tester.enterText(
        find.byKey(const ValueKey('local-text-source')),
        source,
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text('在本地整理'));
      await tester.pump();
      // Test-owned diagnostics distinguish a missed UI gesture from native
      // execution. The bridge allows 300 seconds for the bundled desktop's
      // cold installation; allow that plus the bounded Python task and UI IO.
      // ignore: avoid_print
      print(
        'NATIVE_SMOKE_LOCAL_AFTER_TAP ${jsonEncode({'taskCount': first.controller.tasks.length, 'documentCount': first.controller.documents.length, 'isSending': first.controller.isSending, 'error': first.controller.error})}',
      );
      try {
        await _waitUntil(
          tester,
          () =>
              first.controller.documents.isNotEmpty ||
              (first.controller.tasks.isNotEmpty &&
                  !first.controller.isSending),
          reason: 'The real Python task did not finish.',
          timeout: const Duration(seconds: 350),
        );
      } catch (_) {
        final diagnostics = <String, Object?>{
          'taskCount': first.controller.tasks.length,
          'documentCount': first.controller.documents.length,
          'isSending': first.controller.isSending,
          'error': first.controller.error,
          'frameworkException': tester.takeException()?.toString(),
          'tasks': first.controller.tasks
              .map(
                (task) => {
                  'id': task.id,
                  'status': task.status.name,
                  'detail': task.statusDetail,
                  'steps': task.steps
                      .map(
                        (step) => {'id': step.id, 'status': step.status.name},
                      )
                      .toList(),
                },
              )
              .toList(),
        };
        try {
          final status = await first.controller.bridge.getLinuxStatus();
          diagnostics['nativeStatus'] = {
            'installed': status.installed,
            'active': status.active,
            'sessionId': status.sessionId,
            'desktopSessionId': status.desktopSessionId,
            'pythonAvailable': status.pythonAvailable,
            'reason': status.reason,
          };
        } catch (error) {
          diagnostics['nativeStatusDiagnosticError'] = error.toString();
        }
        // ignore: avoid_print
        print('NATIVE_SMOKE_LOCAL_TIMEOUT_STATE ${jsonEncode(diagnostics)}');
        try {
          final binding =
              IntegrationTestWidgetsFlutterBinding.ensureInitialized();
          await binding.convertFlutterSurfaceToImage();
          await tester.pump();
          final screenshot = await binding.takeScreenshot(
            'local-text-timeout-$nonce',
          );
          // Only this test's fixed text and temporary workspace UI.
          // ignore: avoid_print
          print(
            'NATIVE_SMOKE_LOCAL_TIMEOUT_PNG_BASE64 ${base64Encode(screenshot)}',
          );
        } catch (error) {
          // ignore: avoid_print
          print('NATIVE_SMOKE_LOCAL_SCREENSHOT_DIAGNOSTIC_ERROR $error');
        }
        rethrow;
      }
      ownedTasks.addAll(first.controller.tasks.map((task) => task.id));
      expect(first.controller.error, isNull);
      expect(first.controller.tasks.single.status, TaskStatus.completed);
      expect(first.controller.tasks.single.cloudAuthorization, isNull);
      expect(
        first.controller.tasks.single.steps.every(
          (step) => step.status == TaskStepStatus.succeeded,
        ),
        isTrue,
      );
      final draft = first.controller.documents.single;
      documentId = draft.id;
      expect(draft.isConfirmed, isFalse);
      expect(draft.markdown, contains('负责人：李华'));
      expect(draft.markdown, contains('🐜'));
      expect(
        first.controller.messages.every(
          (message) => message.source == ChatEntrySource.localPython,
        ),
        isTrue,
      );
      expect(find.text('本地 Python 工具'), findsOneWidget);
      await tester.tap(find.text('已收好，打开文档'));
      await tester.pumpAndSettle();
      edited = '${draft.markdown}\n## 人工确认\n\n已核对原文。\n';
      await tester.enterText(find.byType(TextField), edited);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存并确认'));
      await _waitUntil(
        tester,
        () => first.controller.documents.single.isConfirmed,
        reason: 'The generated document was not confirmed.',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await first.close();
      final second = await _NativeSmokeWorkspace.open(databaseName, network);
      workspaces.add(second);
      expect(second.controller.documents.single.id, documentId);
      expect(second.controller.documents.single.markdown, edited);
      expect(second.controller.documents.single.isConfirmed, isTrue);
      expect(second.controller.tasks.single.status, TaskStatus.completed);
      expect(second.controller.messages.last.documentId, documentId);
      expect(
        second.controller.messages.last.source,
        ChatEntrySource.localPython,
      );
      expect(network.requestCount, 0);
      expect(tester.takeException(), isNull);
      // ignore: avoid_print
      print(
        'LOCAL_TEXT_WORKFLOW_RESULT task=${ownedTasks.single} pythonExit=0 confirmedRevision=${second.controller.documents.single.revision} reopenedSqlite=true cloudRequests=${network.requestCount}',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      try {
        for (final taskId in ownedTasks) {
          expect(
            RegExp(r'^local-text-[0-9]+-[0-9]+$').hasMatch(taskId),
            isTrue,
          );
          final bridge = PerantPlatformBridge();
          final status = await bridge.getLinuxStatus();
          // A failed cold installation never created a guest task directory.
          // Preserve that original failure instead of masking it in teardown.
          if (!status.installed || status.active) continue;
          final cleanupId = 'cleanup-$nonce';
          final exited = bridge.events.firstWhere(
            (event) => event.taskId == cleanupId && event.type == 'linuxExit',
          );
          await bridge.ensureRuntimeEventsAttached();
          await bridge.runLinuxCommand(
            taskId: cleanupId,
            command: 'rm -rf -- /workspace/.perant-tasks/$taskId',
          );
          expect(
            (await exited.timeout(const Duration(seconds: 10)))
                .payload['exitCode'],
            0,
          );
        }
      } finally {
        for (final workspace in workspaces.reversed) {
          await workspace.close();
        }
        await deleteDatabase(databasePath);
        network.close();
      }
    }
    expect(await File(databasePath).exists(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 7)));
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    // Give native installation/IO real wall-clock time without forcing ten
    // full static UI frames per second on a software-rendered Android AVD.
    // The original wall-clock deadline and completion predicate stay intact.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// Delegates all reads/writes to the real SQLite store and only exposes a
/// completion signal for the controller's asynchronous dispose/close sequence.
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

final class _NativeSmokeWorkspace {
  _NativeSmokeWorkspace(this.controller, this.persistence);
  final WorkspaceController controller;
  final _ClosingPersistence persistence;
  bool _closed = false;

  static Future<_NativeSmokeWorkspace> open(
    String databaseName,
    _NoNetworkClient network,
  ) async {
    final persistence = _ClosingPersistence(
      await openPersistence(databaseName: databaseName),
    );
    final controller = WorkspaceController(
      persistence: persistence,
      credentials: const PlatformCredentialStore(),
      gateway: OpenAiGateway(client: network),
    );
    final workspace = _NativeSmokeWorkspace(controller, persistence);
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

/// A guard, not a model simulator: any accidental HTTP request fails the test.
final class _NoNetworkClient extends http.BaseClient {
  int requestCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestCount++;
    throw StateError('Native smoke tests must not issue cloud requests.');
  }
}
