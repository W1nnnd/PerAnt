// SPDX-License-Identifier: GPL-3.0-only
import 'package:material_ui/material_ui.dart';
import 'package:perant_core/perant_core.dart';

import '../application/workspace_controller.dart';

class MemoryScreen extends StatelessWidget {
  const MemoryScreen({super.key, required this.controller});
  final WorkspaceController controller;

  (String, Future<String> Function())? _source(MemoryRecord record) {
    final source = record.sources.single;
    final id = source.sourceId.substring(4);
    if (source.sourceId.startsWith('msg:')) {
      final msg = controller.state.messages
          .where((m) => m.id == id)
          .firstOrNull;
      if (msg == null) return null;
      return (
        '用户消息 · ${msg.createdAt.toLocal().toString().split('.').first}',
        () async => msg.text,
      );
    }
    final doc = controller.documents.where((d) => d.id == id).firstOrNull;
    if (doc == null) return null;
    final version = [
      doc.currentVersion,
      ...doc.history,
    ].where((v) => v.revision.toString() == source.version).firstOrNull;
    return version == null
        ? null
        : ('${doc.title} · 修订 ${version.revision}', version.loadText);
  }

  Future<void> _mutate(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (_) {
      if (context.mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('未保存，请检查当前任务或存储后重试。')));
    }
  }

  Future<void> _edit(BuildContext context, MemoryRecord record) async {
    var draft = record.text;
    final edited = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('修改记忆'),
        content: TextFormField(
          initialValue: record.text,
          maxLength: 160,
          minLines: 1,
          maxLines: 4,
          onChanged: (text) => draft = text,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (draft.trim().isNotEmpty) Navigator.pop(c, draft.trim());
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (edited != null && context.mounted)
      await _mutate(context, () => controller.editMemory(record.id, edited));
  }

  Future<void> _remove(BuildContext context, MemoryRecord record) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除这条记忆？'),
        content: const Text('此来源中的相同内容将停止自动提取。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted)
      await _mutate(context, () => controller.deleteMemory(record.id));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('长期记忆')),
    body: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final book = controller.state.memories;
        final locked =
            controller.isConfiguring ||
            controller.isSending ||
            controller.isTesting ||
            controller.manualTerminalActive;
        final records = book.records.values.toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return ListView.builder(
          itemCount: records.length + 1,
          itemBuilder: (context, i) {
            if (i == 0)
              return Column(
                children: [
                  SwitchListTile(
                    title: const Text('在本机自动提取'),
                    subtitle: const Text(
                      '从自己的消息和已确认文档中保存明确写出的偏好与习惯，例如「我喜欢按周整理资料」。',
                    ),
                    value: book.enabled,
                    onChanged: locked
                        ? null
                        : (value) => _mutate(
                            context,
                            () => controller.setMemoryExtraction(value),
                          ),
                  ),
                  if (records.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('还没有长期记忆。'),
                    ),
                ],
              );
            final record = records[i - 1];
            final source = _source(record);
            return ListTile(
              title: Text(record.text),
              subtitle: Text(
                [
                  source?.$1 ?? '原来源已删除',
                  if (record.isUserEdited) '已人工修改',
                ].join(' · '),
              ),
              onTap: source == null
                  ? null
                  : () => showDialog<void>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: Text(source.$1),
                        content: SingleChildScrollView(
                          child: FutureBuilder<String>(
                            future: source.$2(),
                            builder: (_, snap) => snap.hasData
                                ? SelectableText(snap.data!)
                                : snap.hasError
                                ? const Text('来源正文读取失败。')
                                : const CircularProgressIndicator(),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(c),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    ),
              trailing: PopupMenuButton<String>(
                enabled: !locked,
                tooltip: '记忆操作',
                onSelected: (action) => action == 'edit'
                    ? _edit(context, record)
                    : _remove(context, record),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('修改')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            );
          },
        );
      },
    ),
  );
}
