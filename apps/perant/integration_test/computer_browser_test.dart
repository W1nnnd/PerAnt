// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:perant/src/application/computer_browser_service.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant/src/presentation/container_screen.dart';
import 'package:perant_platform/perant_platform.dart';

import 'fixtures/delayed_article.dart' as delayed;

/// Real Android WebView, Activity/PlatformView lifecycle, PNG and input. Pages
/// are served by this test on Android loopback; no model or external website is
/// used. No mock MethodChannel, JavaScript-evaluation API or user files exist.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final bridge = ComputerBrowserBridge(
    responseTimeout: const Duration(seconds: 45),
  );
  final report = <String, dynamic>{
    'suite': 'android-native-computer-browser',
    'fixture': 'android-loopback-http',
    'externalWebsiteNavigation': false,
    'externalModelRequests': 0,
    'browserSandboxOverridesUsed': false,
    'osBackgroundSchedulingVerified': false,
    'systemImeInjectionVerified': false,
    'checks': <Map<String, dynamic>>[],
  };
  binding.reportData = report;
  late _LocalPages pages;
  final owned = <String>[];
  var sequence = 0;

  String ownId() {
    final id = 'browser-smoke-' + pages.nonce + '-' + (sequence++).toString();
    owned.add(id);
    return id;
  }

  setUp(() async {
    expect(Platform.isAndroid, isTrue);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    pages = await _LocalPages.start();
  });
  tearDown(() async {
    for (final id in owned.toList()) {
      await bridge.close(id);
      expect(await bridge.state(id), isNull);
      owned.remove(id);
    }
    await pages.close();
  });

  testWidgets('native reader observes new text without navigation', (
    tester,
  ) async {
    final id = ownId();
    final paragraph = '会议决定在周五复核资料，编号为${pages.nonce}。';
    await delayed.withDelayedArticle(paragraph, (url, publish) async {
      await bridge.open(id: id, url: url, width: 480, height: 640);
      Future<ComputerBrowserPage> read() async {
        final state = await _waitState(
          tester,
          bridge,
          id,
          (s) =>
              s.url == url &&
              s.title == '会议资料' &&
              !s.loading &&
              s.error.isEmpty,
        );
        return bridge.readPage(id, expectedRevision: state.revision);
      }

      final before = await read();
      expect(before.text, contains(delayed.articlePlaceholder));
      expect(before.text, isNot(contains(paragraph)));
      await publish();
      final after = await read();
      expect(after.url, url);
      expect(after.title, before.title);
      expect(after.text, contains(paragraph));
      expect(after.text, isNot(contains(delayed.articlePlaceholder)));
      expect(after.truncated, isFalse);
      _record(report, 'delayed-text-without-navigation', {
        'sourceUrl': after.url,
        'provider': (await bridge.state(id))!.provider,
      });
    });
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('save Chinese form pages, edit, reject a stale edit and reopen', (
    tester,
  ) async {
    const rounds = int.fromEnvironment(
      'PERANT_WORKSPACE_STRESS_ROUNDS',
      defaultValue: 1,
    );
    expect(rounds, inInclusiveRange(1, 200));
    final files = PerantPlatformBridge();
    final controller = WorkspaceController(
      persistence: MemoryWorkspacePersistence(),
      credentials: MemoryCredentialStore(),
      bridge: files,
    );
    await controller.initialize();
    addTearDown(controller.dispose);
    final status = await files.getLinuxStatus();
    expect(status.active, isFalse, reason: 'Use a dedicated idle test device.');
    expect(status.workspaceAvailable, isTrue);
    final cpu = await Process.run('/system/bin/getprop', [
      'ro.product.cpu.abilist64',
    ]);
    expect(cpu.exitCode, 0);
    final primaryAbi = (cpu.stdout as String).trim().split(',').first;
    if (primaryAbi == 'x86_64') {
      expect(status.supported, isFalse);
      expect(status.reason, contains('原生 ARM64'));
    }
    final root = (await getApplicationSupportDirectory()).path;
    final url = pages.url('/one');
    final elapsed = <int>[];
    final paths = <String>{};
    for (var round = 0; round < rounds; round++) {
      final timer = Stopwatch()..start();
      final service = ComputerBrowserService(
        bridge: bridge,
        workspaceBridge: files,
      );
      File? ownedFile;
      try {
        await service.open(url: url);
        final id = service.state!.id;
        final shot = await _shotUntil(
          bridge,
          id,
          (s) => s.area(19, 91, 187).pixels > 1000,
        );
        final field = shot.area(19, 91, 187);
        await bridge.action(
          id,
          action: 'tap',
          x: field.centerX,
          y: field.centerY,
          width: shot.frame.width,
          height: shot.frame.height,
          expectedRevision: shot.frame.state.revision,
        );
        final focused = await bridge.capture(id);
        final draft = '尚未提交的中文草稿${pages.nonce}第${round}轮';
        await bridge.action(
          id,
          action: 'text',
          text: draft,
          expectedRevision: focused.state.revision,
        );
        await pages.waitForInput(draft);
        await service.refreshState();
        final before = await files.listLinuxDirectory('/workspace');
        expect(before.truncated, isFalse);
        final saved = await service.savePage();
        final path = saved.file.path;
        ownedFile = File('$root/linux-runtime$path');
        expect(paths.add(path), isTrue);
        final listing = await files.listLinuxDirectory('/workspace');
        expect(listing.truncated, isFalse);
        expect(
          listing.entries.map((e) => e.path),
          unorderedEquals([...before.entries.map((e) => e.path), path]),
        );
        final file = await files.readLinuxFile(path);
        expect(file.content, contains('公开会议资料'));
        expect(file.content, contains('来源：${url.replaceAll('.', r'\.')}'));
        expect(file.content, isNot(contains(draft)));
        expect(file.sha256, saved.file.sha256);
        expect(file.sizeBytes, utf8.encode(file.content).length);
        expect(file.sizeBytes, saved.file.sizeBytes);
        await service.close();
        final edited = '${file.content}\n用户复核第${round}轮。';
        await tester.pumpWidget(
          MaterialApp(home: ContainerScreen(controller: controller)),
        );
        await tester.pumpAndSettle();
        final listItem = find.text(path.split('/').last);
        await tester.tap(listItem);
        await tester.pumpAndSettle();
        final fieldFinder = find.byKey(
          const ValueKey('container-file-content'),
        );
        expect(
          tester.widget<TextField>(fieldFinder).controller!.text,
          file.content,
        );
        await tester.enterText(fieldFinder, edited);
        await tester.pump();
        await tester.tap(find.byTooltip('保存到 Linux'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        await tester.tap(listItem);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(fieldFinder).controller!.text, edited);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await expectLater(
          files.writeLinuxFile(
            path: path,
            content: '过期修改',
            expectedSha256: file.sha256,
          ),
          throwsA(
            isA<RuntimeBridgeException>().having(
              (e) => e.code,
              'code',
              'file_conflict',
            ),
          ),
        );
        final reopened = await PerantPlatformBridge().readLinuxFile(path);
        expect(reopened.content, edited);
        expect(await ownedFile.readAsString(), edited);
        elapsed.add(timer.elapsedMilliseconds);
      } finally {
        try {
          await service.close();
        } finally {
          service.dispose();
          if (ownedFile != null) await ownedFile.delete();
        }
      }
    }
    elapsed.sort();
    _record(report, 'workspace-form-stress', {
      'completed': elapsed.length,
      'p50Ms': elapsed[(rounds * .50).ceil() - 1],
      'p95Ms': elapsed[(rounds * .95).ceil() - 1],
      'maxMs': elapsed.last,
      'linuxInstalled': status.installed,
      'primaryAbi': primaryAbi,
    });
  }, timeout: const Timeout(Duration(minutes: 18)));

  testWidgets(
    'native browser renders real JavaScript and accepts hidden pointer text and key input',
    (tester) async {
      final id = ownId();
      final opened = await bridge.open(
        id: id,
        url: pages.url('/one'),
        width: 480,
        height: 640,
      );
      _provider(opened.provider);
      _hidden(opened);
      await pages.waitForGet('/one');
      var shot = await _shotUntil(
        bridge,
        id,
        (shot) => shot.area(197, 23, 109).pixels > 30000,
      );
      _hidden((await bridge.state(id))!);
      final before = await _save('HIDDEN_BEFORE', shot, pages);
      final field = shot.area(19, 91, 187);
      expect(field.pixels, greaterThan(1000));
      await bridge.action(
        id,
        action: 'tap',
        x: field.centerX,
        y: field.centerY,
        width: shot.frame.width,
        height: shot.frame.height,
        expectedRevision: shot.frame.state.revision,
      );
      shot = await _shot(bridge, id);
      final typed = 'NATIVE_BROWSER_' + pages.nonce;
      await bridge.action(
        id,
        action: 'text',
        text: typed + 'X',
        expectedRevision: shot.frame.state.revision,
      );
      shot = await _shot(bridge, id);
      await bridge.action(
        id,
        action: 'key',
        key: 'Backspace',
        expectedRevision: shot.frame.state.revision,
      );
      shot = await _shot(bridge, id);
      final button = shot.area(197, 23, 109);
      await bridge.action(
        id,
        action: 'tap',
        x: button.centerX,
        y: button.centerY,
        width: shot.frame.width,
        height: shot.frame.height,
        expectedRevision: shot.frame.state.revision,
      );
      final event = await pages.waitForClick(1);
      expect(event['nonce'], pages.nonce);
      expect(event['value'], typed);
      expect(event['result'], 42);
      expect(event['clicks'], 1);
      final computed = await _shotUntil(
        bridge,
        id,
        (shot) => shot.area(42, 203, 149).pixels > 30000,
      );
      final after = await _save('HIDDEN_JS_RESULT', computed, pages);
      _hidden((await bridge.state(id))!);
      _record(report, 'real-js-hidden-input-and-capture', {
        'provider': computed.frame.state.provider,
        'localHttpRequests': pages.gets.length,
        'javascriptPostNonceMatched': true,
        'typedTextAndBackspaceVerifiedByPage': true,
        'javascriptComputedResult': event['result'],
        'beforeRgb': [197, 23, 109],
        'computedRgb': [42, 203, 149],
        'computedColorPixels': computed.area(42, 203, 149).pixels,
        'pngWidth': computed.frame.width,
        'pngHeight': computed.frame.height,
        'pngDecodedByFlutter': true,
        'hiddenAfterCaptureAndActions': true,
        'beforeScreenshotAppPath': before,
        'afterScreenshotAppPath': after,
      });
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets(
    'real platform view touch invalidates old observations and hiding preserves the page',
    (tester) async {
      final id = ownId();
      await bridge.open(
        id: id,
        url: pages.url('/one'),
        width: 480,
        height: 640,
      );
      await pages.waitForGet('/one');
      await bridge.setVisible(id, true);
      try {
        await _mount(tester, id);
        final visible = await _waitState(
          tester,
          bridge,
          id,
          (state) => state.visible && state.attached,
        );
        _provider(visible.provider);
        final observed = await _shotUntil(
          bridge,
          id,
          (shot) => shot.area(197, 23, 109).pixels > 30000,
        );
        final before = await _save(
          'VISIBLE_BEFORE_USER_TOUCH',
          observed,
          pages,
        );
        final button = observed.area(197, 23, 109);
        final surface = tester.getRect(find.byType(AndroidView));
        // Exercise Flutter's real PlatformView touch dispatch rather than the
        // model action API. Coordinates derive from the actual returned PNG.
        await tester.tapAt(
          Offset(
            surface.left +
                surface.width * button.centerX / observed.frame.width,
            surface.top +
                surface.height * button.centerY / observed.frame.height,
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        final userEvent = await pages.waitForClick(1);
        expect(userEvent['clicks'], 1);
        final changed = await _waitState(
          tester,
          bridge,
          id,
          (state) => state.revision > observed.frame.state.revision,
        );
        await expectLater(
          bridge.action(
            id,
            action: 'tap',
            x: button.centerX,
            y: button.centerY,
            width: observed.frame.width,
            height: observed.frame.height,
            expectedRevision: observed.frame.state.revision,
          ),
          throwsA(
            isA<RuntimeBridgeException>().having(
              (error) => error.code,
              'code',
              'stale_revision',
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(pages.clicks, hasLength(1));
        await bridge.setVisible(id, false);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        _hidden((await bridge.state(id))!);
        var hidden = await _shotUntil(
          bridge,
          id,
          (shot) => shot.area(42, 203, 149).pixels > 30000,
        );
        final hiddenArtifact = await _save('HIDDEN_SAME_PAGE', hidden, pages);
        _hidden((await bridge.state(id))!);
        final hiddenButton = hidden.area(42, 203, 149);
        await bridge.action(
          id,
          action: 'tap',
          x: hiddenButton.centerX,
          y: hiddenButton.centerY,
          width: hidden.frame.width,
          height: hidden.frame.height,
          expectedRevision: hidden.frame.state.revision,
        );
        final second = await pages.waitForClick(2);
        expect(second['clicks'], 2);
        hidden = await _shotUntil(
          bridge,
          id,
          (shot) => shot.area(42, 91, 211).pixels > 30000,
        );
        _hidden((await bridge.state(id))!);
        await bridge.setVisible(id, true);
        await _mount(tester, id);
        await _waitState(
          tester,
          bridge,
          id,
          (state) => state.visible && state.attached,
        );
        final resumed = await _shotUntil(
          bridge,
          id,
          (shot) => shot.area(42, 91, 211).pixels > 30000,
        );
        final resumedArtifact = await _save(
          'REMOUNTED_SAME_PAGE',
          resumed,
          pages,
        );
        expect(pages.gets.where((path) => path == '/one'), hasLength(1));
        await bridge.close(id);
        expect(await bridge.state(id), isNull);
        await tester.pump();
        expect(tester.takeException(), isNull);
        _record(report, 'real-platform-view-touch-hide-and-remount', {
          'provider': resumed.frame.state.provider,
          'userInputTransport': 'Flutter AndroidView real touch dispatch',
          'observationRevision': observed.frame.state.revision,
          'revisionAfterUserTouch': changed.revision,
          'staleActionRejectedBeforeInput': true,
          'noDuplicateClickAfterStaleAction': true,
          'detachedAndHiddenAfterExplicitHide': true,
          'temporaryHiddenCaptureRemainedDetached': true,
          'sameDocumentClickCounterAfterHiddenAction': second['clicks'],
          'sameDocumentSurvivedRemountWithoutReload': true,
          'closedWhilePlatformViewStillMounted': true,
          'beforeScreenshotAppPath': before,
          'hiddenScreenshotAppPath': hiddenArtifact,
          'remountedScreenshotAppPath': resumedArtifact,
          'actualOsBackgroundSwitchPerformed': false,
        });
      } finally {
        if (await bridge.state(id) != null) {
          await bridge.setVisible(id, false);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets(
    'canceling a real pending long press produces no delayed click and keeps the page',
    (tester) async {
      final id = ownId();
      await bridge.open(
        id: id,
        url: pages.url('/one'),
        width: 480,
        height: 640,
      );
      await pages.waitForGet('/one');
      final before = await _shotUntil(
        bridge,
        id,
        (shot) => shot.area(197, 23, 109).pixels > 30000,
      );
      final button = before.area(197, 23, 109);
      final pending = bridge.action(
        id,
        action: 'long_press',
        x: button.centerX,
        y: button.centerY,
        width: before.frame.width,
        height: before.frame.height,
        expectedRevision: before.frame.state.revision,
      );
      final rejected = expectLater(
        pending,
        throwsA(
          isA<RuntimeBridgeException>().having(
            (error) => error.code,
            'code',
            'canceled',
          ),
        ),
      );
      // Wait for actual DOM pointerdown, not merely a queued channel request.
      // Cancel before the native 600ms release, then check beyond that deadline.
      await pages.waitForPointerDown();
      await bridge.cancel(id);
      await rejected;
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(pages.clicks, isEmpty);
      final after = await _shotUntil(
        bridge,
        id,
        (shot) => shot.area(197, 23, 109).pixels > 30000,
      );
      _hidden((await bridge.state(id))!);
      expect(pages.gets.where((path) => path == '/one'), hasLength(1));
      final afterArtifact = await _save(
        'CANCELED_PRESS_PAGE_RETAINED',
        after,
        pages,
      );
      final restoredButton = after.area(197, 23, 109);
      await bridge.action(
        id,
        action: 'tap',
        x: restoredButton.centerX,
        y: restoredButton.centerY,
        width: after.frame.width,
        height: after.frame.height,
        expectedRevision: after.frame.state.revision,
      );
      expect((await pages.waitForClick(1))['clicks'], 1);
      _record(report, 'pending-long-press-cancel-and-reuse', {
        'provider': after.frame.state.provider,
        'domPointerDownObservedBeforeCancel': true,
        'pendingFutureRejectedAsCanceled': true,
        'noClickAfterOriginalReleaseDeadline': true,
        'captureUsableAfterCancel': true,
        'sameDocumentRetainedWithoutReload': true,
        'normalInputUsableAfterCancel': true,
        'afterCancelScreenshotAppPath': afterArtifact,
      });
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets(
    'native browser history resize close and URL rejection use actual engine state',
    (tester) async {
      final id = ownId();
      await bridge.open(
        id: id,
        url: pages.url('/one'),
        width: 480,
        height: 640,
      );
      await pages.waitForGet('/one');
      var shot = await _shotUntil(
        bridge,
        id,
        (shot) => shot.area(197, 23, 109).pixels > 30000,
      );
      final competingId = ownId();
      await expectLater(
        bridge.open(id: competingId, url: pages.url('/two')),
        throwsA(
          isA<RuntimeBridgeException>().having(
            (error) => error.code,
            'code',
            'busy',
          ),
        ),
      );
      expect(await bridge.state(competingId), isNull);
      expect((await bridge.state(id))!.id, id);
      await bridge.action(
        id,
        action: 'scroll',
        deltaY: 320,
        expectedRevision: shot.frame.state.revision,
      );
      final scroll = await pages.waitForScroll();
      expect(scroll['scrollY'], greaterThan(0));
      await bridge.navigate(id, pages.url('/two'));
      await pages.waitForGet('/two');
      shot = await _shotUntil(
        bridge,
        id,
        (shot) => shot.area(23, 109, 197).pixels > 30000,
      );
      expect((await bridge.state(id))!.canGoBack, isTrue);
      await bridge.back(id);
      await _waitState(
        tester,
        bridge,
        id,
        (state) => state.url == pages.url('/one') && !state.loading,
      );
      expect((await bridge.state(id))!.canGoForward, isTrue);
      await bridge.forward(id);
      await _waitState(
        tester,
        bridge,
        id,
        (state) => state.url == pages.url('/two') && !state.loading,
      );
      await bridge.open(
        id: id,
        url: pages.url('/two'),
        width: 600,
        height: 420,
      );
      shot = await _shotUntil(
        bridge,
        id,
        (shot) => shot.area(23, 109, 197).pixels > 30000,
      );
      expect(shot.frame.state.width, 600);
      expect(shot.frame.state.height, 420);
      expect(shot.frame.width, lessThanOrEqualTo(600));
      expect(shot.frame.height, lessThanOrEqualTo(420));
      final resizedArtifact = await _save('HISTORY_RESIZED', shot, pages);

      const native = MethodChannel(ComputerBrowserBridge.methodChannelName);
      for (final url in [
        'file:///workspace/browser-fixture.html',
        'content://dev.perant.invalid/browser-fixture',
        'javascript:document.title="MUST_NOT_RUN"',
        'data:text/html,untrusted-fixture',
        'intent://browser-fixture/#Intent;scheme=https;end',
      ]) {
        // Bypass Dart validation to exercise the actual Kotlin boundary.
        await expectLater(
          native.invokeMethod<Object?>('navigate', {'id': id, 'url': url}),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'invalid_arguments',
            ),
          ),
        );
      }
      expect((await bridge.state(id))!.url, pages.url('/two'));
      await bridge.close(id);
      expect(await bridge.state(id), isNull);
      await expectLater(
        bridge.capture(id),
        throwsA(
          isA<RuntimeBridgeException>().having(
            (error) => error.code,
            'code',
            'not_found',
          ),
        ),
      );
      final previousGets = pages.gets.where((path) => path == '/one').length;
      final freshId = ownId();
      await bridge.open(
        id: freshId,
        url: pages.url('/one'),
        width: 480,
        height: 640,
      );
      await pages.waitForGet('/one', count: previousGets + 1);
      final fresh = await _shotUntil(
        bridge,
        freshId,
        (shot) => shot.area(197, 23, 109).pixels > 30000,
      );
      _hidden((await bridge.state(freshId))!);
      _record(report, 'history-resize-url-boundary-and-close', {
        'provider': fresh.frame.state.provider,
        'scrollObservedByPageJavaScript': true,
        'backAndForwardObservedInNativeState': true,
        'resizedViewport': [600, 420],
        'actualResizedPng': [shot.frame.width, shot.frame.height],
        'disallowedSchemesRejectedByKotlin': true,
        'competingSessionRejectedWithoutTakeover': true,
        'rejectedNavigationPreservedCurrentPage': true,
        'closedStateIsNull': true,
        'closedCaptureRejected': true,
        'freshSessionLoadedItsOwnInitialPage': true,
        'resizedScreenshotAppPath': resizedArtifact,
      });
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets(
    'hidden JavaScript dialogs cannot block capture and main frame errors are reported',
    (tester) async {
      final id = ownId();
      await bridge.open(
        id: id,
        url: pages.url('/dialogs'),
        width: 480,
        height: 640,
      );
      await pages.waitForGet('/dialogs');
      final dialogs = await _shotUntil(
        bridge,
        id,
        (shot) => shot.area(71, 181, 103).pixels > 30000,
      );
      final result = await pages.waitForDialogResult();
      expect(result['confirm'], isFalse);
      expect(result['prompt'], isNull);
      expect(result['scriptContinuedAfterDialogs'], isTrue);
      _hidden((await bridge.state(id))!);
      expect(dialogs.frame.state.error, isEmpty);
      final artifact = await _save('HIDDEN_DIALOGS_CANCELED', dialogs, pages);

      await expectLater(
        bridge.navigate(id, 'http://perant-browser-fixture.invalid/plaintext'),
        throwsA(
          isA<RuntimeBridgeException>().having(
            (error) => error.code,
            'code',
            'cleartext_not_permitted',
          ),
        ),
      );
      expect((await bridge.state(id))!.url, pages.url('/dialogs'));
      expect(pages.gets, ['/dialogs']);
      await bridge.navigate(id, pages.url('/missing'));
      final failed = await _waitState(
        tester,
        bridge,
        id,
        (state) => !state.loading && state.error.contains('HTTP 404'),
      );
      expect(failed.url, pages.url('/missing'));
      final bodyErrorArtifact = await _save(
        'REAL_HTTP404_BODY',
        await _shot(bridge, id),
        pages,
      );
      await bridge.navigate(id, pages.url('/missing-empty'));
      final emptyFailed = await _waitState(
        tester,
        bridge,
        id,
        (state) => !state.loading && state.error.isNotEmpty,
      );
      expect(emptyFailed.url, pages.url('/missing-empty'));
      final emptyErrorArtifact = await _save(
        'REAL_HTTP404_EMPTY',
        await _shot(bridge, id),
        pages,
      );
      await bridge.navigate(id, pages.url('/two'));
      final recovered = await _shotUntil(
        bridge,
        id,
        (shot) => shot.area(23, 109, 197).pixels > 30000,
      );
      expect(recovered.frame.state.error, isEmpty);
      _hidden((await bridge.state(id))!);
      _record(report, 'hidden-dialogs-and-main-frame-error-recovery', {
        'provider': recovered.frame.state.provider,
        'alertConfirmAndPromptDidNotBlockJavaScriptOrCapture': true,
        'confirmCanceled': true,
        'promptCanceled': true,
        'hiddenAndDetachedAfterDialogs': true,
        'remoteCleartextRejectedBeforeNavigation': true,
        'rejectedNavigationPreservedCurrentPage': true,
        'localHttp404Reported': failed.error,
        'localEmptyHttp404Reported': emptyFailed.error,
        'subsequentNavigationClearedErrorAndPainted': true,
        'dialogsScreenshotAppPath': artifact,
        'http404BodyScreenshotAppPath': bodyErrorArtifact,
        'http404EmptyScreenshotAppPath': emptyErrorArtifact,
      });
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<void> _mount(WidgetTester tester, String id) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 340,
            height: 500,
            child: AndroidView(
              viewType: ComputerBrowserBridge.platformViewType,
              creationParams: {'id': id},
              creationParamsCodec: const StandardMessageCodec(),
              layoutDirection: TextDirection.ltr,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<ComputerBrowserState> _waitState(
  WidgetTester tester,
  ComputerBrowserBridge bridge,
  String id,
  bool Function(ComputerBrowserState) predicate,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  ComputerBrowserState? latest;
  while (DateTime.now().isBefore(deadline)) {
    final state = await bridge.state(id);
    latest = state;
    if (state != null && predicate(state)) return state;
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  // ignore: avoid_print
  print(
    'COMPUTER_BROWSER_NATIVE_STATE_TIMEOUT ' +
        jsonEncode({
          'id': latest?.id,
          'url': latest?.url,
          'title': latest?.title,
          'loading': latest?.loading,
          'error': latest?.error,
          'visible': latest?.visible,
          'attached': latest?.attached,
          'revision': latest?.revision,
        }),
  );
  fail('Native browser state did not reach the expected lifecycle state.');
}

void _provider(String provider) {
  expect(provider, isNotEmpty);
  expect(
    provider,
    matches(RegExp(r'[0-9]+\.[0-9]+')),
    reason: 'Record the real Android WebView provider package and version.',
  );
}

void _hidden(ComputerBrowserState state) {
  expect(state.visible, isFalse);
  expect(state.attached, isFalse);
}

Future<_Shot> _shot(ComputerBrowserBridge bridge, String id) async {
  final frame = await bridge.capture(id);
  expect(frame.png.length, lessThanOrEqualTo(2 * 1024 * 1024));
  final codec = await ui.instantiateImageCodec(frame.png);
  ui.Image? image;
  try {
    image = (await codec.getNextFrame()).image;
    expect(image.width, frame.width);
    expect(image.height, frame.height);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(bytes, isNotNull);
    return _Shot(frame, Uint8List.fromList(bytes!.buffer.asUint8List()));
  } finally {
    image?.dispose();
    codec.dispose();
  }
}

Future<_Shot> _shotUntil(
  ComputerBrowserBridge bridge,
  String id,
  bool Function(_Shot) predicate,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  _Shot? latest;
  while (DateTime.now().isBefore(deadline)) {
    latest = await _shot(bridge, id);
    if (!latest.frame.state.loading && predicate(latest)) return latest;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  if (latest != null) {
    // ignore: avoid_print
    print(
      'COMPUTER_BROWSER_NATIVE_FAILURE_PNG_BASE64 ' +
          base64Encode(latest.frame.png),
    );
  }
  fail('The real native browser did not paint the expected fixture pixels.');
}

final class _Shot {
  const _Shot(this.frame, this.rgba);
  final ComputerBrowserFrame frame;
  final Uint8List rgba;

  _Area area(int red, int green, int blue) {
    var pixels = 0;
    var left = frame.width;
    var right = 0;
    var top = frame.height;
    var bottom = 0;
    for (var y = 0; y < frame.height; y++) {
      for (var x = 0; x < frame.width; x++) {
        final i = (y * frame.width + x) * 4;
        if (rgba[i] != red || rgba[i + 1] != green || rgba[i + 2] != blue) {
          continue;
        }
        pixels++;
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }
    return _Area(pixels, (left + right) ~/ 2, (top + bottom) ~/ 2);
  }
}

final class _Area {
  const _Area(this.pixels, this.centerX, this.centerY);
  final int pixels;
  final int centerX;
  final int centerY;
}

Future<String> _save(String label, _Shot shot, _LocalPages pages) async {
  final cache = await getTemporaryDirectory();
  final path =
      cache.path + '/browser-native-' + pages.nonce + '-' + label + '.png';
  await File(path).writeAsBytes(shot.frame.png, flush: true);
  // ignore: avoid_print
  print(
    'COMPUTER_BROWSER_NATIVE_' +
        label +
        '_PNG_BASE64 ' +
        base64Encode(shot.frame.png),
  );
  return path;
}

void _record(
  Map<String, dynamic> report,
  String check,
  Map<String, dynamic> data,
) {
  final value = <String, dynamic>{'check': check, ...data};
  (report['checks'] as List<Map<String, dynamic>>).add(value);
  // ignore: avoid_print
  print('COMPUTER_BROWSER_NATIVE_RESULT ' + jsonEncode(value));
}

final class _LocalPages {
  _LocalPages(this.server);
  final HttpServer server;
  final nonce = DateTime.now().microsecondsSinceEpoch.toString();
  final gets = <String>[];
  final events = <Map<String, dynamic>>[];
  StreamSubscription<HttpRequest>? subscription;
  List<Map<String, dynamic>> get clicks =>
      events.where((event) => event['type'] == 'click').toList();

  static Future<_LocalPages> start() async {
    final pages = _LocalPages(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    pages.subscription = pages.server.listen(pages.serve);
    return pages;
  }

  String url(String path) =>
      'http://127.0.0.1:' + server.port.toString() + path;

  Future<void> serve(HttpRequest request) async {
    try {
      request.response.headers.set('Cache-Control', 'no-store');
      if (request.method == 'GET' &&
          (request.uri.path == '/one' ||
              request.uri.path == '/two' ||
              request.uri.path == '/dialogs')) {
        gets.add(request.uri.path);
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          request.uri.path == '/one'
              ? _firstPage(nonce)
              : request.uri.path == '/dialogs'
              ? _dialogPage(nonce)
              : _secondPage,
        );
      } else if (request.method == 'POST' && request.uri.path == '/events') {
        final bytes = <int>[];
        await for (final part in request) {
          bytes.addAll(part);
          if (bytes.length > 2048)
            throw const FormatException('Fixture event too large.');
        }
        final event = Map<String, dynamic>.from(
          jsonDecode(utf8.decode(bytes)) as Map,
        );
        if (event['nonce'] != nonce)
          throw const FormatException('Wrong fixture nonce.');
        events.add(event);
        request.response.statusCode = HttpStatus.noContent;
      } else {
        request.response.statusCode = HttpStatus.notFound;
        if (request.uri.path != '/missing-empty') {
          request.response.headers.contentType = ContentType.html;
          request.response.write(
            '<!doctype html><title>Test-owned HTTP 404</title>'
            '<p>This local fixture really returned HTTP 404.</p>',
          );
        }
      }
    } catch (_) {
      request.response.statusCode = HttpStatus.badRequest;
    } finally {
      try {
        await request.response.close();
      } on SocketException {
        // Destroying the test's browser can cancel an otherwise completed
        // local request; JS/nonce/pixel assertions still verify every action.
      } on HttpException {
        // The loopback client may also close its keep-alive socket on teardown.
      }
    }
  }

  Future<void> waitForGet(String path, {int count = 1}) =>
      _wait(() => gets.where((value) => value == path).length >= count);

  Future<Map<String, dynamic>> waitForClick(int count) async {
    await _wait(() => clicks.length >= count);
    return clicks[count - 1];
  }

  Future<void> waitForInput(String value) => _wait(
    () => events.any(
      (event) => event['type'] == 'input' && event['value'] == value,
    ),
  );

  Future<Map<String, dynamic>> waitForScroll() async {
    await _wait(
      () => events.any(
        (event) => event['type'] == 'scroll' && (event['scrollY'] as num) > 0,
      ),
    );
    return events.firstWhere(
      (event) => event['type'] == 'scroll' && (event['scrollY'] as num) > 0,
    );
  }

  Future<void> waitForPointerDown() =>
      _wait(() => events.any((event) => event['type'] == 'pointerdown'));

  Future<Map<String, dynamic>> waitForDialogResult() async {
    await _wait(() => events.any((event) => event['type'] == 'dialogs'));
    return events.firstWhere((event) => event['type'] == 'dialogs');
  }

  Future<void> _wait(bool Function() predicate) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!predicate()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('The local browser fixture did not receive its real page event.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> close() async {
    await server.close(force: true);
    await subscription?.cancel();
  }
}

String _firstPage(String nonce) =>
    '''
<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy"
content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'">
<title>PerAnt native fixture</title><style>
html,body{margin:0;min-height:240vh;background:white;}
input{position:fixed;left:5vw;top:8vh;width:90vw;height:14vh;box-sizing:border-box;
border:0;background:rgb(19,91,187);color:white;font:24px sans-serif;}
button{position:fixed;left:5vw;top:35vh;width:90vw;height:45vh;border:0;
background:rgb(197,23,109);color:white;font:24px sans-serif;}
</style></head><body>
<p style="position:absolute;top:175vh">公开会议资料</p>
<input id="field" aria-label="Fixture input" autocomplete="off">
<button id="run">Run local JavaScript</button><script>
let clicks=0;
function post(value){return fetch('/events',{method:'POST',
headers:{'Content-Type':'application/json'},body:JSON.stringify(value)});}
document.getElementById('field').addEventListener('input',function(){
 post({type:'input',nonce:'$nonce',value:this.value});
});
document.getElementById('run').addEventListener('click',function(){
 const result=[6,7].reduce(function(a,b){return a*b;},1); clicks++;
 this.style.backgroundColor=clicks%2 ? 'rgb('+result+',203,149)' : 'rgb('+result+',91,211)';
 this.textContent='JS: '+result+' / click '+clicks;
 document.title='PerAnt native fixture '+clicks;
 post({type:'click',nonce:'$nonce',clicks:clicks,result:result,
 value:document.getElementById('field').value});
});
document.getElementById('run').addEventListener('pointerdown',function(){
 post({type:'pointerdown',nonce:'$nonce'});
});
let scrollSent=false;
window.addEventListener('scroll',function(){
 if(window.scrollY>0&&!scrollSent){scrollSent=true;
 post({type:'scroll',nonce:'$nonce',scrollY:window.scrollY});}
});
</script></body></html>
''';

const _secondPage = '''
<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
<title>PerAnt second local page</title>
<style>html,body{margin:0;height:100%;background:rgb(23,109,197);color:white;font:32px sans-serif;}</style>
</head><body>SECOND LOCAL PAGE</body></html>
''';

String _dialogPage(String nonce) =>
    '''
<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy"
content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'">
<title>PerAnt local modal fixture</title>
<style>html,body{margin:0;height:100%;background:white;}</style>
</head><body><script>
alert('PerAnt test-owned alert');
const confirmation=confirm('PerAnt test-owned confirm');
const answer=prompt('PerAnt test-owned prompt','fixture');
document.body.style.backgroundColor='rgb(71,181,103)';
fetch('/events',{method:'POST',headers:{'Content-Type':'application/json'},
body:JSON.stringify({type:'dialogs',nonce:'$nonce',confirm:confirmation,
prompt:answer,scriptContinuedAfterDialogs:true})});
</script></body></html>
''';
