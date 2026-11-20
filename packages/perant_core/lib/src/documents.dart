// SPDX-License-Identifier: GPL-3.0-only

import 'authorization.dart';

enum DocumentFormat { markdown, docx, pdf, pptx, html }

final class DocumentVersion {
  DocumentVersion({
    required this.documentId,
    required this.revision,
    required this.markdown,
    required this.updatedAt,
  }) {
    if (documentId.trim().isEmpty || revision < 1) {
      throw ArgumentError('A document needs an ID and a positive revision.');
    }
  }

  final String documentId;
  final int revision;
  final String markdown;
  final DateTime updatedAt;

  SourceVersion get sourceVersion => SourceVersion(
        sourceId: documentId,
        version: revision.toString(),
      );
}

final class MarkdownDocument {
  MarkdownDocument({
    required String id,
    required this.title,
    required String markdown,
    required DateTime updatedAt,
    int revision = 1,
    this.confirmedRevision,
    this.confirmedAt,
    List<DocumentVersion> history = const [],
  })  : history = List.unmodifiable(history),
        currentVersion = DocumentVersion(
          documentId: id,
          revision: revision,
          markdown: markdown,
          updatedAt: updatedAt,
        ) {
    var lastRevision = 0;
    for (final version in history) {
      if (version.documentId != id ||
          version.revision <= lastRevision ||
          version.revision >= revision) {
        throw ArgumentError('Invalid document revision history.');
      }
      lastRevision = version.revision;
    }
    if (confirmedRevision != null && confirmedRevision != revision) {
      throw ArgumentError('Confirmation must refer to the current revision.');
    }
    if ((confirmedRevision == null) != (confirmedAt == null)) {
      throw ArgumentError(
          'Confirmation revision and time must appear together.');
    }
  }

  final String title;
  final List<DocumentVersion> history;
  final DocumentVersion currentVersion;
  final int? confirmedRevision;
  final DateTime? confirmedAt;

  String get id => currentVersion.documentId;
  String get markdown => currentVersion.markdown;
  int get revision => currentVersion.revision;
  DateTime get updatedAt => currentVersion.updatedAt;
  bool get isConfirmed => confirmedRevision == revision;

  MarkdownDocument edit(String value, {required DateTime at}) {
    if (value == markdown) return this;
    return MarkdownDocument(
      id: id,
      title: title,
      markdown: value,
      updatedAt: at,
      revision: revision + 1,
      history: [...history, currentVersion],
    );
  }

  MarkdownDocument confirm({required DateTime at}) => MarkdownDocument(
        id: id,
        title: title,
        markdown: markdown,
        updatedAt: updatedAt,
        revision: revision,
        confirmedRevision: revision,
        confirmedAt: at,
        history: history,
      );

  ConfirmedDocument confirmedSnapshot() {
    if (!isConfirmed) {
      throw StateError('Review and confirm this revision before exporting.');
    }
    return ConfirmedDocument._(
      documentId: id,
      title: title,
      revision: revision,
      markdown: markdown,
      confirmedAt: confirmedAt!,
    );
  }
}

/// Immutable export input. Later edits cannot silently alter this snapshot.
final class ConfirmedDocument {
  const ConfirmedDocument._({
    required this.documentId,
    required this.title,
    required this.revision,
    required this.markdown,
    required this.confirmedAt,
  });

  final String documentId;
  final String title;
  final int revision;
  final String markdown;
  final DateTime confirmedAt;
}

final class DocumentArtifact {
  DocumentArtifact({
    required this.id,
    required this.documentId,
    required this.documentRevision,
    required this.format,
    required this.uri,
    required this.createdAt,
    List<String> warnings = const [],
  }) : warnings = List.unmodifiable(warnings);

  final String id;
  final String documentId;
  final int documentRevision;
  final DocumentFormat format;
  final Uri uri;
  final DateTime createdAt;
  final List<String> warnings;
}

abstract interface class DocumentExporter {
  Future<DocumentArtifact> export(
    ConfirmedDocument document, {
    required DocumentFormat format,
  });
}
