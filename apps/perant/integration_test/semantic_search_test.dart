// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:perant/src/data/persistence_native.dart';
import 'package:perant/src/data/library_search.dart';
import 'package:perant/src/data/semantic_index.dart';
import 'package:perant_core/perant_core.dart';
import 'package:sqflite/sqflite.dart';

import 'fixtures/semantic_cases.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real offline BGE encodes, retrieves paraphrases, resumes and retires stale vectors',
    (_) async {
      final name =
          'perant.semantic.${DateTime.now().microsecondsSinceEpoch}.sqlite';
      final path = '${(await getApplicationSupportDirectory()).path}/$name';
      final store = await openPersistence(databaseName: name);
      try {
        final state = await store.load();
        for (var i = 0; i < semanticCases.length; i++) {
          state.documents.add(
            MarkdownDocument(
              id: 'source-$i',
              title: '资料 $i',
              markdown: semanticCases[i].$2,
              updatedAt: DateTime.utc(2026, 11, 20),
            ),
          );
        }
        const large = bool.fromEnvironment('PERANT_LARGE_LIBRARY');
        if (large) {
          final initial = state.documents.fold<int>(
            0,
            (n, d) => n + d.markdown.runes.length,
          );
          final longBudget = 5000000 - initial - 475 * 2500;
          for (var i = 0; i < 950; i++) {
            final longIndex = i ~/ 2;
            final n = i.isEven
                ? 2500
                : longBudget ~/ 475 + (longIndex < longBudget % 475 ? 1 : 0);
            final filler = [
              '教室物品按清单摆放。请核对登记表。',
              '附件归档后记下日期和数量。',
              'Team notes. 例会记录存档。',
            ][i % 3];
            final body = (filler * (n ~/ filler.length + 1)).substring(0, n);
            state.documents.add(
              MarkdownDocument(
                id: 'background-$i',
                title: '归档资料 $i',
                markdown: body,
                updatedAt: DateTime.utc(2026, 11, 20),
              ),
            );
          }
          expect(
            state.documents.fold<int>(0, (n, d) => n + d.markdown.runes.length),
            5000000,
          );
        }
        await store.save(state.toJson());
        final engine = store as SemanticControl;
        final lexical = store as PassageSearch;
        final timer = Stopwatch()..start();
        var interrupted = false;
        await engine.indexSemantics(
          cancelled: () => interrupted,
          onProgress: (s) {
            interrupted = s.done > 0;
          },
          downloadProgress: (_, __) {},
        );
        final partial = await engine.vectorProgress();
        expect(partial.done, inInclusiveRange(1, 49));
        await engine.indexSemantics(
          cancelled: () => false,
          onProgress: (_) {},
          downloadProgress: (_, __) {},
        );
        final built = await engine.vectorProgress();
        expect(built.done, built.total);
        final db = await openDatabase(path, singleInstance: false);
        late int unique;
        try {
          unique = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM library_embedding'),
          )!;
        } finally {
          await db.close();
        }
        final buildMs = timer.elapsedMilliseconds;
        debugPrint(
          'PERANT_VECTOR_BUILD docs=${state.documents.length} passages=${built.total} distinct=$unique indexMs=$buildMs',
        );
        final times = <int>[];
        var top = 0, keywordTop = 0;
        for (var i = 0; i < semanticCases.length; i++) {
          final q = semanticCases[i].$1;
          final expected = 'source-$i';
          if ((await lexical.searchPassages(q))
              .take(5)
              .any((r) => r.documentId == expected))
            keywordTop++;
          final clock = Stopwatch()..start();
          final matches = await engine.hybridSearch(q);
          times.add(clock.elapsedMilliseconds);
          if (matches.take(5).any((r) => r.documentId == expected)) top++;
        }
        times.sort();
        const negatives = [
          '南极冰芯的氧同位素反映哪个时期',
          '巴赫平均律的赋格主题有哪些',
          '冥王星表面的氮冰物理性质',
          '中子星的磁场强度是多少',
          '长颈鹿的颈椎有几块',
        ];
        var rejected = 0;
        for (final q in negatives) {
          if ((await engine.hybridSearch(q)).isEmpty) rejected++;
        }
        debugPrint(
          'PERANT_HYBRID 50 queries lexicalTop5=$keywordTop hybridTop5=$top noAnswer=$rejected/5 p50ms=${times[24]} p90ms=${times[44]} maxms=${times.last}',
        );
        expect(top, greaterThanOrEqualTo(45));
        expect(top, greaterThan(keywordTop));
        expect(rejected, greaterThanOrEqualTo(4));
        state.documents[0] = state.documents.first.edit(
          '修订后的资料',
          at: DateTime.now(),
        );
        state.documents.removeAt(1);
        await store.save(state.toJson());
        final finish = await engine.vectorProgress();
        expect(finish, (done: built.total - 2, total: built.total - 1));
        final hits = await engine.hybridSearch(semanticCases[1].$1);
        expect(hits.any((h) => h.documentId == 'source-1'), isFalse);
      } finally {
        await store.close();
        await deleteDatabase(path);
      }
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
