// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:file_selector/file_selector.dart';

import '../data/bge_encoder.dart';
import '../data/semantic_index.dart';

class SemanticSettings extends StatefulWidget {
  const SemanticSettings({super.key, required this.index});
  final SemanticControl index;
  @override
  State<SemanticSettings> createState() => _SemanticSettingsState();
}

class _SemanticSettingsState extends State<SemanticSettings> {
  VectorProgress? status;
  String? message;
  bool busy = false;
  bool cancelled = false;
  int received = 0, totalBytes = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final result = await widget.index.vectorProgress();
      if (mounted) setState(() => status = result);
    } catch (_) {
      if (mounted) setState(() => message = '索引状态读取失败。');
    }
  }

  @override
  void dispose() {
    cancelled = true;
    super.dispose();
  }

  Future<void> _import() async {
    if (busy) return;
    setState(() {
      busy = true;
      cancelled = false;
      message = null;
    });
    try {
      final selected = await openFiles(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'BGE 模型和词表',
            extensions: ['onnx', 'txt'],
            mimeTypes: ['application/octet-stream', 'text/plain'],
            uniformTypeIdentifiers: ['public.data', 'public.plain-text'],
          ),
        ],
      );
      if (selected.isEmpty || !mounted) return;
      await EmbeddingFiles.importFiles({
        for (final f in selected) f.name: f.openRead(),
      }, cancelled: () => cancelled);
      if (mounted) setState(() => message = '两个文件均通过校验，可以离线更新索引。');
    } on FormatException catch (e) {
      if (mounted) setState(() => message = e.message);
    } catch (_) {
      if (mounted)
        setState(() => message = cancelled ? '已暂停导入。' : '模型导入失败，请重新选择两个完整文件。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _start() async {
    if (busy) return;
    setState(() {
      busy = true;
      cancelled = false;
      message = null;
      received = 0;
      totalBytes = 0;
    });
    try {
      await widget.index.indexSemantics(
        cancelled: () => cancelled,
        onProgress: (s) {
          if (mounted) setState(() => status = s);
        },
        downloadProgress: (n, total) {
          if (mounted && (n == total || n == 0 || n - received >= 262144))
            setState(() {
              received = n;
              totalBytes = total;
            });
        },
      );
      if (mounted)
        setState(
          () => message = cancelled ? '已暂停，已完成的片段可以检索。' : '当前资料已完成语义索引。',
        );
    } catch (_) {
      if (mounted)
        setState(
          () => message = cancelled
              ? '已暂停，可稍后继续。'
              : '未能完成，请检查网络、可用空间后重试。已完成的片段会保留。',
        );
    } finally {
      if (mounted) {
        setState(() => busy = false);
        await _refresh();
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('离线语义检索')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('BGE-small-zh-v1.5 · 中文检索模型'),
        const SizedBox(height: 8),
        const Text('首次需要下载约 24.1 MB 的模型与词表。资料和查询在本机计算，建立索引后可用意思相近的说法搜索。'),
        const SizedBox(height: 24),
        if (!busy)
          TextButton(onPressed: _import, child: const Text('从本机导入模型与词表')),
        if (status != null) Text('已索引 ${status!.done} / ${status!.total} 个片段'),
        if (busy) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: totalBytes > 0 && received < totalBytes
                ? received / totalBytes
                : status != null && status!.total > 0
                ? status!.done / status!.total
                : null,
          ),
          if (totalBytes > 0 && received < totalBytes)
            Text(
              '下载 ${(received / 1e6).toStringAsFixed(1)} / ${(totalBytes / 1e6).toStringAsFixed(1)} MB',
            ),
        ],
        if (message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(message!),
          ),
        const SizedBox(height: 16),
        if (busy)
          OutlinedButton(
            onPressed: cancelled
                ? null
                : () => setState(() => cancelled = true),
            child: const Text('暂停'),
          )
        else
          FilledButton(
            onPressed: status == null || status!.total == 0 ? null : _start,
            child: const Text('准备模型并更新索引'),
          ),
      ],
    ),
  );
}
