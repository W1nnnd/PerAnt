// SPDX-License-Identifier: GPL-3.0-only

import 'package:perant_core/perant_core.dart';
import 'package:test/test.dart';

void main() {
  test('unlinked Linux never pretends to start or execute a command', () async {
    const runtime = UnavailableLinuxRuntime();
    expect((await runtime.inspect()).isAvailable, isFalse);
    await expectLater(
        runtime.start(), throwsA(isA<RuntimeUnavailableException>()));
    await expectLater(
      runtime.execute(CommandRequest(
        executionId: 'execution',
        taskId: 'task',
        workspaceId: 'workspace',
        executable: 'python3',
      )),
      emitsError(isA<RuntimeUnavailableException>()),
    );
  });

  test('unlinked inference cannot emit a simulated model answer', () async {
    const inference = UnavailableLocalInference();
    expect((await inference.inspect()).availability,
        RuntimeAvailability.unavailable);
    await expectLater(
      inference
          .generate(ModelRequest(id: 'request', taskId: 'task', messages: [])),
      emitsError(isA<RuntimeUnavailableException>()),
    );
  });
}
