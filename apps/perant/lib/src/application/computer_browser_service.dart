// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:perant_platform/perant_platform.dart';

import 'browser_page_document.dart';

final class BrowserObservation {
  const BrowserObservation(this.id, this.frame, this.capturedAt);
  final String id;
  final ComputerBrowserFrame frame;
  final DateTime capturedAt;
}

final class BrowserSavedPage {
  const BrowserSavedPage({
    required this.file,
    required this.page,
    required this.savedAt,
    required this.truncated,
  });
  final LinuxFileImport file;
  final ComputerBrowserPage page;
  final DateTime savedAt;
  final bool truncated;

  Map<String, Object?> toToolReceipt() => {
    'path': file.path,
    'sha256': file.sha256,
    'size_bytes': file.sizeBytes,
    'source_url': page.url,
    'title': page.title,
    'truncated': truncated,
    'saved_at': savedAt.toUtc().toIso8601String(),
    'message':
        '已创建新的 Markdown 文字摘录；不包含附件、表单和内嵌页面。'
        '${truncated ? '正文已截断，请核对来源页面。' : ''}'
        '这是发布时的文件摘要，后续 Linux 应用可能修改文件；需要使用时重新读取或从桌面打开。',
  };
}

/// One browser shared by the user and model. No timer captures its pixels.
final class ComputerBrowserService extends ChangeNotifier {
  ComputerBrowserService({
    ComputerBrowserBridge? bridge,
    PerantPlatformBridge? workspaceBridge,
  }) : bridge = bridge ?? ComputerBrowserBridge(),
       workspaceBridge = workspaceBridge ?? PerantPlatformBridge();
  final ComputerBrowserBridge bridge;
  final PerantPlatformBridge workspaceBridge;
  ComputerBrowserState? state;
  String? error;
  bool busy = false;
  bool modelHasControl = false;
  bool _disposed = false;
  bool _notificationScheduled = false;
  int _generation = 0;
  int _observationCount = 0;
  BrowserObservation? _observation;
  Future<void> _queue = Future.value();
  bool get running => state != null;

  void _notify() {
    if (_disposed) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_notificationScheduled) return;
      _notificationScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _notificationScheduled = false;
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  void _alive() {
    if (_disposed) throw StateError('浏览器工作区已关闭。');
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) {
      _alive();
      return action();
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _update(
    Future<ComputerBrowserState> Function() operation,
  ) async {
    busy = true;
    error = null;
    _observation = null;
    _notify();
    try {
      final value = await operation();
      _alive();
      state = value;
    } catch (_) {
      error = '浏览器操作未完成，请检查页面后重试。';
      rethrow;
    } finally {
      busy = false;
      _notify();
    }
  }

  /// Page size while no viewer is attached. Height matters more than width:
  /// at phone pixel density the former 1024×640 landscape frame showed only a
  /// few lines of a page per screenshot.
  static const hiddenWidth = 1000;
  static const hiddenHeight = 1200;

  Future<void> open({String url = 'about:blank', bool fromModel = false}) {
    final generation = _generation;
    return _serial(() async {
      if (fromModel) _owned(generation);
      if (!fromModel && modelHasControl) throw StateError('请先接管浏览器。');
      await _update(() async {
        final current = state;
        if (current == null) {
          final id = 'browser-${DateTime.now().microsecondsSinceEpoch}';
          final opened = await bridge.open(
            id: id,
            url: url,
            width: hiddenWidth,
            height: hiddenHeight,
          );
          if (_disposed) {
            await bridge.close(id);
            throw StateError('浏览器工作区已关闭。');
          }
          return opened;
        }
        if (url == 'about:blank' && !fromModel) return current;
        return bridge.navigate(current.id, url);
      });
      if (fromModel) _owned(generation);
    });
  }

  Future<void> navigate(String url) {
    noteUserInput();
    return _serial(() async {
      if (modelHasControl) throw StateError('请先接管浏览器。');
      final current = state;
      if (current == null) throw StateError('浏览器尚未启动。');
      await _update(() => bridge.navigate(current.id, url));
    });
  }

  Future<void> back() => _history(false);
  Future<void> forward() => _history(true);
  Future<void> _history(bool forward) {
    noteUserInput();
    return _serial(() async {
      final current = state;
      if (current == null || modelHasControl) throw StateError('浏览器不可操作。');
      await _update(
        () => forward ? bridge.forward(current.id) : bridge.back(current.id),
      );
    });
  }

  Future<void> refreshState() async {
    if (_disposed || busy || state == null) return;
    final id = state!.id;
    final value = await bridge.state(id);
    if (_disposed || state?.id != id) return;
    state = value;
    _notify();
  }

  Future<void> setVisible(bool visible) async {
    final current = state;
    if (_disposed || current == null) return;
    await bridge.setVisible(current.id, visible);
  }

  void noteUserInput() {
    if (modelHasControl) return;
    ++_generation;
    _observation = null;
  }

  void takeModelControl() {
    _alive();
    ++_generation;
    _observation = null;
    modelHasControl = true;
    _notify();
  }

  void releaseModelControl() {
    ++_generation;
    _observation = null;
    modelHasControl = false;
    final id = state?.id;
    if (id != null) unawaited(bridge.cancel(id).catchError((Object _) {}));
    _notify();
  }

  void _owned(int generation) {
    _alive();
    if (!modelHasControl || generation != _generation) {
      throw StateError('浏览器控制权已变更，请重新观察。');
    }
  }

  Future<BrowserObservation> observe() {
    final generation = _generation;
    return _serial(() async {
      _owned(generation);
      final current = state;
      if (current == null) throw StateError('请先打开浏览器。');
      final frame = await bridge.capture(current.id);
      _owned(generation);
      state = frame.state;
      final observation = BrowserObservation(
        'browser-observation-${++_observationCount}-${DateTime.now().microsecondsSinceEpoch}',
        frame,
        DateTime.now(),
      );
      _observation = observation;
      _notify();
      return observation;
    });
  }

  /// Saves only the native reader's fixed, bounded excerpt. It never submits
  /// forms, executes model-provided scripts, or stops a live Linux desktop.
  Future<BrowserSavedPage> savePage({
    bool fromModel = false,
    String? observationId,
  }) {
    if (!fromModel) noteUserInput();
    final generation = _generation;
    void checkControl() {
      if (fromModel) {
        _owned(generation);
      } else {
        _alive();
        if (modelHasControl || generation != _generation) {
          throw StateError('页面或控制权已变更，请重新检查后保存。');
        }
      }
    }

    return _serial(() async {
      checkControl();
      final current = state;
      if (current == null) throw StateError('请先打开网页。');
      var revision = current.revision;
      if (fromModel) {
        final observed = _observation;
        if (observed == null ||
            observed.id != observationId ||
            observed.frame.state.id != current.id ||
            DateTime.now().difference(observed.capturedAt) >
                const Duration(minutes: 2)) {
          throw StateError('浏览器截图已失效，请重新观察后保存。');
        }
        revision = observed.frame.state.revision;
      }
      _observation = null;
      busy = true;
      error = null;
      _notify();
      var publishing = false;
      try {
        final page = await bridge.readPage(
          current.id,
          expectedRevision: revision,
        );
        checkControl();
        final savedAt = DateTime.now();
        final document = buildBrowserPageDocument(page, savedAt: savedAt);
        checkControl();
        publishing = true;
        final file = await workspaceBridge.importLinuxTextFile(
          content: document.content,
        );
        // Publication cannot be rolled back on a late cancellation: retain
        // the receipt. The task runner checks ownership before any next step.
        return BrowserSavedPage(
          file: file,
          page: page,
          savedAt: savedAt,
          truncated: document.truncated,
        );
      } catch (failure) {
        error = switch (failure) {
          RuntimeBridgeException(code: 'not_installed') =>
            '请先打开“模型的电脑”初始化 Linux，再保存网页文字。',
          RuntimeBridgeException(code: 'busy') =>
            '请先结束当前终端或任务，再保存网页文字。桌面窗口可保留。',
          RuntimeBridgeException(code: 'page_empty') => '当前页面没有可保存的正文。',
          RuntimeBridgeException(code: 'page_not_ready') => '请等待网页加载成功后，再保存正文。',
          RuntimeBridgeException(code: 'stale_revision') =>
            '网页已经变化，请检查当前页面后重新保存。',
          _ => publishing ? '保存结果未确认，请先检查工作区，避免重复保存。' : '网页正文未能读取，请检查页面后重试。',
        };
        rethrow;
      } finally {
        busy = false;
        _notify();
      }
    });
  }

  Future<Map<String, Object?>> perform({
    required String observationId,
    required String action,
    int? x,
    int? y,
    int? deltaY,
    String? text,
    String? key,
    List<String> modifiers = const [],
  }) {
    final generation = _generation;
    return _serial(() async {
      _owned(generation);
      final observed = _observation;
      if (observed == null ||
          observed.id != observationId ||
          DateTime.now().difference(observed.capturedAt) >
              const Duration(minutes: 2)) {
        throw StateError('浏览器截图已失效，请重新观察。');
      }
      _observation = null;
      final current = state;
      if (current == null || current.id != observed.frame.state.id) {
        throw StateError('浏览器会话已变更。');
      }
      final result = await bridge.action(
        current.id,
        action: action,
        x: x,
        y: y,
        deltaY: deltaY,
        text: text,
        key: key,
        modifiers: modifiers,
        width: observed.frame.width,
        height: observed.frame.height,
        expectedRevision: observed.frame.state.revision,
      );
      _owned(generation);
      state = result;
      _notify();
      return {
        'url': result.url,
        'title': result.title,
        'loading': result.loading,
        'error': result.error,
      };
    });
  }

  Future<void> close() {
    if (modelHasControl) throw StateError('请先接管浏览器。');
    noteUserInput();
    return _serial(() async {
      final current = state;
      if (current == null) return;
      await bridge.close(current.id);
      state = null;
      _observation = null;
      _notify();
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    final id = state?.id;
    _disposed = true;
    ++_generation;
    _observation = null;
    if (id != null) unawaited(bridge.close(id).catchError((Object _) {}));
    super.dispose();
  }
}
