// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:perant_core/perant_core.dart';

typedef MeetingSource = ({
  String id,
  int revision,
  String title,
  String updated,
});

/// Private recovery data for one unfinished local meeting. The recipe version
/// also pins chunk sizes, traversal order and the map/reduce instructions.
class MeetingProgress {
  MeetingProgress._(
    this.id,
    this.fingerprint,
    this.modelId,
    this.contextSize,
    List<MeetingSource> sources,
    List<String> steps,
    this.recipeVersion,
  ) : sources = List.unmodifiable(sources),
      steps = List.unmodifiable(steps);
  final String id, fingerprint, modelId;
  final int contextSize;
  final List<MeetingSource> sources;
  final List<String> steps;
  static const recipe = 2;
  final int recipeVersion;
  bool get needsNewSelection => recipeVersion < recipe;
  factory MeetingProgress.start(
    String id,
    List<MarkdownDocument> docs,
    String modelId,
    String modelSha,
    int contextSize, {
    int recipeVersion = recipe,
  }) {
    final sources = [
      for (final d in docs)
        (
          id: d.id,
          revision: d.revision,
          title: d.title,
          updated: d.updatedAt.toUtc().toIso8601String(),
        ),
    ];
    final digest = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              recipeVersion,
              modelId,
              modelSha,
              contextSize,
              for (final d in docs) [d.id, d.title, d.revision, d.markdown],
            ]),
          ),
        )
        .toString();
    return MeetingProgress._(
      id,
      digest,
      modelId,
      contextSize,
      sources,
      [],
      recipeVersion,
    );
  }
  bool isCurrent(List<MarkdownDocument> docs) => sources.every(
    (s) => docs.any(
      (d) =>
          s.id == d.id &&
          s.revision == d.revision &&
          s.title == d.title &&
          s.updated == d.updatedAt.toUtc().toIso8601String(),
    ),
  );
  MeetingProgress append(String output) {
    if (needsNewSelection ||
        steps.length >= 80 ||
        output.trim().isEmpty ||
        output.length > 8192 ||
        steps.fold<int>(output.length, (n, s) => n + s.length) > 65536)
      throw const FormatException('纪要进度超过可恢复范围，已保留之前完成的步骤。');
    return MeetingProgress._(id, fingerprint, modelId, contextSize, sources, [
      ...steps,
      output,
    ], recipeVersion);
  }

  Map<String, Object?> toJson() => {
    'recipe': recipeVersion,
    'id': id,
    'fingerprint': fingerprint,
    'model': modelId,
    'context': contextSize,
    'sources': [
      for (final s in sources)
        {
          'id': s.id,
          'revision': s.revision,
          'title': s.title,
          'updated': s.updated,
        },
    ],
    'steps': steps,
  };
  static MeetingProgress? read(Object? value) {
    if (value is! Map || ![1, recipe].contains(value['recipe'])) return null;
    try {
      final rows = value['sources'] as List;
      final sources = [
        for (final s in rows.cast<Map>())
          (
            id: s['id'] as String,
            revision: s['revision'] as int,
            title: s['title'] as String,
            updated: s['updated'] as String,
          ),
      ];
      final fingerprint = value['fingerprint'] as String;
      final id = value['id'] as String,
          model = value['model'] as String,
          context = value['context'] as int;
      final steps = (value['steps'] as List).cast<String>();
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint) ||
          id.isEmpty ||
          model.isEmpty ||
          ![2048, 4096].contains(context) ||
          sources.isEmpty ||
          sources.length > 5 ||
          sources.map((s) => s.id).toSet().length != sources.length ||
          steps.length > 80 ||
          steps.any((s) => s.trim().isEmpty || s.length > 8192) ||
          steps.fold<int>(0, (n, s) => n + s.length) > 65536)
        return null;
      final version = value['recipe'] as int;
      return MeetingProgress._(
        id,
        fingerprint,
        model,
        context,
        sources,
        version == 1 ? [] : steps,
        version,
      );
    } on TypeError {
      return null;
    }
  }
}
