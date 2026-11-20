// SPDX-License-Identifier: GPL-3.0-only
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:perant/src/application/local_document_work.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/gguf_models.dart';
import 'package:perant/src/data/persistence_native.dart';
import 'package:perant/src/presentation/local_model_screen.dart';
import 'package:perant_core/perant_core.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'release real model under memory pressure and keep the last completed meeting step',
    (tester) async {
      final name =
          'pressure-model-${DateTime.now().microsecondsSinceEpoch}.sqlite';
      final db = await openPersistence(databaseName: name);
      final c = WorkspaceController(
        persistence: db,
        credentials: MemoryCredentialStore(),
      );
      try {
        await c.initialize();
        final model = DeviceModel.small;
        if (!await model.installed()) {
          await model.install(
            File('/data/local/tmp/perant-007/${model.name}').openRead(),
            stopped: () => false,
            progress: (_) {},
          );
        }
        final doc = await c.createDocument(
          title: '会议预算',
          markdown: '培训费用为三万元，由李明核对。' * 120,
        );
        LocalInference? engine;
        var signaled = false;
        final work = recoverableMeeting(c, [doc], (_) {});
        await tester.pumpWidget(
          MaterialApp(
            home: LocalModelScreen(
              controller: c,
              work: (runtime, id, stopped, progress) {
                engine = runtime;
                return work(runtime, id, stopped, (s) {
                  progress(s);
                  if (!signaled && s.startsWith('归纳第 2/')) {
                    signaled = true;
                    debugPrint(
                      'PERANT_PRESSURE_READY completed=${c.state.currentMeeting!.steps.length}',
                    );
                    if (!const bool.fromEnvironment('PERANT_EXTERNAL_MEMORY'))
                      Future.microtask(tester.binding.handleMemoryPressure);
                  }
                });
              },
            ),
          ),
        );
        Future<void> until(bool Function() condition) async {
          final end = DateTime.now().add(const Duration(minutes: 2));
          while (!condition() && DateTime.now().isBefore(end)) {
            await tester.pump(const Duration(milliseconds: 200));
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(condition(), isTrue);
        }

        final load = find.text('加载到内存');
        await until(() => load.evaluate().isNotEmpty);
        await tester.tap(load);
        final start = find.text('开始在本机处理');
        await until(() => start.evaluate().isNotEmpty);
        await tester.tap(start);
        await until(
          () => find.textContaining('设备内存紧张，已释放模型').evaluate().isNotEmpty,
        );
        expect(
          (await engine!.inspect()).availability,
          RuntimeAvailability.notInstalled,
        );
        final saved = (await db.load()).currentMeeting!;
        expect(saved.steps.length, greaterThanOrEqualTo(1));
        expect(c.documents.single.id, doc.id);
        await tester.tap(load);
        await until(() => start.evaluate().isNotEmpty);
        expect(
          (await engine!.inspect()).availability,
          RuntimeAvailability.ready,
        );
        expect(c.state.currentMeeting!.steps, saved.steps);
        debugPrint(
          'PERANT_PRESSURE_RELEASED steps=${saved.steps.length} reloaded=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        await db.close();
        await deleteDatabase(
          '${(await getApplicationSupportDirectory()).path}/$name',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
