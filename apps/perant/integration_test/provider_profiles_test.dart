// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/persistence_native.dart';
import 'package:perant/src/data/portable_documents.dart';
import 'package:perant_core/perant_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'model catalog, isolated profiles and two fixed echo turns survive device restart',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <({String path, String auth, Map body})>[];
      var corrupt = false;
      final sub = server.listen((r) async {
        final raw = await utf8.decoder.bind(r).join();
        final body = raw.isEmpty ? <String, dynamic>{} : jsonDecode(raw) as Map;
        requests.add((
          path: r.uri.path,
          auth: r.headers.value('authorization') ?? '',
          body: body,
        ));
        if (r.method == 'GET') {
          r.response.headers.contentType = ContentType.json;
          r.response.write(
            '{"data":[{"id":"office-b"},{"id":"office-a"},{"id":"office-a"}]}',
          );
        } else {
          r.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          void event(Object data) =>
              r.response.write('data: ${jsonEncode(data)}\n\n');
          final chat = r.uri.path.endsWith('/chat/completions');
          final calls = body.containsKey('tools');
          const name = 'perant_echo';
          final args = jsonEncode({'value': corrupt ? 'other' : 'ping'});
          if (chat) {
            event({
              'choices': [
                {
                  'delta': calls
                      ? {
                          'role': 'assistant',
                          'tool_calls': [
                            {
                              'index': 0,
                              'id': 'echo-1',
                              'type': 'function',
                              'function': {'name': name, 'arguments': args},
                            },
                          ],
                        }
                      : {'content': 'PONG'},
                  'finish_reason': calls ? 'tool_calls' : 'stop',
                },
              ],
            });
            r.response.write('data: [DONE]\n\n');
          } else {
            if (!calls)
              event({'type': 'response.output_text.delta', 'delta': 'PONG'});
            event({
              'type': 'response.completed',
              'response': {
                'status': 'completed',
                'output': [
                  if (calls)
                    {
                      'type': 'function_call',
                      'id': 'item-1',
                      'call_id': 'echo-1',
                      'name': name,
                      'arguments': args,
                    },
                ],
              },
            });
          }
        }
        await r.response.close();
      });
      final creds = MemoryCredentialStore();
      final db =
          'perant.profiles.${DateTime.now().microsecondsSinceEpoch}.sqlite';
      final path = '${(await getApplicationSupportDirectory()).path}/$db';
      Future<WorkspaceController> open() async {
        final c = WorkspaceController(
          persistence: await openPersistence(databaseName: db),
          credentials: creds,
        );
        await c.initialize();
        return c;
      }

      var c = await open();
      ProviderProfile profile(String ref, ApiProtocol protocol) =>
          ProviderProfile(
            id: ref,
            displayName: ref,
            modelId: 'office-a',
            protocol: protocol,
            baseUrl: Uri.parse('http://127.0.0.1:${server.port}/$ref/v1'),
            storageKeyRef: 'test.$ref',
            options: {
              'temperature': 0.25,
              'top_p': 0.9,
              'previous_response_id': 'must-not-leave-device',
            },
          );
      final a = profile('office-a', ApiProtocol.chatCompletions);
      final b = profile('office-b', ApiProtocol.responses);
      try {
        expect(await c.availableModels(a, 'test-A'), ['office-a', 'office-b']);
        await c.configure(a, 'test-A');
        await c.createDocument(
          title: 'Private material',
          markdown: 'PRIVATE-ORIGINAL',
        );
        await c.configure(b, 'test-B');
        await c.persistence.close();
        c.dispose();
        c = await open();
        expect(c.profile!.id, b.id);
        expect(c.state.savedProfiles.length, 2);
        for (final selected in [a, b]) {
          await c.configure(selected, '');
          final key = selected.id == a.id ? 'test-A' : 'test-B';
          expect(await c.availableModels(selected, ''), [
            'office-a',
            'office-b',
          ]);
          expect(requests.last.path, '/${selected.id}/v1/models');
          expect(requests.last.auth, 'Bearer $key');
          final n = requests.length;
          await c.testConnection(verifyTool: true);
          expect(c.connectionMessage, contains('已验证'));
          expect(c.profile!.verification, ProviderVerification.toolsVerified);
          expect(requests.length, n + 2);
          expect(jsonEncode(requests[n + 1].body), contains('echo-1'));
          expect(jsonEncode(requests[n + 1].body), contains('PONG'));
          expect(requests[n + 1].body.containsKey('tools'), isFalse);
          await c.send('ordinary chat', cloudApproved: true);
          expect(requests.last.body['temperature'], 0.25);
          expect(requests.last.body['top_p'], 0.9);
          expect(requests.last.body.containsKey('tools'), isFalse);
          expect(
            requests.last.body.containsKey('previous_response_id'),
            isFalse,
          );
        }
        final n = requests.length;
        corrupt = true;
        await c.testConnection(verifyTool: true);
        expect(c.connectionMessage, isNot(contains('已验证')));
        expect(requests.length, n + 1);
        expect(
          jsonEncode(requests.map((r) => r.body).toList()),
          isNot(contains('PRIVATE-ORIGINAL')),
        );
        await expectLater(
          c.availableModels(profile('unknown', ApiProtocol.responses), ''),
          throwsA(anything),
        );
        expect(requests.length, n + 1);
        final backup = utf8.decode(
          encodeWorkspaceBackup(await portableSnapshot(c.state)),
        );
        for (final forbidden in [
          'otherProfiles',
          'test.office-a',
          'test.office-b',
          'test-A',
          'test-B',
        ]) {
          expect(backup, isNot(contains(forbidden)));
        }
      } finally {
        c.dispose();
        await c.persistence.close();
        await sub.cancel();
        await server.close(force: true);
        await deleteDatabase(path);
      }
    },
  );
}
