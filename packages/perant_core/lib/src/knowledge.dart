// SPDX-License-Identifier: GPL-3.0-only

import 'authorization.dart';

final class KnowledgeDocument {
  const KnowledgeDocument({
    required this.id,
    required this.title,
    required this.source,
    required this.text,
  });

  final String id;
  final String title;
  final SourceVersion source;
  final String text;
}

final class KnowledgeQuery {
  KnowledgeQuery({
    required this.text,
    this.limit = 10,
    this.includeMemories = true,
  }) {
    if (text.trim().isEmpty || limit < 1) {
      throw ArgumentError('A query needs text and a positive result limit.');
    }
  }

  final String text;
  final int limit;
  final bool includeMemories;
}

final class KnowledgeMatch {
  const KnowledgeMatch({
    required this.source,
    required this.title,
    required this.excerpt,
    required this.score,
    required this.locator,
  });

  final SourceVersion source;
  final String title;
  final String excerpt;
  final double score;
  final String locator;
}

final class MemoryRecord {
  MemoryRecord({
    required this.id,
    required this.text,
    required this.createdAt,
    required List<SourceVersion> sources,
    this.isUserEdited = false,
    this.hasMissingSource = false,
  }) : sources = List.unmodifiable(sources);

  final String id;
  final String text;
  final DateTime createdAt;
  final List<SourceVersion> sources;
  final bool isUserEdited;
  final bool hasMissingSource;
}

/// A persistent adapter must propagate document deletions to chunks, vectors
/// and automatic memories, while recording memory-deletion suppression markers.
abstract interface class KnowledgeStore {
  Future<void> saveDocument(KnowledgeDocument document);
  Future<void> deleteDocument(String documentId);
  Future<List<KnowledgeMatch>> search(KnowledgeQuery query);
  Future<List<MemoryRecord>> listMemories();
  Future<void> saveMemory(MemoryRecord memory);
  Future<void> deleteMemory(String memoryId);
}
