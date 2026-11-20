// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

typedef MeetingQuote = ({
  int source,
  int first,
  int last,
  String text,
  bool partial,
});

final _boundaries = '。！？!?；;\n'.runes.toSet();

int meetingWindowEnd(List<int> points, int start) {
  final end = (start + 480).clamp(0, points.length);
  if (end == points.length) return end;
  // Prefer a complete sentence near the end. A lower bound on window size
  // keeps all 20,000 code points and their reductions within the journal limit.
  for (var i = end; i >= start + 432; i--) {
    if (_boundaries.contains(points[i - 1])) return i;
  }
  return end;
}

/// Keep exact Unicode offsets and source wording. Group adjacent sentences when
/// a single model window would otherwise contain too many tiny choices.
List<MeetingQuote> meetingQuotes(
  List<int> points,
  int source,
  int start,
  int end,
) {
  final ranges = <({int from, int to})>[];
  var from = start;
  for (var i = start; i < end; i++) {
    if (i + 1 == end || _boundaries.contains(points[i])) {
      if (String.fromCharCodes(points, from, i + 1).trim().isNotEmpty) {
        ranges.add((from: from, to: i + 1));
      }
      from = i + 1;
    }
  }
  const maxChoices = 8;
  final result = <MeetingQuote>[];
  for (var i = 0; i < ranges.length;) {
    final count = (ranges.length / maxChoices).ceil();
    final next = (i + count).clamp(0, ranges.length);
    var first = ranges[i].from, last = ranges[next - 1].to;
    while (first < last && String.fromCharCode(points[first]).trim().isEmpty) {
      first++;
    }
    while (first < last &&
        String.fromCharCode(points[last - 1]).trim().isEmpty) {
      last--;
    }
    result.add((
      source: source,
      first: first + 1,
      last: last,
      partial:
          (ranges[i].from == start &&
              start > 0 &&
              !_boundaries.contains(points[start - 1])) ||
          (ranges[next - 1].to == end &&
              end < points.length &&
              !_boundaries.contains(points[end - 1])),
      text: String.fromCharCodes(points, first, last),
    ));
    i = next;
  }
  return result;
}

class QuoteSelection {
  const QuoteSelection(this.indices, {this.fallback = false});
  final List<int> indices;
  final bool fallback;
  String get checkpoint => '${fallback ? "F" : "S"}:${indices.join(",")}';

  static List<int>? _parse(String text, int size, int limit) {
    if (!RegExp(r'^[0-9]+(?:\s*[,，]\s*[0-9]+)*$').hasMatch(text.trim()))
      return null;
    final items = text
        .trim()
        .split(RegExp(r'\s*[,，]\s*'))
        .map((s) => int.tryParse(s) ?? 0)
        .toList();
    if (items.length > limit ||
        items.toSet().length != items.length ||
        items.any((n) => n < 1 || n > size))
      return null;
    return items;
  }

  factory QuoteSelection.fromModel(String text, int size, int limit) {
    final values = _parse(text, size, limit);
    if (values != null) return QuoteSelection(values);
    // A malformed model answer is never copied to the document. Keep excerpts
    // in source order and disclose the fallback in the resulting draft.
    return QuoteSelection(
      List.generate(size.clamp(0, limit), (i) => i + 1),
      fallback: true,
    );
  }

  factory QuoteSelection.restore(String saved, int size, int limit) {
    final values = saved.length > 2
        ? _parse(saved.substring(2), size, limit)
        : null;
    if (values == null || !(saved.startsWith('S:') || saved.startsWith('F:'))) {
      throw const FormatException('纪要选句进度无效，请清除进度并用原资料重试。');
    }
    return QuoteSelection(values, fallback: saved.startsWith('F:'));
  }
}

String meetingChoiceInput(List<MeetingQuote> choices, {required bool summary}) {
  final limit = 600 ~/ choices.length;
  return jsonEncode([
    for (final q in choices)
      summary && q.text.runes.length > limit
          ? '${String.fromCharCodes(q.text.runes.take(limit))}…'
          : q.text,
  ]);
}

String formatMeetingQuote(MeetingQuote q) {
  final lines = q.text.split('\n').map((line) => '> $line').join('\n');
  return '[S${q.source} · 第 ${q.first}–${q.last} 字]${q.partial ? '（长句节选）' : ''}\n\n$lines';
}
