// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:perant_core/perant_core.dart';

typedef MemoryEvidence = ({
  String id,
  int revision,
  String text,
  DateTime at,
  bool confirmed,
});

/// A record belongs to one source. Two corroborating sources remain separately
/// inspectable and deleting one never removes the other.
class LocalMemoryBook {
  LocalMemoryBook({
    this.enabled = true,
    Map<String, MemoryRecord> records = const {},
    Set<String> suppressed = const {},
    Map<String, int> scanned = const {},
  }) : records = Map.unmodifiable(records),
       suppressed = Set.unmodifiable(suppressed),
       _scanned = Map.unmodifiable(scanned);
  final bool enabled;
  final Map<String, MemoryRecord> records;
  final Set<String> suppressed;
  final Map<String, int> _scanned;
  static final _fact = RegExp(
    r'^(?:[-*]\s*)?(?:我(?:更?喜欢|的偏好是|(?:更)?习惯|通常在|的工作时间是)|(?:个人偏好|工作习惯|长期约定|常用格式)[：:])\s*[^？?]+$',
  );
  static final _digest = RegExp(r'^[a-f0-9]{64}$');

  LocalMemoryBook reconcile(Iterable<MemoryEvidence> sources) {
    final pending = {...records};
    final scans = <String, int>{};
    final present = <String>{};
    for (final source in sources) {
      present.add(source.id);
      if (!source.confirmed || !enabled) continue;
      scans[source.id] = source.revision;
      if (_scanned[source.id] == source.revision) continue;
      final facts = <String>{};
      // Whole declarative lines only. Oversized prose is never truncated into a fact.
      for (final raw in const LineSplitter().convert(source.text)) {
        final line = raw.trim();
        if (line.isEmpty ||
            line.length > 320 ||
            line.runes.length > 160 ||
            !_fact.hasMatch(line))
          continue;
        final id = sha256
            .convert(utf8.encode(jsonEncode([source.id, line])))
            .toString();
        facts.add(id);
        if (suppressed.contains(id)) continue;
        final old = pending[id];
        if (old?.isUserEdited == true) continue;
        pending[id] = MemoryRecord(
          id: id,
          text: line,
          createdAt: old?.createdAt ?? source.at,
          sources: [
            SourceVersion(
              sourceId: source.id,
              version: source.revision.toString(),
            ),
          ],
        );
      }
      pending.removeWhere(
        (id, r) =>
            r.sources.single.sourceId == source.id &&
            !r.isUserEdited &&
            !facts.contains(id),
      );
    }
    for (final r in pending.values.toList()) {
      final missing = !present.contains(r.sources.single.sourceId);
      if (missing && !r.isUserEdited) {
        pending.remove(r.id);
        continue;
      }
      if (missing != r.hasMissingSource)
        pending[r.id] = MemoryRecord(
          id: r.id,
          text: r.text,
          createdAt: r.createdAt,
          sources: r.sources,
          isUserEdited: r.isUserEdited,
          hasMissingSource: missing,
        );
    }
    return LocalMemoryBook(
      enabled: enabled,
      records: pending,
      suppressed: suppressed,
      scanned: scans,
    );
  }

  LocalMemoryBook withEnabled(bool value) =>
      LocalMemoryBook(enabled: value, records: records, suppressed: suppressed);
  LocalMemoryBook edit(String id, String text) {
    final record = records[id];
    final value = text.trim();
    if (record == null || value.isEmpty || value.runes.length > 160)
      throw const FormatException('记忆需要 1–160 个字符。');
    return LocalMemoryBook(
      enabled: enabled,
      records: {
        ...records,
        id: MemoryRecord(
          id: id,
          text: value,
          createdAt: record.createdAt,
          sources: record.sources,
          isUserEdited: true,
          hasMissingSource: record.hasMissingSource,
        ),
      },
      suppressed: suppressed,
      scanned: _scanned,
    );
  }

  LocalMemoryBook remove(String id) {
    if (!records.containsKey(id)) throw StateError('记忆已变化。');
    return LocalMemoryBook(
      enabled: enabled,
      records: {...records}..remove(id),
      suppressed: {...suppressed, id},
      scanned: _scanned,
    );
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'suppressed': suppressed.toList(),
    'records': [
      for (final r in records.values)
        {
          'id': r.id,
          'text': r.text,
          'createdAt': r.createdAt.toUtc().toIso8601String(),
          'source': r.sources.single.toJson(),
          'edited': r.isUserEdited,
          'missing': r.hasMissingSource,
        },
    ],
  };
  factory LocalMemoryBook.fromJson(Map<String, Object?> data) {
    final records = <String, MemoryRecord>{};
    final suppressed = (data['suppressed'] as List).cast<String>().toSet();
    if (suppressed.any((id) => !_digest.hasMatch(id)))
      throw const FormatException('记忆删除记录无效。');
    for (final row in (data['records'] as List).cast<Map>()) {
      final id = row['id'] as String, text = row['text'] as String;
      final source = SourceVersion.fromJson(
        Map<String, Object?>.from(row['source'] as Map),
      );
      if (!_digest.hasMatch(id) ||
          records.containsKey(id) ||
          suppressed.contains(id) ||
          text.trim().isEmpty ||
          text.runes.length > 160 ||
          !RegExp(r'^(?:doc|msg):.+$').hasMatch(source.sourceId) ||
          (int.tryParse(source.version) ?? 0) < 1)
        throw const FormatException('记忆或来源版本无效。');
      records[id] = MemoryRecord(
        id: id,
        text: text,
        createdAt: DateTime.parse(row['createdAt'] as String),
        sources: [source],
        isUserEdited: row['edited'] as bool,
        hasMissingSource: row['missing'] as bool,
      );
    }
    return LocalMemoryBook(
      enabled: data['enabled'] as bool,
      records: records,
      suppressed: suppressed,
    );
  }
}
