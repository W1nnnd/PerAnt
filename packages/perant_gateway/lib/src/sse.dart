// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';

import 'models.dart';

final class SseMessage {
  const SseMessage(this.data, this.event);
  final String data;
  final String? event;
}

/// Handles UTF-8 chunk boundaries, CRLF, comments and multiline SSE data.
Stream<SseMessage> decodeSse(Stream<List<int>> bytes) {
  final parser = _SseParser();
  return bytes.transform(utf8.decoder).transform(
        StreamTransformer<String, SseMessage>.fromHandlers(
          handleData: (chunk, sink) {
            try {
              for (final message in parser.add(chunk)) {
                sink.add(message);
              }
            } catch (error, stackTrace) {
              sink.addError(error, stackTrace);
            }
          },
          handleDone: (sink) {
            try {
              for (final message in parser.finish()) {
                sink.add(message);
              }
            } catch (error, stackTrace) {
              sink.addError(error, stackTrace);
            }
            sink.close();
          },
        ),
      );
}

final class _SseParser {
  static const maxFrameCharacters = 1024 * 1024;
  String _pending = '';
  final List<String> _data = [];
  int _frameLength = 0;
  String? _event;
  bool _firstLine = true;

  Iterable<SseMessage> add(String chunk) sync* {
    _pending += chunk;
    var end = _pending.indexOf('\n');
    while (end >= 0) {
      var line = _pending.substring(0, end);
      _pending = _pending.substring(end + 1);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      final message = _line(line);
      if (message != null) yield message;
      end = _pending.indexOf('\n');
    }
    if (_pending.length > maxFrameCharacters) _tooLarge();
  }

  Iterable<SseMessage> finish() sync* {
    if (_pending.isNotEmpty) {
      final message = _line(_pending);
      _pending = '';
      if (message != null) yield message;
    }
    final message = _line('');
    if (message != null) yield message;
  }

  SseMessage? _line(String line) {
    if (_firstLine) {
      _firstLine = false;
      if (line.startsWith('\uFEFF')) line = line.substring(1);
    }
    if (line.length > maxFrameCharacters) _tooLarge();
    if (line.isEmpty) {
      final result =
          _data.isEmpty ? null : SseMessage(_data.join('\n'), _event);
      _data.clear();
      _event = null;
      _frameLength = 0;
      return result;
    }
    if (line.startsWith(':')) return null;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'event') _event = value;
    if (field == 'data') {
      _frameLength += value.length + 1;
      if (_frameLength > maxFrameCharacters) _tooLarge();
      _data.add(value);
    }
    return null;
  }

  Never _tooLarge() => throw const GatewayException(
      'frame_too_large', 'The API returned an oversized stream event.');
}
