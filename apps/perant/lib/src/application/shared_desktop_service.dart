// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:perant_platform/perant_platform.dart';

final class DesktopObservation {
  const DesktopObservation({
    required this.id,
    required this.width,
    required this.height,
    required this.png,
    required this.capturedAt,
  });
  final String id;
  final int width;
  final int height;
  final Uint8List png;
  final DateTime capturedAt;
}

/// One real Linux desktop. A live framebuffer exists in Dart only while a
/// foreground viewer is attached. Model observations use short-lived sockets.
final class SharedDesktopService extends ChangeNotifier {
  SharedDesktopService(this.bridge);
  final PerantPlatformBridge bridge;
  LinuxDesktopSession? session;
  DesktopFrame? frame;
  String? error;
  bool busy = false;
  bool modelHasControl = false;
  bool _disposed = false;
  bool _notificationScheduled = false;
  bool _visible = false;
  int _viewGeneration = 0;
  int _userGeneration = 0;
  int _controlGeneration = 0;
  int _userX = 0, _userY = 0, _userButtons = 0;
  int _observationNumber = 0;
  int _viewerWidth = 1024;
  int _viewerHeight = 640;
  String? _observationId;
  DateTime? _observedAt;
  int _observedUserGeneration = -1;
  int _observedWidth = 0;
  int _observedHeight = 0;
  DesktopRfbClient? _viewer;
  // Cancelled via a captured reference in _detachViewer so a late disconnect
  // cannot cancel a replacement viewer's subscription.
  // ignore: cancel_subscriptions
  StreamSubscription<DesktopFrame>? _frames;
  StreamSubscription<RuntimeEvent>? _events;
  Future<LinuxDesktopSession>? _starting;
  Future<void>? _stopping;
  Future<void> _input = Future.value();
  bool get running => session != null;
  bool get viewerConnected => _viewer != null;

  void _notify() {
    if (_disposed) return;
    // Route teardown can detach the viewer while Flutter finalizes its tree.
    // Release pixels/sockets immediately; only status notification waits for
    // that frame to unlock so the previous chat route can safely rebuild.
    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      if (_notificationScheduled) return;
      _notificationScheduled = true;
      scheduler.addPostFrameCallback((_) {
        _notificationScheduled = false;
        if (!_disposed) notifyListeners();
      });
      return;
    }
    notifyListeners();
  }

  void _alive() {
    if (_disposed) throw StateError('桌面连接已关闭。');
  }

  Future<LinuxDesktopSession> start({int width = 1024, int height = 640}) {
    _alive();
    if (_starting case final pending?) return pending;
    final existing = session;
    if (existing != null) return Future.value(existing);
    return _starting = _start(
      width,
      height,
    ).whenComplete(() => _starting = null);
  }

  Future<LinuxDesktopSession> _start(int width, int height) async {
    busy = true;
    error = null;
    _notify();
    final requestedId = 'desktop-${DateTime.now().microsecondsSinceEpoch}';
    String? startedId;
    try {
      _events ??= bridge.events.listen(
        (event) {
          if (event.type == 'linuxDesktopExit' &&
              event.payload['sessionId'] == session?.sessionId) {
            session = null;
            _observationId = null;
            error = 'Linux 桌面已退出，可重新启动。';
            unawaited(_detachViewer());
            _notify();
          }
        },
        onError: (Object failure) {
          error = '原生事件连接中断，请检查桌面状态。';
          _notify();
        },
      );
      await bridge.ensureRuntimeEventsAttached();
      _alive();
      var status = await bridge.getLinuxStatus();
      _alive();
      if (!status.supported) throw StateError(status.reason);
      if (!status.installed) status = await bridge.initializeLinux();
      _alive();
      if (!status.desktopAvailable) throw StateError('当前安装包尚无可用图形桌面资源，请更新应用。');
      final existing = await bridge.getLinuxDesktopSession();
      _alive();
      final started =
          existing ??
          await bridge.startLinuxDesktop(
            sessionId: requestedId,
            width: width,
            height: height,
          );
      startedId = started.sessionId;
      _alive();
      session = started;
      _notify();
      return started;
    } catch (failure) {
      error = _message(failure);
      // A channel timeout can leave a start queued on the native FIFO.
      try {
        await bridge.stopLinuxDesktop(startedId ?? requestedId);
      } catch (_) {
        /* Retry through native status before a later start. */
      }
      rethrow;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> setViewerVisible(bool visible, {int? width, int? height}) async {
    if (_disposed) return;
    if ((width == null) != (height == null)) {
      throw ArgumentError('桌面宽高须同时指定。');
    }
    if (width != null && height != null) {
      if (width < 640 ||
          width > 1600 ||
          height < 480 ||
          height > 1200 ||
          width * height > 1920000) {
        throw ArgumentError('桌面尺寸超出可用范围。');
      }
      _viewerWidth = width;
      _viewerHeight = height;
    }
    _visible = visible;
    final generation = ++_viewGeneration;
    if (!visible) {
      await _detachViewer();
      return;
    }
    try {
      final current = await start(width: _viewerWidth, height: _viewerHeight);
      if (_disposed || !_visible || generation != _viewGeneration) return;
      if (_viewer != null) return;
      final client = await DesktopRfbClient.connectUnix(current.socketPath);
      if (_disposed || !_visible || generation != _viewGeneration) {
        await client.close();
        return;
      }
      _viewer = client;
      frame = client.frame;
      _frames = client.frames.listen(
        (value) {
          if (!identical(_viewer, client)) return;
          frame = value;
          _notify();
        },
        onError: (Object failure) {
          if (!identical(_viewer, client)) return;
          error = '桌面显示连接中断，可重新连接。';
          unawaited(_detachViewer());
        },
      );
      unawaited(
        client.done.then(
          (_) {
            if (identical(_viewer, client)) {
              error = '桌面显示连接已结束，可重新连接。';
              unawaited(_detachViewer());
            }
          },
          onError: (Object failure, StackTrace stack) {
            if (identical(_viewer, client)) {
              error = '桌面显示连接中断，可重新连接。';
              unawaited(_detachViewer());
            }
          },
        ),
      );
      final first = await client.firstFrame;
      if (identical(_viewer, client) && _visible && !_disposed) {
        frame = first;
        _notify();
      }
    } catch (failure) {
      if (!_disposed && generation == _viewGeneration) {
        error = _message(failure);
        _notify();
      }
    }
  }

  Future<void> _detachViewer() async {
    final client = _viewer;
    final subscription = _frames;
    _viewer = null;
    _frames = null;
    frame = null;
    _notify();
    await subscription?.cancel();
    await client?.close();
  }

  Future<T> _connection<T>(Future<T> Function(DesktopRfbClient) action) async {
    _alive();
    final current = await start();
    final live = _viewer;
    if (live != null) return action(live);
    final single = await DesktopRfbClient.connectUnix(
      current.socketPath,
      continuous: false,
      requestInitialFrame: false,
    );
    try {
      _alive();
      return await action(single);
    } finally {
      await single.close();
    }
  }

  Future<DesktopObservation> observe() async {
    if (!modelHasControl) throw StateError('尚未取得本次桌面操作授权。');
    final control = _controlGeneration;
    await _input.catchError((Object _) {});
    final screenshot = await _connection((client) => client.capture());
    _alive();
    if (!modelHasControl || control != _controlGeneration)
      throw StateError('模型已停止，桌面截图未发布。');
    final png = screenshot.encodePng();
    if (png.length > 650 * 1024) throw StateError('桌面截图超过本轮大小限制，请降低桌面分辨率后重试。');
    final id = 'desktop-frame-${++_observationNumber}-${screenshot.sequence}';
    _observationId = id;
    _observedAt = DateTime.now();
    _observedUserGeneration = _userGeneration;
    _observedWidth = screenshot.width;
    _observedHeight = screenshot.height;
    return DesktopObservation(
      id: id,
      width: screenshot.width,
      height: screenshot.height,
      png: png,
      capturedAt: _observedAt!,
    );
  }

  void takeModelControl() {
    ++_controlGeneration;
    modelHasControl = true;
    _observationId = null;
    final client = _viewer;
    if (client != null && _userButtons != 0) {
      _userButtons = 0;
      _input = _input.catchError((Object _) {}).then((_) async {
        if (identical(client, _viewer))
          await client.pointer(x: _userX, y: _userY);
      });
    }
    _notify();
  }

  void releaseModelControl() {
    ++_controlGeneration;
    modelHasControl = false;
    _observationId = null;
    _notify();
  }

  void _requireObservation(String id) {
    _alive();
    if (!modelHasControl ||
        id != _observationId ||
        _observedAt == null ||
        _observedUserGeneration != _userGeneration ||
        DateTime.now().difference(_observedAt!) > const Duration(seconds: 90)) {
      throw StateError('桌面画面已过期或用户已接管，请重新截图后再操作。');
    }
  }

  Future<Map<String, Object?>> perform({
    required String observationId,
    required String action,
    int? x,
    int? y,
    int? toX,
    int? toY,
    String? text,
    String? key,
    List<String> modifiers = const [],
    String button = 'left',
  }) async {
    _requireObservation(observationId);
    final control = _controlGeneration;
    bool canContinue() =>
        modelHasControl && !_disposed && control == _controlGeneration;
    if (!{
      'click',
      'double_click',
      'move',
      'drag',
      'scroll_up',
      'scroll_down',
      'type',
      'key',
    }.contains(action))
      throw ArgumentError('不支持的桌面动作。');
    if (!{'left', 'right', 'middle'}.contains(button))
      throw ArgumentError('不支持的鼠标按钮。');
    void point(int? px, int? py) {
      if (px == null ||
          py == null ||
          px < 0 ||
          py < 0 ||
          px >= _observedWidth ||
          py >= _observedHeight)
        throw ArgumentError('坐标须位于刚取得的桌面截图内。');
    }

    if (action == 'type') {
      if (text == null ||
          text.runes.length > 2000 ||
          text.runes.any((rune) => rune < 32 && !{9, 10, 13}.contains(rune)))
        throw ArgumentError('桌面输入须在 2000 字符以内，控制字符仅支持换行与 Tab。');
    } else if (action == 'key') {
      desktopKeysym(key ?? '');
      for (final modifier in modifiers) {
        if (!{'Ctrl', 'Alt', 'Shift', 'Super'}.contains(modifier))
          throw ArgumentError('不支持的修饰键。');
      }
      if (modifiers.length > 4 || modifiers.toSet().length != modifiers.length)
        throw ArgumentError('修饰键无效。');
    } else {
      point(x, y);
      if (action == 'drag') point(toX, toY);
    }
    _input = _input
        .catchError((Object _) {})
        .then(
          (_) => _connection((client) async {
            // Connection setup may have waited while the user stopped the task.
            _requireObservation(observationId);
            _observationId = null;
            if (action == 'type') {
              for (final rune in text!.runes) {
                if (!canContinue()) throw StateError('模型输入已停止。');
                if (rune == 13) continue;
                final value = rune == 10
                    ? 0xff0d
                    : rune == 9
                    ? 0xff09
                    : rune <= 255
                    ? rune
                    : 0x01000000 | rune;
                await client.key(keysym: value, down: true);
                await client.key(keysym: value, down: false);
              }
            } else if (action == 'key') {
              await _key(client, key!, modifiers, canContinue);
            } else if (action == 'move') {
              await client.pointer(x: x!, y: y!);
            } else if (action == 'drag') {
              final mask = _buttonMask(button);
              final fromX = x!, fromY = y!;
              var lastX = fromX, lastY = fromY;
              await client.pointer(x: fromX, y: fromY, buttons: mask);
              try {
                for (var i = 1; i <= 8; i++) {
                  if (!canContinue()) break;
                  lastX = fromX + ((toX! - fromX) * i / 8).round();
                  lastY = fromY + ((toY! - fromY) * i / 8).round();
                  await client.pointer(x: lastX, y: lastY, buttons: mask);
                }
              } finally {
                await client.pointer(x: lastX, y: lastY);
              }
            } else {
              final mask = action == 'scroll_up'
                  ? 8
                  : action == 'scroll_down'
                  ? 16
                  : _buttonMask(button);
              final count = action == 'double_click' ? 2 : 1;
              for (var i = 0; i < count; i++) {
                if (!canContinue()) break;
                await client.pointer(x: x!, y: y!, buttons: mask);
                await client.pointer(x: x, y: y);
              }
            }
          }),
        );
    await _input;
    return {
      'ok': true,
      'action': action,
      'input_sent': true,
      'message': '输入已发送，请重新截图确认实际窗口结果。',
    };
  }

  int _buttonMask(String value) => switch (value) {
    'right' => 4,
    'middle' => 2,
    _ => 1,
  };
  Future<void> _key(
    DesktopRfbClient client,
    String key,
    List<String> modifiers,
    bool Function() canContinue,
  ) async {
    final held = <int>[];
    try {
      for (final name in modifiers) {
        if (!canContinue()) throw StateError('桌面输入权已变更。');
        final value = desktopKeysym(name);
        held.add(value);
        await client.key(keysym: value, down: true);
      }
      if (!canContinue()) throw StateError('桌面输入权已变更。');
      final value = desktopKeysym(key);
      held.add(value);
      await client.key(keysym: value, down: true);
    } finally {
      for (final value in held.reversed) {
        await client.key(keysym: value, down: false);
      }
    }
  }

  Future<void> pointerFromUser(int x, int y, int buttons) async {
    if (modelHasControl || _viewer == null || _disposed) return;
    _userGeneration++;
    _observationId = null;
    final client = _viewer!, control = _controlGeneration;
    _input = _input.catchError((Object _) {}).then((_) async {
      if (modelHasControl ||
          _disposed ||
          control != _controlGeneration ||
          !identical(client, _viewer))
        return;
      _userX = x;
      _userY = y;
      _userButtons = buttons;
      await client.pointer(x: x, y: y, buttons: buttons);
    });
    await _input;
  }

  Future<void> revealFromUser(LinuxFileImport file) async {
    final current = session, viewer = _viewer, control = _controlGeneration;
    if (current == null ||
        viewer == null ||
        modelHasControl ||
        !_visible ||
        _disposed) {
      throw StateError('请先接管并打开当前 Linux 桌面。');
    }
    _userGeneration++;
    _observationId = null;
    _input = _input.catchError((Object _) {}).then((_) async {
      if (_disposed ||
          !_visible ||
          modelHasControl ||
          control != _controlGeneration ||
          !identical(viewer, _viewer) ||
          !identical(current, session)) {
        throw StateError('桌面或控制权已变化。');
      }
      await bridge.revealDesktopExcerpt(current.sessionId, file);
    });
    await _input;
  }

  Future<void> textFromUser(String text) async {
    if (modelHasControl || _viewer == null || _disposed) return;
    if (text.runes.length > 2000) throw ArgumentError('文字最多2000字符。');
    _userGeneration++;
    _observationId = null;
    final client = _viewer!, control = _controlGeneration;
    _input = _input.catchError((Object _) {}).then((_) async {
      for (final rune in text.runes) {
        if (modelHasControl ||
            _disposed ||
            control != _controlGeneration ||
            !identical(client, _viewer))
          return;
        if (rune == 13) continue;
        if (rune < 32 && rune != 9 && rune != 10)
          throw ArgumentError('不支持的控制字符。');
        final key = rune == 10
            ? 0xff0d
            : rune == 9
            ? 0xff09
            : rune <= 255
            ? rune
            : 0x01000000 | rune;
        await client.key(keysym: key, down: true);
        await client.key(keysym: key, down: false);
      }
    });
    await _input;
  }

  Future<void> keyFromUser(
    String key, [
    List<String> modifiers = const [],
  ]) async {
    if (modelHasControl || _viewer == null || _disposed) return;
    _userGeneration++;
    _observationId = null;
    final client = _viewer!, control = _controlGeneration;
    _input = _input
        .catchError((Object _) {})
        .then(
          (_) => _key(
            client,
            key,
            modifiers,
            () =>
                !modelHasControl &&
                !_disposed &&
                control == _controlGeneration &&
                identical(client, _viewer),
          ),
        );
    await _input;
  }

  Future<void> stop() {
    if (_stopping case final pending?) return pending;
    return _stopping = _stop().whenComplete(() => _stopping = null);
  }

  Future<void> _stop() async {
    busy = true;
    _notify();
    try {
      await _starting;
      final current = session ?? await bridge.getLinuxDesktopSession();
      ++_viewGeneration;
      await _detachViewer();
      if (current != null) await bridge.stopLinuxDesktop(current.sessionId);
      session = null;
      _observationId = null;
      error = null;
    } catch (failure) {
      error = _message(failure);
      rethrow;
    } finally {
      busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    modelHasControl = false;
    ++_viewGeneration;
    final current = session;
    unawaited(_detachViewer());
    unawaited(_events?.cancel() ?? Future.value());
    if (current != null)
      unawaited(
        bridge.stopLinuxDesktop(current.sessionId).catchError((Object _) {}),
      );
    super.dispose();
  }
}

String _message(Object value) => value is RuntimeBridgeException
    ? value.message
    : value is StateError
    ? value.message
    : '桌面显示连接未完成，请检查 Linux 环境后重试。';

int desktopKeysym(String name) {
  const names = {
    'Return': 0xff0d,
    'Enter': 0xff0d,
    'Tab': 0xff09,
    'Escape': 0xff1b,
    'Backspace': 0xff08,
    'Delete': 0xffff,
    'Left': 0xff51,
    'Up': 0xff52,
    'Right': 0xff53,
    'Down': 0xff54,
    'Home': 0xff50,
    'End': 0xff57,
    'PageUp': 0xff55,
    'PageDown': 0xff56,
    'Ctrl': 0xffe3,
    'Alt': 0xffe9,
    'Shift': 0xffe1,
    'Super': 0xffeb,
    'F1': 0xffbe,
    'F2': 0xffbf,
    'F3': 0xffc0,
    'F4': 0xffc1,
    'F5': 0xffc2,
    'F6': 0xffc3,
    'F7': 0xffc4,
    'F8': 0xffc5,
    'F9': 0xffc6,
    'F10': 0xffc7,
    'F11': 0xffc8,
    'F12': 0xffc9,
  };
  if (names[name] case final value?) return value;
  final runes = name.runes.toList();
  if (runes.length == 1 && runes.single >= 32 && runes.single != 127)
    return runes.single <= 255 ? runes.single : 0x01000000 | runes.single;
  throw ArgumentError('不支持的桌面按键。');
}
