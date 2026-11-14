// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perant_platform/perant_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(PerantPlatformBridge.methodChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('import sends content only and accepts a generated root-only receipt',
      () async {
    const content = '# 资料 🐜\n\n\$(touch never) <script>plain text</script>\n';
    late MethodCall observed;
    messenger.setMockMethodCallHandler(channel, (call) async {
      observed = call;
      return _receipt(content);
    });
    final result =
        await PerantPlatformBridge().importLinuxTextFile(content: content);
    expect(observed.method, 'importLinuxTextFile');
    expect(observed.arguments, {'content': content});
    expect(
        result.path, '/workspace/web-12345678-1234-1234-1234-123456789abc.md');
    expect(result.sizeBytes, utf8.encode(content).length);
    expect(result.sha256, '0' * 64);
  });

  test('import validates UTF-8 byte quota and NUL before native calls',
      () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return _receipt((call.arguments as Map)['content'] as String);
    });
    final bridge = PerantPlatformBridge();
    for (final content in [
      '\u0000',
      String.fromCharCode(0xd800),
      '🐜' * 65537,
    ]) {
      await expectLater(
          bridge.importLinuxTextFile(content: content), throwsArgumentError);
    }
    expect(calls, 0);
    final result = await bridge.importLinuxTextFile(content: '🐜' * 65536);
    expect(result.sizeBytes, 262144);
    expect(calls, 1);
  });

  test('import rejects malformed path, byte count and digest receipts',
      () async {
    final bridge = PerantPlatformBridge();
    for (final response in [
      null,
      {..._receipt('x'), 'path': '/workspace/elsewhere.md'},
      {
        ..._receipt('x'),
        'path': '/workspace/sub/web-12345678-1234-1234-1234-123456789abc.md'
      },
      {
        ..._receipt('x'),
        'path': '/workspace/../web-12345678-1234-1234-1234-123456789abc.md'
      },
      {..._receipt('x'), 'sha256': 'A' * 64},
      {..._receipt('x'), 'sizeBytes': 2},
      {..._receipt('x'), 'sizeBytes': -1},
      {..._receipt('x'), 'sizeBytes': 262145},
    ]) {
      messenger.setMockMethodCallHandler(channel, (call) async => response);
      await expectLater(bridge.importLinuxTextFile(content: 'x'),
          throwsA(_error('invalid_response')));
    }
  });

  test('import preserves explicit native busy, conflict and storage failures',
      () async {
    final bridge = PerantPlatformBridge();
    await expectLater(bridge.importLinuxTextFile(content: 'x'),
        throwsA(_error('unavailable')));
    for (final code in [
      'busy',
      'not_installed',
      'file_conflict',
      'storage_error'
    ]) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: code, message: 'Import refused.');
      });
      await expectLater(
          bridge.importLinuxTextFile(content: 'x'), throwsA(_error(code)));
    }
  });
}

Map<String, Object?> _receipt(String content) => {
      'path': '/workspace/web-12345678-1234-1234-1234-123456789abc.md',
      'sha256': '0' * 64,
      'sizeBytes': utf8.encode(content).length,
    };

Matcher _error(String code) =>
    isA<RuntimeBridgeException>().having((value) => value.code, 'code', code);
