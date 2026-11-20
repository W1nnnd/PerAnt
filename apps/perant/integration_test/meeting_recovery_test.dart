// SPDX-License-Identifier: GPL-3.0-only
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:perant/src/application/device_inference.dart';
import 'package:perant/src/application/local_document_work.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/gguf_models.dart';
import 'package:perant/src/data/persistence_native.dart';
import 'package:perant_core/perant_core.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('resume a real local meeting after external process death', (
    tester,
  ) async {
    const name = 'perant.qwen.meeting.recovery.sqlite';
    final store = await openPersistence(databaseName: name);
    final c = WorkspaceController(
      persistence: store,
      credentials: MemoryCredentialStore(),
    );
    final engine = DeviceInference();
    final model = DeviceModel.small;
    var finished = false;
    try {
      await c.initialize();
      if (c.documents.isEmpty) {
        await c.createDocument(
          title: '会议预算',
          markdown: '本次培训预算为三万元，李明负责核对。' * 45,
        );
        await c.createDocument(
          title: '会议排期',
          markdown: '周五前提交报名表，周一开始培训。' * 45,
        );
      }
      final docs = c.documents;
      expect(docs.length, 2);
      for (final d in docs) {
        await d.currentVersion.loadText();
      }
      final prior = c.state.currentMeeting;
      if (!await model.installed()) {
        await model.install(
          File('/data/local/tmp/perant-007/${model.name}').openRead(),
          stopped: () => false,
          progress: (_) {},
        );
      }
      await engine.load(
        LocalModelConfiguration(
          modelId: model.id,
          modelFile: (await model.file()).uri,
        ),
      );
      String? runId;
      var reused = 0;
      final work = recoverableMeeting(c, docs, (id) => runId = id);
      final draft = await work(engine, 'test-meeting', () => false, (message) {
        if (message.startsWith('继续上次纪要')) reused++;
        if (prior == null && message.startsWith('归纳第 3/'))
          debugPrint(
            'PERANT_MEETING_KILL saved=${c.state.currentMeeting!.steps.length}',
          );
      });
      if (prior == null && const bool.fromEnvironment('PERANT_KILL_MEETING')) {
        fail(
          'Dedicated test driver must stop the process after the meeting checkpoint.',
        );
      }
      expect(reused, prior?.steps.length ?? 0);
      if (prior != null) expect(reused, greaterThanOrEqualTo(2));
      expect(draft, contains('会议预算'));
      expect(draft, contains('会议排期'));
      final allSteps = c.state.currentMeeting!.steps.length;
      await c.createDocument(
        title: '恢复的会议草稿',
        markdown: draft,
        completedMeetingId: runId!,
      );
      final readback = await store.load();
      expect(readback.currentMeeting, isNull);
      expect(
        readback.documents.where((d) => d.title == '恢复的会议草稿').single.markdown,
        draft,
      );
      expect(readback.documents.length, 3);
      debugPrint(
        'PERANT_MEETING_RESTORED reused=$reused total=$allSteps drafts=1 chars=${draft.runes.length}',
      );
      finished = true;
    } finally {
      await engine.unload();
      c.dispose();
      await store.close();
      if (finished)
        await deleteDatabase(
          '${(await getApplicationSupportDirectory()).path}/$name',
        );
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
