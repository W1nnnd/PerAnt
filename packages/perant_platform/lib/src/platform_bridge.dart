// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'workspace_files.dart';

/// The thin host boundary. This package does not pretend to execute Linux or AI.
final class PerantPlatformBridge {
  PerantPlatformBridge({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    this.responseTimeout = const Duration(seconds: 5),
    this.initializationTimeout = const Duration(seconds: 300),
  })  : _methods = methodChannel ?? const MethodChannel(methodChannelName),
        _events = eventChannel ?? const EventChannel(eventChannelName);

  static const methodChannelName = 'dev.perant/runtime';
  static const eventChannelName = 'dev.perant/runtime/events';

  final MethodChannel _methods;
  final EventChannel _events;
  final Duration responseTimeout;
  final Duration initializationTimeout;
  Stream<RuntimeEvent>? _eventStream;
  final _eventAttachmentSignal = Completer<void>();
  RuntimeBridgeException? _eventAttachmentError;
  bool _eventsAttached = false;

  Future<PlatformCapabilities> getCapabilities() async {
    try {
      final result = await _invoke('getCapabilities');
      return PlatformCapabilities.fromMap(_asMap(result));
    } on MissingPluginException {
      return PlatformCapabilities.unsupported(
        platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
        reason: '此构建未连接 Android 或 iOS 原生桥接，运行时能力尚不可用。',
      );
    } on FormatException {
      throw const RuntimeBridgeException(
        code: 'invalid_response',
        message: '原生能力响应与协议不一致。',
      );
    }
  }

  Future<TaskCancellation> cancelTask(String taskId) async {
    _validateId(taskId, 'taskId');
    try {
      final result = await _invoke('cancelTask', {'taskId': taskId});
      final cancellation = TaskCancellation.fromMap(_asMap(result));
      if (cancellation.taskId != taskId) {
        throw const FormatException('Native cancellation task ID mismatch.');
      }
      return cancellation;
    } on MissingPluginException {
      return TaskCancellation(
        taskId: taskId,
        status: TaskCancellationStatus.unavailable,
        reason: '原生桥接尚未连接，没有可取消的原生任务。',
      );
    } on FormatException {
      throw const RuntimeBridgeException(
        code: 'invalid_response',
        message: '原生取消响应与协议不一致。',
      );
    }
  }

  Future<LinuxStatus> getLinuxStatus() => _readLinuxStatus('getLinuxStatus');

  /// Bytes currently available to this app on its private data volume.
  Future<int?> availableStorageBytes() async {
    try {
      final value = await _invoke('getAvailableStorageBytes');
      return value is int && value >= 0 ? value : null;
    } on MissingPluginException {
      return null;
    } on RuntimeBridgeException {
      return null;
    }
  }

  /// Reuses an existing, ready desktop after a page change or hot restart.
  Future<LinuxDesktopSession?> getLinuxDesktopSession() async {
    try {
      final result = await _invokeLinux('getLinuxDesktopSession', null);
      return result == null
          ? null
          : LinuxDesktopSession.fromMap(_asMap(result));
    } on FormatException {
      throw _invalidLinuxResponse;
    }
  }

  /// Starts genuine Xvnc/Openbox processes. If a ready desktop already exists,
  /// its actual session ID is returned instead of launching a duplicate server.
  Future<LinuxDesktopSession> startLinuxDesktop({
    required String sessionId,
    int width = 1024,
    int height = 768,
  }) async {
    _validateId(sessionId, 'sessionId');
    if (width < 640 ||
        width > 1600 ||
        height < 480 ||
        height > 1200 ||
        width * height > 1920000) {
      throw ArgumentError(
          'Desktop dimensions must be 640–1600 by 480–1200 and at most 1920000 pixels.');
    }
    try {
      return LinuxDesktopSession.fromMap(_asMap(await _invokeLinux(
          'startLinuxDesktop',
          {
            'sessionId': sessionId,
            'width': width,
            'height': height,
          },
          initializationTimeout)));
    } on FormatException {
      throw _invalidLinuxResponse;
    }
  }

  /// Resolves only after this desktop's process tree has been reaped. A stale
  /// ID cannot stop a different desktop, command or manually owned terminal.
  Future<void> stopLinuxDesktop(String sessionId) async {
    _validateId(sessionId, 'sessionId');
    await _invokeLinuxVoid('stopLinuxDesktop', {'sessionId': sessionId});
  }

  Future<void> revealDesktopExcerpt(
      String sessionId, LinuxFileImport file) async {
    _validateId(sessionId, 'sessionId');
    await _invokeLinuxVoid(
        'revealDesktopExcerpt', {'sessionId': sessionId, 'path': file.path});
  }

  /// Reads shared guest files only while the native runtime is idle.
  Future<LinuxDirectoryListing> listLinuxDirectory(String path) async {
    final normalized = normalizeLinuxWorkspacePath(path);
    try {
      final listing = LinuxDirectoryListing.fromMap(
        _asMap(await _invokeLinux('listLinuxDirectory', {'path': normalized})),
      );
      if (listing.path != normalized)
        throw const FormatException('Wrong directory.');
      return listing;
    } on FormatException {
      throw _invalidLinuxResponse;
    }
  }

  Future<LinuxTextFile> readLinuxFile(String path) async {
    final normalized = normalizeLinuxWorkspacePath(path, allowRoot: false);
    try {
      final file = LinuxTextFile.fromMap(
        _asMap(await _invokeLinux('readLinuxFile', {'path': normalized})),
      );
      if (file.path != normalized) throw const FormatException('Wrong file.');
      return file;
    } on FormatException {
      throw _invalidLinuxResponse;
    }
  }

  /// Existing files require their last-read digest. New files never overwrite.
  Future<LinuxTextFile> writeLinuxFile({
    required String path,
    required String content,
    String? expectedSha256,
    bool createOnly = false,
  }) async {
    final normalized = normalizeLinuxWorkspacePath(path, allowRoot: false);
    validateLinuxFileContent(content);
    if ((expectedSha256 != null &&
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedSha256)) ||
        (createOnly && expectedSha256 != null)) {
      throw ArgumentError('Invalid or conflicting file write conditions.');
    }
    try {
      final file = LinuxTextFile.fromMap(
        _asMap(await _invokeLinux('writeLinuxFile', {
          'path': normalized,
          'content': content,
          'expectedSha256': expectedSha256,
          'createOnly': createOnly,
        })),
      );
      if (file.path != normalized || file.content != content) {
        throw const FormatException('Unexpected saved file.');
      }
      return file;
    } on FormatException {
      throw _invalidLinuxResponse;
    }
  }

  Future<void> createLinuxDirectory(String path) async {
    final normalized = normalizeLinuxWorkspacePath(path, allowRoot: false);
    await _invokeLinuxVoid('createLinuxDirectory', {'path': normalized});
  }

  /// Creates a generated Markdown file at the workspace root without replacing
  /// any file. This dedicated operation can coexist with a ready Linux desktop.
  /// The receipt describes published bytes, not a read-back of the live path.
  Future<LinuxFileImport> importLinuxTextFile({required String content}) async {
    validateLinuxFileContent(content);
    try {
      final receipt = LinuxFileImport.fromMap(
        _asMap(await _invokeLinux('importLinuxTextFile', {'content': content})),
      );
      if (receipt.sizeBytes != utf8.encode(content).length) {
        throw const FormatException('Unexpected import byte count.');
      }
      return receipt;
    } on FormatException {
      throw _invalidLinuxResponse;
    }
  }

  /// Installation may take longer than ordinary channel requests.
  Future<LinuxStatus> initializeLinux() => _readLinuxStatus(
        'initializeLinux',
        timeout: initializationTimeout,
      );

  /// Subscribe to [events] before starting a process to receive its output.
  /// The host enforces one active session or command at a time.
  Future<LinuxSession> startLinuxSession({
    required String sessionId,
    int columns = 80,
    int rows = 24,
  }) async {
    _validateId(sessionId, 'sessionId');
    _validateDimensions(columns, rows);
    try {
      final result = await _invokeLinux('startLinuxSession', {
        'sessionId': sessionId,
        'columns': columns,
        'rows': rows,
      });
      final session = LinuxSession.fromMap(_asMap(result));
      if (session.sessionId != sessionId) {
        throw const FormatException('Native Linux session ID mismatch.');
      }
      return session;
    } on FormatException {
      throw _invalidLinuxResponse;
    }
  }

  Future<void> writeLinuxSession(String sessionId, String data) async {
    _validateId(sessionId, 'sessionId');
    _validateText(data, 'data', allowEmpty: true);
    await _invokeLinuxVoid('writeLinuxSession', {
      'sessionId': sessionId,
      'data': data,
    });
  }

  Future<void> resizeLinuxSession(
      String sessionId, int columns, int rows) async {
    _validateId(sessionId, 'sessionId');
    _validateDimensions(columns, rows);
    await _invokeLinuxVoid('resizeLinuxSession', {
      'sessionId': sessionId,
      'columns': columns,
      'rows': rows,
    });
  }

  /// Resolves only after the native host has closed and cleaned up the process.
  Future<void> closeLinuxSession(String sessionId) async {
    _validateId(sessionId, 'sessionId');
    await _invokeLinuxVoid('closeLinuxSession', {'sessionId': sessionId});
  }

  /// Starts a manually authorized command; completion arrives through [events].
  /// This bridge grants no model permission to execute arbitrary shell commands.
  Future<LinuxCommandHandle> runLinuxCommand({
    required String taskId,
    required String command,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _validateId(taskId, 'taskId');
    _validateText(command, 'command');
    final timeoutMs = timeout.inMilliseconds;
    if (timeoutMs < 1 || timeoutMs > 300000) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be 1–300000 ms.');
    }
    try {
      final result = await _invokeLinux('runLinuxCommand', {
        'taskId': taskId,
        'command': command,
        'timeoutMs': timeoutMs,
      });
      final handle = LinuxCommandHandle.fromMap(_asMap(result));
      if (handle.taskId != taskId) {
        throw const FormatException('Native Linux command task ID mismatch.');
      }
      return handle;
    } on FormatException {
      throw _invalidLinuxResponse;
    }
  }

  /// Starts the APK's fixed text-formatting task. User text is a structured
  /// file input, never shell syntax, a command argument, or terminal output.
  /// Subscribe to [events] first, then wait for its matching `linuxExit` before
  /// requesting [readLinuxTextTaskResult].
  Future<LinuxCommandHandle> startLinuxTextTask({
    required String taskId,
    required String title,
    required String text,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _validateTextTaskId(taskId);
    final titleBytes = utf8.encode(title);
    if (title.trim().isEmpty ||
        title.runes.length > 80 ||
        utf8.decode(titleBytes) != title ||
        RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]').hasMatch(title)) {
      throw ArgumentError.value(
        title.length,
        'title.length',
        'Must contain 1–80 Unicode characters without controls or line breaks.',
      );
    }
    final textBytes = utf8.encode(text);
    if (text.trim().isEmpty ||
        text.runes.length > 20000 ||
        textBytes.length > 131072 ||
        utf8.decode(textBytes) != text ||
        text.contains('\u0000')) {
      throw ArgumentError.value(
        text.length,
        'text.length',
        'Must contain 1–20000 Unicode characters, no NUL, and fit in 131072 UTF-8 bytes.',
      );
    }
    final timeoutMs = timeout.inMilliseconds;
    if (timeoutMs < 1 || timeoutMs > 300000) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be 1–300000 ms.');
    }
    try {
      final handle = LinuxCommandHandle.fromMap(
        _asMap(await _invokeLinux('startLinuxTextTask', {
          'taskId': taskId,
          'title': title,
          'text': text,
          'timeoutMs': timeoutMs,
        })),
      );
      if (handle.taskId != taskId) {
        throw const FormatException('Native text task ID mismatch.');
      }
      return handle;
    } on FormatException {
      throw _invalidLinuxResponse;
    }
  }

  /// Reads the task's fixed output file after successful native process exit.
  /// This method itself does not infer that execution has succeeded.
  Future<LinuxTextTaskResult> readLinuxTextTaskResult(String taskId) async {
    _validateTextTaskId(taskId);
    try {
      final result = LinuxTextTaskResult.fromMap(
        _asMap(await _invokeLinux('readLinuxTextTaskResult', {
          'taskId': taskId,
        })),
      );
      if (result.taskId != taskId) {
        throw const FormatException('Native text result task ID mismatch.');
      }
      return result;
    } on FormatException {
      throw _invalidLinuxResponse;
    }
  }

  /// Unsupported hosts produce an empty stream, rather than fabricated events.
  Stream<RuntimeEvent> get events =>
      _eventStream ??= _listenToEvents().asBroadcastStream();

  /// Waits for the native EventChannel's real `bridgeAttached` handshake.
  /// Subscribe to [events] before calling this method. The bridge remembers a
  /// confirmed connection, so later task subscribers need not await a second
  /// handshake which an already-connected broadcast stream will not repeat.
  Future<void> ensureRuntimeEventsAttached() async {
    if (_eventAttachmentError case final error?) throw error;
    if (_eventsAttached) return;
    try {
      await _eventAttachmentSignal.future.timeout(responseTimeout);
    } on TimeoutException {
      throw const RuntimeBridgeException(
        code: 'timeout',
        message: '等待原生事件通道连接超时。',
      );
    }
    if (_eventAttachmentError case final error?) throw error;
    if (!_eventsAttached) {
      throw const RuntimeBridgeException(
        code: 'event_stream_closed',
        message: '原生事件通道未连接。',
      );
    }
  }

  Stream<RuntimeEvent> _listenToEvents() async* {
    try {
      final capabilities = await getCapabilities();
      if (!capabilities.nativeBridgeAvailable) {
        _failEventAttachment(const RuntimeBridgeException(
          code: 'unavailable',
          message: '此构建未连接原生事件通道。',
        ));
        return;
      }
      await for (final raw in _events.receiveBroadcastStream()) {
        final event = RuntimeEvent.fromMap(_asMap(raw));
        if (event.type == 'bridgeAttached') {
          final attachedCapabilities =
              PlatformCapabilities.fromMap(event.payload);
          if (!attachedCapabilities.nativeBridgeAvailable) {
            throw const FormatException(
              'Native event handshake reports an unavailable bridge.',
            );
          }
          _eventsAttached = true;
          if (!_eventAttachmentSignal.isCompleted) {
            _eventAttachmentSignal.complete();
          }
        }
        yield event;
      }
    } catch (error, stackTrace) {
      _failEventAttachment(switch (error) {
        RuntimeBridgeException() => error,
        MissingPluginException() => const RuntimeBridgeException(
            code: 'unavailable',
            message: '此构建未连接原生事件通道。',
          ),
        FormatException() => const RuntimeBridgeException(
            code: 'invalid_response',
            message: '原生事件通道响应与协议不一致。',
          ),
        PlatformException() => RuntimeBridgeException(
            code: error.code,
            message: error.message ?? '原生事件通道连接失败。',
          ),
        _ => const RuntimeBridgeException(
            code: 'event_stream_error',
            message: '原生事件通道连接失败。',
          ),
      });
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      _failEventAttachment(const RuntimeBridgeException(
        code: 'event_stream_closed',
        message: '原生事件通道已关闭。',
      ));
    }
  }

  void _failEventAttachment(RuntimeBridgeException error) {
    _eventsAttached = false;
    _eventAttachmentError ??= error;
    // Complete normally, then throw only from the awaited public operation.
    // A terminal-only listener need not await readiness or handle an orphaned
    // completer error merely because its event subscription ends.
    if (!_eventAttachmentSignal.isCompleted) {
      _eventAttachmentSignal.complete();
    }
  }

  Future<LinuxStatus> _readLinuxStatus(
    String method, {
    Duration? timeout,
  }) async {
    try {
      return LinuxStatus.fromMap(
        _asMap(await _invoke(method, null, timeout)),
      );
    } on MissingPluginException {
      return LinuxStatus.unsupported(reason: '此构建未连接支持 Linux 的原生桥接。');
    } on RuntimeBridgeException catch (error) {
      if (error.code == 'unavailable') {
        return LinuxStatus.unsupported(reason: error.message);
      }
      rethrow;
    } on FormatException {
      throw _invalidLinuxResponse;
    }
  }

  Future<Object?> _invokeLinux(String method, Object? arguments,
      [Duration? timeout]) async {
    try {
      return await _invoke(method, arguments, timeout);
    } on MissingPluginException {
      throw const RuntimeBridgeException(
        code: 'unavailable',
        message: '此构建未连接支持 Linux 执行的原生桥接。',
      );
    }
  }

  Future<void> _invokeLinuxVoid(String method, Object? arguments) async {
    if (await _invokeLinux(method, arguments) != null) {
      throw _invalidLinuxResponse;
    }
  }

  Future<Object?> _invoke(
    String method, [
    Object? arguments,
    Duration? timeout,
  ]) async {
    try {
      return await _methods
          .invokeMethod<Object?>(method, arguments)
          .timeout(timeout ?? responseTimeout);
    } on PlatformException catch (error) {
      throw RuntimeBridgeException(
        code: error.code,
        message: error.message ?? '原生桥接请求失败。',
      );
    } on TimeoutException {
      throw const RuntimeBridgeException(code: 'timeout', message: '原生桥接响应超时。');
    }
  }

  static const _invalidLinuxResponse = RuntimeBridgeException(
    code: 'invalid_response',
    message: '原生 Linux 响应与协议不一致。',
  );

  static void _validateId(String value, String name) {
    if (value.trim().isEmpty || value.length > 128) {
      throw ArgumentError.value(value, name, 'Must contain 1–128 characters.');
    }
  }

  static void _validateTextTaskId(String value) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$').hasMatch(value)) {
      throw ArgumentError.value(
        value,
        'taskId',
        'Must contain 1–96 ASCII identifier characters, starting with a letter or digit.',
      );
    }
  }

  static void _validateDimensions(int columns, int rows) {
    for (final entry in {'columns': columns, 'rows': rows}.entries) {
      if (entry.value < 1 || entry.value > 500) {
        throw ArgumentError.value(entry.value, entry.key, 'Must be 1–500.');
      }
    }
  }

  static void _validateText(
    String value,
    String name, {
    bool allowEmpty = false,
  }) {
    if ((!allowEmpty && value.trim().isEmpty) ||
        utf8.encode(value).length > 65536) {
      throw ArgumentError.value(
        value.length,
        '$name.length',
        'Must ${allowEmpty ? '' : 'be non-empty and '}fit within 65536 UTF-8 bytes.',
      );
    }
  }

  static Map<Object?, Object?> _asMap(Object? value) {
    if (value is! Map) {
      throw const FormatException('Expected native response map.');
    }
    return Map<Object?, Object?>.from(value);
  }
}
