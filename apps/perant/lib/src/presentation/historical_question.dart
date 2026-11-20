// SPDX-License-Identifier: GPL-3.0-only
import 'package:material_ui/material_ui.dart';
import 'package:perant_core/perant_core.dart';

import '../data/library_search.dart';
import '../data/semantic_index.dart';
import '../application/historical_excerpt.dart';
import '../application/workspace_controller.dart';

typedef HistoricalQuestion = ({
  String prompt,
  List<HistoricalExcerpt> excerpts,
});

class HistoricalQuestionPage extends StatefulWidget {
  const HistoricalQuestionPage({
    super.key,
    required this.controller,
    required this.profile,
    this.initial = '',
  });
  final WorkspaceController controller;
  final ProviderProfile profile;
  final String initial;
  @override
  State<HistoricalQuestionPage> createState() => _HistoricalQuestionPageState();
}

class _HistoricalQuestionPageState extends State<HistoricalQuestionPage> {
  late final prompt = TextEditingController(text: widget.initial);
  final term = TextEditingController();
  final selected = <(SourceVersion, int), HistoricalExcerpt>{};
  List<HistoricalExcerpt> available = [];
  bool searching = false;
  String? info;
  @override
  void dispose() {
    prompt.dispose();
    term.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = term.text.trim();
    if (q.isEmpty || q.runes.length > 128 || searching) return;
    setState(() {
      searching = true;
      info = null;
    });
    try {
      final c = widget.controller, store = c.persistence;
      final list = store is SemanticControl
          ? await (store as SemanticControl).hybridSearch(q)
          : store is PassageSearch
          ? await (store as PassageSearch).searchPassages(q)
          : LibrarySearch.inMemory(c.documents, q);
      if (!mounted) return;
      final docs = {for (final d in c.documents) d.id: d};
      final items = <HistoricalExcerpt>[];
      for (final h in list) {
        final doc = docs[h.documentId];
        if (doc == null) continue;
        final excerpt = await HistoricalExcerpt.readPassage(doc, h, store);
        if (!mounted) return;
        if (excerpt != null) items.add(excerpt);
      }
      items.addAll(
        c.state.memories.records.values
            .where((m) => m.text.toLowerCase().contains(q.toLowerCase()))
            .take(10)
            .map(HistoricalExcerpt.memory),
      );
      setState(() {
        available = items;
        if (items.isEmpty) info = '没有找到相符的资料或记忆。';
      });
    } catch (_) {
      if (mounted) setState(() => info = '暂时无法检索，请重试。');
    } finally {
      if (mounted) setState(() => searching = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('引用本机资料提问')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            controller: prompt,
            minLines: 2,
            maxLines: 4,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: '本轮问题'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: term,
            maxLength: 128,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              labelText: '查找资料或记忆',
              suffixIcon: IconButton(
                onPressed: searching ? null : _search,
                icon: const Icon(Icons.search),
                tooltip: '查找引用',
              ),
            ),
          ),
          if (searching) const LinearProgressIndicator(),
          if (info != null) Text(info!),
          for (final e in available)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(e.title),
              subtitle: Text(
                e.text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              value: selected.containsKey((e.source, e.offset)),
              onChanged: (checked) {
                setState(() {
                  final k = (e.source, e.offset);
                  if (checked != true) {
                    selected.remove(k);
                  } else if (selected.length < 5) {
                    selected[k] = e;
                  } else {
                    info = '每轮最多选 5 个片段。';
                  }
                });
              },
            ),
          const Divider(),
          Text('本轮将发送的片段（${selected.length}/5）'),
          for (final e in selected.values)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(e.title),
              subtitle: Text(e.text),
              trailing: IconButton(
                tooltip: '移除引用',
                onPressed: () =>
                    setState(() => selected.remove((e.source, e.offset))),
                icon: const Icon(Icons.close),
              ),
            ),
          const SizedBox(height: 12),
          Text(
            '目的地：${widget.profile.displayName} · ${widget.profile.baseUrl.host} · ${widget.profile.modelId}。本次只发送上面的问题与勾选的原文，按该服务账户计费。',
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed:
                selected.isEmpty || prompt.text.trim().isEmpty || searching
                ? null
                : () => Navigator.pop(context, (
                    prompt: prompt.text.trim(),
                    excerpts: selected.values.toList(),
                  )),
            child: const Text('授权发送选中的片段'),
          ),
        ],
      ),
    ),
  );
}
