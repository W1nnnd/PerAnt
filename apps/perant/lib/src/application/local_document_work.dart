// SPDX-License-Identifier: GPL-3.0-only
import 'package:perant_core/perant_core.dart';

import 'meeting_minutes.dart';
import 'meeting_evidence.dart';
import 'device_inference.dart';
import 'workspace_controller.dart';

typedef LocalDocumentWork = Future<String> Function(
  LocalInference model,
  String requestId,
  bool Function() stopped,
  void Function(String) progress,
);

Future<String> _generate(
  LocalInference model,
  String id,
  String instruction,
  String source,
  bool Function() stopped, {
  int limit = 256,
  bool allowInvalidSelection = false,
}) async {
  if (stopped()) throw StateError('已停止。');
  final result = StringBuffer();
  bool complete = false;
  await for (final event in model.generate(
    ModelRequest(
      id: id,
      taskId: id,
      maxOutputTokens: limit,
      messages: [
        ModelMessage(role: ModelRole.system, content: instruction),
        ModelMessage(role: ModelRole.user, content: source),
      ],
    ),
  )) {
    if (stopped()) throw StateError('已停止。');
    if (event.type == ModelEventType.textDelta) result.write(event.text);
    if (event.type == ModelEventType.completed) {
      if (event.finishReason == 'length') {
        if (allowInvalidSelection && !stopped()) return '';
        throw const FormatException('模型输出达到上限，未采用不完整的结果。请缩短材料重试。');
      }
      complete = true;
    }
  }
  if (stopped() ||
      !complete ||
      (!allowInvalidSelection && result.toString().trim().isEmpty))
    throw const FormatException('没有收到完整结果，草稿未改动。');
  return result.toString().trim();
}

LocalDocumentWork reviseSelection(String original) {
  if (original.trim().isEmpty || original.runes.length > 320)
    throw const FormatException('请选择 1 至 320 字需要润色的原文。');
  return (model, id, stopped, progress) async {
    progress('正在润色所选原文');
    return _generate(
      model,
      id,
      '你是中文校对员。只润色下面文字的语序和标点，保留事实、数字、姓名、Markdown 和原意。只返回修改后的文字。',
      original,
      stopped,
      limit: 512,
    );
  };
}

typedef MeetingJournal = ({
  List<String> completed,
  Future<void> Function(int, String) append,
});

LocalDocumentWork recoverableMeeting(
  WorkspaceController controller,
  List<MarkdownDocument> materials,
  void Function(String) onReady,
) => synthesizeMeeting(
  materials,
  openJournal: (engine) async {
    if (engine is! DeviceInference || engine.loadedModel == null)
      throw StateError('请先加载所选模型。');
    final spec = engine.loadedModel!;
    var progress = await controller.beginMeeting(
      materials,
      spec.id,
      spec.sha,
      engine.contextSize,
    );
    onReady(progress.id);
    return (
      completed: progress.steps,
      append: (int index, String output) async {
        progress = await controller.saveMeetingStep(progress, index, output);
      },
    );
  },
);

LocalDocumentWork synthesizeMeeting(
  List<MarkdownDocument> materials, {
  Future<MeetingJournal> Function(LocalInference)? openJournal,
}) {
  checkMeetingMaterials(materials);
  final pieces = <({String label, List<MeetingQuote> choices})>[];
  final sources = <String>[];
  for (var i = 0; i < materials.length; i++) {
    final doc = materials[i], points = doc.markdown.runes.toList();
    sources.add(
      '- S${i + 1} · ${doc.title.replaceAll(RegExp(r'[\r\n]'), ' ')} · ${doc.id} · 版本 ${doc.revision}',
    );
    for (var start = 0; start < points.length;) {
      final end = meetingWindowEnd(points, start);
      final choices = meetingQuotes(points, i + 1, start, end);
      if (choices.isNotEmpty)
        pieces.add((
          label: 'S${i + 1} · 第 ${start + 1}–$end 字',
          choices: choices,
        ));
      start = end;
    }
  }
  return (model, id, stopped, progress) async {
    final journal = await openJournal?.call(model);
    var step = 0;
    var usedFallback = false;
    Future<List<MeetingQuote>> select(
      List<MeetingQuote> choices, {
      bool summary = false,
    }) async {
      if (stopped()) throw StateError('已停止。');
      final index = step++;
      final limit = summary ? 4 : 3;
      final QuoteSelection selection;
      if (journal != null && index < journal.completed.length) {
        progress(
          '继续上次纪要 · 复用第 ${index + 1}/${journal.completed.length} 个已完成步骤',
        );
        selection = QuoteSelection.restore(
          journal.completed[index],
          choices.length,
          limit,
        );
      } else {
        final output = await _generate(
          model,
          id,
          '你在整理会议材料。下面是按原文顺序排列的字符串数组。'
          '优先选择有具体依据的决定、待办和待确认事项，也保留明确的否定。'
          '从 1 开始编号，选择最多 $limit 项。只返回编号，用逗号分隔，例如 1,2。不要生成正文。',
          meetingChoiceInput(choices, summary: summary),
          stopped,
          limit: 64,
          allowInvalidSelection: true,
        );
        if (stopped()) throw StateError('已停止。');
        selection = QuoteSelection.fromModel(output, choices.length, limit);
        await journal?.append(index, selection.checkpoint);
      }
      usedFallback |= selection.fallback;
      return [for (final n in selection.indices) choices[n - 1]];
    }

    final notes = <List<MeetingQuote>>[];
    for (var i = 0; i < pieces.length; i++) {
      final piece = pieces[i];
      progress('归纳第 ${i + 1}/${pieces.length} 段 · ${piece.label}');
      notes.add(await select(piece.choices));
    }
    var summaries = List.of(notes);
    var level = 0;
    while (summaries.length > 1) {
      final next = <List<MeetingQuote>>[];
      level++;
      for (var i = 0; i < summaries.length; i += 3) {
        final group = summaries.skip(i).take(3).toList();
        progress('汇总第 $level 轮 · ${i ~/ 3 + 1}/${(summaries.length + 2) ~/ 3}');
        final seen = <(int, String)>{};
        next.add(
          group.length == 1
              ? group.first
              : await select([
                  for (final batch in group)
                    for (final q in batch)
                      if (seen.add((q.source, q.text))) q,
                ], summary: true),
        );
      }
      summaries = next;
    }
    if (stopped()) throw StateError('已停止。');
    return [
      '# 会议纪要（待核对）',
      '## 重点原文',
      for (final q in summaries.single) formatMeetingQuote(q),
      if (usedFallback) '部分步骤未取得有效选句，已按资料顺序保留原文。',
      '## 分段核对',
      for (var i = 0; i < pieces.length; i++)
        '### ${pieces[i].label}\n\n${notes[i].map(formatMeetingQuote).join('\n\n')}',
      '## 引用资料',
      sources.join('\n'),
    ].join('\n\n');
  };
}
