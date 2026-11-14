// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perant/src/application/browser_page_document.dart';
import 'package:perant/src/application/computer_browser_service.dart';
import 'package:perant_platform/perant_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ComputerBrowserPage page(String text, {bool truncated = false}) =>
      ComputerBrowserPage(
        id: 'test',
        url: 'https://example.com/article?q=1&lang=zh',
        title: '测试网页',
        revision: 1,
        text: text,
        truncated: truncated,
      );
  final date = DateTime.utc(2026, 11, 14);

  test('excerpt preserves source and paragraphs but renders page syntax literally', () {
    final document = buildBrowserPageDocument(
      page(
        '第一段 😀\n\n![track](https://example.com/pixel)\n<script>bad()</script>',
      ),
      savedAt: date,
    );
    expect(document.truncated, isFalse);
    expect(document.content, contains('第一段 😀\n\n'));
    expect(
      document.content,
      contains(r'\!\[track\]\(https://example\.com/pixel\)'),
    );
    expect(
      document.content,
      contains('&lt;script&gt;bad\\(\\)&lt;/script&gt;'),
    );
    expect(document.content, contains('2026-11-14T00:00:00.000Z'));
    expect(
      document.content,
      contains('来源：https://example\\.com/article?q=1&amp;lang=zh'),
    );
    expect(document.content, isNot(contains('<script>')));
  });

  test('UTF8 budget includes escaping and a visible truncation notice', () {
    final document = buildBrowserPageDocument(
      page(List.filled(60000, '&😀').join()),
      savedAt: date,
    );
    final bytes = utf8.encode(document.content);
    expect(bytes.length, lessThanOrEqualTo(262144));
    expect(utf8.decode(bytes), document.content);
    expect(document.truncated, isTrue);
    expect(document.content, contains('正文已截断'));
    expect(document.content, isNot(contains('\uFFFD')));
  });

  test('native traversal truncation remains explicit for a short excerpt', () {
    final document = buildBrowserPageDocument(
      page('已提取的正文', truncated: true),
      savedAt: date,
    );
    expect(document.truncated, isTrue);
    expect(document.content, contains('不是完整网页归档'));
  });

  group('shared browser page publication', () {
    const browserChannel = MethodChannel('dev.perant/browser');
    const runtimeChannel = MethodChannel('dev.perant/runtime');
    late ComputerBrowserService service;
    late Map<String, Object?> native;
    late List<MethodCall> browserCalls;
    late List<MethodCall> runtimeCalls;
    late Uint8List png;
    Completer<void>? readGate;
    Completer<void>? importGate;
    PlatformException? importFailure;
    const savedPath = '/workspace/web-12345678-1234-1234-1234-123456789abc.md';
    setUp(() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(640, 480);
      png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
          .asUint8List();
      image.dispose();
      picture.dispose();
      native = {
        'id': 'test',
        'url': 'https://example.com/article',
        'title': '测试网页',
        'loading': false,
        'canGoBack': false,
        'canGoForward': false,
        'width': 640,
        'height': 480,
        'visible': false,
        'attached': false,
        'provider': 'test fixture',
        'revision': 1,
      };
      browserCalls = [];
      runtimeCalls = [];
      readGate = null;
      importGate = null;
      importFailure = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(browserChannel, (call) async {
            browserCalls.add(call);
            final args = Map<String, Object?>.from(call.arguments as Map);
            switch (call.method) {
              case 'open':
                native = {...native, 'id': args['id'], 'url': args['url']};
                return native;
              case 'state':
                return native;
              case 'capture':
                return {
                  'state': native,
                  'width': 640,
                  'height': 480,
                  'png': png,
                };
              case 'readPage':
                await readGate?.future;
                return {
                  'id': native['id'],
                  'url': native['url'],
                  'title': native['title'],
                  'revision': native['revision'],
                  'text': '第一段 😀\n\n资料内容',
                  'truncated': false,
                };
              case 'cancel':
              case 'close':
                return null;
              default:
                throw MissingPluginException(call.method);
            }
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(runtimeChannel, (call) async {
            runtimeCalls.add(call);
            if (call.method != 'importLinuxTextFile')
              throw MissingPluginException(call.method);
            await importGate?.future;
            if (importFailure != null) throw importFailure!;
            final args = Map<String, Object?>.from(call.arguments as Map);
            return {
              'path': savedPath,
              'sha256': List.filled(64, 'a').join(),
              'sizeBytes': utf8.encode(args['content']! as String).length,
            };
          });
      service = ComputerBrowserService();
      await service.open(url: 'https://example.com/article');
    });
    tearDown(() async {
      service.dispose();
      await Future<void>.delayed(Duration.zero);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(browserChannel, null);
      messenger.setMockMethodCallHandler(runtimeChannel, null);
    });

    test('manual save reads same page and publishes once without screenshots or shell', () async {
      final saved = await service.savePage();
      expect(saved.file.path, savedPath);
      expect(
        saved.toToolReceipt()['source_url'],
        'https://example.com/article',
      );
      expect(runtimeCalls.single.method, 'importLinuxTextFile');
      final markdown =
          (runtimeCalls.single.arguments as Map)['content'] as String;
      expect(markdown, contains('第一段 😀\n\n资料内容'));
      expect(browserCalls.map((c) => c.method), ['open', 'readPage']);
      expect(service.running, isTrue);
      expect(service.busy, isFalse);
    });

    test(
      'control change while reading prevents any file publication',
      () async {
        readGate = Completer<void>();
        final saving = service.savePage();
        final expectation = expectLater(saving, throwsStateError);
        await Future<void>.delayed(Duration.zero);
        service.takeModelControl();
        readGate!.complete();
        await expectation;
        expect(runtimeCalls, isEmpty);
      },
    );

    test('model save requires and consumes its latest observation', () async {
      service.takeModelControl();
      await expectLater(service.savePage(fromModel: true), throwsStateError);
      final observed = await service.observe();
      final saved = await service.savePage(
        fromModel: true,
        observationId: observed.id,
      );
      expect(saved.file.path, savedPath);
      await expectLater(
        service.savePage(fromModel: true, observationId: observed.id),
        throwsStateError,
      );
      expect(runtimeCalls, hasLength(1));
      expect((browserCalls.last.arguments as Map)['expectedRevision'], 1);
    });

    test(
      'revoked model control during read never publishes a late page',
      () async {
        service.takeModelControl();
        final observed = await service.observe();
        readGate = Completer<void>();
        final saving = service.savePage(
          fromModel: true,
          observationId: observed.id,
        );
        final expectation = expectLater(saving, throwsStateError);
        await Future<void>.delayed(Duration.zero);
        service.releaseModelControl();
        readGate!.complete();
        await expectation;
        expect(runtimeCalls, isEmpty);
      },
    );

    test(
      'a late successful publication retains its receipt without retrying',
      () async {
        service.takeModelControl();
        final observed = await service.observe();
        importGate = Completer<void>();
        final saving = service.savePage(
          fromModel: true,
          observationId: observed.id,
        );
        while (runtimeCalls.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
        service.releaseModelControl();
        importGate!.complete();
        expect((await saving).file.path, savedPath);
        expect(runtimeCalls, hasLength(1));
      },
    );

    test(
      'unconfirmed native publication reports uncertainty and never retries',
      () async {
        importFailure = PlatformException(
          code: 'timeout',
          message: 'fixture timeout',
        );
        await expectLater(
          service.savePage(),
          throwsA(isA<RuntimeBridgeException>()),
        );
        expect(service.error, contains('保存结果未确认'));
        expect(runtimeCalls, hasLength(1));
        expect(service.busy, isFalse);
      },
    );
  });
}
