// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perant_platform/perant_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel(PerantPlatformBridge.methodChannelName);
  const eventControl = MethodChannel(PerantPlatformBridge.eventChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> sendEvent(Map<String, Object?>? event) async {
    await messenger.handlePlatformMessage(
      PerantPlatformBridge.eventChannelName,
      event == null
          ? null
          : const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
  }

  tearDown(() async {
    await sendEvent(null);
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(eventControl, null);
  });

  test('text task sends full structured Unicode input without shell encoding',
      () async {
    late MethodCall observed;
    messenger.setMockMethodCallHandler(methods, (call) async {
      observed = call;
      return {'taskId': 'text-1', 'pid': 43};
    });
    // 20,000 astral characters are 40,000 UTF-16 code units and 80,000 UTF-8
    // bytes. This deliberately exceeds the ordinary shell-command limit.
    final text = '🐜' * 20000;
    final handle = await PerantPlatformBridge().startLinuxTextTask(
      taskId: 'text-1',
      title: r"原文：$(touch should-not-run); ' \ 🌍",
      text: text,
      timeout: const Duration(seconds: 12),
    );

    expect(handle.taskId, 'text-1');
    expect(handle.pid, 43);
    expect(observed.method, 'startLinuxTextTask');
    expect(observed.arguments, {
      'taskId': 'text-1',
      'title': r"原文：$(touch should-not-run); ' \ 🌍",
      'text': text,
      'timeoutMs': 12000,
    });
    expect((observed.arguments as Map).containsKey('command'), isFalse);
  });

  test('text task IDs, character limits and controls fail before native calls',
      () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls++;
      return null;
    });
    final bridge = PerantPlatformBridge();
    for (final id in [
      '',
      ' ',
      '../task',
      '.task',
      'task/child',
      '中文',
      'a' * 97
    ]) {
      await expectLater(
        bridge.startLinuxTextTask(taskId: id, title: '标题', text: '原文'),
        throwsArgumentError,
      );
      await expectLater(
          bridge.readLinuxTextTaskResult(id), throwsArgumentError);
    }
    for (final title in [
      '',
      '   ',
      'a\nb',
      'a\rb',
      'a\tb',
      'a\u007fb',
      'a\u0085b',
      'a\u2028b',
      '🐜' * 81,
      String.fromCharCode(0xd800),
    ]) {
      await expectLater(
        bridge.startLinuxTextTask(taskId: 'task-1', title: title, text: '原文'),
        throwsArgumentError,
      );
    }
    for (final text in [
      '',
      ' \n',
      'a\u0000b',
      '界' * 20001,
      '🐜' * 20001,
      String.fromCharCode(0xd800),
    ]) {
      await expectLater(
        bridge.startLinuxTextTask(taskId: 'task-1', title: '标题', text: text),
        throwsArgumentError,
      );
    }
    for (final timeout in [
      Duration.zero,
      const Duration(milliseconds: 300001),
    ]) {
      await expectLater(
        bridge.startLinuxTextTask(
          taskId: 'task-1',
          title: '标题',
          text: '原文',
          timeout: timeout,
        ),
        throwsArgumentError,
      );
    }
    expect(calls, 0);
  });

  test('title limit counts Unicode characters and retains original text',
      () async {
    late Map<Object?, Object?> observed;
    messenger.setMockMethodCallHandler(methods, (call) async {
      observed = Map<Object?, Object?>.from(call.arguments as Map);
      return {'taskId': 'a' * 96, 'pid': 42};
    });
    final title = '🐜' * 80;
    const text = '  中文\r\n\t\$(echo unsafe)\n\n保持原文 🌍  ';
    await PerantPlatformBridge().startLinuxTextTask(
      taskId: 'a' * 96,
      title: title,
      text: text,
    );
    expect(observed['title'], title);
    expect(observed['text'], text);
    expect(observed['timeoutMs'], 30000);
  });

  test('result reads exact task output path and counts UTF-8 file bytes',
      () async {
    late MethodCall observed;
    const markdown = '# 原文 🐜\n\n保留所有文字。\n';
    messenger.setMockMethodCallHandler(methods, (call) async {
      observed = call;
      return _result(markdown: markdown);
    });
    final result =
        await PerantPlatformBridge().readLinuxTextTaskResult('text-1');
    expect(observed.method, 'readLinuxTextTaskResult');
    expect(observed.arguments, {'taskId': 'text-1'});
    expect(result.taskId, 'text-1');
    expect(result.markdown, markdown);
    expect(result.workspacePath, '/workspace/.perant-tasks/text-1/output.md');
    expect(result.sizeBytes, utf8.encode(markdown).length);
  });

  test('mismatched task handles and malformed file responses are rejected',
      () async {
    final bridge = PerantPlatformBridge();
    for (final response in <Object?>[
      null,
      {'taskId': 'other', 'pid': 1},
      {'taskId': 'text-1', 'pid': 0},
    ]) {
      messenger.setMockMethodCallHandler(methods, (call) async => response);
      await expectLater(
        bridge.startLinuxTextTask(taskId: 'text-1', title: '标题', text: '原文'),
        throwsA(_bridgeError('invalid_response')),
      );
    }
    for (final response in <Object?>[
      null,
      _result(taskId: 'other'),
      _result(taskId: '../task'),
      {..._result(), 'workspacePath': '/workspace/other/output.md'},
      {
        ..._result(),
        'workspacePath': '/workspace/.perant-tasks/text-1/../output.md'
      },
      {..._result(), 'sizeBytes': 1},
      {..._result(), 'sizeBytes': '5'},
      _result(markdown: ''),
      _result(markdown: ' \n'),
      _result(markdown: 'a' * 262145),
      {..._result(), 'markdown': 42},
    ]) {
      messenger.setMockMethodCallHandler(methods, (call) async => response);
      await expectLater(
        bridge.readLinuxTextTaskResult('text-1'),
        throwsA(_bridgeError('invalid_response')),
      );
    }
    // StandardMethodCodec encodes strings as UTF-8, replacing an unpaired
    // surrogate before a mock native response can reach the bridge. Validate
    // this malformed in-memory value directly instead of expecting the valid
    // replacement character received across the channel to be distinguishable.
    expect(
      () => LinuxTextTaskResult.fromMap(
        _result(markdown: String.fromCharCode(0xd800)),
      ),
      throwsFormatException,
    );
  });

  test('text task methods preserve unavailable native behavior', () async {
    final bridge = PerantPlatformBridge();
    await expectLater(
      bridge.startLinuxTextTask(taskId: 'text-1', title: '标题', text: '原文'),
      throwsA(_bridgeError('unavailable')),
    );
    await expectLater(bridge.readLinuxTextTaskResult('text-1'),
        throwsA(_bridgeError('unavailable')));
    messenger.setMockMethodCallHandler(methods, (call) async {
      throw PlatformException(
          code: 'python_unavailable', message: 'Initialize Python first.');
    });
    await expectLater(
      bridge.startLinuxTextTask(taskId: 'text-1', title: '标题', text: '原文'),
      throwsA(_bridgeError('python_unavailable')),
    );
  });

  test('Python status is opt-in and requires a supported installed host',
      () async {
    final bridge = PerantPlatformBridge();
    messenger.setMockMethodCallHandler(methods, (call) async => _status());
    expect((await bridge.getLinuxStatus()).pythonAvailable, isFalse);
    messenger.setMockMethodCallHandler(
        methods,
        (call) async => {
              ..._status(),
              'pythonAvailable': true,
              'pythonVersion': '3.14.10',
            });
    final ready = await bridge.getLinuxStatus();
    expect(ready.pythonAvailable, isTrue);
    expect(ready.pythonVersion, '3.14.10');
    for (final response in [
      {..._status(), 'pythonAvailable': 'true'},
      {..._status(), 'pythonAvailable': true},
      {..._status(), 'pythonAvailable': true, 'pythonVersion': ' '},
      {..._status(), 'pythonAvailable': true, 'pythonVersion': 314},
      {
        ..._status(),
        'installed': false,
        'pythonAvailable': true,
        'pythonVersion': '3.14.10',
      },
      {
        ..._status(),
        'supported': false,
        'installed': false,
        'pythonAvailable': true,
        'pythonVersion': '3.14.10',
      },
    ]) {
      messenger.setMockMethodCallHandler(methods, (call) async => response);
      await expectLater(
          bridge.getLinuxStatus(), throwsA(_bridgeError('invalid_response')));
    }
  });

  test('event readiness waits for a real handshake and late listeners reuse it',
      () async {
    final listening = Completer<void>();
    messenger.setMockMethodCallHandler(
        methods, (call) async => _capabilities());
    messenger.setMockMethodCallHandler(eventControl, (call) async {
      if (call.method == 'listen') listening.complete();
      return null;
    });
    final bridge = PerantPlatformBridge();
    final firstEvents = <RuntimeEvent>[];
    final first = bridge.events.listen(firstEvents.add);
    await listening.future;
    var attached = false;
    final readiness = bridge.ensureRuntimeEventsAttached().then((_) {
      attached = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(attached, isFalse);
    await sendEvent(_event('futureEvent', {'custom': true}));
    await Future<void>.delayed(Duration.zero);
    expect(attached, isFalse);
    await sendEvent(_event('bridgeAttached', _capabilities()));
    await readiness;
    expect(attached, isTrue);
    await first.cancel();
    final lateEvents = <RuntimeEvent>[];
    final late = bridge.events.listen(lateEvents.add);
    await bridge.ensureRuntimeEventsAttached();
    expect(lateEvents, isEmpty);
    await sendEvent(_event('linuxOutput', {'text': 'ready'}, taskId: 'text-1'));
    await Future<void>.delayed(Duration.zero);
    expect(lateEvents.single.taskId, 'text-1');
    expect(firstEvents.where((event) => event.type == 'bridgeAttached'),
        hasLength(1));
    await late.cancel();
  });

  test('event readiness times out without inventing a connection', () async {
    final listening = Completer<void>();
    messenger.setMockMethodCallHandler(
        methods, (call) async => _capabilities());
    messenger.setMockMethodCallHandler(eventControl, (call) async {
      if (call.method == 'listen') listening.complete();
      return null;
    });
    final bridge = PerantPlatformBridge(
      responseTimeout: const Duration(milliseconds: 5),
    );
    final subscription = bridge.events.listen((_) {});
    await listening.future;
    await expectLater(
        bridge.ensureRuntimeEventsAttached(), throwsA(_bridgeError('timeout')));
    // A genuinely later handshake may establish a connection; timeout alone
    // must neither fake readiness nor poison a still-listening EventChannel.
    await sendEvent(_event('bridgeAttached', _capabilities()));
    await bridge.ensureRuntimeEventsAttached();
    await subscription.cancel();
  });

  test('malformed and closed event channels cannot report attached', () async {
    final listening = Completer<void>();
    messenger.setMockMethodCallHandler(
        methods, (call) async => _capabilities());
    messenger.setMockMethodCallHandler(eventControl, (call) async {
      if (call.method == 'listen') listening.complete();
      return null;
    });
    final bridge = PerantPlatformBridge();
    final errors = <Object>[];
    final done = Completer<void>();
    bridge.events.listen((_) {}, onError: errors.add, onDone: done.complete);
    await listening.future;
    await sendEvent(_event('bridgeAttached', {'nativeBridgeAvailable': true}));
    await expectLater(bridge.ensureRuntimeEventsAttached(),
        throwsA(_bridgeError('invalid_response')));
    await done.future;
    expect(errors.single, isA<FormatException>());
    await expectLater(bridge.ensureRuntimeEventsAttached(),
        throwsA(_bridgeError('invalid_response')));
  });

  test('a normally closed event channel invalidates cached readiness',
      () async {
    final listening = Completer<void>();
    messenger.setMockMethodCallHandler(
        methods, (call) async => _capabilities());
    messenger.setMockMethodCallHandler(eventControl, (call) async {
      if (call.method == 'listen') listening.complete();
      return null;
    });
    final bridge = PerantPlatformBridge();
    final done = Completer<void>();
    bridge.events.listen((_) {}, onDone: done.complete);
    await listening.future;
    await sendEvent(_event('bridgeAttached', _capabilities()));
    await bridge.ensureRuntimeEventsAttached();
    await sendEvent(null);
    await done.future;
    await expectLater(bridge.ensureRuntimeEventsAttached(),
        throwsA(_bridgeError('event_stream_closed')));
  });

  test('missing native host cannot establish event readiness', () async {
    final bridge = PerantPlatformBridge();
    final subscription = bridge.events.listen((_) {});
    await expectLater(bridge.ensureRuntimeEventsAttached(),
        throwsA(_bridgeError('unavailable')));
    await subscription.cancel();
  });
}

Matcher _bridgeError(String code) => isA<RuntimeBridgeException>().having(
      (error) => error.code,
      'code',
      code,
    );

Map<String, Object?> _result({
  String taskId = 'text-1',
  String markdown = '# 标题\n\n原文 🌍\n',
}) =>
    {
      'taskId': taskId,
      'markdown': markdown,
      'workspacePath': '/workspace/.perant-tasks/$taskId/output.md',
      'sizeBytes': utf8.encode(markdown).length,
    };

Map<String, Object?> _status() => {
      'supported': true,
      'installed': true,
      'active': false,
      'sessionId': null,
      'distribution': 'Alpine',
      'version': '3.24.4',
      'workspace': '/workspace',
      'reason': '',
    };

Map<String, Object?> _capabilities() => {
      'schemaVersion': 1,
      'platform': 'android',
      'systemVersion': 'Android test system',
      'nativeBridgeAvailable': true,
      for (final name in ['linux', 'localInference', 'backgroundTasks'])
        name: {'available': false, 'reason': 'Not integrated.'},
    };

Map<String, Object?> _event(
  String type,
  Map<String, Object?> payload, {
  String? taskId,
}) =>
    {
      'type': type,
      'emittedAtEpochMs': 1000,
      'taskId': taskId,
      'payload': payload,
    };
