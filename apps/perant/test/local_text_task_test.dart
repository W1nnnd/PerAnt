// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant/src/perant_app.dart';
import 'package:perant_core/perant_core.dart';
import 'package:perant_gateway/perant_gateway.dart';
import 'package:perant_platform/perant_platform.dart';

const _nativeMarkdown = '# 文件中的真实测试结果\n\n中文 🐜\n';

final class _TextNativeFixture {
  static int sequence = 0;
  _TextNativeFixture() : name = 'dev.perant/test-local-text-${sequence++}';
  final String name;
  late final methods = MethodChannel('$name/methods');
  late final events = EventChannel('$name/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final started = Completer<void>();
  final initializing = Completer<void>();
  final cancelCalled = Completer<void>();
  bool installed = true;
  bool pythonAvailable = true;
  bool active = false;
  bool autoComplete = false;
  bool cancelFails = false;
  int exitCode = 0;
  int starts = 0;
  int reads = 0;
  int initializations = 0;
  int listeners = 0;
  String? taskId;
  Map<Object?, Object?>? input;
  Completer<void>? startGate;
  Completer<void>? cancelGate;
  Completer<void>? initializationGate;

  Map<String, Object?> get capabilities => {
    'schemaVersion': 1,
    'platform': 'android',
    'systemVersion': 'fixture',
    'nativeBridgeAvailable': true,
    'linux': {'available': true, 'reason': 'Test fixture runtime'},
    'localInference': {'available': false, 'reason': 'No test model'},
    'backgroundTasks': {'available': false, 'reason': 'No test service'},
  };
  Map<String, Object?> get status => {
    'supported': true,
    'installed': installed,
    'active': active,
    'sessionId': null,
    'distribution': 'Alpine',
    'version': '3.24.4',
    'workspace': '/workspace',
    'pythonAvailable': pythonAvailable,
    'pythonVersion': pythonAvailable ? '3.14.10' : null,
    'reason': 'Test fixture status',
  };

  void install() {
    messenger.setMockMethodCallHandler(methods, (call) async {
      final args = call.arguments is Map ? call.arguments! as Map : const {};
      switch (call.method) {
        case 'getCapabilities':
          return capabilities;
        case 'getLinuxStatus':
          return status;
        case 'initializeLinux':
          initializations++;
          if (!initializing.isCompleted) initializing.complete();
          await initializationGate?.future;
          installed = true;
          pythonAvailable = true;
          return status;
        case 'startLinuxTextTask':
          starts++;
          input = args;
          taskId = args['taskId']! as String;
          active = true;
          if (!started.isCompleted) started.complete();
          await startGate?.future;
          if (autoComplete) await complete(code: exitCode);
          return {'taskId': taskId, 'pid': 42};
        case 'readLinuxTextTaskResult':
          reads++;
          return {
            'taskId': args['taskId'],
            'markdown': _nativeMarkdown,
            'workspacePath':
                '/workspace/.perant-tasks/${args['taskId']}/output.md',
            'sizeBytes': utf8.encode(_nativeMarkdown).length,
          };
        case 'cancelTask':
          if (!cancelCalled.isCompleted) cancelCalled.complete();
          await cancelGate?.future;
          if (cancelFails)
            throw PlatformException(
              code: 'timeout',
              message: 'Test cancellation was not acknowledged',
            );
          if (active) await complete(cancelled: true, code: 137);
          return {
            'taskId': args['taskId'],
            'status': 'cancelled',
            'reason': 'Fixture confirmed cleanup',
          };
      }
      throw PlatformException(code: 'unexpected', message: call.method);
    });
    messenger.setMockMethodCallHandler(MethodChannel(events.name), (
      call,
    ) async {
      if (call.method == 'listen') {
        listeners++;
        scheduleMicrotask(
          () => emit({
            'type': 'bridgeAttached',
            'emittedAtEpochMs': DateTime.now().millisecondsSinceEpoch,
            'payload': capabilities,
          }),
        );
      }
      return null;
    });
  }

  Future<void> emit(Map<String, Object?> value) =>
      messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope(value),
        (_) {},
      );
  Future<void> complete({
    int code = 0,
    bool cancelled = false,
    bool timedOut = false,
  }) async {
    active = false;
    await emit({
      'type': 'linuxExit',
      'taskId': taskId,
      'emittedAtEpochMs': DateTime.now().millisecondsSinceEpoch,
      'payload': {
        'exitCode': code,
        'cancelled': cancelled,
        'timedOut': timedOut,
      },
    });
  }

  void uninstall() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(MethodChannel(events.name), null);
  }
}

final class _PublicationPersistence implements WorkspacePersistence {
  final _inner = MemoryWorkspacePersistence();
  bool failPublication = false;
  @override
  String get description => 'Publication test store';
  @override
  Future<WorkspaceState> load() => _inner.load();
  @override
  Future<void> close() => _inner.close();
  @override
  Future<void> save(Map<String, Object?> value) async {
    if (failPublication && (value['documents']! as List).isNotEmpty) {
      failPublication = false;
      throw StateError('Test final snapshot failed');
    }
    await _inner.save(jsonDecode(jsonEncode(value)) as Map<String, Object?>);
  }
}

/// A closed native database rejects writes; record even a caught late attempt.
final class _ClosingPersistence implements WorkspacePersistence {
  final _inner = MemoryWorkspacePersistence();
  final didClose = Completer<void>();
  bool closed = false;
  int writesAfterClose = 0;
  @override
  String get description => 'Closing test store';
  @override
  Future<WorkspaceState> load() => _inner.load();
  @override
  Future<void> save(Map<String, Object?> value) async {
    if (closed) {
      writesAfterClose++;
      throw StateError('Test database is already closed');
    }
    await _inner.save(jsonDecode(jsonEncode(value)) as Map<String, Object?>);
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!didClose.isCompleted) didClose.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<WorkspaceController> launch(
    _TextNativeFixture native, {
    WorkspacePersistence? persistence,
    Duration timeout = const Duration(seconds: 5),
    bool autoDispose = true,
  }) async {
    native.install();
    final gateway = OpenAiGateway(
      client: MockClient(
        (_) async => throw StateError('Unexpected HTTP request'),
      ),
    );
    final controller = WorkspaceController(
      persistence: persistence ?? MemoryWorkspacePersistence(),
      credentials: MemoryCredentialStore(),
      gateway: gateway,
      bridge: PerantPlatformBridge(
        methodChannel: native.methods,
        eventChannel: native.events,
        responseTimeout: timeout,
      ),
    );
    await controller.initialize();
    if (autoDispose) addTearDown(controller.dispose);
    addTearDown(native.uninstall);
    return controller;
  }

  test('publishes actual native Markdown and a linked local receipt without an API', () async {
    final native = _TextNativeFixture()..autoComplete = true;
    final persistence = MemoryWorkspacePersistence();
    final controller = await launch(native, persistence: persistence);
    const source =
        r'原文 $() `command` 中文 🐜'
        '\r\n第二段';
    final document = await controller.generateLocalMarkdown(
      title: '私人材料',
      text: source,
    );
    expect(controller.profile, isNull);
    expect(native.input!['text'], source);
    expect(document!.markdown, _nativeMarkdown);
    expect(document.isConfirmed, isFalse);
    expect(controller.tasks.single.status, TaskStatus.completed);
    expect(
      controller.tasks.single.steps.every(
        (step) => step.status == TaskStepStatus.succeeded,
      ),
      isTrue,
    );
    expect(controller.messages.last.source, ChatEntrySource.localPython);
    expect(controller.messages.first.source, ChatEntrySource.localPython);
    expect(controller.messages.last.documentId, document.id);
    final restored = await persistence.load();
    expect(restored.documents.single.markdown, _nativeMarkdown);
    expect(restored.messages.last.documentId, restored.documents.single.id);
    expect(restored.messages.first.source, ChatEntrySource.localPython);
    expect(restored.tasks.single.status, TaskStatus.completed);
    // Reusing this bridge must not await a second bridgeAttached event.
    await controller.generateLocalMarkdown(title: '第二份', text: '另一段原文');
    expect(controller.documents, hasLength(2));
    expect(native.listeners, 1);
  });

  test(
    'initializes bundled Python and rejects oversized input before executing',
    () async {
      final native = _TextNativeFixture()
        ..installed = false
        ..pythonAvailable = false
        ..autoComplete = true;
      final controller = await launch(native);
      await expectLater(
        controller.generateLocalMarkdown(
          title: '过长',
          text: List.filled(20001, '🐜').join(),
        ),
        throwsArgumentError,
      );
      expect(native.starts, 0);
      expect(controller.tasks, isEmpty);
      await controller.generateLocalMarkdown(title: '初始化', text: '原文');
      expect(native.initializations, 1);
      expect(native.starts, 1);
    },
  );

  test('disposing during initialization never starts Python or writes to the closed store', () async {
    final gate = Completer<void>();
    final native = _TextNativeFixture()
      ..installed = false
      ..pythonAvailable = false
      ..initializationGate = gate;
    final persistence = _ClosingPersistence();
    final controller = await launch(
      native,
      persistence: persistence,
      autoDispose: false,
    );
    var disposed = false;
    addTearDown(() {
      if (!disposed) controller.dispose();
      if (!gate.isCompleted) gate.complete();
    });
    final running = controller.generateLocalMarkdown(
      title: '初始化中关闭',
      text: '不应开始执行的本地原文',
    );
    await native.initializing.future;
    expect(controller.isLocalTaskRunning, isTrue);

    controller.dispose();
    disposed = true;
    await persistence.didClose.future;
    // Initialization belongs to the host and may finish after the UI owner
    // disappears. Its late result must not schedule a new Python process.
    gate.complete();
    expect(await running, isNull);
    expect(native.starts, 0);
    expect(native.reads, 0);
    expect(controller.documents, isEmpty);
    expect(controller.messages.last.documentId, isNull);
    expect(persistence.writesAfterClose, 0);
  });

  test('nonzero and timeout exits never read or publish a result', () async {
    final native = _TextNativeFixture();
    final controller = await launch(native);
    final running = controller.generateLocalMarkdown(
      title: '失败任务',
      text: '保留原文',
    );
    await native.started.future;
    await native.complete(code: 9);
    expect(await running, isNull);
    expect(controller.documents, isEmpty);
    expect(native.reads, 0);
    expect(controller.tasks.single.status, TaskStatus.failed);
    expect(controller.error, contains('9'));
    final second = controller.generateLocalMarkdown(
      title: '超时任务',
      text: '另一份原文',
    );
    await Future.doWhile(() async {
      await Future<void>.delayed(Duration.zero);
      return native.starts < 2;
    }).timeout(const Duration(seconds: 2));
    await native.complete(code: 137, timedOut: true);
    expect(await second, isNull);
    expect(controller.documents, isEmpty);
    expect(controller.error, contains('超时'));
  });

  test('local ownership blocks mutations and failed cancellation holds it until a real late exit', () async {
    final native = _TextNativeFixture()..cancelFails = true;
    final controller = await launch(native);
    final previous = await controller.createDocument(markdown: '先前文档');
    final running = controller.generateLocalMarkdown(
      title: '正在处理',
      text: '新的原文',
    );
    await native.started.future;
    expect(controller.isLocalTaskRunning, isTrue);
    expect(controller.canChat, isFalse);
    expect(controller.acquireManualTerminal, throwsStateError);
    await expectLater(controller.createDocument(), throwsStateError);
    await expectLater(
      controller.saveDocument(previous.id, '不能改'),
      throwsStateError,
    );
    await expectLater(controller.deleteDocument(previous.id), throwsStateError);
    await expectLater(controller.newConversation(), throwsStateError);
    await expectLater(
      controller.selectConversation(controller.activeConversation.id),
      throwsStateError,
    );
    await expectLater(controller.clearConversation(), throwsStateError);
    await expectLater(
      controller.send('不发送云端', cloudApproved: true),
      throwsStateError,
    );
    controller.cancelActiveTask();
    await native.cancelCalled.future;
    await Future<void>.delayed(Duration.zero);
    expect(controller.isSending, isTrue);
    expect(controller.acquireManualTerminal, throwsStateError);
    await native.complete(
      code: 0,
    ); // Too late to publish after a cancel intent.
    expect(await running, isNull);
    expect(controller.isSending, isFalse);
    expect(controller.tasks.single.status, TaskStatus.cancelled);
    expect(controller.documents.single.id, previous.id);
    expect(native.reads, 0);
    final lease = controller.acquireManualTerminal();
    controller.releaseManualTerminal(lease);
  });

  test('a timed out start retains ownership until late native cleanup is confirmed', () async {
    final native = _TextNativeFixture()
      ..startGate = Completer<void>()
      ..cancelGate = Completer<void>();
    final controller = await launch(
      native,
      timeout: const Duration(milliseconds: 50),
    );
    final running = controller.generateLocalMarkdown(title: '迟到启动', text: '原文');
    await native.started.future;
    await native.cancelCalled.future;
    expect(controller.isSending, isTrue);
    expect(controller.acquireManualTerminal, throwsStateError);
    await native.complete(code: 137, cancelled: true);
    native.startGate!.complete();
    native.cancelGate!.complete();
    expect(await running, isNull);
    expect(controller.isSending, isFalse);
    expect(controller.tasks.single.status, TaskStatus.failed);
    expect(controller.documents, isEmpty);
    expect(native.reads, 0);
  });

  test(
    'failed publication exposes neither the document nor a completed receipt',
    () async {
      final native = _TextNativeFixture()..autoComplete = true;
      final persistence = _PublicationPersistence();
      final controller = await launch(native, persistence: persistence);
      persistence.failPublication = true;
      expect(
        await controller.generateLocalMarkdown(title: '保存失败', text: '原文仍在'),
        isNull,
      );
      expect(controller.documents, isEmpty);
      expect(controller.tasks.single.status, TaskStatus.failed);
      expect(controller.messages.last.documentId, isNull);
      final restored = await persistence.load();
      expect(restored.documents, isEmpty);
      expect(restored.tasks.single.status, TaskStatus.failed);
      expect(restored.messages.first.text, '原文仍在');
    },
  );

  testWidgets(
    'chat menu runs without a model and opens the linked editable draft',
    (tester) async {
      final native = _TextNativeFixture()..autoComplete = true;
      final controller = await launch(native);
      await tester.pumpWidget(PerantApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本地整理为 Markdown'));
      await tester.pumpAndSettle();
      expect(find.textContaining('保留原文，只整理换行与段落'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('local-text-title')),
        '本地测试',
      );
      await tester.enterText(
        find.byKey(const ValueKey('local-text-source')),
        '输入材料',
      );
      await tester.tap(find.text('在本地整理'));
      // Native-channel replies can arrive on a later event-loop turn after
      // the dialog animation settles. Wait for the real workflow completion,
      // rather than treating "no scheduled frame" as a completed native task.
      for (var turn = 0; turn < 30; turn++) {
        await tester.pump();
        if (controller.tasks.isNotEmpty && !controller.isSending) break;
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      final detail = '${controller.error} / ${controller.activeTaskDetail}';
      expect(native.starts, 1, reason: detail);
      expect(native.reads, 1, reason: detail);
      expect(controller.isSending, isFalse, reason: detail);
      expect(
        controller.tasks.single.status,
        TaskStatus.completed,
        reason: detail,
      );
      expect(controller.documents, hasLength(1), reason: detail);
      await tester.pumpAndSettle();
      expect(find.text('本地工具 · Python'), findsOneWidget);
      expect(find.text('打开文档'), findsOneWidget);
      await tester.tap(find.text('打开文档'));
      await tester.pumpAndSettle();
      expect(find.text('本地测试'), findsOneWidget);
      expect(find.text('保存并确认'), findsOneWidget);
      expect(find.text(_nativeMarkdown), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
