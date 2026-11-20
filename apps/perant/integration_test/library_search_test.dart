// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/portable_documents.dart';
import 'package:perant/src/perant_app.dart';
import 'package:perant/src/data/library_search.dart';
import 'package:perant/src/data/persistence_native.dart';

import 'package:perant_core/perant_core.dart';
import 'package:sqflite/sqflite.dart';

const _labels =
    '报销 采购 排班 出差 合同 培训 通勤 食堂 租赁 复盘 预算 审计 招聘 采购单 库存 调拨 设备 折旧 团建 福利 保险 公积金 交通 补贴 假期 请假 育儿 医疗 报关 运费 客诉 售后 返修 巡检 清洁 消防 防汛 演练 工时 绩效 交接 考勤 薪酬 税务 发票 对账 转账 利率 收款 退款';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'device opens a Chinese search hit and retains edited memory after source deletion and restore',
    (tester) async {
      final name =
          'perant.memory.${DateTime.now().microsecondsSinceEpoch}.sqlite';
      final path = '${(await getApplicationSupportDirectory()).path}/$name';
      final store = await openPersistence(databaseName: name);
      final controller = WorkspaceController(
        persistence: store,
        credentials: const PlatformCredentialStore(),
      );
      try {
        await controller.initialize();
        await controller.dismissOnboarding();
        const text = '📄本周资料\n我喜欢按周整理收款凭证。';
        final doc = await controller.createDocument(
          title: '财务笔记',
          markdown: text,
        );
        await controller.saveDocument(doc.id, text, confirm: true);
        await tester.pumpWidget(PerantApp(controller: controller));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('文件'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '收款');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('财务笔记'));
        await tester.tap(find.text('财务笔记'));
        await tester.pumpAndSettle();
        final editor = tester
            .widget<TextField>(find.byType(TextField))
            .controller!;
        expect(editor.selection.textInside(editor.text), '收款');
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('资料备份与诊断'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('长期记忆'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('我喜欢按周整理收款凭证。'));
        await tester.pumpAndSettle();
        expect(find.text(text), findsOneWidget);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('记忆操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('修改'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField), '每周五归档。');
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(controller.state.memories.records.values.single.text, '每周五归档。');
        await controller.deleteDocument(doc.id);
        await tester.pumpAndSettle();
        expect(find.textContaining('原来源已删除'), findsOneWidget);
        final backup = backupWorkspace(controller.state);
        final id = controller.state.memories.records.keys.single;
        await controller.deleteMemory(id);
        expect(controller.state.memories.records, isEmpty);
        await controller.restoreWorkspace(readWorkspaceBackup(backup));
        final reopened = await store.load();
        expect(reopened.memories.records[id]!.text, '每周五归档。');
        expect(reopened.memories.records[id]!.hasMissingSource, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await store.close();
        await deleteDatabase(path);
      }
    },
  );
  testWidgets(
    'native SQLite searches 1000 mixed synthetic documents and removes stale revisions',
    (_) async {
      final queries = _labels.split(' ');
      expect(queries, hasLength(50));
      final at = DateTime.utc(2026, 11, 20);
      final name =
          'perant.search.${DateTime.now().microsecondsSinceEpoch}.sqlite';
      final path = '${(await getApplicationSupportDirectory()).path}/$name';
      var store = await openPersistence(databaseName: name);
      addTearDown(() async {
        await store.close();
        await deleteDatabase(path);
      });
      final state = await store.load();
      const phrases = [
        '周会记录包含各组反馈。请在本周整理附件并核对编号。',
        '本周讨论课程安排和资料目录。编辑后请保留旧稿。',
        '周会记录包含各组反馈。请在本周整理附件并核对编号。',
        '业务季度小结中记录进度。Team notes include dates and status. ',
      ];
      for (var i = 0; i < 1000; i++) {
        final n = i.isEven ? 2500 : 7500;
        final phrase = phrases[i % phrases.length];
        final filler = (phrase * (1 + n ~/ phrase.length)).substring(0, n);
        // Fixed evidence for the first 50 files at varied positions including a passage boundary.
        final label = i < queries.length ? queries[i] : '';
        final offset = (399 + i * 73) % (n - label.length);
        final body = filler.replaceRange(offset, offset + label.length, label);
        state.documents.add(
          MarkdownDocument(
            id: 'paper-$i',
            title: '资料 $i',
            markdown: body,
            updatedAt: at,
          ),
        );
      }
      final charCount = state.documents.fold<int>(
        0,
        (n, d) => n + d.markdown.runes.length,
      );
      final bytes = state.documents.fold<int>(
        0,
        (n, d) => n + utf8.encode(d.markdown).length,
      );
      expect(charCount, 5000000);
      final timer = Stopwatch()..start();
      await store.save(state.toJson());
      final buildMs = timer.elapsedMilliseconds;
      await store.close();
      timer.reset();
      store = await openPersistence(databaseName: name);
      final restored = await store.load();
      expect(restored.documents, hasLength(1000));
      final reopenMs = timer.elapsedMilliseconds;
      final search = store as PassageSearch;
      final latencies = <int>[];
      var hits = 0;
      for (var i = 0; i < queries.length; i++) {
        timer.reset();
        final results = await search.searchPassages(queries[i]);
        latencies.add(timer.elapsedMicroseconds);
        final valid = results
            .take(5)
            .where(
              (h) =>
                  h.documentId == 'paper-$i' &&
                  h.revision == restored.documents[i].revision &&
                  restored.documents[i].markdown.startsWith(
                    queries[i],
                    h.offset,
                  ),
            );
        if (valid.isNotEmpty) hits++;
      }
      expect(hits, 50);
      expect(await search.searchPassages('绝无此词'), isEmpty);
      final db = await openDatabase(path, singleInstance: false);
      late int passages;
      late String engine;
      try {
        passages = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM library_passage'),
        )!;
        engine =
            (await db.rawQuery(
                  "SELECT sql FROM sqlite_master WHERE name='library_terms'",
                )).single['sql']
                as String;
      } finally {
        await db.close();
      }
      latencies.sort();
      debugPrint(
        'PERANT_LIBRARY_BENCH ' +
            jsonEncode({
              'documents': 1000,
              'characters': charCount,
              'utf8Bytes': bytes,
              'passages': passages,
              'databaseBytes': await File(path).length(),
              'engine': engine,
              'indexMs': buildMs,
              'reopenMs': reopenMs,
              'top5': hits,
              'labeledQueries': 50,
              'p50us': latencies[24],
              'p90us': latencies[44],
              'maxus': latencies.last,
            }),
      );
      final first = restored.documents.first;
      final prefix = '😀' * 399;
      restored.documents[0] = first.edit('${prefix}𠀀资料更新', at: at);
      await store.save(restored.toJson());
      expect(await search.searchPassages(queries.first), isEmpty);
      final edited = (await search.searchPassages('𠀀资')).single;
      expect(edited.offset, prefix.length);
      expect(edited.revision, first.revision + 1);
      restored.documents.removeAt(0);
      await store.save(restored.toJson());
      expect(await search.searchPassages('𠀀资'), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
