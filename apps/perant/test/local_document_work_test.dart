// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter_test/flutter_test.dart';
import 'package:perant/src/application/device_inference.dart';
import 'package:perant/src/application/local_document_work.dart';
import 'package:perant_core/perant_core.dart';

class _Recorder implements LocalInference {
  final requests = <ModelRequest>[];
  String response = '一条摘记', finish = 'stop';
  @override
  Stream<ModelEvent> generate(ModelRequest request) async* {
    requests.add(request);
    yield ModelEvent.textDelta(response);
    yield ModelEvent.completed(finishReason: finish);
  }

  @override
  Future<RuntimeCapability> inspect() => throw UnimplementedError();
  @override
  Future<void> load(LocalModelConfiguration c) => throw UnimplementedError();
  @override
  Future<void> cancel(String id) async {}
  @override
  Future<void> unload() async {}
}

void main() {
  test('map and reduce cover 5 documents and 20000 code points including surrogate pairs', () async {
    final model = _Recorder();
    final docs = List.generate(
      5,
      (i) => MarkdownDocument(
        id: 'd$i',
        title: 't$i',
        updatedAt: DateTime.utc(2026),
        markdown: '${['一', '二', '三', '四', '五'][i] * 3999}😊',
      ),
    );
    final result = await synthesizeMeeting(docs)(
      model,
      'task',
      () => false,
      (_) {},
    );
    final mapped = model.requests.where(
      (r) => r.messages.first.content!.startsWith('你在整理'),
    );
    expect(
      mapped.map((r) => r.messages.last.content).join(),
      docs.map((d) => d.markdown).join(),
    );
    expect(model.requests.length, greaterThan(mapped.length));
    for (var i = 0; i < docs.length; i++) {
      expect(result, contains('S${i + 1} · 第 3841–4000 字'));
      expect(result, contains('d$i · 版本 1'));
    }
  });
  test('interruption or length limit cannot produce a replacement', () async {
    final model = _Recorder()..finish = 'length';
    expect(() => reviseSelection('字' * 321), throwsFormatException);
    final work = reviseSelection('草稿');
    await expectLater(
      work(model, 'id', () => false, (_) {}),
      throwsFormatException,
    );
    await expectLater(work(model, 'id', () => true, (_) {}), throwsStateError);
    expect(model.requests, hasLength(1));
  });
  test(
    'only one literal user argument can reach a proposed operation',
    () async {
      final model = _Recorder()..response = 'B';
      for (final bad in ['创建笔记', '创建「 」', '建笔记「甲」「乙」', '搜索「嵌套「词」」']) {
        expect(
          (await proposeLocalAction(model, bad, 'a')).action,
          LocalAction.clarify,
        );
      }
      expect(model.requests, isEmpty);
      final proposal = await proposeLocalAction(model, '记一笔「原样保存🙂」', 'a');
      expect(proposal.action, LocalAction.note);
      expect(proposal.argument, '原样保存🙂');
      expect(
        model.requests.single.messages.last.content,
        isNot(contains('原样保存')),
      );
      model.finish = 'length';
      expect(
        (await proposeLocalAction(model, '记一笔「原文」', 'b')).action,
        LocalAction.clarify,
      );
    },
  );
}
