// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'models.dart';

/// Metadata for the one native Chromium/WebView session shared with its viewer.
final class ComputerBrowserState {
  const ComputerBrowserState({
    required this.id,
    this.url = 'about:blank',
    this.title = '',
    this.loading = false,
    this.canGoBack = false,
    this.canGoForward = false,
    this.width = 1024,
    this.height = 640,
    this.visible = false,
    this.attached = false,
    this.provider = 'Android System WebView',
    this.revision = 0,
    this.error = '',
  });

  final String id;
  final String url;
  final String title;
  final bool loading;
  final bool canGoBack;
  final bool canGoForward;
  final int width;
  final int height;
  final bool visible;
  final bool attached;
  final String provider;
  final int revision;
  final String error;

  factory ComputerBrowserState.fromMap(Map<Object?, Object?> map) {
    T field<T>(String key) {
      final value = map[key];
      if (value is! T) throw FormatException('Invalid browser field: $key');
      return value;
    }

    final reportedError = map['error'] ?? '';
    if (reportedError is! String) {
      throw const FormatException('Invalid browser error.');
    }
    final state = ComputerBrowserState(
      id: field<String>('id'),
      url: field<String>('url'),
      title: field<String>('title'),
      loading: field<bool>('loading'),
      canGoBack: field<bool>('canGoBack'),
      canGoForward: field<bool>('canGoForward'),
      width: field<int>('width'),
      height: field<int>('height'),
      visible: field<bool>('visible'),
      attached: field<bool>('attached'),
      provider: field<String>('provider'),
      revision: field<int>('revision'),
      error: reportedError,
    );
    try {
      _id(state.id);
      _url(state.url);
      _viewport(state.width, state.height);
      if (state.revision < 0 ||
          state.title.length > 1024 ||
          state.error.length > 512 ||
          state.provider.isEmpty ||
          state.provider.length > 512) {
        throw const FormatException('Invalid browser metadata.');
      }
    } on ArgumentError {
      throw const FormatException('Invalid browser metadata.');
    }
    return state;
  }
}

/// An on-demand PNG. The native side retains no bitmap after returning it.
final class ComputerBrowserFrame {
  const ComputerBrowserFrame({
    required this.state,
    required this.png,
    required this.width,
    required this.height,
  });

  final ComputerBrowserState state;
  final Uint8List png;
  final int width;
  final int height;

  factory ComputerBrowserFrame.fromMap(Map<Object?, Object?> map) {
    final state = ComputerBrowserState.fromMap(_map(map['state']));
    final png = map['png'];
    final width = map['width'];
    final height = map['height'];
    if (png is! Uint8List ||
        width is! int ||
        height is! int ||
        width > state.width ||
        height > state.height ||
        png.length < 24 ||
        png.length > 2 * 1024 * 1024) {
      throw const FormatException('Invalid browser image.');
    }
    try {
      _dimensions(width, height);
    } on ArgumentError {
      throw const FormatException('Invalid browser image dimensions.');
    }
    const magic = [137, 80, 78, 71, 13, 10, 26, 10];
    for (var i = 0; i < magic.length; i++) {
      if (png[i] != magic[i]) {
        throw const FormatException('Invalid browser PNG.');
      }
    }
    final header = ByteData.sublistView(png);
    if (header.getUint32(16) != width || header.getUint32(20) != height) {
      throw const FormatException('Browser PNG dimensions do not match.');
    }
    return ComputerBrowserFrame(
      state: state,
      png: png,
      width: width,
      height: height,
    );
  }
}

/// A bounded text snapshot of the loaded top-level document's rendered body.
///
/// It excludes forms, editable regions, frames, script/style and hidden nodes.
/// [truncated] covers text, traversal and time budgets. The text is untrusted
/// webpage content, not model instructions or a complete document archive.
final class ComputerBrowserPage {
  const ComputerBrowserPage({
    required this.id,
    required this.url,
    required this.title,
    required this.revision,
    required this.text,
    required this.truncated,
  });

  static const maxCharacters = 120000;
  static const maxBytes = 240 * 1024;
  final String id;
  final String url;
  final String title;
  final int revision;
  final String text;
  final bool truncated;

  factory ComputerBrowserPage.fromMap(Map<Object?, Object?> map) {
    final id = map['id'];
    final url = map['url'];
    final title = map['title'];
    final revision = map['revision'];
    final text = map['text'];
    final truncated = map['truncated'];
    if (id is! String ||
        url is! String ||
        title is! String ||
        title.length > 1024 ||
        revision is! int ||
        revision < 0 ||
        text is! String ||
        text.trim().isEmpty ||
        text.length > maxCharacters ||
        text.contains('\u0000') ||
        truncated is! bool) {
      throw const FormatException('Invalid browser page.');
    }
    final bytes = utf8.encode(text);
    if (bytes.length > maxBytes || utf8.decode(bytes) != text) {
      throw const FormatException('Invalid browser page text.');
    }
    try {
      _id(id);
      _url(url);
      if (url == 'about:blank') throw ArgumentError('Empty page.');
    } on ArgumentError {
      throw const FormatException('Invalid browser page metadata.');
    }
    return ComputerBrowserPage(
      id: id,
      url: url,
      title: title,
      revision: revision,
      text: text,
      truncated: truncated,
    );
  }
}

/// This channel has no arbitrary JavaScript execution or host filesystem methods.
final class ComputerBrowserBridge {
  ComputerBrowserBridge({
    MethodChannel? methodChannel,
    this.responseTimeout = const Duration(seconds: 15),
  }) : _channel = methodChannel ?? const MethodChannel(methodChannelName);

  static const methodChannelName = 'dev.perant/browser';
  static const platformViewType = 'dev.perant/computer-browser';
  static const viewType = platformViewType;
  final MethodChannel _channel;
  final Duration responseTimeout;

  Future<ComputerBrowserState> open({
    required String id,
    required String url,
    int width = 1024,
    int height = 640,
  }) {
    _id(id);
    _url(url);
    _dimensions(width, height);
    return _stateCall(
        'open', id, {'url': url, 'width': width, 'height': height});
  }

  Future<ComputerBrowserState?> state(String id) async {
    _id(id);
    final value = await _invoke('state', {'id': id});
    if (value == null) return null;
    return _readState(value, id);
  }

  Future<ComputerBrowserState> navigate(String id, String url) {
    _url(url);
    return _stateCall('navigate', id, {'url': url});
  }

  Future<ComputerBrowserState> setVisible(String id, bool visible) =>
      _stateCall('visible', id, {'visible': visible});

  Future<ComputerBrowserFrame> capture(String id) async {
    _id(id);
    try {
      final frame = ComputerBrowserFrame.fromMap(
        _map(await _invoke('capture', {'id': id})),
      );
      if (frame.state.id != id) throw const FormatException('Wrong browser.');
      return frame;
    } on FormatException {
      throw _invalidResponse;
    }
  }

  Future<ComputerBrowserPage> readPage(String id,
      {int? expectedRevision}) async {
    _id(id);
    if (expectedRevision != null && expectedRevision < 0) {
      throw ArgumentError('Invalid browser revision.');
    }
    try {
      final page = ComputerBrowserPage.fromMap(
        _map(await _invoke('readPage', {
          'id': id,
          if (expectedRevision != null) 'expectedRevision': expectedRevision,
        })),
      );
      if (page.id != id ||
          (expectedRevision != null && page.revision != expectedRevision)) {
        throw const FormatException('Wrong browser page.');
      }
      return page;
    } on FormatException {
      throw _invalidResponse;
    }
  }

  Future<ComputerBrowserState> action(
    String id, {
    required String action,
    int? x,
    int? y,
    int? deltaY,
    String? text,
    String? key,
    List<String> modifiers = const [],
    int? width,
    int? height,
    int? expectedRevision,
  }) {
    if (!{'tap', 'long_press', 'scroll', 'text', 'key'}.contains(action) ||
        (expectedRevision != null && expectedRevision < 0) ||
        (width != null && (width < 1 || width > 1600)) ||
        (height != null && (height < 1 || height > 1200))) {
      throw ArgumentError('Invalid browser action.');
    }
    if (width != null && height != null) _dimensions(width, height);
    if ({'tap', 'long_press'}.contains(action) &&
        (x == null ||
            y == null ||
            x < 0 ||
            y < 0 ||
            x >= (width ?? 1600) ||
            y >= (height ?? 1200))) {
      throw ArgumentError('Invalid browser coordinates.');
    }
    if (action == 'scroll' &&
        (deltaY == null || deltaY < -12000 || deltaY > 12000)) {
      throw ArgumentError('Invalid browser scroll.');
    }
    if (action == 'text' &&
        (text == null || text.contains('\u0000') || text.length > 4096)) {
      throw ArgumentError('Invalid browser text.');
    }
    const namedKeys = {
      'enter',
      'return',
      'tab',
      'backspace',
      'delete',
      'escape',
      'esc',
      'arrowleft',
      'left',
      'arrowright',
      'right',
      'arrowup',
      'up',
      'arrowdown',
      'down',
      'home',
      'end',
      'pageup',
      'pagedown',
      'space',
      ' ',
    };
    if (action == 'key' &&
        (key == null ||
            !(namedKeys.contains(key.toLowerCase()) ||
                RegExp(r'^[A-Za-z0-9]$').hasMatch(key)))) {
      throw ArgumentError('Invalid browser key.');
    }
    if (modifiers.length > 4 ||
        modifiers.any((value) => !{
              'ctrl',
              'control',
              'shift',
              'alt',
              'super',
              'meta'
            }.contains(value.toLowerCase()))) {
      throw ArgumentError('Invalid browser modifier.');
    }
    return _stateCall('action', id, {
      'action': action,
      if (x != null) 'x': x,
      if (y != null) 'y': y,
      if (deltaY != null) 'deltaY': deltaY,
      if (text != null) 'text': text,
      if (key != null) 'key': key,
      'modifiers': modifiers,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      if (expectedRevision != null) 'expectedRevision': expectedRevision,
    });
  }

  Future<ComputerBrowserState> back(String id) => _stateCall('back', id);
  Future<ComputerBrowserState> forward(String id) => _stateCall('forward', id);
  Future<void> cancel(String id) async {
    _id(id);
    await _invoke('cancel', {'id': id});
  }

  Future<void> close(String id) async {
    _id(id);
    await _invoke('close', {'id': id});
  }

  Future<ComputerBrowserState> _stateCall(String method, String id,
      [Map<String, Object?> extra = const {}]) async {
    _id(id);
    return _readState(await _invoke(method, {'id': id, ...extra}), id);
  }

  ComputerBrowserState _readState(Object? value, String id) {
    try {
      final state = ComputerBrowserState.fromMap(_map(value));
      if (state.id != id) throw const FormatException('Wrong browser.');
      return state;
    } on FormatException {
      throw _invalidResponse;
    }
  }

  Future<Object?> _invoke(String method, Map<String, Object?> args) async {
    try {
      return await _channel
          .invokeMethod<Object?>(method, args)
          .timeout(responseTimeout);
    } on MissingPluginException {
      throw const RuntimeBridgeException(
          code: 'unavailable', message: '当前平台尚未连接原生浏览器。');
    } on PlatformException catch (error) {
      throw RuntimeBridgeException(
          code: error.code, message: error.message ?? '浏览器操作失败。');
    } on TimeoutException {
      throw const RuntimeBridgeException(
          code: 'timeout', message: '等待浏览器操作超时。');
    }
  }

  static const _invalidResponse = RuntimeBridgeException(
    code: 'invalid_response',
    message: '原生浏览器返回了无效数据。',
  );
}

Map<Object?, Object?> _map(Object? value) {
  if (value is! Map) throw const FormatException('Expected browser object.');
  return Map<Object?, Object?>.from(value);
}

void _id(String value) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value)) {
    throw ArgumentError('Invalid browser id.');
  }
}

void _url(String value) {
  if (value == 'about:blank') return;
  final uri = Uri.tryParse(value);
  if (value.isEmpty ||
      value.length > 8192 ||
      value.runes.any((rune) => rune <= 32 || rune == 127) ||
      uri == null ||
      !{'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
    throw ArgumentError('Only HTTP(S) and about:blank are supported.');
  }
}

void _dimensions(int width, int height) {
  if (width < 1 ||
      width > 1600 ||
      height < 1 ||
      height > 1200 ||
      width * height > 1920000) {
    throw ArgumentError('Invalid browser frame dimensions.');
  }
}

void _viewport(int width, int height) {
  if (width < 1 || width > 8192 || height < 1 || height > 8192) {
    throw ArgumentError('Invalid browser viewport dimensions.');
  }
}
