// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/library_search.dart';
import 'package:perant/src/data/persistence_native.dart';
import 'package:perant_core/perant_core.dart';
import 'package:perant_platform/perant_platform.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const processProbe = bool.fromEnvironment('PERANT_PROCESS_PROBE');
  testWidgets(
    'database full rolls back entire edit and FTS, then permits retry',
    (tester) async {
      final name = 'pressure-${DateTime.now().microsecondsSinceEpoch}.sqlite';
      final path = '${(await getApplicationSupportDirectory()).path}/$name';
      var store = await openPersistence(databaseName: name);
      var c = WorkspaceController(
        persistence: store,
        credentials: MemoryCredentialStore(),
      );
      try {
        final free = await PerantPlatformBridge().availableStorageBytes();
        expect(free, isNotNull);
        expect(free!, greaterThan(0));
        await c.initialize();
        final original = await c.createDocument(
          title: '压力测试',
          markdown: '旧稿竹林',
        );
        await store.close();
        c.dispose();
        store = await openPersistence(
          databaseName: name,
          onConfigure: (db) async {
            final used = Sqflite.firstIntValue(
              await db.rawQuery('PRAGMA page_count'),
            )!;
            expect(
              Sqflite.firstIntValue(
                await db.rawQuery('PRAGMA max_page_count=$used'),
              ),
              used,
            );
          },
        );
        c = WorkspaceController(
          persistence: store,
          credentials: MemoryCredentialStore(),
        );
        await c.initialize();
        await expectLater(
          c.saveDocument(original.id, '不可发布的大稿晴川' * 40000, expectedRevision: 1),
          throwsA(
            isA<DatabaseException>().having(
              (e) => e.toString(),
              'SQLite full',
              matches(
                RegExp(
                  'SQLITE_FULL|database or disk is full|code 13',
                  caseSensitive: false,
                ),
              ),
            ),
          ),
        );
        expect(c.documents.single.revision, 1);
        expect((await (store as PassageSearch).searchPassages('晴川')), isEmpty);
        expect(
          (await (store as PassageSearch).searchPassages('竹林'))
              .single
              .documentId,
          original.id,
        );
        await store.close();
        c.dispose();
        store = await openPersistence(databaseName: name);
        c = WorkspaceController(
          persistence: store,
          credentials: MemoryCredentialStore(),
        );
        await c.initialize();
        final d = c.documents.single;
        expect(await d.currentVersion.loadText(), '旧稿竹林');
        expect(d.history, isEmpty);
        final next = await c.saveDocument(
          d.id,
          '空间恢复后的新稿',
          expectedRevision: 1,
        );
        expect(next.revision, 2);
        debugPrint(
          'PERANT_DISK sqliteFull=true preserved=1 retry=2 availableBytes=$free',
        );
      } finally {
        await store.close();
        c.dispose();
        await deleteDatabase(path);
      }
    },
  );
  if (processProbe)
    testWidgets(
      'external process death leaves prior work and revokes pending grants',
      (tester) async {
        const name = 'perant.process-recovery.010.sqlite';
        final store = await openPersistence(databaseName: name);
        final c = WorkspaceController(
          persistence: store,
          credentials: MemoryCredentialStore(),
        );
        final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var completed = false;
        var networkCalls = 0;
        final received = Completer<void>();
        final sub = s.listen((request) async {
          networkCalls++;
          await request.drain<void>();
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.bufferOutput = false;
          request.response.write(
            'data: {"choices":[{"delta":{"content":"等待中"}}]}\n\n',
          );
          await request.response.flush();
          if (!received.isCompleted) received.complete();
        });
        try {
          await c.initialize();
          final previous = c.documents.length;
          expect(c.tasks.length, previous);
          expect(
            c.tasks.every(
              (t) =>
                  t.status == TaskStatus.interrupted &&
                  t.cloudAuthorization == null,
            ),
            isTrue,
          );
          for (final d in c.documents) {
            expect(d.isConfirmed, isTrue);
            expect(await d.currentVersion.loadText(), '已保存的中文资料 ' + d.title);
          }
          expect(networkCalls, 0);
          if (previous >= 10) {
            completed = true;
            debugPrint(
              'PERANT_RECOVERED rounds=$previous confirmed=$previous automaticRequests=$networkCalls',
            );
            return;
          }
          final title = '第${previous + 1}轮';
          final doc = await c.createDocument(
            title: title,
            markdown: '已保存的中文资料 ' + title,
          );
          await c.saveDocument(
            doc.id,
            doc.markdown,
            confirm: true,
            expectedRevision: doc.revision,
          );
          await c.configure(
            ProviderProfile(
              id: 'fixture',
              displayName: '回环测试',
              baseUrl: Uri.parse('http://127.0.0.1:${s.port}/v1'),
              protocol: ApiProtocol.chatCompletions,
              modelId: 'fixture',
              storageKeyRef: 'fixture-key',
            ),
            'device-fixture',
          );
          unawaited(c.send('本轮固定测试', cloudApproved: true));
          await received.future.timeout(const Duration(seconds: 10));
          expect(networkCalls, 1);
          debugPrint('PERANT_INTERRUPT_READY round=${previous + 1}');
          await Future<void>.delayed(const Duration(seconds: 35));
          fail(
            'Test driver must terminate this isolated app process after READY.',
          );
        } finally {
          c.dispose();
          await sub.cancel();
          await s.close(force: true);
          if (completed) {
            await store.close();
            await deleteDatabase(
              '${(await getApplicationSupportDirectory()).path}/$name',
            );
          }
        }
      },
    );
}
