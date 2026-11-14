// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perant/src/application/computer_browser_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.perant/browser');
  late ComputerBrowserService service;
  late Map<String, Object?> native;
  late List<MethodCall> calls;
  late Uint8List png;
  Completer<void>? captureGate;
  Completer<void>? openGate;

  setUp(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(640, 480);
    png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();
    image.dispose();
    picture.dispose();
    calls = [];
    native = {
      'id': 'pending',
      'url': 'about:blank',
      'title': '',
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
    captureGate = null;
    openGate = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          final args = Map<String, Object?>.from(call.arguments as Map);
          switch (call.method) {
            case 'open':
              await openGate?.future;
              native = {...native, 'id': args['id'], 'url': args['url']};
              return native;
            case 'state':
              return native;
            case 'navigate':
              native = {
                ...native,
                'url': args['url'],
                'revision': (native['revision']! as int) + 1,
              };
              return native;
            case 'visible':
              native = {...native, 'visible': args['visible']};
              return native;
            case 'capture':
              await captureGate?.future;
              return {'state': native, 'width': 640, 'height': 480, 'png': png};
            case 'action':
              return native;
            case 'back':
            case 'forward':
              return native;
            case 'close':
            case 'cancel':
              return null;
            default:
              throw MissingPluginException(call.method);
          }
        });
    service = ComputerBrowserService();
  });
  tearDown(() async {
    service.dispose();
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('opening and hiding a browser never capture pixels', () async {
    await service.open();
    await service.setVisible(true);
    await service.setVisible(false);
    await service.refreshState();
    expect(calls.where((call) => call.method == 'capture'), isEmpty);
    await service.close();
    expect(service.running, isFalse);
    expect(calls.last.method, 'close');
  });

  test(
    'one fresh screenshot authorizes one action with its native revision',
    () async {
      service.takeModelControl();
      await service.open(url: 'https://example.org/', fromModel: true);
      final observation = await service.observe();
      await service.perform(
        observationId: observation.id,
        action: 'tap',
        x: 20,
        y: 30,
      );
      final action = calls.singleWhere((call) => call.method == 'action');
      expect(action.arguments, containsPair('expectedRevision', 1));
      expect(action.arguments, containsPair('width', 640));
      expect(action.arguments, containsPair('height', 480));
      await expectLater(
        service.perform(
          observationId: observation.id,
          action: 'tap',
          x: 20,
          y: 30,
        ),
        throwsStateError,
      );
      expect(calls.where((call) => call.method == 'action'), hasLength(1));
    },
  );

  test(
    'user takeover and regrant invalidate the old browser screenshot',
    () async {
      service.takeModelControl();
      await service.open(fromModel: true);
      final observation = await service.observe();
      service.releaseModelControl();
      service.noteUserInput();
      service.takeModelControl();
      await expectLater(
        service.perform(
          observationId: observation.id,
          action: 'text',
          text: 'old',
        ),
        throwsStateError,
      );
      expect(calls.where((call) => call.method == 'action'), isEmpty);
    },
  );

  test('an in-flight capture cannot survive a control change', () async {
    service.takeModelControl();
    await service.open(fromModel: true);
    captureGate = Completer<void>();
    final pending = service.observe();
    final rejected = expectLater(pending, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    service.releaseModelControl();
    captureGate!.complete();
    await rejected;
    expect(calls.where((call) => call.method == 'cancel'), hasLength(1));
    expect(calls.where((call) => call.method == 'action'), isEmpty);
  });

  test(
    'disposal closes a native session whose first open finishes late',
    () async {
      openGate = Completer<void>();
      final pending = service.open();
      final rejected = expectLater(pending, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      service.dispose();
      openGate!.complete();
      await rejected;
      final open = calls.singleWhere((call) => call.method == 'open');
      final close = calls.singleWhere((call) => call.method == 'close');
      expect(
        close.arguments,
        containsPair('id', (open.arguments as Map)['id']),
      );
    },
  );
}
