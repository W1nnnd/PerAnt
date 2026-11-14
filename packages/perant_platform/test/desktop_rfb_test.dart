// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:perant_platform/src/desktop_rfb.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fragmented RFB handshake and actual raw pixels form a decodable PNG',
      () async {
    final server = _Fixture();
    addTearDown(server.close);
    final client = await server.connect(width: 2, height: 1, fragment: 1);
    expect(client.desktopName, 'PerAnt test display');
    expect(server.writes[0], ascii.encode('RFB 003.008\n'));
    final format = ByteData.sublistView(server.writes[3]);
    expect(format.getUint8(4), 32);
    expect(format.getUint8(7), 1);
    expect(format.getUint8(14), 0);
    expect(format.getUint8(15), 8);
    expect(format.getUint8(16), 16);
    server.add(
        _update([
          _raw(0, 0, 2, 1, [255, 0, 0, 0, 0, 255, 0, 0])
        ]),
        fragment: 1);
    final frame = await client.firstFrame.timeout(const Duration(seconds: 2));
    expect(frame.width, 2);
    expect(frame.height, 1);
    expect(frame.rgba, [255, 0, 0, 255, 0, 255, 0, 255]);
    expect(() => frame.rgba[0] = 0, throwsUnsupportedError);
    final png = frame.encodePng();
    final codec = await ui.instantiateImageCodec(png);
    final decoded = await codec.getNextFrame();
    try {
      expect(decoded.image.width, 2);
      expect(decoded.image.height, 1);
      final bytes =
          await decoded.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(bytes!.buffer.asUint8List(), frame.rgba);
    } finally {
      decoded.image.dispose();
      codec.dispose();
    }
    expect(server.updateRequests, 1,
        reason: 'A hidden/snapshot client must not poll.');
  });

  test('CopyRect handles overlap without changing an earlier immutable frame',
      () async {
    final server = _Fixture();
    addTearDown(server.close);
    final client = await server.connect(width: 3, height: 1);
    server.add(_update([
      _raw(0, 0, 3, 1, [10, 0, 0, 0, 20, 0, 0, 0, 30, 0, 0, 0])
    ]));
    final first = await client.firstFrame;
    final next = client.frames.first;
    server.add(_update([_copy(1, 0, 2, 1, 0, 0)]));
    final copied = await next;
    expect([copied.rgba[0], copied.rgba[4], copied.rgba[8]], [10, 10, 20]);
    expect([first.rgba[0], first.rgba[4], first.rgba[8]], [10, 20, 30]);
    expect(copied.sequence, greaterThan(first.sequence));
  });

  test('DesktopSize replaces the buffer only with observed pixels', () async {
    final server = _Fixture();
    addTearDown(server.close);
    final client = await server.connect(width: 1, height: 1);
    server.add(_update([
      _raw(0, 0, 1, 1, [10, 20, 30, 0])
    ]));
    await client.firstFrame;
    final next = client.frames.first;
    server.add(_update([
      _rectangle(0, 0, 2, 1, -223),
      _raw(0, 0, 2, 1, [70, 80, 90, 0, 100, 110, 120, 0]),
      _rectangle(0, 0, 0, 0, -224),
    ]));
    final resized = await next;
    expect(resized.width, 2);
    expect(resized.rgba, [70, 80, 90, 255, 100, 110, 120, 255]);
  });

  test('partial initial updates never publish unobserved black pixels',
      () async {
    final server = _Fixture();
    addTearDown(server.close);
    final client = await server.connect(width: 2, height: 1);
    var observed = false;
    unawaited(client.firstFrame.then((_) => observed = true));
    server.add(_update([
      _raw(0, 0, 1, 1, [1, 2, 3, 0])
    ]));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(client.frame, isNull);
    expect(observed, isFalse);
    server.add(_update([
      _raw(1, 0, 1, 1, [4, 5, 6, 0])
    ]));
    final frame = await client.firstFrame;
    expect(frame.rgba, [1, 2, 3, 255, 4, 5, 6, 255]);
  });

  test('pointer, key and Unicode typing use RFB messages without shell text',
      () async {
    final server = _Fixture();
    addTearDown(server.close);
    final client = await server.connect(width: 100, height: 80);
    server.writes.clear();
    await client.pointer(x: 42, y: 63, buttons: 1);
    await client.pointer(x: 42, y: 63);
    await client.key(keysym: 0xffe3, down: true);
    await client.key(keysym: 0xffe3, down: false);
    await client.text('A你\n');
    expect(server.writes[0], [5, 1, 0, 42, 0, 63]);
    expect(server.writes[1], [5, 0, 0, 42, 0, 63]);
    expect(ByteData.sublistView(server.writes[2]).getUint32(4), 0xffe3);
    final text = ByteData.sublistView(server.writes.last);
    expect(text.getUint32(4), 65);
    expect(text.getUint32(20), 0x01004f60);
    expect(text.getUint32(36), 0xff0d);
    expect(text.getUint8(1), 1);
    expect(text.getUint8(9), 0);
    expect(() => client.pointer(x: 100, y: 0), throwsArgumentError);
    expect(() => client.pointer(x: 0, y: 0, buttons: 256), throwsArgumentError);
    expect(() => client.key(keysym: -1, down: true), throwsArgumentError);
    expect(() => client.text('\u0000'), throwsArgumentError);
  });

  test(
      'explicit capture drains an in-flight update and hidden clients do not poll',
      () async {
    final server = _Fixture();
    addTearDown(server.close);
    server.onUpdateRequest = () {
      server.add(_update([
        _raw(0, 0, 1, 1, [server.updateRequests, 0, 0, 0])
      ]));
    };
    final client = await server.connect(width: 1, height: 1);
    final first = await client.firstFrame;
    expect(first.rgba[0], 1);
    final captured = await client.capture();
    expect(captured.rgba[0], 3);
    expect(server.updateRequests, 3);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(server.updateRequests, 3);
    await client.close();
    expect(client.frame, isNull);
    expect(client.retainedPixelBytes, 0);
    expect(client.isClosed, isTrue);
    expect(server.disconnected, isTrue);
  });

  test(
      'continuous polling can be enabled and stopped without a background timer',
      () async {
    final server = _Fixture();
    addTearDown(server.close);
    server.onUpdateRequest = () => server.add(_update([
          _raw(0, 0, 1, 1, [1, 2, 3, 0])
        ]));
    final client = await server.connect(width: 1, height: 1);
    await client.firstFrame;
    client.setContinuous(true);
    await server.waitRequests(3);
    client.setContinuous(false);
    // Finish the one response already issued before asserting no more requests.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final count = server.updateRequests;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(server.updateRequests, count);
    expect(client.isContinuous, isFalse);
  });

  test(
      'hidden input-only sockets allocate no pixels and explicit capture reads one frame',
      () async {
    final server = _Fixture();
    addTearDown(server.close);
    final client =
        await server.connect(width: 1, height: 1, requestInitialFrame: false);
    expect(server.updateRequests, 0);
    expect(client.frame, isNull);
    expect(client.retainedPixelBytes, 0);
    await client.pointer(x: 0, y: 0, buttons: 1);
    await client.pointer(x: 0, y: 0);
    await client.text('hidden input');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(server.updateRequests, 0);
    expect(client.retainedPixelBytes, 0);
    server.onUpdateRequest = () => server.add(_update([
          _raw(0, 0, 1, 1, [7, 8, 9, 0])
        ]));
    final observation = await client.capture();
    expect(server.updateRequests, 1);
    expect(observation.rgba, [7, 8, 9, 255]);
    expect(client.retainedPixelBytes, 8);
    await client.close();
    expect(client.retainedPixelBytes, 0);
    expect(client.frame, isNull);
  });

  for (final version in [3, 7]) {
    test(
        'RFB 3.$version None omits SecurityResult and still decodes actual pixels',
        () async {
      final server = _Fixture();
      addTearDown(server.close);
      final client =
          await server.connect(width: 1, height: 1, version: version);
      server.add(_update([
        _raw(0, 0, 1, 1, [4, 5, 6, 0])
      ]));
      expect((await client.firstFrame).rgba, [4, 5, 6, 255]);
    });
  }

  test(
      'malformed or unsupported server input closes and releases its framebuffer',
      () async {
    final server = _Fixture();
    addTearDown(server.close);
    final client = await server.connect(width: 1, height: 1);
    server.add(_update([_rectangle(0, 0, 2, 1, 0)]));
    await client.done.timeout(const Duration(seconds: 2));
    expect(client.error, isA<FormatException>());
    expect(client.frame, isNull);
    expect(server.disconnected, isTrue);
  });

  test('unrequested compression is rejected rather than displayed as pixels',
      () async {
    final server = _Fixture();
    addTearDown(server.close);
    final client = await server.connect(width: 1, height: 1);
    server.add(_update([_rectangle(0, 0, 1, 1, 16)]));
    await client.done;
    expect(client.error, isA<FormatException>());
    expect(client.frame, isNull);
  });

  test(
      'oversized dimensions and non-private authentication fail during handshake',
      () async {
    final server = _Fixture();
    addTearDown(server.close);
    await expectLater(server.connect(width: 1024, height: 1024, maxPixels: 100),
        throwsFormatException);
    expect(server.disconnected, isTrue);

    final unsupported = _Fixture();
    addTearDown(unsupported.close);
    await expectLater(
        unsupported.connect(width: 1, height: 1, securityTypes: const [2]),
        throwsFormatException);
    expect(unsupported.disconnected, isTrue);
    await expectLater(
        DesktopRfbClient.connectUnix('127.0.0.1'), throwsArgumentError);
  });

  test('truncated raw data cannot become a screenshot', () async {
    final server = _Fixture();
    addTearDown(server.close);
    final client = await server.connect(width: 1, height: 1);
    server.add(_update([
      _rectangle(0, 0, 1, 1, 0),
      Uint8List.fromList([1, 2])
    ]));
    await server.closeInput();
    await client.done;
    expect(client.frame, isNull);
    expect(client.error, isA<FormatException>());
  });

  test('Unix socket transport connects without any TCP listener', () async {
    final directory = await Directory('/tmp').createTemp('perant-rfb-');
    final path = '${directory.path}/v.sock';
    final listener = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix), 0);
    Socket? peer;
    final accepted = Completer<void>();
    final subscription = listener.listen((socket) {
      peer = socket;
      // Drain real client bytes and provide a valid local test server stream.
      socket.listen((_) {});
      socket.add(_initial(1, 1, 8, const [1]));
      socket.add(_update([
        _raw(0, 0, 1, 1, [9, 8, 7, 0])
      ]));
      if (!accepted.isCompleted) accepted.complete();
    });
    DesktopRfbClient? client;
    try {
      client = await DesktopRfbClient.connectUnix(path, continuous: false);
      await accepted.future;
      expect((await client.firstFrame).rgba, [9, 8, 7, 255]);
      expect(listener.address.type, InternetAddressType.unix);
    } finally {
      await client?.close();
      peer?.destroy();
      await subscription.cancel();
      await listener.close();
      await directory.delete(recursive: true);
    }
  });
}

final class _Fixture {
  final _input = StreamController<List<int>>();
  final writes = <Uint8List>[];
  DesktopRfbClient? client;
  bool disconnected = false;
  int updateRequests = 0;
  void Function()? onUpdateRequest;

  Future<DesktopRfbClient> connect({
    required int width,
    required int height,
    int version = 8,
    int fragment = 0,
    int maxPixels = 2097152,
    List<int> securityTypes = const [1],
    bool requestInitialFrame = true,
  }) async {
    add(_initial(width, height, version, securityTypes), fragment: fragment);
    final result = await DesktopRfbClient.connectTransport(
      incoming: _input.stream,
      write: (bytes) async {
        writes.add(Uint8List.fromList(bytes));
        if (bytes.length == 10 && bytes[0] == 3) {
          updateRequests++;
          onUpdateRequest?.call();
        }
      },
      disconnect: closeInput,
      maxPixels: maxPixels,
      minFrameInterval: const Duration(milliseconds: 10),
      continuous: false,
      requestInitialFrame: requestInitialFrame,
    );
    client = result;
    return result;
  }

  void add(List<int> bytes, {int fragment = 0}) {
    if (fragment == 0) {
      _input.add(Uint8List.fromList(bytes));
      return;
    }
    for (var offset = 0; offset < bytes.length; offset += fragment) {
      _input.add(Uint8List.fromList(
          bytes.sublist(offset, (offset + fragment).clamp(0, bytes.length))));
    }
  }

  Future<void> waitRequests(int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (updateRequests < count) {
      if (DateTime.now().isAfter(deadline))
        throw StateError('No expected framebuffer request.');
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  Future<void> closeInput() async {
    if (disconnected) return;
    disconnected = true;
    await _input.close();
  }

  Future<void> close() async {
    await client?.close();
    await closeInput();
  }
}

Uint8List _initial(
    int width, int height, int version, List<int> securityTypes) {
  final name = utf8.encode('PerAnt test display');
  final initial = ByteData(24)
    ..setUint16(0, width)
    ..setUint16(2, height)
    ..setUint8(4, 32)
    ..setUint8(5, 24)
    ..setUint8(7, 1)
    ..setUint16(8, 255)
    ..setUint16(10, 255)
    ..setUint16(12, 255)
    ..setUint8(14, 16)
    ..setUint8(15, 8)
    ..setUint32(20, name.length);
  return (BytesBuilder(copy: false)
        ..add(ascii.encode('RFB 003.00$version\n'))
        ..add(version == 3
            ? [0, 0, 0, 1]
            : [securityTypes.length, ...securityTypes])
        ..add(version == 8 ? [0, 0, 0, 0] : const [])
        ..add(initial.buffer.asUint8List())
        ..add(name))
      .takeBytes();
}

Uint8List _update(List<Uint8List> rectangles) => (BytesBuilder(copy: false)
      ..add([0, 0, rectangles.length >>> 8, rectangles.length & 255])
      ..add(rectangles.expand((entry) => entry).toList()))
    .takeBytes();

Uint8List _rectangle(int x, int y, int width, int height, int encoding) =>
    (ByteData(12)
          ..setUint16(0, x)
          ..setUint16(2, y)
          ..setUint16(4, width)
          ..setUint16(6, height)
          ..setInt32(8, encoding))
        .buffer
        .asUint8List();

Uint8List _raw(int x, int y, int width, int height, List<int> rgba) =>
    (BytesBuilder(copy: false)
          ..add(_rectangle(x, y, width, height, 0))
          ..add(rgba))
        .takeBytes();

Uint8List _copy(int x, int y, int width, int height, int sx, int sy) =>
    (BytesBuilder(copy: false)
          ..add(_rectangle(x, y, width, height, 1))
          ..add((ByteData(4)
                ..setUint16(0, sx)
                ..setUint16(2, sy))
              .buffer
              .asUint8List()))
        .takeBytes();
