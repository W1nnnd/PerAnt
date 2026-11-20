// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perant_core/perant_core.dart';

import '../application/device_inference.dart';
import '../application/local_document_work.dart';
import '../application/workspace_controller.dart';
import '../data/gguf_models.dart';
import '../data/library_search.dart';
import 'document_editor.dart';
import 'install_storage.dart';

class LocalModelScreen extends StatefulWidget {
  const LocalModelScreen({
    super.key,
    required this.controller,
    this.work,
    this.title = '本地中文模型',
  });
  final WorkspaceController controller;
  final LocalDocumentWork? work;
  final String title;
  @override
  State<LocalModelScreen> createState() => _LocalModelScreenState();
}

class _LocalModelScreenState extends State<LocalModelScreen>
    with WidgetsBindingObserver {
  final runtime = DeviceInference();
  final question = TextEditingController();
  DeviceModel model = DeviceModel.small;
  int contextSize = 2048, received = 0;
  bool busy = false, installed = false, loaded = false, stopped = false;
  String message = '', reply = '';
  String? requestId;
  bool runningPython = false;
  LocalProposal? proposal;
  List<LibraryHit> hits = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final target = model;
    try {
      final found = await target.installed();
      if (mounted && model == target) setState(() => installed = found);
    } catch (_) {
      if (mounted) setState(() => message = '模型目录读取失败。');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached) &&
        (loaded || requestId != null)) {
      stopped = true;
      setState(() {
        loaded = false;
        proposal = null;
        message = '已释放模型，回到前台可重新加载。';
      });
      unawaited(runtime.unload());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    stopped = true;
    if (runningPython) widget.controller.cancelActiveTask();
    unawaited(runtime.unload());
    question.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (busy) return;
    setState(() {
      busy = true;
      stopped = false;
      message = '';
    });
    try {
      await operation();
    } on FormatException catch (e) {
      if (mounted) setState(() => message = e.message);
    } catch (_) {
      if (mounted)
        setState(
          () => message = stopped ? '已停止。' : '操作失败。请检查模型文件、可用空间或缩短输入后重试。',
        );
    } finally {
      if (mounted)
        setState(() {
          busy = false;
          requestId = null;
        });
    }
  }

  Future<void> _install(bool fromFile) => _run(() async {
    final spec = model;
    received = 0;
    void progress(int n) {
      if (mounted && (n == spec.bytes || n - received >= 1048576))
        setState(() => received = n);
    }

    if (fromFile) {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'GGUF',
            extensions: ['gguf'],
            mimeTypes: ['application/octet-stream'],
            uniformTypeIdentifiers: ['public.data'],
          ),
        ],
      );
      if (file == null || !mounted) return;
      await spec.install(
        file.openRead(),
        availableBytes: widget.controller.bridge.availableStorageBytes,
        stopped: () => stopped,
        progress: progress,
      );
    } else {
      await spec.download(
        stopped: () => stopped,
        progress: progress,
        availableBytes: widget.controller.bridge.availableStorageBytes,
      );
    }
    if (mounted)
      setState(() {
        installed = true;
        message = '文件已通过 SHA-256 校验。';
      });
  });

  Future<void> _load() => _run(() async {
    requestId = 'load';
    await runtime.load(
      LocalModelConfiguration(
        modelId: model.id,
        modelFile: (await model.file()).uri,
        contextTokens: contextSize,
      ),
    );
    if (!mounted || stopped) {
      await runtime.unload();
      return;
    }
    setState(() {
      loaded = true;
      message = '模型已加载，可以离线使用。';
    });
  });

  Future<void> _ask(bool command) => _run(() async {
    final input = question.text.trim();
    if (input.isEmpty) return;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    setState(() {
      requestId = id;
      reply = '';
      proposal = null;
      hits = [];
    });
    if (command) {
      final result = await proposeLocalAction(runtime, input, id);
      if (!mounted || stopped) return;
      setState(() {
        proposal = result;
        message = result.action == LocalAction.clarify
            ? '请说明是查资料还是建笔记，并用「」标出关键词或笔记原文。'
            : '';
      });
      return;
    }
    var done = false;
    await for (final event in runtime.generate(
      ModelRequest(
        id: id,
        taskId: id,
        maxOutputTokens: 256,
        messages: [
          ModelMessage(role: ModelRole.system, content: '用简洁中文回答用户这次提问。'),
          ModelMessage(role: ModelRole.user, content: input),
        ],
      ),
    )) {
      if (!mounted || stopped) continue;
      if (event.type == ModelEventType.textDelta)
        setState(() => reply += event.text!);
      if (event.type == ModelEventType.completed) {
        done = true;
        if (event.finishReason == 'length')
          setState(() => message = '回答达到本轮输出上限。');
      }
    }
    if (mounted && !done && stopped) setState(() => message = '已停止生成。');
  });

  Future<MarkdownDocument?> _pythonNote(String value) async {
    runningPython = true;
    try {
      return await widget.controller.generateLocalMarkdown(
        title: '本地笔记',
        text: value,
      );
    } finally {
      runningPython = false;
    }
  }

  Future<void> _apply({bool usePython = false}) => _run(() async {
    final selected = proposal;
    if (selected == null) return;
    if (selected.action == LocalAction.search) {
      final store = widget.controller.persistence;
      if (store is! PassageSearch) throw const FormatException('当前工作区不支持资料检索。');
      final found = await (store as PassageSearch).searchPassages(
        selected.argument,
      );
      if (mounted)
        setState(() {
          hits = found;
          proposal = null;
          message = '找到 ${found.length} 个片段';
        });
    } else if (selected.action == LocalAction.note) {
      await runtime.unload();
      if (!mounted) return;
      setState(() => loaded = false);
      final doc = usePython
          ? await _pythonNote(selected.argument)
          : await widget.controller.createDocument(
              title: '本地笔记',
              markdown: selected.argument,
            );
      if (!mounted) return;
      if (doc == null)
        throw FormatException(widget.controller.error ?? '本地整理未完成。');
      setState(() {
        proposal = null;
        message = '笔记草稿已保存。';
      });
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) =>
              DocumentEditor(controller: widget.controller, document: doc),
        ),
      );
    }
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        DropdownButtonFormField<DeviceModel>(
          isExpanded: true,
          initialValue: model,
          decoration: const InputDecoration(labelText: '模型'),
          items: [
            for (final spec in DeviceModel.values)
              DropdownMenuItem(
                value: spec,
                child: Text(
                  '${spec.id} · ${(spec.bytes / 1e6).round()} MB',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: busy || loaded
              ? null
              : (value) {
                  if (value != null) {
                    setState(() {
                      model = value;
                      installed = false;
                      received = 0;
                      message = '';
                    });
                    unawaited(_refresh());
                  }
                },
        ),
        DropdownButtonFormField<int>(
          isExpanded: true,
          initialValue: contextSize,
          decoration: const InputDecoration(labelText: '上下文'),
          items: [
            for (final n in [2048, 4096])
              DropdownMenuItem(value: n, child: Text('$n tokens')),
          ],
          onChanged: busy || loaded
              ? null
              : (value) {
                  if (value != null) setState(() => contextSize = value);
                },
        ),
        const SizedBox(height: 12),
        if (!installed) ...[
          InstallStorage(
            key: ValueKey(model),
            bridge: widget.controller.bridge,
            estimate:
                '完整模型需 ${(model.bytes / 1e6).ceil()} MB 存储空间。下载可从断点继续；选择已有文件时仍需复制到应用目录。',
          ),
          FilledButton(
            onPressed: busy ? null : () => _install(false),
            child: Text('下载 ${model.name}'),
          ),
          TextButton(
            onPressed: busy ? null : () => _install(true),
            child: const Text('从本机导入 GGUF'),
          ),
          if (busy && received > 0)
            LinearProgressIndicator(value: received / model.bytes),
        ] else if (!loaded)
          FilledButton(
            onPressed: busy ? null : _load,
            child: const Text('加载到内存'),
          )
        else if (widget.work != null)
          FilledButton(
            onPressed: busy
                ? null
                : () => _run(() async {
                    final id = DateTime.now().microsecondsSinceEpoch.toString();
                    requestId = id;
                    final result = await widget.work!(
                      runtime,
                      id,
                      () => stopped || !mounted,
                      (value) {
                        if (mounted) setState(() => message = value);
                      },
                    );
                    await runtime.unload();
                    if (mounted && !stopped) Navigator.of(context).pop(result);
                  }),
            child: const Text('开始在本机处理'),
          )
        else ...[
          OutlinedButton(
            onPressed: busy
                ? null
                : () => _run(() async {
                    await runtime.unload();
                    if (mounted) setState(() => loaded = false);
                  }),
            child: const Text('释放模型内存'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: question,
            enabled: !busy,
            maxLines: 3,
            maxLength: 2000,
            decoration: const InputDecoration(
              labelText: '本机输入',
              hintText: '例如：查找资料「会议安排」',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (proposal != null || hits.isNotEmpty)
                setState(() {
                  proposal = null;
                  hits = [];
                });
            },
          ),
          FilledButton(
            onPressed: busy ? null : () => _ask(false),
            child: const Text('离线回答'),
          ),
          OutlinedButton(
            onPressed: busy ? null : () => _ask(true),
            child: const Text('识别查找或建笔记指令'),
          ),
        ],
        if (busy)
          TextButton(
            onPressed: stopped
                ? null
                : () {
                    setState(() => stopped = true);
                    if (runningPython) widget.controller.cancelActiveTask();
                    if (requestId != null)
                      unawaited(runtime.cancel(requestId!));
                  },
            child: const Text('停止'),
          ),
        if (message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(message),
          ),
        if (reply.isNotEmpty) SelectableText(reply),
        if (proposal != null && proposal!.action != LocalAction.clarify) ...[
          SelectableText(proposal!.argument),
          FilledButton(
            onPressed: busy ? null : () => _apply(),
            child: Text(
              proposal!.action == LocalAction.note ? '确认创建笔记' : '确认搜索资料',
            ),
          ),
          if (proposal!.action == LocalAction.note &&
              widget.controller.capabilities?.linux.available == true)
            TextButton(
              onPressed: busy ? null : () => _apply(usePython: true),
              child: const Text('用本地 Linux Python 整理成笔记'),
            ),
        ],
        for (final hit in hits)
          ListTile(
            title: Text(hit.title),
            subtitle: Text(
              hit.excerpt,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () async {
              final doc = widget.controller.state.documents
                  .where(
                    (d) => d.id == hit.documentId && d.revision == hit.revision,
                  )
                  .firstOrNull;
              if (doc == null) {
                setState(() => message = '资料已更新，请重新查找。');
                return;
              }
              await runtime.unload();
              try {
                await doc.currentVersion.loadText();
              } catch (_) {
                if (mounted)
                  setState(() {
                    loaded = false;
                    message = '资料已变化，请重新检索。';
                  });
                return;
              }
              if (!context.mounted) return;
              setState(() => loaded = false);
              await Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => DocumentEditor(
                    controller: widget.controller,
                    document: doc,
                    matchOffset: hit.offset,
                    matchQuery: hit.excerpt,
                  ),
                ),
              );
            },
          ),
      ],
    ),
  );
}
