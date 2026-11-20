// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:perant/src/application/browser_page_document.dart';
import 'package:perant/src/application/computer_browser_service.dart';
import 'package:perant_platform/perant_platform.dart';

import 'fixtures/delayed_article.dart' as delayed;

/// Real Android WebView and native create-only workspace publication. The only
/// website is this test's Android loopback server. No API Key, cloud client,
/// production database or existing document is read. Cleanup is limited to
/// exact import receipts and native sessions created by this suite.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final browser = ComputerBrowserBridge(
    responseTimeout: const Duration(seconds: 45),
  );
  final linux = _LinuxHarness(
    PerantPlatformBridge(
      responseTimeout: const Duration(seconds: 30),
      initializationTimeout: const Duration(minutes: 5),
    ),
  );
  final ownedBrowsers = <String>{};
  final report = <String, dynamic>{
    'suite': 'android-browser-page-save',
    'fixture': 'android-loopback-http',
    'externalWebsiteNavigation': false,
    'externalModelRequests': 0,
    'realModelProviderVerified': false,
    'physicalLowMemoryDeviceVerified': false,
    'osBackgroundSchedulingVerified': false,
    'checks': <Map<String, dynamic>>[],
  };
  binding.reportData = report;
  late _Pages pages;

  setUpAll(() async {
    expect(Platform.isAndroid, isTrue);
    await linux.attach();
    expect(
      await linux.bridge.getLinuxDesktopSession(),
      isNull,
      reason: 'Do not take over an existing personal desktop.',
    );
    expect(
      (await linux.bridge.getLinuxStatus()).active,
      isFalse,
      reason: 'Close a personal terminal/task before running this suite.',
    );
    final status = await linux.bridge.initializeLinux();
    expect(
      status.installed && status.desktopAvailable,
      isTrue,
      reason: status.reason,
    );
  });
  setUp(() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    pages = await _Pages.start();
  });
  tearDown(() async {
    for (final id in ownedBrowsers.toList()) {
      await browser.close(id);
      expect(await browser.state(id), isNull);
      ownedBrowsers.remove(id);
    }
    await linux.cleanup();
    await pages.close();
    expect(linux.streamError, isNull);
  });
  tearDownAll(linux.dispose);

  Future<String> open(String path) async {
    final id = 'page-save-${pages.nonce}-${ownedBrowsers.length}';
    ownedBrowsers.add(id);
    await browser.open(id: id, url: pages.url(path), width: 480, height: 640);
    await _ready(browser, id, pages.url(path));
    return id;
  }

  testWidgets(
    'real top-level reader excludes private regions and binds SPA URL',
    (tester) async {
      final id = await open('/article');
      await pages.waitForRequest('/frame');
      final frame = await browser.capture(id);
      final button = await _coloredCenter(frame, 17, 109, 191);
      final screenshot = await _savePng('READER', frame.png, pages.nonce);
      final ready = await _ready(browser, id, pages.url('/article'));
      // The fixture declares a data favicon, inline styles/scripts and no remote
      // resources. Wait for the initial frame request before the comparison.
      await pages.waitForQuiet();
      final requestsBeforeRead = pages.requests.length;
      final page = await browser.readPage(id, expectedRevision: ready.revision);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(
        pages.requests.length,
        requestsBeforeRead,
        reason: 'Reading the loaded DOM must not fetch the page again.',
      );
      expect(page.id, id);
      expect(page.url, pages.url('/article'));
      expect(page.revision, ready.revision);
      expect(page.truncated, isFalse);
      expect(page.text, contains('公开资料 ${pages.nonce} 🐜'));
      expect(page.text, contains('第一段 中文 😀 行内文本'));
      expect(page.text, contains('\n\n第二段 一起整理'));
      for (final marker in _excludedMarkers) {
        expect(page.text, isNot(contains(marker)), reason: marker);
      }
      final hidden = (await browser.state(id))!;
      expect(hidden.visible || hidden.attached, isFalse);

      // This real button arms a delayed autonomous pushState. Record the native
      // revision AFTER the pointer operation, so the later increment proves SPA
      // history detection rather than merely detecting our earlier touch.
      final shot = await browser.capture(id);
      await browser.action(
        id,
        action: 'tap',
        x: button.$1,
        y: button.$2,
        width: shot.width,
        height: shot.height,
        expectedRevision: shot.state.revision,
      );
      await pages.waitForEvent('armed');
      final beforeSpa = await _ready(browser, id, pages.url('/article'));
      await pages.waitForEvent('spa');
      final spaUrl = '${pages.url('/article')}?spa=${pages.nonce}#after';
      final afterSpa = await _ready(browser, id, spaUrl);
      expect(afterSpa.revision, greaterThan(beforeSpa.revision));
      await expectLater(
        browser.readPage(id, expectedRevision: beforeSpa.revision),
        throwsA(
          isA<RuntimeBridgeException>().having(
            (e) => e.code,
            'code',
            'stale_revision',
          ),
        ),
      );
      final fresh = await browser.readPage(
        id,
        expectedRevision: afterSpa.revision,
      );
      expect(fresh.url, spaUrl);
      expect(fresh.text, contains('SPA 更新 ${pages.nonce}'));
      _record(report, 'real-dom-reader-and-autonomous-spa-history', {
        'provider': ready.provider,
        'sourceUrl': page.url,
        'unicodeAndParagraphsPreserved': true,
        'excludedRegions': _excludedMarkers,
        'requestCountBeforeRead': requestsBeforeRead,
        'requestCountAfterRead': requestsBeforeRead,
        'readerIssuedAdditionalHttpRequests': false,
        'hiddenAfterRead': !hidden.attached && !hidden.visible,
        'revisionAfterPointerBeforeSpa': beforeSpa.revision,
        'revisionAfterAutonomousSpa': afterSpa.revision,
        'spaUrl': fresh.url,
        'staleReadRejected': true,
        'screenshotAppPath': screenshot,
        'screenshotDimensions': [frame.width, frame.height],
      });
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets('save reads the published paragraph at the unchanged URL', (
    tester,
  ) async {
    final paragraph = '会议决定在周五复核资料，编号为${pages.nonce}。';
    await delayed.withDelayedArticle(paragraph, (url, publish) async {
      final service = ComputerBrowserService(
        bridge: browser,
        workspaceBridge: linux.bridge,
      );
      try {
        await service.open(url: url);
        final id = service.state!.id;
        final before = await _ready(browser, id, url);
        await publish();
        await service.refreshState();
        final priorFiles = await linux.bridge.listLinuxDirectory('/workspace');
        expect(
          priorFiles.truncated,
          isFalse,
          reason: 'A full listing is needed to count new files.',
        );
        final saved = await service.savePage();
        linux.ownImport(saved.file.path);
        expect(saved.page.id, id);
        expect(saved.page.url, url);
        expect(saved.page.title, before.title);
        expect(saved.truncated, isFalse);
        final nextFiles = await linux.bridge.listLinuxDirectory('/workspace');
        expect(nextFiles.truncated, isFalse);
        expect(
          nextFiles.entries.map((entry) => entry.path),
          unorderedEquals([
            ...priorFiles.entries.map((entry) => entry.path),
            saved.file.path,
          ]),
        );
        final actual = await linux.bridge.readLinuxFile(saved.file.path);
        expect(actual.content, contains(paragraph));
        expect(actual.content, isNot(contains(delayed.articlePlaceholder)));
        expect(
          actual.content.split('\n'),
          contains('来源：${url.replaceAll('.', r'\.')}'),
        );
        expect(actual.sizeBytes, saved.file.sizeBytes);
        expect(actual.sha256, saved.file.sha256);
        _record(report, 'delayed-body-same-url-publication', {
          'provider': before.provider,
          'receipt': saved.toToolReceipt(),
          'actualReadbackSha256': actual.sha256,
        });
      } finally {
        try {
          await service.close();
        } finally {
          service.dispose();
        }
      }
    });
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('real reader truncates text and traversal and escapes Markdown', (
    tester,
  ) async {
    final id = await open('/large');
    var state = await _ready(browser, id, pages.url('/large'));
    final large = await browser.readPage(id, expectedRevision: state.revision);
    expect(large.truncated, isTrue);
    expect(
      large.text.length,
      lessThanOrEqualTo(ComputerBrowserPage.maxCharacters),
    );
    expect(
      utf8.encode(large.text).length,
      lessThanOrEqualTo(ComputerBrowserPage.maxBytes),
    );
    expect(large.text, contains('# injected [link](javascript:alert(1))'));
    final document = buildBrowserPageDocument(
      large,
      savedAt: DateTime.utc(2026, 11, 14),
    );
    expect(document.truncated, isTrue);
    expect(utf8.encode(document.content).length, lessThanOrEqualTo(262144));
    expect(
      document.content,
      contains(r'\# injected \[link\]\(javascript:alert\(1\)\)'),
    );
    expect(document.content, contains('&lt;img'));
    expect(document.content, isNot(contains('<img')));
    expect(document.content, isNot(contains('[link](javascript:')));
    expect(document.content, isNot(contains('![image](https://')));
    expect(document.content, contains('正文已截断'));
    expect(document.content, contains('第一段 中文 😀'));
    validateLinuxFileContent(document.content);

    await browser.navigate(id, pages.url('/many'));
    state = await _ready(browser, id, pages.url('/many'));
    final many = await browser.readPage(id, expectedRevision: state.revision);
    expect(many.text, startsWith('遍历预算起点'));
    expect(many.truncated, isTrue);
    expect(many.text, isNot(contains('UNREACHED_END_MARKER')));
    expect(
      many.text.length,
      lessThan(ComputerBrowserPage.maxCharacters),
      reason: 'This short-text fixture should reach a traversal/time budget.',
    );
    _record(report, 'real-dom-budgets-and-literal-markdown', {
      'oversizedTextTruncated': large.truncated,
      'readerCharacters': large.text.length,
      'readerUtf8Bytes': utf8.encode(large.text).length,
      'markdownUtf8Bytes': utf8.encode(document.content).length,
      'markdownWithin256KiB': true,
      'markdownHtmlAndLinkSyntaxEscaped': true,
      'truncationNoticePresent': true,
      'traversalOrTimeBudgetTruncated': many.truncated,
      'traversalOutputCharacters': many.text.length,
      'trailingMarkerNotScanned': true,
    });
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets(
    'service saves into a live desktop without restarting its process',
    (tester) async {
      final service = ComputerBrowserService(
        bridge: browser,
        workspaceBridge: linux.bridge,
      );
      DesktopRfbClient? viewer;
      try {
        await service.open(url: pages.url('/article'));
        final browserId = service.state!.id;
        ownedBrowsers.add(browserId);
        await _ready(browser, browserId, pages.url('/article'));
        await service.refreshState();
        final desktop = await linux.startDesktop();
        viewer = await DesktopRfbClient.connectUnix(
          desktop.socketPath,
          continuous: false,
        );
        await _paintedDesktop(viewer);
        final saved = await service.savePage();
        linux.ownImport(saved.file.path);
        expect(saved.page.url, pages.url('/article'));
        expect(saved.truncated, isFalse);
        expect(saved.file.sizeBytes, greaterThan(0));
        await expectLater(
          linux.bridge.revealDesktopExcerpt('stale-desktop', saved.file),
          throwsA(
            isA<RuntimeBridgeException>().having(
              (e) => e.code,
              'code',
              'session_mismatch',
            ),
          ),
        );
        await linux.bridge.revealDesktopExcerpt(desktop.sessionId, saved.file);
        final retained = (await linux.bridge.getLinuxDesktopSession())!;
        expect(retained.sessionId, desktop.sessionId);
        expect(retained.pid, desktop.pid);
        expect(retained.socketPath, desktop.socketPath);
        expect((await linux.bridge.getLinuxStatus()).active, isTrue);
        final afterSave = await _paintedDesktop(viewer);
        final desktopShot = await _savePng(
          'LIVE_DESKTOP',
          afterSave.encodePng(),
          pages.nonce,
        );
        await viewer.close();
        viewer = null;
        await linux.stopDesktop(desktop.sessionId);
        final actual = await linux.bridge.readLinuxFile(saved.file.path);
        expect(actual.sizeBytes, saved.file.sizeBytes);
        expect(actual.sha256, saved.file.sha256);
        expect(utf8.encode(actual.content).length, saved.file.sizeBytes);
        expect(actual.content, contains('公开资料 ${pages.nonce} 🐜'));
        expect(actual.content, contains('第一段 中文 😀 行内文本'));
        for (final marker in _excludedMarkers) {
          expect(actual.content, isNot(contains(marker)));
        }
        final digest = await linux.run(
          'sha256sum -- ${_quote(saved.file.path)}',
        );
        expect(digest.exitCode, 0, reason: digest.output.toString());
        expect(
          digest.output.toString().trim().split(RegExp(r'\s+')).first,
          saved.file.sha256,
        );
        final receipt = saved.toToolReceipt();
        expect(receipt['path'], saved.file.path);
        expect(receipt['source_url'], saved.page.url);
        expect(receipt['sha256'], actual.sha256);
        _record(report, 'real-live-desktop-service-publication-and-readback', {
          'desktopSessionBefore': desktop.sessionId,
          'desktopSessionAfterSave': retained.sessionId,
          'fileManagerAcknowledgedLocation': true,
          'desktopPidBefore': desktop.pid,
          'desktopPidAfterSave': retained.pid,
          'sameRfbEndpointStillPaintedAfterSave': true,
          'desktopStoppedOnlyAfterSaveVerification': true,
          'receipt': receipt,
          'actualReadbackSizeBytes': actual.sizeBytes,
          'actualReadbackSha256': actual.sha256,
          'independentGuestSha256sumMatched': true,
          'actualUtf8AndExcludedRegionsChecked': true,
          'desktopScreenshotAppPath': desktopShot,
        });
      } finally {
        await viewer?.close();
        await service.close();
        service.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets('ordinary live PTY rejects import and remains usable', (
    tester,
  ) async {
    final id = await linux.startTerminal();
    final before = await linux.bridge.getLinuxStatus();
    expect(before.active, isTrue);
    expect(before.sessionId, id);
    await expectLater(
      linux.bridge.importLinuxTextFile(
        content: 'TEST_ONLY_BUSY_${pages.nonce}',
      ),
      throwsA(
        isA<RuntimeBridgeException>().having((e) => e.code, 'code', 'busy'),
      ),
    );
    final after = await linux.bridge.getLinuxStatus();
    expect(after.sessionId, id);
    expect(after.active, isTrue);
    final marker = 'PTY_RETAINED_${pages.nonce}';
    await linux.bridge.writeLinuxSession(
      id,
      "printf '%s%s\\n' 'PTY_RETAINED_' '${pages.nonce}'\n",
    );
    await linux.waitForOutput(id, marker);
    await linux.stopTerminal(id);
    _record(report, 'real-terminal-busy-import-boundary', {
      'terminalSessionBefore': before.sessionId,
      'terminalSessionAfterRejection': after.sessionId,
      'importRejectedWithBusy': true,
      'samePtyAcceptedCommandAfterRejection': true,
      'terminalExplicitlyClosedByTest': true,
      'noSuccessfulImportReceipt': true,
    });
  }, timeout: const Timeout(Duration(minutes: 2)));
}

const _excludedMarkers = [
  'FORM_SECRET',
  'INPUT_SECRET',
  'TEXTAREA_SECRET',
  'EDITABLE_SECRET',
  'HIDDEN_SECRET',
  'CSS_SECRET',
  'ARIA_SECRET',
  'SCRIPT_SECRET',
  'FRAME_SECRET',
];

Future<ComputerBrowserState> _ready(
  ComputerBrowserBridge bridge,
  String id,
  String url,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  int? prior;
  var stable = 0;
  while (DateTime.now().isBefore(deadline)) {
    final state = await bridge.state(id);
    if (state != null &&
        state.url == url &&
        !state.loading &&
        state.error.isEmpty &&
        state.title.isNotEmpty) {
      stable = prior == state.revision ? stable + 1 : 0;
      prior = state.revision;
      if (stable >= 2) return state;
    } else {
      prior = null;
      stable = 0;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('The real native page did not settle at the expected URL.');
}

Future<(int, int)> _coloredCenter(
  ComputerBrowserFrame frame,
  int red,
  int green,
  int blue,
) async {
  final codec = await ui.instantiateImageCodec(frame.png);
  final decoded = await codec.getNextFrame();
  try {
    expect(decoded.image.width, frame.width);
    expect(decoded.image.height, frame.height);
    final data = (await decoded.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
    var minX = frame.width,
        minY = frame.height,
        maxX = -1,
        maxY = -1,
        count = 0;
    for (var offset = 0; offset < data.length; offset += 4) {
      if (data[offset] == red &&
          data[offset + 1] == green &&
          data[offset + 2] == blue) {
        final pixel = offset ~/ 4;
        final x = pixel % frame.width, y = pixel ~/ frame.width;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
        count++;
      }
    }
    expect(
      count,
      greaterThan(1000),
      reason: 'A real painted fixture button must be present in native PNG.',
    );
    return ((minX + maxX) ~/ 2, (minY + maxY) ~/ 2);
  } finally {
    decoded.image.dispose();
    codec.dispose();
  }
}

Future<String> _savePng(String label, Uint8List png, String nonce) async {
  final path =
      '${(await getTemporaryDirectory()).path}/'
      'browser-page-save-$nonce-$label.png';
  await File(path).writeAsBytes(png, flush: true);
  // Only test-owned website/desktop pixels; no personal browser is opened.
  // ignore: avoid_print
  print('BROWSER_PAGE_SAVE_${label}_PNG_BASE64 ${base64Encode(png)}');
  return path;
}

Future<DesktopFrame> _paintedDesktop(DesktopRfbClient client) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  var frame = await client.capture(timeout: const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    final colors = <int>{};
    for (var offset = 0; offset < frame.rgba.length; offset += 4 * 97) {
      colors.add(
        (frame.rgba[offset] << 16) |
            (frame.rgba[offset + 1] << 8) |
            frame.rgba[offset + 2],
      );
      if (colors.length >= 8) return frame;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    frame = await client.capture(timeout: const Duration(seconds: 15));
  }
  fail('The real retained desktop did not produce painted pixels.');
}

void _record(
  Map<String, dynamic> report,
  String check,
  Map<String, dynamic> details,
) {
  final result = <String, dynamic>{'check': check, ...details};
  (report['checks'] as List<Map<String, dynamic>>).add(result);
  // ignore: avoid_print
  print('BROWSER_PAGE_SAVE_RESULT ${jsonEncode(result)}');
}

String _quote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

final class _Command {
  final output = StringBuffer();
  final exit = Completer<int>();
  int? exitCode;
}

final class _LinuxHarness {
  _LinuxHarness(this.bridge);
  final PerantPlatformBridge bridge;
  final nonce = DateTime.now().microsecondsSinceEpoch.toString();
  final _desktops = <String>{};
  final _terminals = <String>{};
  final _imports = <String>{};
  final _commands = <String, _Command>{};
  final _terminalOutput = <String, StringBuffer>{};
  StreamSubscription<RuntimeEvent>? _events;
  Object? streamError;
  var _sequence = 0;

  Future<void> attach() async {
    _events = bridge.events.listen((event) {
      // Interactive PTY events have no taskId: payload.sessionId owns them.
      // Commands use taskId, as exercised by linux_runtime_test.dart.
      final owner = event.taskId ?? event.payload['sessionId'];
      if (owner is! String) return;
      if (event.type == 'linuxOutput') {
        _commands[owner]?.output.write(event.payload['text']);
        _terminalOutput[owner]?.write(event.payload['text']);
      } else if (event.type == 'linuxExit') {
        final command = _commands[owner];
        if (command != null && !command.exit.isCompleted) {
          command.exitCode = event.payload['exitCode'] as int;
          command.exit.complete(command.exitCode);
        }
      }
    }, onError: (Object error) => streamError = error);
    await bridge.ensureRuntimeEventsAttached();
  }

  Future<LinuxDesktopSession> startDesktop() async {
    expect(await bridge.getLinuxDesktopSession(), isNull);
    final id = 'browser-save-desktop-$nonce-${_sequence++}';
    _desktops.add(id);
    final desktop = await bridge.startLinuxDesktop(
      sessionId: id,
      width: 720,
      height: 1080,
    );
    expect(
      desktop.sessionId,
      id,
      reason: 'Do not attach to or clean up an unowned desktop.',
    );
    return desktop;
  }

  Future<void> stopDesktop(String id) async {
    if (!_desktops.contains(id)) throw StateError('Unowned desktop.');
    await bridge.stopLinuxDesktop(id);
    _desktops.remove(id);
    expect(await bridge.getLinuxDesktopSession(), isNull);
  }

  void ownImport(String path) {
    if (!RegExp(
      r'^/workspace/web-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.md$',
    ).hasMatch(path)) {
      throw StateError('Unexpected import receipt path.');
    }
    _imports.add(path);
  }

  Future<String> startTerminal() async {
    final id = 'browser-save-pty-$nonce-${_sequence++}';
    _terminals.add(id);
    _terminalOutput[id] = StringBuffer();
    expect((await bridge.startLinuxSession(sessionId: id)).sessionId, id);
    return id;
  }

  Future<void> stopTerminal(String id) async {
    if (!_terminals.contains(id)) throw StateError('Unowned terminal.');
    await bridge.closeLinuxSession(id);
    _terminals.remove(id);
  }

  Future<void> waitForOutput(String id, String marker) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!(_terminalOutput[id]?.toString().contains(marker) ?? false)) {
      if (DateTime.now().isAfter(deadline))
        fail('Test-owned PTY did not respond: ${_terminalOutput[id]}');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<_Command> run(String command) async {
    final id = 'browser-save-command-$nonce-${_sequence++}';
    final result = _Command();
    _commands[id] = result;
    await bridge.runLinuxCommand(taskId: id, command: command);
    await result.exit.future.timeout(const Duration(seconds: 40));
    return result;
  }

  Future<void> cleanup() async {
    for (final id in _desktops.toList()) {
      await stopDesktop(id);
    }
    for (final id in _terminals.toList()) {
      await stopTerminal(id);
    }
    for (final entry in _commands.entries.toList()) {
      if (!entry.value.exit.isCompleted) await bridge.cancelTask(entry.key);
    }
    for (final path in _imports.toList()) {
      // Exact paths registered from this test's successful receipts only.
      // No wildcard, root scan or recursive deletion is used.
      final result = await run('rm -f -- ${_quote(path)}');
      expect(result.exitCode, 0, reason: result.output.toString());
      _imports.remove(path);
    }
  }

  Future<void> dispose() async {
    await cleanup();
    await _events?.cancel();
  }
}

final class _Pages {
  _Pages(this.server);
  final HttpServer server;
  final nonce = DateTime.now().microsecondsSinceEpoch.toString();
  final requests = <String>[];
  final events = <String>[];
  StreamSubscription<HttpRequest>? _subscription;

  static Future<_Pages> start() async {
    final pages = _Pages(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    pages._subscription = pages.server.listen(pages._serve);
    return pages;
  }

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  Future<void> _serve(HttpRequest request) async {
    requests.add('${request.method} ${request.uri.path}');
    try {
      request.response.headers.set('Cache-Control', 'no-store');
      if (request.method == 'POST' && request.uri.path == '/event') {
        final data = await utf8.decoder.bind(request).join();
        final event = jsonDecode(data) as Map;
        if (event['nonce'] != nonce)
          throw const FormatException('Wrong nonce.');
        events.add(event['type'] as String);
        request.response.statusCode = HttpStatus.noContent;
      } else if (request.method == 'GET') {
        request.response.headers.contentType = ContentType.html;
        final body = switch (request.uri.path) {
          '/article' => _article(nonce),
          '/frame' => _html('<p>FRAME_SECRET</p>'),
          '/large' => _html(
            '<p>第一段 中文 😀</p><p>'
            '# injected [link](javascript:alert(1)) '
            '![image](https://example.invalid/never-fetch) '
            '&lt;img src="https://example.invalid/no-image"&gt; '
            '${'&amp;' * 150000}</p>',
            title: '# title [x](javascript:bad)',
          ),
          '/many' => _html(
            '<p>遍历预算起点</p>${'<span>x</span>' * 25000}'
            '<p>UNREACHED_END_MARKER</p>',
          ),
          _ => null,
        };
        if (body == null) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.write(body);
        }
      } else {
        request.response.statusCode = HttpStatus.methodNotAllowed;
      }
    } catch (_) {
      request.response.statusCode = HttpStatus.badRequest;
    } finally {
      try {
        await request.response.close();
      } on SocketException {
        // Closing only this test browser can cancel an in-flight local request.
      } on HttpException {
        // Keep-alive socket may close during test-owned server teardown.
      }
    }
  }

  Future<void> waitForRequest(String path) =>
      _wait(() => requests.contains('GET $path'));
  Future<void> waitForEvent(String name) => _wait(() => events.contains(name));

  Future<void> waitForQuiet() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      final count = requests.length;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (requests.length == count) return;
    }
    fail('The local fixture did not settle before DOM reading.');
  }

  Future<void> _wait(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline))
        fail('Missing local fixture event.');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> close() async {
    await server.close(force: true);
    await _subscription?.cancel();
  }
}

String _html(String body, {String title = 'PerAnt page save fixture'}) =>
    '''
<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none';
style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self';
frame-src 'self'; img-src data:">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg'/%3E">
<title>$title</title><style>body{margin:24px;padding-top:80px;font:20px sans-serif;}
#spa{position:fixed;left:0;top:0;width:100%;height:70px;border:0;
background:rgb(17,109,191);color:white;}iframe{height:30px;width:100%;}</style>
</head><body>$body</body></html>''';

String _article(String nonce) => _html('''
<button id="spa">Arm autonomous SPA update</button>
<h1>公开资料 $nonce 🐜</h1>
<p>第一段 中文 😀 <span>行内文本</span></p><p>第二段 一起整理</p>
<p id="updated"></p>
<form><p>FORM_SECRET</p><input value="INPUT_SECRET"></form>
<input value="INPUT_SECRET"><textarea>TEXTAREA_SECRET</textarea>
<div contenteditable="true">EDITABLE_SECRET</div>
<div hidden>HIDDEN_SECRET</div><div style="display:none">CSS_SECRET</div>
<div aria-hidden="true">ARIA_SECRET</div>
<iframe src="/frame"></iframe>
<script>
const privateScriptText='SCRIPT_SECRET';
function post(type){return fetch('/event',{method:'POST',headers:{'Content-Type':'application/json'},
body:JSON.stringify({type:type,nonce:'$nonce'})});}
document.getElementById('spa').addEventListener('click',function(){
post('armed');
setTimeout(function(){history.pushState({},'', '/article?spa=$nonce#after');
document.getElementById('updated').textContent='SPA 更新 $nonce';post('spa');},4000);
},{once:true});
</script>
''');
