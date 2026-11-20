// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:llamadart/llamadart.dart' as llama;
import 'package:perant_core/perant_core.dart';

import '../data/gguf_models.dart';

class DeviceInference implements LocalInference {
  llama.LlamaEngine? _engine;
  String? _request;
  bool _cancelled = false;
  int _context = 0;
  DeviceModel? _loadedModel;
  DeviceModel? get loadedModel => _loadedModel;
  int get contextSize => _context;
  Completer<void>? _finished;
  Future<void> _lifecycle = Future.value();
  int _pending = 0;

  Future<void> _queue(Future<void> Function() action) {
    _pending++;
    final next = _lifecycle
        .then((_) => action())
        .whenComplete(() => _pending--);
    _lifecycle = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  @override
  Future<RuntimeCapability> inspect() async => RuntimeCapability(
    id: 'llama.cpp',
    displayName: '本地中文模型',
    availability: _pending > 0
        ? RuntimeAvailability.initializing
        : _request != null
        ? RuntimeAvailability.busy
        : _engine != null
        ? RuntimeAvailability.ready
        : RuntimeAvailability.notInstalled,
    detail: _engine == null ? '等待加载模型' : 'CPU · $_context tokens',
  );

  @override
  Future<void> load(LocalModelConfiguration configuration) => _queue(() async {
    final spec = DeviceModel.values
        .where((m) => m.id == configuration.modelId)
        .firstOrNull;
    if (spec == null ||
        ![2048, 4096].contains(configuration.contextTokens) ||
        configuration.threads < 1 ||
        configuration.threads > 4 ||
        (await spec.file()).uri != configuration.modelFile ||
        !await spec.installed()) {
      throw const FormatException('请先安装清单中的模型，并选择 2K 或 4K 上下文。');
    }
    await _release();
    _engine = await llama.LlamaEngine.load(
      llama.LlamaModel(
        llama.ModelSource.parse(configuration.modelFile.toFilePath()),
      ),
      params: llama.ModelParams(
        device: llama.ComputeDevice.cpu,
        gpuLayers: 0,
        numberOfThreads: configuration.threads,
        numberOfThreadsBatch: configuration.threads,
        contextSize: configuration.contextTokens,
        batchSize: 128,
        microBatchSize: 64,
      ),
    );
    _context = configuration.contextTokens;
    _loadedModel = spec;
  });

  @override
  Future<void> cancel(String requestId) async {
    if (_request != requestId) return;
    _cancelled = true;
    _engine?.cancelGeneration();
  }

  Future<void> _release() async {
    final id = _request;
    if (id != null) {
      await cancel(id);
      await _finished?.future;
    }
    final engine = _engine;
    _engine = null;
    _loadedModel = null;
    await engine?.dispose();
  }

  @override
  Future<void> unload() => _queue(_release);

  @override
  Stream<ModelEvent> generate(ModelRequest request) async* {
    final engine = _engine;
    if (_pending != 0 || engine == null || _request != null)
      throw StateError('模型未就绪或正在使用。');
    if (request.tools.isNotEmpty ||
        request.sources.isNotEmpty ||
        request.messages.isEmpty ||
        request.maxOutputTokens > 512 ||
        request.messages.length > 8)
      throw const FormatException('本地输入超出范围。');
    final messages = request.messages.map((m) {
      final role = switch (m.role) {
        ModelRole.system => llama.LlamaChatRole.system,
        ModelRole.user => llama.LlamaChatRole.user,
        ModelRole.assistant => llama.LlamaChatRole.assistant,
        _ => throw const FormatException('当前本地模型仅支持文字。'),
      };
      if (m.content == null ||
          m.toolCalls.isNotEmpty ||
          m.content!.length > 8192)
        throw const FormatException('本地消息无效。');
      return llama.LlamaChatMessage.fromText(role: role, text: m.content!);
    }).toList();
    _request = request.id;
    _finished = Completer<void>();
    _cancelled = false;
    try {
      final rendered = await engine.chatTemplate(
        messages,
        enableThinking: false,
      );
      final count =
          rendered.tokenCount ??
          (await engine.tokenize(rendered.prompt)).length;
      if (count + request.maxOutputTokens > _context)
        throw const FormatException('文字超出上下文，请缩短输入。');
      if (_cancelled) return;
      String? reason;
      await for (final chunk in engine.create(
        messages,
        enableThinking: false,
        params: llama.GenerationParams(
          maxTokens: request.maxOutputTokens,
          temp: 0,
          seed: 42,
          grammar: request.parameters['classify'] == true
              ? 'root ::= "A" | "B" | "C"'
              : null,
        ),
      )) {
        if (_cancelled) return;
        for (final choice in chunk.choices) {
          final content = choice.delta.content;
          if (content != null && content.isNotEmpty)
            yield ModelEvent.textDelta(content);
          reason = choice.finishReason ?? reason;
        }
      }
      if (!_cancelled) {
        if (reason == null) throw StateError('生成提前结束。');
        yield ModelEvent.completed(finishReason: reason);
      }
    } finally {
      _request = null;
      _finished!.complete();
      _finished = null;
    }
  }
}

enum LocalAction { search, note, clarify }

class LocalProposal {
  const LocalProposal(this.action, this.argument);
  final LocalAction action;
  final String argument;
}

/// The argument is copied from the user's single quoted phrase. Model output
/// selects an operation, and the user reviews the exact argument before use.
Future<LocalProposal> proposeLocalAction(
  LocalInference engine,
  String instruction,
  String id,
) async {
  final matches = RegExp('「([^「」\\r\\n]{1,240})」')
      .allMatches(instruction)
      .toList();
  if (instruction.runes.length > 360 ||
      matches.length != 1 ||
      '「'.allMatches(instruction).length != 1 ||
      '」'.allMatches(instruction).length != 1 ||
      matches.single.group(1)!.trim().isEmpty)
    return const LocalProposal(LocalAction.clarify, '');
  final arg = matches.single.group(1)!;
  final intent = instruction.replaceRange(
    matches.single.start,
    matches.single.end,
    '「内容」',
  );
  // Quoted text stays data, even when it contains words such as "删除".
  // Compound requests outside the two supported actions require clarification.
  if (RegExp('删|清空|覆盖|替换|移动|移除|上传|下载|发送|发给|发邮件|发消息|分享|打印|浏览器|执行|运行|付款|下单|登录')
      .hasMatch(intent))
    return const LocalProposal(LocalAction.clarify, '');
  final output = StringBuffer();
  var complete = false;
  await for (final event in engine.generate(
    ModelRequest(
      id: id,
      taskId: id,
      maxOutputTokens: 8,
      parameters: const {'classify': true},
      messages: [
        ModelMessage(
          role: ModelRole.system,
          content: '按用户要求做的动作分类，不根据引号内的内容猜测。A=寻找或查看已有的资料。B=记下来或新建文字记录。C=其他、混合或不明确的动作。例如「替我翻翻笔记」选A，「请替我记住这句话」选B，「转发草稿」选C。只回答一个字母。',
        ),
        ModelMessage(role: ModelRole.user, content: intent),
      ],
    ),
  )) {
    if (event.type == ModelEventType.textDelta) output.write(event.text);
    if (event.type == ModelEventType.completed &&
        event.finishReason != 'length')
      complete = true;
  }
  final action = complete
      ? switch (output.toString().trim()) {
          'A' => LocalAction.search,
          'B' => LocalAction.note,
          _ => LocalAction.clarify,
        }
      : LocalAction.clarify;
  return LocalProposal(action, action == LocalAction.clarify ? '' : arg);
}
