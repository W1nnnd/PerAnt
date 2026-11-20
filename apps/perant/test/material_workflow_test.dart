// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:perant/src/application/meeting_minutes.dart';
import 'package:perant/src/data/portable_documents.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant_core/perant_core.dart';

void main() {
  final at = DateTime.utc(2026, 11, 20);
  MarkdownDocument sample(String id, String body) =>
      MarkdownDocument(id: id, title: '私密标题$id', markdown: body, updatedAt: at);
  test(
    'five documents / 20000 characters preserve every source and its revision',
    () {
      final docs = List.generate(5, (i) {
        final start = '议题：进度\n决定：通过\n待办：核对\n';
        return sample('doc$i', start + '字' * (4000 - start.runes.length));
      });
      final result = meetingOutline(docs);
      expect(result, contains('## 决策候选'));
      expect(result, contains('## 待办候选'));
      for (var i = 0; i < 5; i++) {
        expect(result, contains('S${i + 1} · 第 4 行'));
        expect(result, contains('doc$i · 版本 1'));
      }
      expect(
        result.runes.where((c) => c == '字'.codeUnitAt(0)).length,
        docs
            .map(
              (d) =>
                  d.markdown.runes.where((c) => c == '字'.codeUnitAt(0)).length,
            )
            .reduce((a, b) => a + b),
      );
      expect(
        () => meetingOutline([...docs, sample('extra', '一')]),
        throwsFormatException,
      );
      expect(
        () => meetingOutline([docs.first, docs.first]),
        throwsFormatException,
      );
      expect(
        () => meetingOutline([docs.first.edit('字' * 20001, at: at)]),
        throwsFormatException,
      );
    },
  );
  test('portable backup restores only personal data and clears provider configuration', () {
    final original = sample('id', '原文').edit('最终内容', at: at).confirm(at: at);
    final encoded = backupWorkspace(
      WorkspaceState(documents: [original], companionName: '同伴'),
    );
    final imported = readWorkspaceBackup(encoded);
    expect(imported.documents.single.history.single.markdown, '原文');
    expect(imported.documents.single.confirmedSnapshot().markdown, '最终内容');
    expect(imported.companionName, '同伴');
    expect(imported.profile, isNull);
    expect(
      jsonDecode(utf8.decode(encoded))['workspace'],
      isNot(contains('profile')),
    );
    expect(
      () => readWorkspaceBackup(
        backupWorkspace(WorkspaceState(documents: [original, original])),
      ),
      throwsFormatException,
    );
    final diag = utf8.decode(
      localDiagnostics(WorkspaceState(documents: [original]), 'secret-host'),
    );
    expect(diag, isNot(contains('secret-host')));
    expect(diag, isNot(contains('私密标题')));
    expect(diag, isNot(contains('最终内容')));
    expect(jsonDecode(diag)['revisionCount'], 2);
  });
}
