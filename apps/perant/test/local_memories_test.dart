// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:perant/src/data/portable_documents.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant_core/perant_core.dart';

void main() {
  final at = DateTime.utc(2026, 11, 20);
  const fact = '我喜欢按周整理资料。';
  test('extracts only explicit facts from user messages and confirmed documents; suppressions survive backup', () {
    final doc = MarkdownDocument(
      id: 'note',
      title: '周报',
      markdown: fact,
      updatedAt: at,
    );
    final state = WorkspaceState(
      documents: [doc],
      messages: [
        ChatEntry(
          id: 'user',
          role: ChatRole.user,
          text: '我喜欢用表格。\n我喜欢苹果吗？',
          createdAt: at,
        ),
        ChatEntry(
          id: 'ai',
          role: ChatRole.assistant,
          text: '我喜欢披萨。',
          createdAt: at,
        ),
      ],
    );
    void sync() =>
        state.memories = state.memories.reconcile(state.memorySources);
    sync();
    expect(state.memories.records.values.single.text, '我喜欢用表格。');
    state.documents[0] = doc.confirm(at: at);
    sync();
    final record = state.memories.records.values.singleWhere(
      (m) => m.text == fact,
    );
    expect(record.sources.single.version, '1');
    state.memories = state.memories.remove(record.id);
    state.documents[0] = doc.edit('$fact\n周报', at: at).confirm(at: at);
    sync();
    expect(state.memories.records.length, 1);
    final back = readWorkspaceBackup(backupWorkspace(state));
    back.memories = back.memories.reconcile(back.memorySources);
    expect(back.memories.suppressed, contains(record.id));
    expect(back.memories.records.length, 1);
    final legacy = jsonDecode(utf8.decode(backupWorkspace(state))) as Map;
    (legacy['workspace'] as Map).remove('memoryBook');
    expect(
      readWorkspaceBackup(utf8.encode(jsonEncode(legacy))).memories.records,
      isEmpty,
    );
  });
  test('manual edit preserves its source revision, deletion propagates even while stopped', () {
    final doc = MarkdownDocument(
      id: 'note',
      title: '周报',
      markdown: '$fact\n常用格式：表格',
      updatedAt: at,
    ).confirm(at: at);
    final state = WorkspaceState(documents: [doc]);
    var book = state.memories.reconcile(state.memorySources);
    final id = book.records.values.singleWhere((m) => m.text == fact).id;
    book = book.edit(id, '每周五整理资料。');
    state.documents[0] = doc
        .edit('$fact\n常用格式：表格\n常用格式：清单', at: at)
        .confirm(at: at);
    book = book.reconcile(state.memorySources);
    expect(book.records[id]!.sources.single.version, '1');
    expect(book.records[id]!.text, '每周五整理资料。');
    expect(book.records.length, 3);
    book = book.withEnabled(false);
    state.documents.clear();
    state.messages.add(
      ChatEntry(id: 'new', role: ChatRole.user, text: '我习惯早起。', createdAt: at),
    );
    book = book.reconcile(state.memorySources);
    expect(book.records.values.single.hasMissingSource, isTrue);
    expect(
      book.withEnabled(true).reconcile(state.memorySources).records.length,
      2,
    );
    state.memories = book;
    final restored = readWorkspaceBackup(backupWorkspace(state));
    expect(restored.memories.enabled, isFalse);
    expect(restored.memories.records[id]!.hasMissingSource, isTrue);
    expect(
      utf8.decode(localDiagnostics(state, 'android')),
      isNot(contains('每周五')),
    );
  });
}
