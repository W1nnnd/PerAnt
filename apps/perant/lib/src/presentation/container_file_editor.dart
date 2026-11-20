// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perant_platform/perant_platform.dart';

import '../application/workspace_controller.dart';
import 'theme.dart';

class ContainerFileEditor extends StatefulWidget {
  const ContainerFileEditor({
    super.key,
    required this.controller,
    required this.path,
    this.file,
    this.initialContent = '',
  });
  final WorkspaceController controller;
  final String path;
  final LinuxTextFile? file;
  final String initialContent;

  @override
  State<ContainerFileEditor> createState() => _ContainerFileEditorState();
}

class _ContainerFileEditorState extends State<ContainerFileEditor> {
  late final TextEditingController _text;
  LinuxTextFile? _saved;
  bool _saving = false;
  bool _preview = false;
  bool _allowPop = false;
  String? _error;
  bool get _dirty => _saved == null || _text.text != _saved!.content;
  bool get _blocked =>
      _saving ||
      widget.controller.isSending ||
      widget.controller.isConfiguring ||
      widget.controller.manualTerminalActive;

  @override
  void initState() {
    super.initState();
    _saved = widget.file;
    _text = TextEditingController(
      text: _saved?.content ?? widget.initialContent,
    )..addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _text.removeListener(_changed);
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_blocked) return;
    if (utf8.encode(_text.text).length > 256 * 1024) {
      setState(() => _error = '文件须小于或等于 256 KiB，请先缩短内容。');
      return;
    }
    String? lease;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      lease = widget.controller.acquireManualTerminal();
      final saved = await widget.controller.bridge.writeLinuxFile(
        path: widget.path,
        content: _text.text,
        expectedSha256: _saved?.sha256,
        createOnly: _saved == null,
      );
      if (!mounted) return;
      setState(() => _saved = saved);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已保存到 Linux 工作区')));
    } catch (error) {
      if (mounted)
        setState(
          () => _error = error is RuntimeBridgeException
              ? '${error.message} 当前编辑内容已保留，可复制后再读取最新版本。'
              : '工作区正被占用或保存失败，当前编辑内容已保留。',
        );
    } finally {
      if (lease != null) widget.controller.releaseManualTerminal(lease);
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reload() async {
    if (_blocked) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('读取文件最新版本？'),
        content: const Text('这会替换编辑框中尚未保存的内容。需要保留时，请先复制。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('读取最新版本'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    String? lease;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      lease = widget.controller.acquireManualTerminal();
      final file = await widget.controller.bridge.readLinuxFile(widget.path);
      if (!mounted) return;
      _saved = file;
      _text.text = file.content;
    } catch (error) {
      if (mounted)
        setState(
          () => _error = error is RuntimeBridgeException
              ? error.message
              : '暂时无法读取文件，请结束正在运行的任务后重试。',
        );
    } finally {
      if (lease != null) widget.controller.releaseManualTerminal(lease);
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _leave() async {
    if (_saving) return;
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('文件尚未保存'),
          content: const Text('返回编辑器保存，或放弃这次编辑。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回编辑'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('放弃编辑'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.pop(context);
  }

  Widget _previewBody() {
    final path = widget.path.toLowerCase();
    if (path.endsWith('.html') || path.endsWith('.htm')) {
      if (defaultTargetPlatform != TargetPlatform.android || kIsWeb) {
        return const Center(child: Text('HTML 静态预览需要 Android 原生应用。'));
      }
      if (utf8.encode(_text.text).length > 256 * 1024) {
        return const Center(child: Text('HTML 预览上限为 256 KiB。'));
      }
      return AndroidView(
        key: ValueKey(_text.text),
        viewType: 'dev.perant/html-preview',
        creationParams: {'html': _text.text},
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    if (path.endsWith('.md') || path.endsWith('.markdown')) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: MarkdownBody(
          data: _text.text,
          selectable: true,
          imageBuilder: (uri, title, alt) => Text(alt ?? '图片未加载'),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: SelectableText(
        _text.text,
        style: const TextStyle(fontFamily: 'monospace', height: 1.6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => PopScope(
      canPop: _allowPop || (!_dirty && !_saving),
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
          title: Text(
            widget.path.split('/').last,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: _preview ? '编辑文件' : '预览文件',
              onPressed: () => setState(() => _preview = !_preview),
              icon: Icon(
                _preview ? Icons.edit_outlined : Icons.visibility_outlined,
              ),
            ),
            IconButton(
              tooltip: '保存到 Linux',
              onPressed: _blocked || !_dirty ? null : _save,
              icon: const Icon(Icons.save_outlined),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                color: PerantColors.soft,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      widget.path,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_dirty ? '尚未保存' : '已保存'} · ${utf8.encode(_text.text).length} 字节${_preview && (widget.path.toLowerCase().endsWith('.html') || widget.path.toLowerCase().endsWith('.htm')) ? ' · 静态预览，脚本与网络关闭' : ''}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: PerantColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        _error!,
                        style: const TextStyle(fontSize: 12),
                      ),
                      TextButton(
                        onPressed: _blocked ? null : _reload,
                        child: const Text('读取最新版本'),
                      ),
                    ],
                  ),
                ),
              if (_saving) const LinearProgressIndicator(),
              Expanded(
                child: _preview
                    ? _previewBody()
                    : TextField(
                        key: const ValueKey('container-file-content'),
                        controller: _text,
                        enabled: !_saving,
                        expands: true,
                        maxLines: null,
                        minLines: null,
                        keyboardType: TextInputType.multiline,
                        textAlignVertical: TextAlignVertical.top,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 14,
                          height: 1.6,
                        ),
                        decoration: const InputDecoration(
                          hintText: '在这里编辑容器中的文件…',
                          fillColor: Colors.transparent,
                          border: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.all(20),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
