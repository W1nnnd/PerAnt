// SPDX-License-Identifier: GPL-3.0-only
import 'package:perant_core/perant_core.dart';

import 'meeting_minutes.dart';
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
      if (event.finishReason == 'length')
        throw const FormatException('模型输出达到上限，未采用不完整的结果。请缩短材料重试。');
      complete = true;
    }
  }
  if (stopped() || !complete || result.toString().trim().isEmpty)
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
  final pieces = <({String label, String text})>[];
  final sources = <String>[];
  for (var i = 0; i < materials.length; i++) {
    final doc = materials[i], points = doc.markdown.runes.toList();
    sources.add(
      '- S${i + 1} · ${doc.title.replaceAll(RegExp(r'[\r\n]'), ' ')} · ${doc.id} · 版本 ${doc.revision}',
    );
    for (var start = 0; start < points.length; start += 480) {
      final end = (start + 480).clamp(0, points.length);
      final value = String.fromCharCodes(points.getRange(start, end));
      if (value.trim().isNotEmpty)
        pieces.add((label: 'S${i + 1} · 第 ${start + 1}–$end 字', text: value));
    }
  }
  return (model, id, stopped, progress) async {
    final journal = await openJournal?.call(model);
    var step = 0;
    Future<String> generateStep(String instruction, String source) async {
      if (stopped()) throw StateError('已停止。');
      final index = step++;
      if (journal != null && index < journal.completed.length) {
        progress(
          '继续上次纪要 · 复用第 ${index + 1}/${journal.completed.length} 个已完成步骤',
        );
        return journal.completed[index];
      }
      final output = await _generate(model, id, instruction, source, stopped);
      if (stopped()) throw StateError('已停止。');
      await journal?.append(index, output);
      return output;
    }

    final notes = <String>[];
    for (var i = 0; i < pieces.length; i++) {
      final piece = pieces[i];
      progress('归纳第 ${i + 1}/${pieces.length} 段 · ${piece.label}');
      final result = await generateStep(
        '你在整理会议材料。用不超过80个汉字归纳这一段的议题、已作决定、待办、负责人和期限。只写原文有据的内容，讨论与决定要区分。',
        piece.text,
      );
      notes.add(result);
    }
    var summaries = List.of(notes);
    var level = 0;
    while (summaries.length > 1) {
      final next = <String>[];
      level++;
      for (var i = 0; i < summaries.length; i += 3) {
        final group = summaries.skip(i).take(3).toList();
        progress('汇总第 $level 轮 · ${i ~/ 3 + 1}/${(summaries.length + 2) ~/ 3}');
        next.add(
          group.length == 1
              ? group.first
              : await generateStep(
                  '汇总这些会议摘记，不超过100个汉字。分别列出有依据的决策、待办和待确认事项，不补猜时间和负责人。',
                  group.join('\n\n'),
                ),
        );
      }
      summaries = next;
    }
    if (stopped()) throw StateError('已停止。');
    return [
      '# 会议纪要（模型草稿）',
      '## 综合摘要',
      summaries.single,
      '## 分段核对',
      for (var i = 0; i < pieces.length; i++)
        '### ${pieces[i].label}\n\n${notes[i]}',
      '## 引用资料',
      sources.join('\n'),
    ].join('\n\n');
  };
}
