// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:perant_platform/perant_platform.dart';

/// One explicit invocation of the APK's fixed text formatter, never user code.
final class LocalTextTaskCancellation {
  bool requested = false;
}

final class LocalTextTaskException implements Exception {
  const LocalTextTaskException(this.message, {this.cancelled = false});
  final String message;
  final bool cancelled;
}

/// Keeps ownership until a real exit or an acknowledged stop plus idle status.
/// A timed out platform response does not prove a queued native start stopped.
final class LocalTextTaskRunner {
  LocalTextTaskRunner(this.bridge);
  final PerantPlatformBridge bridge;
  _TextExecution? _active;

  Future<LinuxTextTaskResult> run({
    required String taskId,
    required String title,
    required String text,
    required LocalTextTaskCancellation cancellation,
    required void Function(String) onProgress,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_active != null) throw const LocalTextTaskException('本地任务仍在清理，请稍后重试。');
    final execution = _TextExecution(taskId, cancellation, onProgress);
    _active = execution;
    final subscription = bridge.events.listen(
      (event) {
        if (event.taskId != taskId) return;
        if (event.type == 'linuxExit') {
          execution.exit = _TextExit(
            event.payload['exitCode']! as int,
            event.payload['cancelled']! as bool,
            event.payload['timedOut']! as bool,
          );
          execution.confirmStopped();
        }
      },
      onError: (Object error, StackTrace stack) {
        execution.streamFailed = true;
        execution.onProgress('终端事件连接中断，正在确认任务已停止…');
        unawaited(_attemptStop(execution));
      },
      onDone: () {
        if (!execution.stopped.isCompleted && execution.startAttempted) {
          execution.streamFailed = true;
          unawaited(_attemptStop(execution));
        }
      },
    );
    try {
      await bridge.ensureRuntimeEventsAttached();
      _checkCancellation(cancellation);
      execution.startAttempted = true;
      try {
        await bridge.startLinuxTextTask(
          taskId: taskId,
          title: title,
          text: text,
          timeout: timeout,
        );
      } catch (error) {
        if (error is RuntimeBridgeException &&
            {
              'busy',
              'not_installed',
              'invalid_arguments',
              'unavailable',
            }.contains(error.code)) {
          execution.startAttempted = false;
          throw LocalTextTaskException(error.message);
        }
        await _stopAndWait(execution);
        _checkCancellation(cancellation);
        throw const LocalTextTaskException('本地脚本未能正常启动，已确认进程停止；没有发布文档。');
      }
      onProgress('Python 正在整理换行与段落…');
      if (cancellation.requested) unawaited(_attemptStop(execution));
      try {
        await execution.stopped.future.timeout(
          timeout + const Duration(seconds: 10),
        );
      } on TimeoutException {
        execution.streamFailed = true;
        await _stopAndWait(execution);
      }
      _checkCancellation(cancellation);
      final exit = execution.exit;
      if (execution.streamFailed || exit == null) {
        throw const LocalTextTaskException('未取得完整的本地执行结果，已确认停止；没有发布文档。');
      }
      if (exit.cancelled) {
        throw const LocalTextTaskException('本地任务已取消，没有发布文档。', cancelled: true);
      }
      if (exit.timedOut) throw const LocalTextTaskException('本地脚本执行超时，没有发布文档。');
      if (exit.code != 0) {
        throw LocalTextTaskException('本地脚本退出码为 ${exit.code}，没有发布文档。');
      }
      onProgress('正在读取并校验实际生成的 Markdown…');
      final result = await bridge.readLinuxTextTaskResult(taskId);
      _checkCancellation(cancellation);
      return result;
    } finally {
      // Errors before start cannot leave a native process. After a possible
      // start every error path waits for cleanup, retaining the workspace lock.
      if (execution.startAttempted && !execution.stopped.isCompleted) {
        await _stopAndWait(execution);
      }
      await subscription.cancel();
      if (identical(_active, execution)) _active = null;
    }
  }

  Future<void> cancel(String taskId) async {
    final execution = _active;
    if (execution == null || execution.id != taskId) return;
    execution.cancellation.requested = true;
    if (execution.startAttempted) await _attemptStop(execution);
  }

  Future<void> _stopAndWait(_TextExecution execution) async {
    await _attemptStop(execution);
    if (!execution.stopped.isCompleted) {
      execution.onProgress('尚未确认进程清理，工作区继续占用；可点击停止重试。');
      await execution.stopped.future;
    }
  }

  Future<void> _attemptStop(_TextExecution execution) {
    final pending = execution.stopAttempt;
    if (pending != null) return pending;
    final attempt = _stopOnce(execution).whenComplete(() {
      execution.stopAttempt = null;
    });
    execution.stopAttempt = attempt;
    return attempt;
  }

  Future<void> _stopOnce(_TextExecution execution) async {
    if (execution.stopped.isCompleted || !execution.startAttempted) return;
    try {
      final acknowledgement = await bridge.cancelTask(execution.id);
      if (execution.stopped.isCompleted) return;
      if (acknowledgement.status != TaskCancellationStatus.cancelled &&
          acknowledgement.status != TaskCancellationStatus.notRunning)
        return;
      // Native control operations are FIFO: an acknowledged cancellation is
      // ordered after this task's start, unlike a standalone idle observation.
      final status = await bridge.getLinuxStatus();
      if (!status.active) execution.confirmStopped();
    } catch (_) {
      execution.onProgress('尚未确认进程清理，工作区继续占用；可点击停止重试。');
    }
  }

  void dispose() {
    final execution = _active;
    if (execution != null) {
      execution.cancellation.requested = true;
      unawaited(_attemptStop(execution));
    }
  }

  static void _checkCancellation(LocalTextTaskCancellation value) {
    if (value.requested) {
      throw const LocalTextTaskException('本地任务已取消，没有发布文档。', cancelled: true);
    }
  }
}

final class _TextExecution {
  _TextExecution(this.id, this.cancellation, this.onProgress);
  final String id;
  final LocalTextTaskCancellation cancellation;
  final void Function(String) onProgress;
  final stopped = Completer<void>();
  bool startAttempted = false;
  bool streamFailed = false;
  _TextExit? exit;
  Future<void>? stopAttempt;
  void confirmStopped() {
    if (!stopped.isCompleted) stopped.complete();
  }
}

final class _TextExit {
  const _TextExit(this.code, this.cancelled, this.timedOut);
  final int code;
  final bool cancelled;
  final bool timedOut;
}
