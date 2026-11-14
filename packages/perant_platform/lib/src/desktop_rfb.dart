// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// An immutable snapshot decoded from actual RFB framebuffer rectangles.
/// Pixels use row-major RGBA8888, without a Flutter or image-library dependency.
final class DesktopFrame {
  DesktopFrame._({
    required this.width,
    required this.height,
    required Uint8List rgba,
    required this.sequence,
    required this.receivedAt,
  }) : rgba = Uint8List.fromList(rgba).asUnmodifiableView();

  final int width;
  final int height;
  final Uint8List rgba;
  final int sequence;
  final DateTime receivedAt;

  /// Encodes this observed framebuffer as a standalone PNG, including alpha.
  /// The caller chooses whether/where to save or transmit the image.
  Uint8List encodePng() {
    final scanlines = Uint8List((width * 4 + 1) * height);
    for (var row = 0; row < height; row++) {
      final start = row * (width * 4 + 1);
      scanlines[start] = 0; // PNG filter: None.
      scanlines.setRange(
          start + 1, start + 1 + width * 4, rgba, row * width * 4);
    }
    final header = ByteData(13)
      ..setUint32(0, width)
      ..setUint32(4, height)
      ..setUint8(8, 8)
      ..setUint8(9, 6); // RGBA, eight bits per channel.
    final result = BytesBuilder(copy: false)
      ..add(const [137, 80, 78, 71, 13, 10, 26, 10])
      ..add(_pngChunk('IHDR', header.buffer.asUint8List()))
      ..add(_pngChunk('IDAT', zlib.encode(scanlines)))
      ..add(_pngChunk('IEND', const []));
    return result.takeBytes();
  }
}

/// A deliberately small RFC 6143 client for the APK's private Unix socket.
///
/// Supports RFB 3.3/3.7/3.8, None security on this private transport, Raw,
/// CopyRect, DesktopSize and LastRect. It negotiates little-endian true-colour
/// 32bpp RGB bytes, then sets an opaque alpha channel for RGBA consumers.
/// No public TCP/hostname connection method or clipboard synchronisation exists.
final class DesktopRfbClient {
  DesktopRfbClient._({
    required Stream<List<int>> incoming,
    required Future<void> Function(Uint8List bytes) write,
    required Future<void> Function() disconnect,
    required this.maxPixels,
    required this.minFrameInterval,
    required bool continuous,
    required bool requestInitialFrame,
  })  : _reader = _RfbReader(incoming),
        _write = write,
        _disconnect = disconnect,
        _continuous = continuous,
        _requestInitialFrame = requestInitialFrame {
    // Keep early connection failures handled even if the UI has not yet
    // subscribed to firstFrame. Consumers can still await its original future.
    unawaited(_firstFrame!.future.then<void>((_) {}, onError: (Object _) {}));
  }

  static Future<DesktopRfbClient> connectUnix(
    String socketPath, {
    Duration timeout = const Duration(seconds: 10),
    int maxPixels = 2097152,
    Duration minFrameInterval = const Duration(milliseconds: 33),
    bool continuous = true,
    bool requestInitialFrame = true,
  }) async {
    _validateSettings(timeout, maxPixels, minFrameInterval);
    if (!requestInitialFrame && continuous) {
      throw ArgumentError('Input-only connections cannot poll frames.');
    }
    final bytes = utf8.encode(socketPath);
    if (!socketPath.startsWith('/') ||
        bytes.length > 103 ||
        socketPath.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
        utf8.decode(bytes) != socketPath) {
      throw ArgumentError(
          'Use an absolute, short app-private Unix socket path.');
    }
    final socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
      timeout: timeout,
    );
    return connectTransport(
      incoming: socket,
      write: (bytes) async {
        socket.add(bytes);
        await socket.flush();
      },
      disconnect: () async => socket.destroy(),
      timeout: timeout,
      maxPixels: maxPixels,
      minFrameInterval: minFrameInterval,
      continuous: continuous,
      requestInitialFrame: requestInitialFrame,
    );
  }

  /// Also permits an in-memory test transport or a native private byte proxy.
  /// The caller must ensure this stream has the app-private Unix-socket scope;
  /// None security is intentionally unsupported on public/listening TCP.
  static Future<DesktopRfbClient> connectTransport({
    required Stream<List<int>> incoming,
    required Future<void> Function(Uint8List bytes) write,
    required Future<void> Function() disconnect,
    Duration timeout = const Duration(seconds: 10),
    int maxPixels = 2097152,
    Duration minFrameInterval = const Duration(milliseconds: 33),
    bool continuous = true,
    bool requestInitialFrame = true,
  }) async {
    _validateSettings(timeout, maxPixels, minFrameInterval);
    if (!requestInitialFrame && continuous)
      throw ArgumentError('Input-only connections cannot poll frames.');
    final client = DesktopRfbClient._(
      incoming: incoming,
      write: write,
      disconnect: disconnect,
      maxPixels: maxPixels,
      minFrameInterval: minFrameInterval,
      continuous: continuous,
      requestInitialFrame: requestInitialFrame,
    );
    try {
      await client._handshake().timeout(timeout);
      unawaited(client._listen());
      if (requestInitialFrame) await client._request(incremental: false);
      return client;
    } catch (error) {
      client._fail(error);
      await client.close();
      rethrow;
    }
  }

  static void _validateSettings(
      Duration timeout, int maxPixels, Duration interval) {
    if (maxPixels < 1 ||
        maxPixels > 8388608 ||
        timeout <= Duration.zero ||
        interval < Duration.zero) {
      throw ArgumentError('Invalid framebuffer or timing bounds.');
    }
  }

  final int maxPixels;
  final Duration minFrameInterval;
  final _RfbReader _reader;
  final Future<void> Function(Uint8List bytes) _write;
  final Future<void> Function() _disconnect;
  final _frames = StreamController<DesktopFrame>.broadcast();
  Completer<DesktopFrame>? _firstFrame = Completer<DesktopFrame>();
  final _done = Completer<void>();
  final _waiters = <({int after, Completer<DesktopFrame> completion})>[];
  Future<void> _writes = Future.value();
  Future<void>? _closing;
  Future<DesktopFrame>? _capture;
  Timer? _nextRequest;
  Uint8List _pixels = Uint8List(0);
  Uint8List? _initialized;
  int _initializedCount = 0;
  int _width = 0;
  int _height = 0;
  int _sequence = 0;
  bool _closed = false;
  bool _continuous;
  final bool _requestInitialFrame;
  bool _hasRequestedPixels = false;
  String desktopName = '';
  Object? error;
  DesktopFrame? frame;

  Stream<DesktopFrame> get frames => _frames.stream;
  Future<DesktopFrame> get firstFrame {
    final observed = frame;
    if (observed != null) return Future.value(observed);
    if (_closed) return Future.error(StateError('RFB connection is closed.'));
    var pending = _firstFrame;
    if (pending == null) {
      pending = Completer<DesktopFrame>();
      unawaited(pending.future.then<void>((_) {}, onError: (Object _) {}));
      _firstFrame = pending;
    }
    return pending.future;
  }

  /// Completes after disconnection. Inspect [error] for an unexpected failure.
  Future<void> get done => _done.future;
  bool get isClosed => _closed;
  bool get isContinuous => _continuous;

  /// Hidden/background viewers disable polling or close the client entirely.
  /// A non-continuous connection still receives its one initial full frame.
  void setContinuous(bool enabled) {
    if (_closed) return;
    _continuous = enabled;
    _nextRequest?.cancel();
    if (enabled && _capture == null) {
      _nextRequest = Timer(minFrameInterval, () {
        unawaited(_request(incremental: true)
            .catchError((Object failure) => _fail(failure)));
      });
    }
  }

  int get width => _width;
  int get height => _height;

  /// Client-owned pixel/coverage bytes, excluding snapshots held by consumers.
  /// Useful when verifying that a hidden/closed viewer releases its buffers.
  int get retainedPixelBytes =>
      _pixels.length + (_initialized?.length ?? 0) + (frame?.rgba.length ?? 0);

  Future<void> _handshake() async {
    final version = ascii.decode(await _reader.exact(12));
    final match = RegExp(r'^RFB (\d{3})\.(\d{3})\n$').firstMatch(version);
    if (match == null || match.group(1) != '003') {
      throw const FormatException('Unsupported RFB protocol version.');
    }
    final minor = int.parse(match.group(2)!);
    final negotiated = minor == 8
        ? 8
        : minor == 7
            ? 7
            : 3;
    await _send(ascii.encode('RFB 003.00$negotiated\n'));
    if (negotiated == 3) {
      final security = await _reader.u32();
      if (security == 0) throw FormatException(await _reader.reason());
      if (security != 1)
        throw const FormatException('Private RFB None security required.');
    } else {
      final count = await _reader.u8();
      if (count == 0) throw FormatException(await _reader.reason());
      final types = await _reader.exact(count);
      if (!types.contains(1))
        throw const FormatException('Private RFB None security required.');
      await _send(const [1]);
      if (negotiated == 8 && await _reader.u32() != 0) {
        throw FormatException(await _reader.reason());
      }
    }
    await _send(const [1]); // ClientInit: shared desktop session.
    final initial = ByteData.sublistView(await _reader.exact(24));
    _resize(initial.getUint16(0), initial.getUint16(2),
        allocate: _requestInitialFrame);
    final nameLength = initial.getUint32(20);
    if (nameLength > 65536)
      throw const FormatException('RFB desktop name exceeds its limit.');
    desktopName =
        utf8.decode(await _reader.exact(nameLength), allowMalformed: true);
    final format = ByteData(20)
      ..setUint8(0, 0)
      ..setUint8(4, 32)
      ..setUint8(5, 24)
      ..setUint8(6, 0)
      ..setUint8(7, 1)
      ..setUint16(8, 255)
      ..setUint16(10, 255)
      ..setUint16(12, 255)
      ..setUint8(14, 0)
      ..setUint8(15, 8)
      ..setUint8(16, 16);
    await _send(format.buffer.asUint8List());
    final encodings = ByteData(20)
      ..setUint8(0, 2)
      ..setUint16(2, 4)
      ..setInt32(4, 1)
      ..setInt32(8, 0)
      ..setInt32(12, -223)
      ..setInt32(16, -224);
    await _send(encodings.buffer.asUint8List());
  }

  Future<void> _listen() async {
    try {
      while (!_closed) {
        final type = await _reader.u8();
        if (_closed) return;
        switch (type) {
          case 0:
            await _framebufferUpdate();
          case 1:
            await _reader.exact(3);
            final count = await _reader.u16();
            await _reader.exact(count * 6);
          case 2:
            break; // Bell: never changes a framebuffer or grants input.
          case 3:
            await _reader.exact(3);
            final length = await _reader.u32();
            if (length > 1048576)
              throw const FormatException('RFB clipboard exceeds its limit.');
            await _reader
                .exact(length); // Never copy server text to the OS clipboard.
          default:
            throw FormatException('Unsupported RFB server message: $type.');
        }
      }
    } catch (failure) {
      if (!_closed) _fail(failure);
    } finally {
      await close();
    }
  }

  Future<void> _framebufferUpdate() async {
    if (!_hasRequestedPixels)
      throw const FormatException(
          'Unrequested framebuffer data on an input-only connection.');
    await _reader.exact(1);
    final rectangles = await _reader.u16();
    if (_closed) return;
    var resized = false;
    for (var index = 0; index < rectangles; index++) {
      if (index >= 4096)
        throw const FormatException('Too many RFB rectangles.');
      final rect = ByteData.sublistView(await _reader.exact(12));
      if (_closed) return;
      final x = rect.getUint16(0);
      final y = rect.getUint16(2);
      final width = rect.getUint16(4);
      final height = rect.getUint16(6);
      final encoding = rect.getInt32(8);
      if (encoding == -224) break;
      if (encoding == -223) {
        if (x != 0 || y != 0)
          throw const FormatException('Invalid DesktopSize rectangle.');
        _resize(width, height);
        resized = true;
        continue;
      }
      _bounds(x, y, width, height);
      if (encoding == 0) {
        final data = await _reader.exact(width * height * 4);
        if (_closed) return;
        for (var row = 0; row < height; row++) {
          final offset = ((y + row) * _width + x) * 4;
          _pixels.setRange(offset, offset + width * 4, data, row * width * 4);
          for (var column = 0; column < width; column++) {
            _pixels[offset + column * 4 + 3] = 255;
            _mark((y + row) * _width + x + column, true);
          }
        }
      } else if (encoding == 1) {
        final source = ByteData.sublistView(await _reader.exact(4));
        if (_closed) return;
        final sx = source.getUint16(0);
        final sy = source.getUint16(2);
        _bounds(sx, sy, width, height);
        final data = Uint8List(width * height * 4);
        final known = _initialized == null ? null : Uint8List(width * height);
        for (var row = 0; row < height; row++) {
          final offset = ((sy + row) * _width + sx) * 4;
          data.setRange(
              row * width * 4, (row + 1) * width * 4, _pixels, offset);
          if (known != null) {
            known.setRange(row * width, (row + 1) * width, _initialized!,
                (sy + row) * _width + sx);
          }
        }
        for (var row = 0; row < height; row++) {
          final offset = ((y + row) * _width + x) * 4;
          _pixels.setRange(offset, offset + width * 4, data, row * width * 4);
          if (known != null) {
            for (var column = 0; column < width; column++) {
              _mark((y + row) * _width + x + column,
                  known[row * width + column] == 1);
            }
          }
        }
      } else {
        throw FormatException('Unrequested RFB rectangle encoding: $encoding.');
      }
    }
    if (_closed) return;
    if (_initializedCount == _width * _height) {
      _initialized = null;
      final observed = DesktopFrame._(
        width: _width,
        height: _height,
        rgba: _pixels,
        sequence: ++_sequence,
        receivedAt: DateTime.now(),
      );
      frame = observed;
      final first = _firstFrame;
      if (first != null && !first.isCompleted) first.complete(observed);
      _firstFrame = null;
      _frames.add(observed);
      for (final waiter in _waiters.toList()) {
        if (observed.sequence > waiter.after) {
          _waiters.remove(waiter);
          waiter.completion.complete(observed);
        }
      }
    }
    _nextRequest?.cancel();
    if ((_continuous || _initialized != null) && _capture == null) {
      _nextRequest = Timer(minFrameInterval, () {
        unawaited(_request(incremental: !resized && _initialized == null)
            .catchError((Object failure) => _fail(failure)));
      });
    }
  }

  void _resize(int width, int height, {bool allocate = true}) {
    if (_closed) throw StateError('RFB connection is closed.');
    if (width < 1 || height < 1 || width * height > maxPixels) {
      throw const FormatException(
          'RFB framebuffer dimensions exceed their limit.');
    }
    _width = width;
    _height = height;
    _pixels = allocate ? Uint8List(width * height * 4) : Uint8List(0);
    _initialized = allocate ? Uint8List(width * height) : null;
    _initializedCount = 0;
    frame = null;
  }

  void _bounds(int x, int y, int width, int height) {
    if (x + width > _width || y + height > _height) {
      throw const FormatException(
          'RFB rectangle lies outside the framebuffer.');
    }
  }

  void _mark(int index, bool known) {
    final mask = _initialized;
    if (mask == null) return;
    final value = known ? 1 : 0;
    if (mask[index] == value) return;
    _initializedCount += known ? 1 : -1;
    mask[index] = value;
  }

  Future<void> _request({required bool incremental}) {
    if (_pixels.isEmpty) _resize(_width, _height);
    _hasRequestedPixels = true;
    final request = ByteData(10)
      ..setUint8(0, 3)
      ..setUint8(1, incremental ? 1 : 0)
      ..setUint16(6, _width)
      ..setUint16(8, _height);
    return _send(request.buffer.asUint8List());
  }

  /// Requests a fresh full image after preceding input writes. Two request/
  /// response observations drain a possibly already-in-flight incremental
  /// update before publishing the capture; RFB has no per-request IDs. A fresh
  /// input-only connection needs just one full response, with no prior update.
  Future<DesktopFrame> capture(
      {Duration timeout = const Duration(seconds: 5)}) {
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
    if (_closed) return Future.error(StateError('RFB connection is closed.'));
    final pending = _capture;
    if (pending != null) return pending;
    _nextRequest?.cancel();
    final result = _captureFresh(timeout);
    _capture = result;
    return result;
  }

  Future<DesktopFrame> _captureFresh(Duration timeout) async {
    final watch = Stopwatch()..start();
    try {
      var after = _sequence;
      final passes = _hasRequestedPixels ? 2 : 1;
      for (var pass = 0; pass < passes; pass++) {
        final completion = Completer<DesktopFrame>();
        unawaited(completion.future.then<void>((_) {}, onError: (Object _) {}));
        final waiter = (after: after, completion: completion);
        _waiters.add(waiter);
        try {
          final requestBudget = timeout - watch.elapsed;
          if (requestBudget <= Duration.zero) {
            throw TimeoutException('Desktop capture timed out.', timeout);
          }
          await _request(incremental: false).timeout(requestBudget);
          final frameBudget = timeout - watch.elapsed;
          if (frameBudget <= Duration.zero) {
            throw TimeoutException('Desktop capture timed out.', timeout);
          }
          final observed = await completion.future.timeout(frameBudget);
          after = observed.sequence;
          if (pass == passes - 1) return observed;
        } finally {
          _waiters.remove(waiter);
        }
      }
      throw StateError('A complete desktop capture was not received.');
    } finally {
      _capture = null;
      if (!_closed && _continuous) {
        _nextRequest = Timer(minFrameInterval, () {
          unawaited(_request(incremental: true)
              .catchError((Object failure) => _fail(failure)));
        });
      }
    }
  }

  Future<void> pointer({required int x, required int y, int buttons = 0}) {
    if (x < 0 ||
        y < 0 ||
        x >= _width ||
        y >= _height ||
        buttons < 0 ||
        buttons > 255) {
      throw ArgumentError(
          'Pointer coordinates/buttons are outside their bounds.');
    }
    final event = ByteData(6)
      ..setUint8(0, 5)
      ..setUint8(1, buttons)
      ..setUint16(2, x)
      ..setUint16(4, y);
    return _send(event.buffer.asUint8List());
  }

  Future<void> key({required int keysym, required bool down}) {
    if (keysym < 0 || keysym > 0xffffffff)
      throw ArgumentError.value(keysym, 'keysym');
    final event = ByteData(8)
      ..setUint8(0, 4)
      ..setUint8(1, down ? 1 : 0)
      ..setUint32(4, keysym);
    return _send(event.buffer.asUint8List());
  }

  /// Sends paired X11 key events; no host clipboard or shell interpolation.
  Future<void> text(String value) {
    if (value.runes.length > 4096 || utf8.decode(utf8.encode(value)) != value) {
      throw ArgumentError('Desktop text must fit in 4096 Unicode characters.');
    }
    final output = BytesBuilder(copy: false);
    for (final rune in value.runes) {
      final keysym = switch (rune) {
        10 || 13 => 0xff0d,
        9 => 0xff09,
        8 => 0xff08,
        >= 32 && <= 255 => rune,
        >= 256 => 0x01000000 | rune,
        _ => throw ArgumentError('Unsupported desktop text control character.'),
      };
      for (final down in [true, false]) {
        final event = ByteData(8)
          ..setUint8(0, 4)
          ..setUint8(1, down ? 1 : 0)
          ..setUint32(4, keysym);
        output.add(event.buffer.asUint8List());
      }
    }
    return _send(output.takeBytes());
  }

  Future<void> _send(List<int> bytes) {
    final stable = Uint8List.fromList(bytes);
    final next = _writes.then((_) async {
      if (_closed) throw StateError('RFB connection is closed.');
      try {
        await _write(stable);
      } catch (failure) {
        _fail(failure);
        rethrow;
      }
    });
    // The internal tail must not become an unhandled secondary error when a
    // caller catches its own write failure and the connection is then closed.
    _writes = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  void _fail(Object failure) {
    if (_closed) return;
    error ??= failure;
    final first = _firstFrame;
    if (first != null && !first.isCompleted) first.completeError(failure);
    _firstFrame = null;
    for (final waiter in _waiters.toList()) {
      if (!waiter.completion.isCompleted)
        waiter.completion.completeError(failure);
    }
    _waiters.clear();
    if (_frames.hasListener) _frames.addError(failure);
    unawaited(close());
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _nextRequest?.cancel();
    final stopped = StateError('RFB connection is closed.');
    final first = _firstFrame;
    if (first != null && !first.isCompleted)
      first.completeError(error ?? stopped);
    _firstFrame = null;
    for (final waiter in _waiters.toList()) {
      if (!waiter.completion.isCompleted)
        waiter.completion.completeError(error ?? stopped);
    }
    _waiters.clear();
    frame = null;
    _pixels = Uint8List(0);
    _initialized = null;
    _initializedCount = 0;
    try {
      await _reader.close();
    } catch (failure) {
      error ??= failure;
    }
    try {
      await _disconnect();
    } catch (failure) {
      error ??= failure;
    } finally {
      unawaited(_frames.close());
      if (!_done.isCompleted) _done.complete();
    }
  }
}

final class _RfbReader {
  _RfbReader(Stream<List<int>> stream) : _stream = StreamIterator(stream);
  final StreamIterator<List<int>> _stream;
  List<int> _chunk = const [];
  int _offset = 0;

  Future<Uint8List> exact(int count) async {
    if (count < 0 || count > 33554432)
      throw const FormatException('RFB read exceeds its limit.');
    final result = Uint8List(count);
    var written = 0;
    while (written < count) {
      if (_offset >= _chunk.length) {
        if (!await _stream.moveNext())
          throw const FormatException(
              'RFB stream ended before a complete message.');
        _chunk = _stream.current;
        _offset = 0;
        if (_chunk.length > 33554432)
          throw const FormatException('RFB input chunk exceeds its limit.');
        if (_chunk.isEmpty) continue;
      }
      final remaining = count - written;
      final available = _chunk.length - _offset;
      final take = remaining < available ? remaining : available;
      result.setRange(written, written + take, _chunk, _offset);
      _offset += take;
      written += take;
    }
    return result;
  }

  Future<int> u8() async => (await exact(1)).single;
  Future<int> u16() async => ByteData.sublistView(await exact(2)).getUint16(0);
  Future<int> u32() async => ByteData.sublistView(await exact(4)).getUint32(0);
  Future<String> reason() async {
    final count = await u32();
    if (count > 65536)
      throw const FormatException('RFB rejection message exceeds its limit.');
    return utf8.decode(await exact(count), allowMalformed: true);
  }

  Future<void> close() async {
    _chunk = const [];
    _offset = 0;
    await _stream.cancel();
  }
}

Uint8List _pngChunk(String type, List<int> data) {
  final name = ascii.encode(type);
  final checksumInput = Uint8List(4 + data.length)
    ..setRange(0, 4, name)
    ..setRange(4, 4 + data.length, data);
  final result = ByteData(data.length + 12)..setUint32(0, data.length);
  result.buffer.asUint8List().setRange(4, 8 + data.length, checksumInput);
  result.setUint32(8 + data.length, _crc32(checksumInput));
  return result.buffer.asUint8List();
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc = (crc >>> 8) ^ _crcTable[(crc ^ byte) & 255];
  }
  return crc ^ 0xffffffff;
}

final _crcTable = List<int>.generate(256, (index) {
  var value = index;
  for (var bit = 0; bit < 8; bit++) {
    value = (value & 1) == 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  }
  return value;
}, growable: false);
