// SPDX-License-Identifier: GPL-3.0-only

import 'authorization.dart';

enum TaskStatus {
  queued,
  running,
  awaitingAuthorization,
  awaitingNetwork,
  awaitingForeground,
  interrupted,
  manualControl,
  completed,
  failed,
  cancelled;

  String get label => switch (this) {
        queued => '排队中',
        running => '执行中',
        awaitingAuthorization => '等待授权',
        awaitingNetwork => '等待网络',
        awaitingForeground => '等待回到前台',
        interrupted => '已中断',
        manualControl => '手动接管中',
        completed => '已完成',
        failed => '执行失败',
        cancelled => '已取消',
      };

  bool get isTerminal => switch (this) {
        completed || failed || cancelled => true,
        _ => false,
      };
}

enum TaskStepStatus { pending, running, succeeded, failed, uncertain }

enum RecoveryDisposition { resumable, inspectionRequired, notApplicable }

final class TaskStep {
  const TaskStep({
    required this.id,
    required this.title,
    this.status = TaskStepStatus.pending,
    this.hasSideEffects = false,
    this.executionId,
    this.resultSummary,
  });

  final String id;
  final String title;
  final TaskStepStatus status;
  final bool hasSideEffects;
  final String? executionId;
  final String? resultSummary;

  TaskStep withStatus(TaskStepStatus value, {String? resultSummary}) =>
      TaskStep(
        id: id,
        title: title,
        status: value,
        hasSideEffects: hasSideEffects,
        executionId: executionId,
        resultSummary: resultSummary ?? this.resultSummary,
      );
}

final class TaskRecord {
  TaskRecord({
    required this.id,
    required this.title,
    required this.createdAt,
    DateTime? updatedAt,
    this.status = TaskStatus.queued,
    List<TaskStep> steps = const [],
    this.cloudAuthorization,
    this.statusDetail,
  })  : updatedAt = updatedAt ?? createdAt,
        steps = List.unmodifiable(steps) {
    if (id.trim().isEmpty || title.trim().isEmpty) {
      throw ArgumentError('Task ID and title must not be empty.');
    }
    if (steps.map((step) => step.id).toSet().length != steps.length) {
      throw ArgumentError('Task step IDs must be unique.');
    }
    if (cloudAuthorization != null && cloudAuthorization!.taskId != id) {
      throw ArgumentError('Cloud authorization belongs to a different task.');
    }
  }

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final TaskStatus status;
  final List<TaskStep> steps;
  final CloudAuthorization? cloudAuthorization;
  final String? statusDetail;

  bool get hasUncertainSteps =>
      steps.any((step) => step.status == TaskStepStatus.uncertain);

  RecoveryDisposition get recoveryDisposition {
    if (status != TaskStatus.interrupted) {
      return RecoveryDisposition.notApplicable;
    }
    return hasUncertainSteps
        ? RecoveryDisposition.inspectionRequired
        : RecoveryDisposition.resumable;
  }

  TaskRecord copyWith({
    TaskStatus? status,
    DateTime? updatedAt,
    List<TaskStep>? steps,
    CloudAuthorization? cloudAuthorization,
    String? statusDetail,
    bool clearStatusDetail = false,
  }) =>
      TaskRecord(
        id: id,
        title: title,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        status: status ?? this.status,
        steps: steps ?? this.steps,
        cloudAuthorization: cloudAuthorization ?? this.cloudAuthorization,
        statusDetail:
            clearStatusDetail ? null : statusDetail ?? this.statusDetail,
      );
}

final class InvalidTaskTransition implements Exception {
  const InvalidTaskTransition(this.from, this.to);

  final TaskStatus from;
  final TaskStatus to;

  @override
  String toString() => 'Invalid task transition: ${from.name} → ${to.name}';
}

final class UnsafeTaskRecovery implements Exception {
  const UnsafeTaskRecovery(this.taskId);

  final String taskId;

  @override
  String toString() =>
      'Task $taskId has uncertain results. Inspect its artifacts before retrying.';
}

abstract final class TaskStateMachine {
  static bool canTransition(TaskStatus from, TaskStatus to) => switch (from) {
        TaskStatus.queued => {
            TaskStatus.running,
            TaskStatus.awaitingAuthorization,
            TaskStatus.cancelled,
          }.contains(to),
        TaskStatus.running => {
            TaskStatus.awaitingAuthorization,
            TaskStatus.awaitingNetwork,
            TaskStatus.awaitingForeground,
            TaskStatus.interrupted,
            TaskStatus.manualControl,
            TaskStatus.completed,
            TaskStatus.failed,
            TaskStatus.cancelled,
          }.contains(to),
        TaskStatus.awaitingAuthorization ||
        TaskStatus.awaitingNetwork ||
        TaskStatus.awaitingForeground =>
          {
            TaskStatus.running,
            TaskStatus.interrupted,
            TaskStatus.failed,
            TaskStatus.cancelled,
          }.contains(to),
        TaskStatus.interrupted => {
            TaskStatus.running,
            TaskStatus.manualControl,
            TaskStatus.failed,
            TaskStatus.cancelled,
          }.contains(to),
        TaskStatus.manualControl => {
            TaskStatus.running,
            TaskStatus.interrupted,
            TaskStatus.cancelled,
          }.contains(to),
        TaskStatus.completed ||
        TaskStatus.failed ||
        TaskStatus.cancelled =>
          false,
      };

  static TaskRecord transition(
    TaskRecord task,
    TaskStatus to, {
    required DateTime at,
    String? detail,
  }) {
    if (!canTransition(task.status, to)) {
      throw InvalidTaskTransition(task.status, to);
    }
    if (to == TaskStatus.running && task.hasUncertainSteps) {
      throw UnsafeTaskRecovery(task.id);
    }
    if (to == TaskStatus.completed &&
        task.steps.any((step) => step.status != TaskStepStatus.succeeded)) {
      throw StateError('A task cannot complete before all its steps succeed.');
    }
    if (to == TaskStatus.manualControl &&
        task.steps.any((step) => step.status == TaskStepStatus.running)) {
      throw StateError('Stop active tools before entering manual control.');
    }
    final steps = to == TaskStatus.interrupted
        ? task.steps
            .map((step) => step.status == TaskStepStatus.running
                ? step.withStatus(TaskStepStatus.uncertain)
                : step)
            .toList()
        : task.steps;
    return task.copyWith(
      status: to,
      steps: steps,
      updatedAt: at,
      statusDetail: detail,
      clearStatusDetail: detail == null,
      cloudAuthorization: to.isTerminal
          ? task.cloudAuthorization?.revoke(at)
          : task.cloudAuthorization,
    );
  }

  /// Use only after the caller has inspected the execution journal/artifacts.
  static TaskRecord resolveUncertainStep(
    TaskRecord task,
    String stepId, {
    required bool completed,
    required String evidence,
    required DateTime at,
  }) {
    if (evidence.trim().isEmpty) {
      throw ArgumentError('Recovery requires recorded evidence.');
    }
    final index = task.steps.indexWhere((step) => step.id == stepId);
    if (index < 0 || task.steps[index].status != TaskStepStatus.uncertain) {
      throw StateError('No uncertain step with ID $stepId.');
    }
    final steps = [...task.steps];
    steps[index] = steps[index].withStatus(
      completed ? TaskStepStatus.succeeded : TaskStepStatus.pending,
      resultSummary: evidence,
    );
    return task.copyWith(steps: steps, updatedAt: at);
  }
}

abstract interface class TaskStore {
  Future<TaskRecord?> getById(String id);
  Future<List<TaskRecord>> list();
  Future<void> save(TaskRecord task);
  Future<void> delete(String id);
}

/// An explicit session-only store for the initial scaffold and domain tests.
/// Native persistence is a separate adapter; this does not survive app restart.
final class InMemoryTaskStore implements TaskStore {
  final Map<String, TaskRecord> _records = {};

  @override
  Future<TaskRecord?> getById(String id) async => _records[id];

  @override
  Future<List<TaskRecord>> list() async {
    final records = _records.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(records);
  }

  @override
  Future<void> save(TaskRecord task) async {
    _records[task.id] = task;
  }

  @override
  Future<void> delete(String id) async {
    _records.remove(id);
  }
}
