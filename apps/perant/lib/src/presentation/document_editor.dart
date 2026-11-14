// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:perant_core/perant_core.dart';

import '../application/workspace_controller.dart';
import 'theme.dart';

class DocumentEditor extends StatefulWidget {
  const DocumentEditor({
    super.key,
    required this.controller,
    required this.document,
  });
  final WorkspaceController controller;
  final MarkdownDocument document;
  @override
  State<DocumentEditor> createState() => _DocumentEditorState();
}

class _DocumentEditorState extends State<DocumentEditor> {
  late MarkdownDocument _saved;
  late final TextEditingController _text;
  bool _preview = false;
  bool _saving = false;
  bool get _dirty => _text.text != _saved.markdown;
  @override
  void initState() {
    super.initState();
    _saved = widget.document;
    _text = TextEditingController(text: _saved.markdown)..addListener(_changed);
  }

  void _changed() => setState(() {});
  @override
  void dispose() {
    _text.removeListener(_changed);
    _text.dispose();
    super.dispose();
  }

  Future<void> _save({bool confirm = false}) async {
    setState(() => _saving = true);
    try {
      final result = await widget.controller.saveDocument(
        _saved.id,
        _text.text,
        confirm: confirm,
      );
      if (!mounted) return;
      setState(() => _saved = result);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(confirm ? '已确认当前版本' : '文档已保存')));
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('未能保存，请保留当前文字后重试。')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _leave() async {
    if (_saving) return;
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('离开前保存修改？'),
          content: const Text('可以返回编辑器保存，或放弃尚未保存的修改。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回编辑'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('放弃修改'),
            ),
          ],
        ),
      );
      if (discard != true) return;
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final confirmed = !_dirty && _saved.isConfirmed;
    return PopScope(
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: _leave,
            tooltip: '返回',
            icon: const Icon(Icons.arrow_back),
          ),
          title: Text(_saved.title, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              onPressed: () => setState(() => _preview = !_preview),
              tooltip: _preview ? '继续编辑' : '预览 Markdown',
              icon: Icon(
                _preview ? Icons.edit_outlined : Icons.visibility_outlined,
              ),
            ),
            IconButton(
              onPressed: _saving ? null : () => _save(),
              tooltip: '保存文档',
              icon: const Icon(Icons.save_outlined),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Container(
                width: double.infinity,
                color: PerantColors.soft,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                child: Wrap(
                  spacing: 16,
                  runSpacing: 4,
                  children: [
                    Text(
                      'Markdown · 版本 ${_saved.revision}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Text(
                      _dirty
                          ? '有未保存修改 · 确认将失效'
                          : confirmed
                          ? '此版本已确认'
                          : '草稿 · 尚未确认',
                      style: TextStyle(
                        fontSize: 12,
                        color: confirmed
                            ? PerantColors.accent
                            : PerantColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1000),
                    child: _preview
                        ? SingleChildScrollView(
                            padding: const EdgeInsets.all(24),
                            child: MarkdownBody(
                              data: _text.text.isEmpty ? '尚无内容。' : _text.text,
                              imageBuilder: (uri, title, alt) =>
                                  Text(alt ?? '图片预览暂不加载'),
                              selectable: true,
                            ),
                          )
                        : TextField(
                            controller: _text,
                            expands: true,
                            maxLines: null,
                            minLines: null,
                            textAlignVertical: TextAlignVertical.top,
                            decoration: const InputDecoration(
                              hintText: '写下内容，或粘贴已有的 Markdown…',
                              fillColor: PerantColors.paper,
                              border: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: EdgeInsets.all(24),
                            ),
                            style: const TextStyle(fontSize: 16, height: 1.8),
                          ),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: PerantColors.line)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: _text.text),
                              );
                              if (context.mounted)
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Markdown 已复制')),
                                );
                            },
                            icon: const Icon(Icons.copy_outlined, size: 18),
                            label: const Text('复制'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed:
                                _saving ||
                                    _text.text.trim().isEmpty ||
                                    confirmed
                                ? null
                                : () => _save(confirm: true),
                            child: Text(confirmed ? '版本已确认' : '保存并确认'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '当前可编辑、预览和复制 Markdown；Word / PDF 导出尚未开放。',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
