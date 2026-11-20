// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:diff_match_patch/diff_match_patch.dart' as edits;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:perant_core/perant_core.dart';

import '../application/office_document.dart';
import '../application/courseware.dart';
import '../application/local_document_work.dart';
import 'local_model_screen.dart';
import 'container_file_editor.dart';
import '../application/workspace_controller.dart';
import 'theme.dart';

class DocumentEditor extends StatefulWidget {
  const DocumentEditor({
    super.key,
    required this.controller,
    required this.document,
    this.matchOffset,
    this.matchQuery = '',
  });
  final WorkspaceController controller;
  final MarkdownDocument document;
  final int? matchOffset;
  final String matchQuery;
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
    final offset = widget.matchOffset;
    if (offset != null) {
      final start = offset.clamp(0, _text.text.length);
      final match = RegExp(
        RegExp.escape(widget.matchQuery),
        caseSensitive: false,
        unicode: true,
      ).matchAsPrefix(_text.text, start);
      _text.selection = TextSelection(
        baseOffset: start,
        extentOffset: match?.end ?? start,
      );
    }
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
        expectedRevision: _saved.revision,
      );
      if (!mounted) return;
      setState(() => _saved = result);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(confirm ? '已确认当前版本' : '文档已保存')));
    } on StateError catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message.toString())));
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('未能保存，请保留当前文字后重试。')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _history() async {
    final version = await showModalBottomSheet<DocumentVersion>(
      context: context,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('选择版本，与当前编辑内容比较')),
            for (final version in [
              _saved.currentVersion,
              ..._saved.history.reversed,
            ])
              ListTile(
                title: Text('版本 ${version.revision}'),
                subtitle: Text(
                  version.updatedAt.toLocal().toString().split('.').first,
                ),
                onTap: () => Navigator.pop(sheet, version),
              ),
          ],
        ),
      ),
    );
    if (version == null || !mounted) return;
    try {
      await version.loadText();
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('读取该修订失败。')));
      return;
    }
    if (!mounted) return;
    final draft = _text.text;
    final restore = await _reviewChanges(
      version.markdown,
      draft,
      '版本 ${version.revision} → 当前编辑内容',
      _dirty ? '用此版本替换未保存草稿' : '将此版本载入草稿',
    );
    if (restore && mounted) _text.text = version.markdown;
  }

  Future<bool> _reviewChanges(
    String before,
    String after,
    String title,
    String accept,
  ) async {
    final changes = edits.diff(before, after);
    edits.cleanupSemantic(changes);
    final restore = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: SelectableText.rich(
            TextSpan(
              children: [
                for (final change in changes)
                  TextSpan(
                    text: change.text,
                    style: switch (change.operation) {
                      edits.DIFF_INSERT => const TextStyle(
                        backgroundColor: Color(0xffd4eedc),
                        decoration: TextDecoration.underline,
                      ),
                      edits.DIFF_DELETE => const TextStyle(
                        backgroundColor: Color(0xffffdcdc),
                        decoration: TextDecoration.lineThrough,
                      ),
                      _ => null,
                    },
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('关闭'),
          ),
          if (before != after)
            TextButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(accept),
            ),
        ],
      ),
    );
    return restore == true;
  }

  Future<void> _revise() async {
    final draft = _text.text;
    final selected = _text.selection;
    final range = selected.isValid && !selected.isCollapsed
        ? selected
        : TextSelection(baseOffset: 0, extentOffset: draft.length);
    final original = range.textInside(draft);
    try {
      final work = reviseSelection(original);
      final result = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => LocalModelScreen(
            controller: widget.controller,
            title: '润色所选原文',
            work: work,
          ),
        ),
      );
      if (result == null || !mounted || draft != _text.text) return;
      final accepted = await _reviewChanges(
        original,
        result,
        '原文与模型建议',
        '采用到编辑草稿',
      );
      if (!accepted || !mounted || draft != _text.text) return;
      final latest = widget.controller.documents
          .where((d) => d.id == _saved.id)
          .firstOrNull;
      if (latest == null ||
          latest.revision != _saved.revision ||
          latest.markdown != _saved.markdown) {
        throw const FormatException('资料已更新，请重新打开后核对。');
      }
      _text.value = TextEditingValue(
        text: draft.replaceRange(range.start, range.end, result),
        selection: TextSelection(
          baseOffset: range.start,
          extentOffset: range.start + result.length,
        ),
      );
    } on FormatException catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  ConfirmedDocument _confirmedForOutput() {
    final latest = widget.controller.documents
        .where((d) => d.id == _saved.id)
        .firstOrNull;
    if (_dirty ||
        latest == null ||
        !latest.isConfirmed ||
        latest.revision != _saved.revision ||
        latest.markdown != _saved.markdown) {
      throw StateError('资料版本已变更，请重新打开并确认。');
    }
    return latest.confirmedSnapshot();
  }

  Future<void> _make(String action) async {
    if (action == 'pptx') return _export(DocumentFormat.pptx);
    if (action == 'html') return _export(DocumentFormat.html);
    if (_saving || _dirty || !_saved.isConfirmed) return;
    setState(() => _saving = true);
    try {
      final source = _confirmedForOutput();
      if (action == 'outline') {
        final draft = await widget.controller.createDocument(
          title: '${source.title} · 课件大纲',
          markdown: makeCourseOutline(source),
        );
        if (mounted)
          await Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => DocumentEditor(
                controller: widget.controller,
                document: draft,
              ),
            ),
          );
      } else {
        final html = courseHtml(source);
        if (utf8.encode(html).length > 256 * 1024)
          throw const FormatException('网页超过工作文件的 256 KiB 上限，请分段后生成。');
        final path =
            '/workspace/page-${DateTime.now().microsecondsSinceEpoch}.html';
        if (mounted)
          await Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => ContainerFileEditor(
                controller: widget.controller,
                path: path,
                initialContent: html,
              ),
            ),
          );
      }
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is FormatException ? error.message : '未能创建，请重新核对已确认资料。',
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _export(DocumentFormat format) async {
    if (_saving || _dirty || !_saved.isConfirmed) return;
    setState(() => _saving = true);
    try {
      final snapshot = _confirmedForOutput();
      final bytes = switch (format) {
        DocumentFormat.docx => await compute(exportDocx, snapshot),
        DocumentFormat.pptx => await compute(exportCourseSlides, snapshot),
        DocumentFormat.html => utf8.encode(courseHtml(snapshot)),
        DocumentFormat.markdown => utf8.encode(snapshot.markdown),
        DocumentFormat.pdf => await compute(renderOfficePdf, (
          snapshot,
          await rootBundle.load(officeFontAsset),
        )),
      };
      if (!mounted) return;
      final result = await FilePicker.saveFile(
        bytes: bytes,
        fileName: officeFileName(snapshot, format),
        mimeType: switch (format) {
          DocumentFormat.docx => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
          DocumentFormat.pptx => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
          DocumentFormat.html => 'text/html',
          DocumentFormat.markdown => 'text/markdown',
          DocumentFormat.pdf => 'application/pdf',
        },
      );
      if (mounted && result != null)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已导出版本 ${snapshot.revision} · ${format.name.toUpperCase()}',
            ),
          ),
        );
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is StateError
                  ? error.message.toString()
                  : error is FormatException
                  ? error.message
                  : '导出失败，请检查文档大小、目标位置和设备空间。',
            ),
          ),
        );
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
            IconButton(
              onPressed: _saving ? null : _history,
              tooltip: '版本历史与差异',
              icon: const Icon(Icons.history),
            ),
            IconButton(
              onPressed: _saving || _preview ? null : _revise,
              tooltip: '用本地模型润色所选原文',
              icon: const Icon(Icons.edit_note),
            ),
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
                            autofocus: widget.matchOffset != null,
                            readOnly: _saving,
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
                    Wrap(
                      alignment: WrapAlignment.center,
                      children: [
                        for (final format in [
                          DocumentFormat.docx,
                          DocumentFormat.pdf,
                          DocumentFormat.markdown,
                        ])
                          TextButton(
                            onPressed: confirmed && !_saving
                                ? () => _export(format)
                                : null,
                            child: Text(
                              '导出 ${format == DocumentFormat.markdown ? 'MD' : format.name.toUpperCase()}',
                            ),
                          ),
                        PopupMenuButton<String>(
                          enabled: confirmed && !_saving,
                          tooltip: '制作课件或网页',
                          onSelected: _make,
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'outline',
                              child: Text('从此资料生成课件大纲'),
                            ),
                            const PopupMenuItem(
                              value: 'pptx',
                              child: Text('将已确认大纲导出为 PPTX'),
                            ),
                            const PopupMenuItem(
                              value: 'html',
                              child: Text('导出静态网页 HTML'),
                            ),
                            if (defaultTargetPlatform == TargetPlatform.android)
                              const PopupMenuItem(
                                value: 'page',
                                child: Text('在工作区编辑并预览网页'),
                              ),
                          ],
                        ),
                      ],
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
