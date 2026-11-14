// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perant_platform/perant_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel(PerantPlatformBridge.methodChannelName);
  const eventControl = MethodChannel(PerantPlatformBridge.eventChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(eventControl, null);
  });

  test('Linux status reflects native installation and active process state',
      () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      expect(call.method, 'getLinuxStatus');
      return _status(installed: true, active: true, sessionId: 'terminal-1');
    });

    final result = await PerantPlatformBridge().getLinuxStatus();

    expect(result.supported, isTrue);
    expect(result.installed, isTrue);
    expect(result.active, isTrue);
    expect(result.sessionId, 'terminal-1');
    expect(result.distribution, 'Alpine');
    expect(result.version, '3.24.4');
    expect(result.workspace, '/workspace');
  });

  test('missing plugin returns unsupported status and cannot execute Linux',
      () async {
    final bridge = PerantPlatformBridge();
    for (final status in [
      await bridge.getLinuxStatus(),
      await bridge.initializeLinux(),
    ]) {
      expect(status.supported, isFalse);
      expect(status.installed, isFalse);
      expect(status.active, isFalse);
      expect(status.sessionId, isNull);
      expect(status.reason, isNotEmpty);
    }
    for (final request in <Future<Object?> Function()>[
      () => bridge.startLinuxSession(sessionId: 'terminal-1'),
      () => bridge.writeLinuxSession('terminal-1', 'pwd\n'),
      () => bridge.resizeLinuxSession('terminal-1', 80, 24),
      () => bridge.closeLinuxSession('terminal-1'),
      () => bridge.runLinuxCommand(taskId: 'task-1', command: 'pwd'),
    ]) {
      await expectLater(request(), throwsA(_bridgeError('unavailable')));
    }
  });

  test('unsupported native hosts stay unsupported during initialization',
      () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'getLinuxStatus') {
        return _status(supported: false, version: 'unavailable');
      }
      throw PlatformException(
          code: 'unavailable', message: 'Unsupported host.');
    });

    final bridge = PerantPlatformBridge();
    expect((await bridge.getLinuxStatus()).supported, isFalse);
    expect((await bridge.initializeLinux()).supported, isFalse);
    await expectLater(
      bridge.startLinuxSession(sessionId: 'terminal-1'),
      throwsA(_bridgeError('unavailable')),
    );
  });

  test('initialization has a separate timeout from ordinary status calls',
      () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return _status(installed: true);
    });
    final bridge = PerantPlatformBridge(
      responseTimeout: const Duration(milliseconds: 5),
      initializationTimeout: const Duration(milliseconds: 150),
    );

    await expectLater(
      bridge.getLinuxStatus(),
      throwsA(_bridgeError('timeout')),
    );
    expect((await bridge.initializeLinux()).installed, isTrue);
    expect(
      PerantPlatformBridge().initializationTimeout,
      const Duration(seconds: 300),
    );
  });

  test('session lifecycle and commands use exact channel arguments', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return switch (call.method) {
        'startLinuxSession' => {
            'sessionId': 'terminal-1',
            'pid': 42,
            'workspace': '/workspace',
          },
        'runLinuxCommand' => {'taskId': 'task-1', 'pid': 43},
        _ => null,
      };
    });
    final bridge = PerantPlatformBridge();

    final session = await bridge.startLinuxSession(sessionId: 'terminal-1');
    expect(session.sessionId, 'terminal-1');
    expect(session.pid, 42);
    expect(session.workspace, '/workspace');
    await bridge.writeLinuxSession('terminal-1', '你好\n');
    await bridge.resizeLinuxSession('terminal-1', 100, 32);
    await bridge.closeLinuxSession('terminal-1');
    final command = await bridge.runLinuxCommand(
      taskId: 'task-1',
      command: 'printf hello',
      timeout: const Duration(seconds: 12),
    );
    expect(command.taskId, 'task-1');
    expect(command.pid, 43);
    expect(calls.map((call) => call.method), [
      'startLinuxSession',
      'writeLinuxSession',
      'resizeLinuxSession',
      'closeLinuxSession',
      'runLinuxCommand',
    ]);
    expect(calls.map((call) => call.arguments), [
      {'sessionId': 'terminal-1', 'columns': 80, 'rows': 24},
      {'sessionId': 'terminal-1', 'data': '你好\n'},
      {'sessionId': 'terminal-1', 'columns': 100, 'rows': 32},
      {'sessionId': 'terminal-1'},
      {'taskId': 'task-1', 'command': 'printf hello', 'timeoutMs': 12000},
    ]);
  });

  test('invalid parameters never enter the native channel', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls += 1;
      return null;
    });
    final bridge = PerantPlatformBridge();
    for (final request in <Future<Object?> Function()>[
      () => bridge.startLinuxSession(sessionId: ' '),
      () => bridge.startLinuxSession(sessionId: 'a' * 129),
      () => bridge.startLinuxSession(sessionId: 'terminal-1', columns: 0),
      () => bridge.startLinuxSession(sessionId: 'terminal-1', rows: 501),
      () => bridge.resizeLinuxSession('terminal-1', 501, 24),
      () => bridge.closeLinuxSession(''),
      () => bridge.writeLinuxSession('terminal-1', '界' * 21846),
      () => bridge.runLinuxCommand(taskId: '', command: 'pwd'),
      () => bridge.runLinuxCommand(taskId: 'task-1', command: ' \n'),
      () => bridge.runLinuxCommand(taskId: 'task-1', command: 'a' * 65537),
      () => bridge.runLinuxCommand(
            taskId: 'task-1',
            command: 'pwd',
            timeout: Duration.zero,
          ),
      () => bridge.runLinuxCommand(
            taskId: 'task-1',
            command: 'pwd',
            timeout: const Duration(milliseconds: 300001),
          ),
    ]) {
      await expectLater(request(), throwsArgumentError);
    }
    expect(calls, 0);
  });

  test('native handles must match requested IDs and valid process types',
      () async {
    final bridge = PerantPlatformBridge();
    for (final response in <Object?>[
      null,
      {'sessionId': 'other', 'pid': 42, 'workspace': '/workspace'},
      {'sessionId': 'terminal-1', 'pid': 0, 'workspace': '/workspace'},
      {'sessionId': 'terminal-1', 'pid': '42', 'workspace': '/workspace'},
      {'sessionId': 'terminal-1', 'pid': 42, 'workspace': '/private'},
    ]) {
      messenger.setMockMethodCallHandler(methods, (call) async => response);
      await expectLater(
        bridge.startLinuxSession(sessionId: 'terminal-1'),
        throwsA(_bridgeError('invalid_response')),
      );
    }
    for (final response in <Object?>[
      null,
      {'taskId': 'other', 'pid': 42},
      {'taskId': 'task-1', 'pid': 1.5},
    ]) {
      messenger.setMockMethodCallHandler(methods, (call) async => response);
      await expectLater(
        bridge.runLinuxCommand(taskId: 'task-1', command: 'pwd'),
        throwsA(_bridgeError('invalid_response')),
      );
    }
  });

  test('malformed status and non-void acknowledgements are rejected', () async {
    final bridge = PerantPlatformBridge();
    for (final response in <Object?>[
      null,
      {..._status(), 'supported': 'true'},
      _status(supported: false, installed: true),
      _status(installed: false, active: true),
      {..._status(), 'workspace': '/tmp'},
      {..._status(), 'sessionId': 10},
    ]) {
      messenger.setMockMethodCallHandler(methods, (call) async => response);
      await expectLater(
        bridge.getLinuxStatus(),
        throwsA(_bridgeError('invalid_response')),
      );
    }
    messenger.setMockMethodCallHandler(methods, (call) async => true);
    await expectLater(
      bridge.closeLinuxSession('terminal-1'),
      throwsA(_bridgeError('invalid_response')),
    );
  });

  test('native process ownership and output survive the event channel',
      () async {
    final listening = Completer<void>();
    messenger.setMockMethodCallHandler(
        methods, (call) async => _capabilities());
    messenger.setMockMethodCallHandler(eventControl, (call) async {
      if (call.method == 'listen') listening.complete();
      return null;
    });
    final received = PerantPlatformBridge().events.toList();
    await listening.future;
    for (final event in [
      _event(
          'linuxOutput', {'sessionId': 'terminal-1', 'text': '\u001b[32mHi'}),
      _event('linuxOutput', {'text': 'done\n'}, taskId: 'task-1'),
      _event(
        'linuxExit',
        {'exitCode': 143, 'cancelled': true, 'timedOut': false},
        taskId: 'task-1',
      ),
    ]) {
      await messenger.handlePlatformMessage(
        PerantPlatformBridge.eventChannelName,
        const StandardMethodCodec().encodeSuccessEnvelope(event),
        (_) {},
      );
    }
    await messenger.handlePlatformMessage(
      PerantPlatformBridge.eventChannelName,
      null,
      (_) {},
    );
    final events = await received;
    expect(events, hasLength(3));
    expect(events.first.payload['sessionId'], 'terminal-1');
    expect(events.first.payload['text'], '\u001b[32mHi');
    expect(events[1].taskId, 'task-1');
    expect(events.last.payload['exitCode'], 143);
    expect(events.last.payload['cancelled'], isTrue);
  });

  test('known Linux events reject malformed payloads and missing ownership',
      () {
    for (final event in [
      _event('linuxOutput', {'text': 'unowned'}),
      _event('linuxOutput', {'sessionId': 'terminal-1', 'text': 3}),
      _event('linuxOutput', {'sessionId': 1, 'text': 'bad'}),
      _event('linuxExit', {'exitCode': '0'}, taskId: 'task-1'),
      _event(
        'linuxExit',
        {'exitCode': 0, 'cancelled': false, 'timedOut': 'false'},
        taskId: 'task-1',
      ),
    ]) {
      expect(() => RuntimeEvent.fromMap(event), throwsFormatException);
    }
    expect(
      RuntimeEvent.fromMap(_event('futureEvent', {'custom': true})).type,
      'futureEvent',
    );
  });
}

Matcher _bridgeError(String code) => isA<RuntimeBridgeException>().having(
      (error) => error.code,
      'code',
      code,
    );

Map<String, Object?> _status({
  bool supported = true,
  bool installed = false,
  bool active = false,
  String? sessionId,
  String version = '3.24.4',
}) =>
    {
      'supported': supported,
      'installed': installed,
      'active': active,
      'sessionId': sessionId,
      'distribution': 'Alpine',
      'version': version,
      'workspace': '/workspace',
      'reason': installed ? '' : 'Not initialized.',
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
