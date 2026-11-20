// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:perant/src/application/material_import.dart';
import 'package:perant/src/application/office_document.dart';
import 'package:perant/src/data/persistence_native.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant_core/perant_core.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native PDF text layer preserves Chinese, pages and final paragraph',
    (_) async {
      final at = DateTime.utc(2026, 11, 20);
      final doc = MarkdownDocument(
        id: 'test',
        title: '材料',
        updatedAt: at,
        markdown: [
          '# 纪要验证',
          '',
          '| 人员 | 日期 |',
          '| --- | --- |',
          '| 小林 | 周一 |',
          '',
          ...List.generate(100, (i) => '已核对第${i + 1}条设备测试记录。\n'),
          '最终确认文字',
        ].join('\n'),
      ).confirm(at: at).confirmedSnapshot();
      final bytes = await exportPdf(
        doc,
        await rootBundle.load(officeFontAsset),
      );
      final pages = await const MethodChannel('dev.perant/pdf')
          .invokeListMethod<String>('readPages', bytes);
      expect(pages!.length, greaterThan(1));
      final body = importPdfPages(pages).replaceAll(RegExp(r'\s'), '');
      for (final sample in ['纪要验证', '小林', '第100条', '最终确认文字']) {
        expect(body, contains(sample));
      }
      expect(importDocx(exportDocx(doc)), contains('最终确认文字'));
    },
  );
  testWidgets(
    'old large SQLite snapshot migrates, retains 30 revisions and purges deleted chunks',
    (_) async {
      final name =
          'perant.office.${DateTime.now().microsecondsSinceEpoch}.sqlite';
      final path = '${(await getApplicationSupportDirectory()).path}/$name';
      final at = DateTime.utc(2026, 11, 20);
      final big = '字😀' * 340000;
      final state = WorkspaceState(
        documents: [
          MarkdownDocument(
            id: 'paper',
            title: '迁移',
            markdown: big,
            updatedAt: at,
          ),
        ],
      );
      final legacy = await openDatabase(
        path,
        version: 1,
        onCreate: (db, _) => db.execute(
          'CREATE TABLE workspace_snapshot(id INTEGER PRIMARY KEY,schema_version INTEGER NOT NULL,payload TEXT NOT NULL)',
        ),
      );
      await legacy.insert('workspace_snapshot', {
        'id': 1,
        'schema_version': 1,
        'payload': jsonEncode(state.toJson()),
      });
      await legacy.close();
      addTearDown(() => deleteDatabase(path));
      var store = await openPersistence(databaseName: name);
      try {
        final migrated = await store.load();
        expect(migrated.documents.single.markdown == big, isTrue);
        for (var i = 1; i <= 30; i++) {
          migrated.documents[0] = migrated.documents.single.edit(
            '第$i稿',
            at: at,
          );
          await store.save(migrated.toJson());
        }
        await store.close();
        store = await openPersistence(databaseName: name);
        final doc = (await store.load()).documents.single;
        expect(doc.history, hasLength(30));
        expect(doc.history.first.markdown == big, isTrue);
        expect(doc.markdown, '第30稿');
        final concurrent = await openPersistence(databaseName: name);
        try {
          final old = await concurrent.load();
          await store.save(WorkspaceState().toJson());
          await expectLater(concurrent.save(old.toJson()), throwsStateError);
        } finally {
          await concurrent.close();
        }
      } finally {
        await store.close();
      }
      final db = await openDatabase(path);
      try {
        expect(
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT count(*) FROM document_chunk'),
          ),
          0,
        );
      } finally {
        await db.close();
      }
    },
  );
}
