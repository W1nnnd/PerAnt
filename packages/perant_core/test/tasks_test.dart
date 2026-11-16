// SPDX-License-Identifier: GPL-3.0-only

import 'package:perant_core/perant_core.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 13, 10);
  TaskRecord task({
    TaskStatus status = TaskStatus.queued,
    List<TaskStep> steps = const [],
    CloudAuthorization? authorization,
  }) =>
      TaskRecord(
        id: 'meeting',
        title: '整理会议记录',
        createdAt: now,
        status: status,
        steps: steps,
        cloudAuthorization: authorization,
      );

  group('TaskStateMachine', () {
    test('cannot skip execution and complete a queued task', () {
      expect(
        () =>
            TaskStateMachine.transition(task(), TaskStatus.completed, at: now),
        throwsA(isA<InvalidTaskTransition>()),
      );
    });

    test('terminal tasks cannot resume', () {
      for (final status in [
        TaskStatus.completed,
        TaskStatus.cancelled,
        TaskStatus.failed,
      ]) {
        expect(
          () => TaskStateMachine.transition(
            task(status: status),
            TaskStatus.running,
            at: now,
          ),
          throwsA(isA<InvalidTaskTransition>()),
        );
      }
    });

    test('interruption marks active tool outcomes uncertain', () {
      final interrupted = TaskStateMachine.transition(
        task(status: TaskStatus.running, steps: const [
          TaskStep(
            id: 'write',
            title: '写入草稿',
            status: TaskStepStatus.running,
            hasSideEffects: true,
          ),
          TaskStep(id: 'review', title: '检查结果'),
        ]),
        TaskStatus.interrupted,
        at: now,
      );
      expect(interrupted.steps.first.status, TaskStepStatus.uncertain);
      expect(interrupted.steps.last.status, TaskStepStatus.pending);
      expect(
        interrupted.recoveryDisposition,
        RecoveryDisposition.inspectionRequired,
      );
      expect(
        () => TaskStateMachine.transition(
          interrupted,
          TaskStatus.running,
          at: now,
        ),
        throwsA(isA<UnsafeTaskRecovery>()),
      );
    });

    test('recovery requires inspection evidence before replay', () {
      final interrupted = task(status: TaskStatus.interrupted, steps: const [
        TaskStep(
          id: 'write',
          title: '写入草稿',
          status: TaskStepStatus.uncertain,
          hasSideEffects: true,
        ),
      ]);
      expect(
        () => TaskStateMachine.resolveUncertainStep(
          interrupted,
          'write',
          completed: false,
          evidence: ' ',
          at: now,
        ),
        throwsArgumentError,
      );
      final inspected = TaskStateMachine.resolveUncertainStep(
        interrupted,
        'write',
        completed: true,
        evidence: '已检查完整草稿与执行标识，文件已提交。',
        at: now,
      );
      expect(inspected.steps.single.status, TaskStepStatus.succeeded);
      expect(
        TaskStateMachine.transition(inspected, TaskStatus.running, at: now)
            .status,
        TaskStatus.running,
      );
    });

    test('cannot complete a task with unfinished steps', () {
      expect(
        () => TaskStateMachine.transition(
          task(status: TaskStatus.running, steps: const [
            TaskStep(id: 'write', title: '写入草稿'),
          ]),
          TaskStatus.completed,
          at: now,
        ),
        throwsStateError,
      );
    });

    test('a failed step completes only when the same step later succeeded', () {
      TaskRecord withSteps(List<TaskStep> steps) =>
          task(status: TaskStatus.running, steps: steps);
      const failed = TaskStep(
        id: 'first',
        title: '写入文件：/workspace/todo.md',
        status: TaskStepStatus.failed,
      );
      TaskStep later(String title, TaskStepStatus status) =>
          TaskStep(id: 'second', title: title, status: status);

      final recovered = withSteps([
        failed,
        later(failed.title, TaskStepStatus.succeeded),
      ]);
      expect(recovered.hasUnrecoveredSteps, isFalse);
      expect(
        TaskStateMachine.transition(recovered, TaskStatus.completed, at: now)
            .status,
        TaskStatus.completed,
      );

      for (final steps in [
        // Nothing repeated it.
        [failed],
        // A different operation succeeded.
        [failed, later('写入文件：/workspace/other.md', TaskStepStatus.succeeded)],
        // The success came first, the failure is the latest word.
        [later(failed.title, TaskStepStatus.succeeded), failed],
        // An uncertain outcome is never recovered by a repeat.
        [
          const TaskStep(
            id: 'first',
            title: '写入文件：/workspace/todo.md',
            status: TaskStepStatus.uncertain,
          ),
          later(failed.title, TaskStepStatus.succeeded),
        ],
      ]) {
        final record = withSteps(steps);
        expect(record.hasUnrecoveredSteps, isTrue);
        expect(
          () => TaskStateMachine.transition(
            record,
            TaskStatus.completed,
            at: now,
          ),
          throwsStateError,
        );
      }
    });

    test('manual takeover requires active tools to stop', () {
      expect(
        () => TaskStateMachine.transition(
          task(status: TaskStatus.running, steps: const [
            TaskStep(
              id: 'write',
              title: '写入草稿',
              status: TaskStepStatus.running,
            ),
          ]),
          TaskStatus.manualControl,
          at: now,
        ),
        throwsStateError,
      );
    });

    test('finishing a task revokes its cloud authorization', () {
      final grant = CloudAuthorization(
        taskId: 'meeting',
        providerProfileId: 'provider',
        providerEndpoint: Uri.parse('https://example.com/v1/responses'),
        modelId: 'model',
        scope: CloudDataScope.currentMaterials,
        grantedAt: now,
        currentSources: {},
      );
      final finished = TaskStateMachine.transition(
        task(status: TaskStatus.running, authorization: grant),
        TaskStatus.completed,
        at: now.add(const Duration(minutes: 1)),
      );
      expect(finished.cloudAuthorization!.isRevoked, isTrue);
    });

    test('status changes clear outdated waiting detail', () {
      final waiting = task(status: TaskStatus.running).copyWith(
        status: TaskStatus.awaitingNetwork,
        statusDetail: '网络已断开',
      );
      final resumed = TaskStateMachine.transition(
        waiting,
        TaskStatus.running,
        at: now,
      );
      expect(resumed.statusDetail, isNull);
    });
  });

  test('session store returns immutable newest-first records', () async {
    final store = InMemoryTaskStore();
    await store.save(task());
    await store.save(TaskRecord(
      id: 'later',
      title: '另一项任务',
      createdAt: now.add(const Duration(minutes: 1)),
    ));
    final records = await store.list();
    expect(records.map((record) => record.id), ['later', 'meeting']);
    expect(records.clear, throwsUnsupportedError);
  });
}
