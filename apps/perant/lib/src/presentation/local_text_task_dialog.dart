// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

final class LocalTextTaskInput {
  const LocalTextTaskInput(this.title, this.text);
  final String title;
  final String text;
}

class LocalTextTaskDialog extends StatefulWidget {
  const LocalTextTaskDialog({super.key, this.initialText = ''});
  final String initialText;
  @override
  State<LocalTextTaskDialog> createState() => _LocalTextTaskDialogState();
}

class _LocalTextTaskDialogState extends State<LocalTextTaskDialog> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController(text: '本地整理');
  late final _text = TextEditingController(text: widget.initialText);
  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('本地整理为 Markdown'),
    content: SizedBox(
      width: 600,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .65,
        ),
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '在手机本地使用 Python 处理任务副本。保留原文，只整理换行与段落；不生成语义摘要，不调用模型 API。',
                ),
                const SizedBox(height: 20),
                TextFormField(
                  key: const ValueKey('local-text-title'),
                  controller: _title,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: '文档标题'),
                  validator: (value) {
                    final title = value?.trim() ?? '';
                    return title.isEmpty || title.runes.length > 80
                        ? '请输入 1～80 个字符的标题'
                        : null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('local-text-source'),
                  controller: _text,
                  minLines: 5,
                  maxLines: 12,
                  maxLength: 20000,
                  decoration: const InputDecoration(
                    labelText: '粘贴原文',
                    hintText: '最多 2 万个字符、128 KiB',
                  ),
                  validator: (value) {
                    final text = value ?? '';
                    if (text.trim().isEmpty) return '请粘贴需要整理的原文';
                    if (text.runes.length > 20000 ||
                        utf8.encode(text).length > 128 * 1024) {
                      return '原文最多 2 万个字符、128 KiB';
                    }
                    return null;
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(
              context,
              LocalTextTaskInput(_title.text.trim(), _text.text),
            );
          }
        },
        child: const Text('在本地整理'),
      ),
    ],
  );
}
