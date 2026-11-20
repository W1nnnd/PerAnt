// SPDX-License-Identifier: GPL-3.0-only
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:perant/src/application/device_inference.dart';
import 'package:perant/src/application/local_document_work.dart';
import 'package:perant/src/data/gguf_models.dart';
import 'package:perant_core/perant_core.dart';

int verifyQuotes(String draft, List<MarkdownDocument> docs) {
  final locator = RegExp(r'^\[S(\d+) · 第 (\d+)–(\d+) 字\](?:（长句节选）)?$');
  final rows = draft.split('\n');
  final sources = {
    for (final (i, doc) in docs.indexed) i + 1: doc.markdown.runes.toList(),
  };
  final cited = <int>{};
  var count = 0;
  for (var i = 0; i < rows.length; i++) {
    final span = locator.firstMatch(rows[i]);
    if (span == null) continue;
    final source = int.parse(span[1]!);
    final first = int.parse(span[2]!);
    final last = int.parse(span[3]!);
    expect(rows[i + 1], isEmpty);
    var j = i + 2;
    final lines = <String>[];
    while (j < rows.length && rows[j].startsWith('> ')) {
      lines.add(rows[j++].substring(2));
    }
    expect(lines, isNotEmpty);
    expect(
      lines.join('\n'),
      String.fromCharCodes(sources[source]!, first - 1, last),
    );
    cited.add(source);
    count++;
    i = j - 1;
  }
  expect(cited, sources.keys.toSet());
  return count;
}

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
        for (final sample in [
          'PerAnt offline office roundtrip 011',
          '会议决定：保留原方案，由李明在周五前核对预算。',
          '预算尚未批准，负责人和日期待定。',
        ]) {
          final input = MarkdownDocument(
            id: 'repro',
            title: '测试资料',
            markdown: sample,
            updatedAt: DateTime.utc(2026),
          );
          final draft = await synthesizeMeeting([input])(
            runtime,
            'source-repro',
            () => false,
            (_) {},
          );
          final lines = draft
              .split('\n')
              .where((line) => line.startsWith('> '))
              .toList();
          expect(lines, ['> $sample', '> $sample']);
          expect(draft, isNot(contains('技术团队')));
          expect(draft, isNot(contains('2024-10-27')));
        }
        debugPrint('PERANT_GROUNDED sparse=1 decided=1 undecided=1 exact=3');
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
        final verified = verifyQuotes(report, docs);
        debugPrint(
          'PERANT_MEETING characters=${docs.fold<int>(0, (a, d) => a + d.markdown.runes.length)} elapsedMs=${watch.elapsedMilliseconds} output=${report.runes.length} verifiedExcerpts=$verified',
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
