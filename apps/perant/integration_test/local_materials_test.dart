// SPDX-License-Identifier: GPL-3.0-only
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:perant/src/application/device_inference.dart';
import 'package:perant/src/application/local_document_work.dart';
import 'package:perant/src/data/gguf_models.dart';
import 'package:perant_core/perant_core.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real offline model summarizes Chinese materials and revises a selection',
    (tester) async {
      final model = DeviceModel.small;
      final runtime = DeviceInference();
      if (!await model.installed()) {
        await model.install(
          File('/data/local/tmp/perant-007/${model.name}').openRead(),
          stopped: () => false,
          progress: (_) {},
        );
      }
      try {
        await runtime.load(
          LocalModelConfiguration(
            modelId: model.id,
            modelFile: (await model.file()).uri,
          ),
        );
        const large = bool.fromEnvironment('PERANT_LONG_MEETING');
        final facts = [
          '预算上限为三万元，由李明复核。',
          '下周三发布新版，张文负责文档。',
          '陈佳在周五前整理投票结果。',
          '培训安排在六月十五日，王平负责场地。',
          '下周一检查库存，负责人为刘洋。',
        ];
        final docs = List.generate(facts.length, (i) {
          final body = '议题：第${i + 1}项。会议决定：${facts[i]}\n';
          return MarkdownDocument(
            id: 'fixture-$i',
            title: '资料${i + 1}',
            markdown: large
                ? (body * ((4000 ~/ body.length) + 1)).substring(0, 4000)
                : body,
            updatedAt: DateTime.utc(2026),
          );
        });
        final watch = Stopwatch()..start();
        final report = await synthesizeMeeting(docs)(
          runtime,
          'meeting',
          () => false,
          (s) => debugPrint('PERANT_MEETING $s'),
        );
        for (var i = 0; i < 5; i++) {
          expect(report, contains('fixture-$i · 版本 1'));
          expect(report, contains('S${i + 1} · 第 1'));
        }
        expect(report, contains('三万'));
        expect(report, contains('周五'));
        debugPrint(
          'PERANT_MEETING characters=${docs.fold<int>(0, (a, d) => a + d.markdown.runes.length)} elapsedMs=${watch.elapsedMilliseconds} output=${report.runes.length}',
        );
        final revised = await reviseSelection('会议时间是周三请大家来参加。')(
          runtime,
          'edit',
          () => false,
          (_) {},
        );
        expect(revised, contains('周三'));
        var interrupted = false;
        await for (final event in runtime.generate(
          ModelRequest(
            id: 'cancel',
            taskId: 'cancel',
            maxOutputTokens: 128,
            messages: [
              ModelMessage(role: ModelRole.user, content: '写十句关于春天的话。'),
            ],
          ),
        )) {
          if (event.type == ModelEventType.textDelta && !interrupted) {
            interrupted = true;
            await runtime.cancel('cancel');
          } else if (interrupted) {
            fail('cancelled request delivered another event');
          }
        }
        expect(interrupted, isTrue);
      } finally {
        await runtime.unload();
      }
    },
    timeout: const Timeout(Duration(hours: 2)),
  );
}
