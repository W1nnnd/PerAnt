// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perant_platform/perant_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(ComputerBrowserBridge.methodChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('fixed reader request binds its response to the current page revision',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'readPage');
      expect(call.arguments, {'id': 'reader-1', 'expectedRevision': 7});
      return _page(text: '第一段\n\n第二段 😀', truncated: true);
    });
    final page =
        await ComputerBrowserBridge().readPage('reader-1', expectedRevision: 7);
    expect(page.text, '第一段\n\n第二段 😀');
    expect(page.truncated, isTrue);
    expect(page.url, 'https://example.com/article');
  });

  test('wrong session and stale revision cannot be saved as the observed page',
      () async {
    for (final response in [
      {..._page(), 'id': 'another-reader'},
      {..._page(), 'revision': 8},
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => response);
      await expectLater(
        ComputerBrowserBridge().readPage('reader-1', expectedRevision: 7),
        throwsA(isA<RuntimeBridgeException>()
            .having((e) => e.code, 'code', 'invalid_response')),
      );
    }
  });

  test('invalid source and incomplete or malformed text responses are rejected',
      () async {
    for (final response in [
      {..._page(), 'url': 'about:blank'},
      {..._page(), 'url': 'file:///private'},
      {..._page(), 'text': '  \n'},
      {..._page(), 'text': 'x\u0000y'},
      {..._page(), 'truncated': 'false'},
      {..._page()}..remove('truncated'),
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => response);
      await expectLater(
        ComputerBrowserBridge().readPage('reader-1'),
        throwsA(isA<RuntimeBridgeException>()
            .having((e) => e.code, 'code', 'invalid_response')),
      );
    }
  });

  test('Unicode byte budget and surrogate integrity are checked independently',
      () {
    expect(ComputerBrowserPage.fromMap(_page(text: '中' * 81920)).text.length,
        81920);
    expect(ComputerBrowserPage.fromMap(_page(text: '😀' * 60000)).text.length,
        120000);
    for (final text in ['a' * 120001, '中' * 81921, 'x\uD800', '\uDC00x']) {
      expect(() => ComputerBrowserPage.fromMap(_page(text: text)),
          throwsFormatException);
    }
  });

  test('browser state carries an optional scroll position and page height', () {
    Map<Object?, Object?> native([Map<Object?, Object?> extra = const {}]) => {
          'id': 'reader-1',
          'url': 'https://example.com/article',
          'title': '文章',
          'loading': false,
          'canGoBack': false,
          'canGoForward': false,
          'width': 1000,
          'height': 1200,
          'visible': false,
          'attached': false,
          'provider': 'Fixture WebView',
          'revision': 3,
          ...extra,
        };
    final positioned = ComputerBrowserState.fromMap(
      native({'scrollY': 2400, 'pageHeight': 9000}),
    );
    expect(positioned.scrollY, 2400);
    expect(positioned.pageHeight, 9000);
    // An older native side that does not report them stays readable.
    final legacy = ComputerBrowserState.fromMap(native());
    expect(legacy.scrollY, 0);
    expect(legacy.pageHeight, 0);
    for (final bad in <Object?>[-1, 16000001, '12', 1.5]) {
      expect(
        () => ComputerBrowserState.fromMap(native({'scrollY': bad})),
        throwsFormatException,
      );
    }
  });

  test('invalid input does not enter native code and native errors keep codes',
      () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      throw PlatformException(code: 'page_not_ready', message: '等待加载');
    });
    await expectLater(
        ComputerBrowserBridge().readPage('../wrong'), throwsArgumentError);
    await expectLater(
        ComputerBrowserBridge().readPage('reader-1', expectedRevision: -1),
        throwsArgumentError);
    expect(calls, 0);
    await expectLater(
      ComputerBrowserBridge().readPage('reader-1'),
      throwsA(isA<RuntimeBridgeException>()
          .having((e) => e.code, 'code', 'page_not_ready')),
    );
    expect(calls, 1);
  });
}

Map<String, Object?> _page(
        {String text = 'Public article', bool truncated = false}) =>
    {
      'id': 'reader-1',
      'url': 'https://example.com/article',
      'title': '文章',
      'revision': 7,
      'text': text,
      'truncated': truncated,
    };
