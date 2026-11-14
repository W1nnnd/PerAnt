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

  test('shared files normalize paths and preserve exact structured Unicode',
      () async {
    final observed = <MethodCall>[];
    const content = '# 中文 🐜\n\n\$(touch never); <script>kept</script>\n';
    messenger.setMockMethodCallHandler(channel, (call) async {
      observed.add(call);
      return switch (call.method) {
        'createLinuxDirectory' => null,
        'listLinuxDirectory' => {
            'path': '/workspace/资料',
            'entries': [_entry()],
            'truncated': false,
          },
        _ => _file(content: content),
      };
    });
    final bridge = PerantPlatformBridge();
    await bridge.createLinuxDirectory('资料');
    final saved = await bridge.writeLinuxFile(
      path: '资料/会议.md',
      content: content,
      createOnly: true,
    );
    final listing = await bridge.listLinuxDirectory('资料');
    final read = await bridge.readLinuxFile('/workspace/资料/会议.md');
    expect(saved.content, content);
    expect(saved.sizeBytes, utf8.encode(content).length);
    expect(read.path, saved.path);
    expect(listing.entries.single.path, saved.path);
    expect(observed.map((call) => call.method), [
      'createLinuxDirectory',
      'writeLinuxFile',
      'listLinuxDirectory',
      'readLinuxFile',
    ]);
    expect(observed[0].arguments, {'path': '/workspace/资料'});
    expect(observed[1].arguments, {
      'path': '/workspace/资料/会议.md',
      'content': content,
      'expectedSha256': null,
      'createOnly': true,
    });
  });

  test(
      'updates transmit the exact last-read digest and default never overwrites',
      () async {
    late MethodCall observed;
    messenger.setMockMethodCallHandler(channel, (call) async {
      observed = call;
      return _file(content: 'edit');
    });
    await PerantPlatformBridge().writeLinuxFile(
      path: '资料/会议.md',
      content: 'edit',
      expectedSha256: '1' * 64,
    );
    expect(observed.arguments, {
      'path': '/workspace/资料/会议.md',
      'content': 'edit',
      'expectedSha256': '1' * 64,
      'createOnly': false,
    });
  });

  test('unsafe paths and invalid text fail before the native channel',
      () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return null;
    });
    final bridge = PerantPlatformBridge();
    for (final path in [
      '',
      '/',
      '/etc/passwd',
      '/workspace-other/note',
      '.',
      '..',
      '../file',
      '/workspace/../file',
      'a//b',
      'a/./b',
      'a/',
      r'a\b',
      '.perant-tasks/input.json',
      'dir/.perant-write-anything',
      'a\nb',
      'a\u0000b',
      '界' * 86,
      String.fromCharCode(0xd800),
    ]) {
      await expectLater(bridge.listLinuxDirectory(path), throwsArgumentError);
      await expectLater(bridge.readLinuxFile(path), throwsArgumentError);
      await expectLater(bridge.createLinuxDirectory(path), throwsArgumentError);
      await expectLater(
        bridge.writeLinuxFile(path: path, content: 'x'),
        throwsArgumentError,
      );
    }
    await expectLater(bridge.readLinuxFile('/workspace'), throwsArgumentError);
    for (final text in [
      'a' * 262145,
      'a\u0000b',
      String.fromCharCode(0xd800)
    ]) {
      await expectLater(
        bridge.writeLinuxFile(path: 'file.md', content: text),
        throwsArgumentError,
      );
    }
    for (final digest in ['', 'A' * 64, '0' * 63, '../file']) {
      await expectLater(
        bridge.writeLinuxFile(
          path: 'file.md',
          content: 'x',
          expectedSha256: digest,
        ),
        throwsArgumentError,
      );
    }
    await expectLater(
      bridge.writeLinuxFile(
        path: 'file.md',
        content: 'x',
        expectedSha256: '0' * 64,
        createOnly: true,
      ),
      throwsArgumentError,
    );
    expect(calls, 0);
  });

  test('empty files and the exact UTF-8 byte limit are accepted', () async {
    final bridge = PerantPlatformBridge();
    for (final text in ['', '🐜' * 65536]) {
      messenger.setMockMethodCallHandler(
          channel, (call) async => _file(content: text));
      final file = await bridge.writeLinuxFile(
        path: '资料/会议.md',
        content: text,
        createOnly: true,
      );
      expect(file.content, text);
      expect(file.sizeBytes, utf8.encode(text).length);
    }
  });

  test('file response must match requested owner, content and byte size',
      () async {
    final bridge = PerantPlatformBridge();
    for (final response in [
      null,
      {..._file(), 'path': '/workspace/other.md'},
      {..._file(), 'path': '/workspace/资料/../会议.md'},
      {..._file(), 'sha256': 'invalid'},
      {..._file(), 'sizeBytes': 2},
      {..._file(), 'sizeBytes': -1},
      {..._file(), 'content': 42},
      _file(content: 'a\u0000b'),
      _file(content: 'a' * 262145),
    ]) {
      messenger.setMockMethodCallHandler(channel, (call) async => response);
      await expectLater(bridge.readLinuxFile('资料/会议.md'),
          throwsA(_error('invalid_response')));
    }
    messenger.setMockMethodCallHandler(
        channel, (call) async => _file(content: 'different'));
    await expectLater(
      bridge.writeLinuxFile(path: '资料/会议.md', content: 'expected'),
      throwsA(_error('invalid_response')),
    );
    expect(
        () =>
            LinuxTextFile.fromMap(_file(content: String.fromCharCode(0xd800))),
        throwsFormatException);
  });

  test(
      'directory responses reject duplicates, foreign files and malformed metadata',
      () async {
    final bridge = PerantPlatformBridge();
    for (final response in [
      null,
      {'path': '/workspace/other', 'entries': [], 'truncated': false},
      {
        'path': '/workspace/资料',
        'entries': [_entry(), _entry()],
        'truncated': false
      },
      {
        'path': '/workspace/资料',
        'entries': [
          {..._entry(), 'path': '/workspace/file.md'}
        ],
        'truncated': false
      },
      {
        'path': '/workspace/资料',
        'entries': [
          {..._entry(), 'name': 'other'}
        ],
        'truncated': false
      },
      {
        'path': '/workspace/资料',
        'entries': [
          {..._entry(), 'sizeBytes': -1}
        ],
        'truncated': false
      },
      {
        'path': '/workspace/资料',
        'entries': [
          {..._entry(), 'isDirectory': true}
        ],
        'truncated': false
      },
      {
        'path': '/workspace/资料',
        'entries': [
          {..._entry(), 'modifiedAtEpochMs': -1}
        ],
        'truncated': false
      },
      {
        'path': '/workspace/资料',
        'entries': List.filled(501, _entry()),
        'truncated': false
      },
      {'path': '/workspace/资料', 'entries': [], 'truncated': 'no'},
    ]) {
      messenger.setMockMethodCallHandler(channel, (call) async => response);
      await expectLater(
          bridge.listLinuxDirectory('资料'), throwsA(_error('invalid_response')));
    }
  });

  test('native errors and unavailable hosts remain explicit', () async {
    final bridge = PerantPlatformBridge();
    await expectLater(bridge.listLinuxDirectory('/workspace'),
        throwsA(_error('unavailable')));
    await expectLater(
        bridge.readLinuxFile('file.md'), throwsA(_error('unavailable')));
    await expectLater(bridge.writeLinuxFile(path: 'file.md', content: 'x'),
        throwsA(_error('unavailable')));
    await expectLater(
        bridge.createLinuxDirectory('project'), throwsA(_error('unavailable')));
    for (final code in [
      'busy',
      'not_installed',
      'file_conflict',
      'unsupported_file'
    ]) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
            code: code, message: 'Native file request refused.');
      });
      await expectLater(bridge.readLinuxFile('file.md'), throwsA(_error(code)));
    }
    messenger.setMockMethodCallHandler(channel, (call) async => true);
    await expectLater(bridge.createLinuxDirectory('project'),
        throwsA(_error('invalid_response')));
  });
}

Map<String, Object?> _file({String content = '中文 🐜'}) => {
      'path': '/workspace/资料/会议.md',
      'content': content,
      'sha256': '0' * 64,
      'sizeBytes': utf8.encode(content).length,
    };

Map<String, Object?> _entry() => {
      'name': '会议.md',
      'path': '/workspace/资料/会议.md',
      'isDirectory': false,
      'sizeBytes': 12,
      'modifiedAtEpochMs': 1000,
    };

Matcher _error(String code) => isA<RuntimeBridgeException>().having(
      (value) => value.code,
      'code',
      code,
    );
