// SPDX-License-Identifier: GPL-3.0-only
import 'package:perant_core/perant_core.dart';

import 'material_import.dart';

/// An extractive outline. Every nonempty source line appears once and can
/// be checked against the retained revision, including uncategorized lines.
String meetingOutline(List<MarkdownDocument> materials) {
  if (materials.isEmpty ||
      materials.length > 5 ||
      materials.map((d) => d.id).toSet().length != materials.length) {
    throw const FormatException('请选择 1 至 5 份不同的资料。');
  }
  final count = materials.fold(0, (n, d) => n + d.markdown.runes.length);
  if (count > materialCharacterLimit)
    throw const FormatException('所选资料合计超过 2 万字，请缩小范围。');
  final buckets = {
    for (final name in ['议题', '决策候选', '待办候选', '其他原文']) name: <String>[],
  };
  final sources = <String>[];
  for (var i = 0; i < materials.length; i++) {
    final doc = materials[i];
    final label = 'S${i + 1}';
    sources.add(
      '- $label · ${doc.title.replaceAll(RegExp(r'[\r\n]'), ' ')} · ${doc.id} · 版本 ${doc.revision}',
    );
    final lines = doc.markdown.split('\n');
    for (var j = 0; j < lines.length; j++) {
      final line = lines[j].trim();
      if (line.isEmpty) continue;
      final bucket =
          RegExp(
            r'^(?:[-*]\s*)?(?:\[[ xX]\]|待办|行动项|下一步|负责人|TODO\b)',
            caseSensitive: false,
          ).hasMatch(line)
          ? '待办候选'
          : RegExp(r'^(?:[-*]\s*)?(?:决策|决定|决议|结论|已同意)').hasMatch(line)
          ? '决策候选'
          : RegExp(r'^(?:#{1,6}\s+|议题|主题|讨论项)').hasMatch(line)
          ? '议题'
          : '其他原文';
      buckets[bucket]!.add('- [$label · 第 ${j + 1} 行] $line');
    }
  }
  if (buckets.values.every((b) => b.isEmpty))
    throw const FormatException('所选资料没有正文。');
  return [
    '# 会议纪要（待核对）',
    '按原文标记整理。请核对决策、负责人和截止日期，再确认版本。',
    for (final entry in buckets.entries.where((b) => b.value.isNotEmpty)) ...[
      '## ${entry.key}',
      entry.value.join('\n'),
    ],
    '## 引用资料',
    sources.join('\n'),
  ].join('\n\n');
}
