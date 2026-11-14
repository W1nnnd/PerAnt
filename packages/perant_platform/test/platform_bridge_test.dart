// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perant_platform/perant_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(PerantPlatformBridge.methodChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'host diagnostic response reports capabilities without enabling runtimes',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getCapabilities');
        return _capabilities();
      });

      final capabilities = await PerantPlatformBridge().getCapabilities();

      expect(capabilities.platform, 'android');
      expect(capabilities.systemVersion, 'Android test system');
      expect(capabilities.nativeBridgeAvailable, isTrue);
      expect(capabilities.linux.available, isFalse);
      expect(capabilities.localInference.available, isFalse);
      expect(capabilities.backgroundTasks.available, isFalse);
    },
  );

  test(
    'missing native plugin is an explicit unavailable capability result',
    () async {
      final capabilities = await PerantPlatformBridge().getCapabilities();

      expect(capabilities.nativeBridgeAvailable, isFalse);
      expect(capabilities.linux.available, isFalse);
      expect(capabilities.linux.reason, isNotEmpty);
      expect(await PerantPlatformBridge().events.toList(), isEmpty);
    },
  );

  test(
    'invalid or future wire schema is rejected rather than assumed available',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return {..._capabilities(), 'schemaVersion': 99};
      });

      await expectLater(
        PerantPlatformBridge().getCapabilities(),
        throwsA(
          isA<RuntimeBridgeException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
    },
  );

  test('unknown native errors preserve their code', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'native_fault',
        message: 'diagnostics failed',
      );
    });

    await expectLater(
      PerantPlatformBridge().getCapabilities(),
      throwsA(
        isA<RuntimeBridgeException>().having(
          (error) => error.code,
          'code',
          'native_fault',
        ),
      ),
    );
  });

  test('cancellation of an unstarted task remains notRunning', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'cancelTask');
      expect(call.arguments, {'taskId': 'task-1'});
      return {
        'taskId': 'task-1',
        'status': 'notRunning',
        'reason': 'No native task has started.',
      };
    });

    final result = await PerantPlatformBridge().cancelTask('task-1');

    expect(result.status, TaskCancellationStatus.notRunning);
  });

  test('cancellation cannot silently apply to a different task', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return {
        'taskId': 'different-task',
        'status': 'cancelled',
        'reason': 'Wrong task.',
      };
    });

    await expectLater(
      PerantPlatformBridge().cancelTask('task-1'),
      throwsA(isA<RuntimeBridgeException>()),
    );
  });

  test('empty task IDs are rejected before entering the platform', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls += 1;
      return null;
    });

    await expectLater(
      PerantPlatformBridge().cancelTask(' '),
      throwsArgumentError,
    );
    expect(calls, 0);
  });

  test('missing plugin cannot claim a task was cancelled', () async {
    final result = await PerantPlatformBridge().cancelTask('task-1');

    expect(result.status, TaskCancellationStatus.unavailable);
  });
}

Map<String, Object?> _capabilities() {
  const unavailable = {'available': false, 'reason': 'Not integrated.'};
  return {
    'schemaVersion': 1,
    'platform': 'android',
    'systemVersion': 'Android test system',
    'nativeBridgeAvailable': true,
    'linux': unavailable,
    'localInference': unavailable,
    'backgroundTasks': unavailable,
  };
}
