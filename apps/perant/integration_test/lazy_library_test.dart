// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/application/historical_excerpt.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/library_search.dart';
import 'package:perant/src/data/persistence_native.dart';
import 'package:perant/src/data/portable_documents.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant_core/perant_core.dart';
import 'package:sqflite/sqflite.dart';

import 'library_search_test.dart' as search_suite;
import 'office_materials_test.dart' as office;
import 'sourced_question_test.dart' as sourced;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    '1000-document cold catalog loads only requested revisions and preserves recovery',
    (tester) async {
      final name = 'catalog-${DateTime.now().microsecondsSinceEpoch}.sqlite';
      final path = '${(await getApplicationSupportDirectory()).path}/$name';
      final at = DateTime.utc(2026, 11, 20);
      var store = await openPersistence(databaseName: name);
      try {
        final docs = List.generate(1000, (i) {
          final title = '资料$i';
          if (i == 0)
            return MarkdownDocument(
              id: 'd0',
              title: title,
              markdown: '历史约定',
              updatedAt: at,
            ).edit('我喜欢早上核对报价。', at: at).confirm(at: at);
          final prefix = i == 111 ? '墨竹报价表' : '会议材料$i';
          return MarkdownDocument(
            id: 'd$i',
            title: title,
            markdown: prefix + '资' * (5000 - prefix.length),
            updatedAt: at,
          );
        });
        final state = WorkspaceState(documents: docs);
        state.memories = state.memories.reconcile(state.memorySources);
        // The 0.0.7 snapshot did not persist the memory extraction watermark.
        await store.save(state.toJson());
        await store.close();
        store = await openPersistence(databaseName: name);
        final controller = WorkspaceController(
          persistence: store,
          credentials: MemoryCredentialStore(),
        );
        final timer = Stopwatch()..start();
        await controller.initialize();
        timer.stop();
        int loaded() => controller.documents
            .expand((d) => [d.currentVersion, ...d.history])
            .where((v) => v.isLoaded)
            .length;
        expect(loaded(), 0);
        expect(controller.state.memories.records, isNotEmpty);
        final hits = await (store as PassageSearch).searchPassages('墨竹报价表');
        expect(hits.first.documentId, 'd111');
        expect(loaded(), 0);
        final selected = controller.documents.firstWhere(
          (d) => d.id == hits.first.documentId,
        );
        final excerpt = await HistoricalExcerpt.readPassage(
          selected,
          hits.first,
          store,
        );
        expect(excerpt!.text, startsWith('墨竹报价表'));
        await HistoricalExcerpt.verify([excerpt], controller.state, store);
        expect(loaded(), 0);
        expect(await selected.currentVersion.loadText(), startsWith('墨竹报价表'));
        expect(loaded(), 1);
        final original = controller.documents.firstWhere((d) => d.id == 'd0');
        expect(await original.history.single.loadText(), '历史约定');
        expect(loaded(), 2);
        await controller.saveDocument(
          selected.id,
          '新价格已确认',
          expectedRevision: selected.revision,
        );
        expect(await (store as PassageSearch).searchPassages('墨竹报价表'), isEmpty);
        final backup = await portableSnapshot(controller.state);
        final recovered = readWorkspaceBackup(encodeWorkspaceBackup(backup));
        expect(recovered.documents.length, 1000);
        expect(
          recovered.documents
              .firstWhere((d) => d.id == 'd111')
              .history
              .single
              .markdown,
          startsWith('墨竹报价表'),
        );
        expect(loaded(), 3);
        final second = await openPersistence(databaseName: name);
        try {
          final stale = await (second as WorkspaceCatalog).loadCatalog();
          await controller.deleteDocument('d112');
          await expectLater(
            stale.documents
                .firstWhere((d) => d.id == 'd112')
                .currentVersion
                .loadText(),
            throwsStateError,
          );
          await expectLater(
            second.save(stale.toJson(forStorage: true)),
            throwsStateError,
          );
        } finally {
          await second.close();
        }
        debugPrint(
          'PERANT_CATALOG docs=1000 revisions=1001 coldBodies=0 searchBodies=0 opened=2 saveAndBackupBodies=3 coldInitMs=${timer.elapsedMilliseconds}',
        );
      } finally {
        await store.close();
        await deleteDatabase(path);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
  if (const bool.fromEnvironment('PERANT_CATALOG_REGRESSION')) {
    office.main();
    search_suite.main();
    sourced.main();
  }
}
