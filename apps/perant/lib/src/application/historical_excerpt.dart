// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:perant_core/perant_core.dart';

import '../data/library_search.dart';
import '../data/workspace_state.dart';

class HistoricalExcerpt {
  const HistoricalExcerpt._(this.source, this.title, this.offset, this.text);
  final SourceVersion source;
  final String title;
  final int offset;
  final String text;
  static HistoricalExcerpt? passage(MarkdownDocument doc, LibraryHit hit) {
    if (doc.id != hit.documentId ||
        doc.revision != hit.revision ||
        hit.offset < 0 ||
        hit.offset > doc.markdown.length)
      return null;
    var start = (hit.offset - 32).clamp(0, doc.markdown.length);
    if (start > 0 &&
        start < doc.markdown.length &&
        doc.markdown.codeUnitAt(start) & 0xfc00 == 0xdc00)
      start--;
    final snippet = String.fromCharCodes(
      doc.markdown.substring(start).runes.take(400),
    );
    if (snippet.trim().isEmpty) return null;
    return HistoricalExcerpt._(
      SourceVersion(
        sourceId: 'doc:' + doc.id,
        version: doc.revision.toString(),
      ),
      doc.title,
      start,
      snippet,
    );
  }

  static HistoricalExcerpt memory(MemoryRecord m) => HistoricalExcerpt._(
    SourceVersion(
      sourceId: 'memory:' + m.id,
      version: sha256
          .convert(
            utf8.encode(
              jsonEncode([
                m.text,
                m.sources.map((s) => s.toJson()).toList(),
                m.hasMissingSource,
              ]),
            ),
          )
          .toString(),
    ),
    '长期记忆',
    0,
    m.text,
  );
  bool matches(WorkspaceState state) {
    if (source.sourceId.startsWith('doc:')) {
      final id = source.sourceId.substring(4);
      final doc = state.documents.where((d) => d.id == id).firstOrNull;
      return doc != null &&
          doc.revision.toString() == source.version &&
          doc.title == title &&
          offset >= 0 &&
          offset <= doc.markdown.length &&
          doc.markdown.startsWith(text, offset);
    }
    final m =
        state.memories.records[source.sourceId.substring('memory:'.length)];
    return m != null && memory(m).source == source && m.text == text;
  }

  static void verify(List<HistoricalExcerpt> excerpts, WorkspaceState state) {
    if (excerpts.length > 5 ||
        excerpts.map((e) => (e.source, e.offset)).toSet().length !=
            excerpts.length ||
        excerpts.any((e) => !e.matches(state)) ||
        excerpts.fold<int>(0, (n, e) => n + e.text.runes.length) > 2000)
      throw StateError('引用资料已变化或超出范围，请重新选择。');
  }

  Map<String, Object?> toPayload(int n) => {
    'citation': 'S$n',
    'title': String.fromCharCodes(title.runes.take(80)),
    'excerpt': text,
  };
}
