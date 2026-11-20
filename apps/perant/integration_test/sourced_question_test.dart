// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/persistence_native.dart';
import 'package:perant/src/perant_app.dart';
import 'package:perant_core/perant_core.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native app sends only selected saved evidence to an explicit loopback test provider',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final payloads = <String>[];
      final sub = server.listen((request) async {
        payloads.add(await utf8.decoder.bind(request).join());
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: {"choices":[{"delta":{"content":"见 [S1]，抬头为青桥。"}}]}\n\ndata: [DONE]\n\n',
        );
        await request.response.close();
      });
      final name =
          'perant.citations.${DateTime.now().microsecondsSinceEpoch}.sqlite';
      final path = '${(await getApplicationSupportDirectory()).path}/$name';
      final store = await openPersistence(databaseName: name);
      final c = WorkspaceController(
        persistence: store,
        credentials: MemoryCredentialStore(),
      );
      try {
        await c.initialize();
        await c.dismissOnboarding();
        await c.configure(
          ProviderProfile(
            id: 'local-fixture',
            displayName: '设备测试服务',
            baseUrl: Uri.parse('http://127.0.0.1:${server.port}/v1'),
            protocol: ApiProtocol.chatCompletions,
            modelId: 'fixture',
            storageKeyRef: 'credential:loopback',
          ),
          'local-test-only',
        );
        await c.createDocument(title: '开票办法', markdown: '发票抬头是青桥。');
        await c.createDocument(title: '个人备忘', markdown: '绝对不应出现在网络请求中。');
        await tester.pumpWidget(PerantApp(controller: c));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('文件'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('资料备份与诊断'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('引用本机资料提问'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField), '抬头是什么？');
        await tester.enterText(find.byType(TextField).last, '发票');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('查找引用'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('开票办法'));
        await tester.pumpAndSettle();
        expect(payloads, isEmpty);
        final send = find.text('授权发送选中的片段');
        await tester.ensureVisible(send);
        await tester.tap(send);
        for (
          var i = 0;
          i < 100 && (c.tasks.isEmpty || !c.tasks.first.status.isTerminal);
          i++
        )
          await tester.pump(const Duration(milliseconds: 100));
        expect(c.tasks.first.status, TaskStatus.completed);
        expect(payloads.single, contains('青桥'));
        expect(payloads.single, isNot(contains('绝对不应')));
        expect(c.messages.last.text, contains('[S1]'));
        final state = await store.load();
        expect(state.tasks.last.steps.single.resultSummary, contains('开票办法'));
        await c.send('接下来的普通消息', cloudApproved: true);
        expect(payloads, hasLength(2));
        expect(payloads.last, isNot(contains('青桥')));
      } finally {
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        await store.close();
        await deleteDatabase(path);
        await sub.cancel();
        await server.close(force: true);
      }
    },
  );
}
