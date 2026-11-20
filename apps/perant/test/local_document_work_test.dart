// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter_test/flutter_test.dart';
import 'package:perant/src/application/device_inference.dart';
import 'package:perant/src/application/local_document_work.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant/src/data/portable_documents.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();
  test('resume skips committed map and reduction calls; incompatible input cannot publish', () async {
    final db = MemoryWorkspacePersistence();
    WorkspaceController controller() => WorkspaceController(
      persistence: db,
      credentials: MemoryCredentialStore(),
    );
    var c = controller();
    await c.initialize();
    final doc = await c.createDocument(title: '预算', markdown: '会' * 2000);
    var checkpoint = await c.beginMeeting([doc], 'fixture', 'fixed', 2048);
    var stopped = false;
    final first = _Recorder();
    Future<MeetingJournal> open(LocalInference _) async => (
      completed: checkpoint.steps,
      append: (int index, String output) async {
        checkpoint = await c.saveMeetingStep(checkpoint, index, output);
        stopped = checkpoint.steps.length == 6;
      },
    );
    await expectLater(
      synthesizeMeeting([doc], openJournal: open)(
        first,
        'one',
        () => stopped,
        (_) {},
      ),
      throwsStateError,
    );
    expect(first.requests.length, 6);
    expect(checkpoint.steps.length, 6);
    expect(
      (await portableSnapshot(c.state)).containsKey('meetingProgress'),
      isFalse,
    );
    c.dispose();
    c = controller();
    addTearDown(c.dispose);
    await c.initialize();
    final source = c.documents.single;
    expect(c.state.currentMeeting!.steps.length, 6);
    await expectLater(
      c.beginMeeting([source], 'fixture', 'changed-model', 2048),
      throwsFormatException,
    );
    checkpoint = await c.beginMeeting([source], 'fixture', 'fixed', 2048);
    final old = checkpoint;
    final second = _Recorder();
    stopped = false;
    final draft = await synthesizeMeeting([source], openJournal: open)(
      second,
      'two',
      () => stopped,
      (_) {},
    );
    expect(second.requests.length, 2);
    await expectLater(c.saveMeetingStep(old, 6, 'late'), throwsStateError);
    final result = await c.createDocument(
      title: '会议纪要',
      markdown: draft,
      completedMeetingId: checkpoint.id,
    );
    expect(c.state.currentMeeting, isNull);
    expect(result.markdown, contains('分段核对'));
    await expectLater(
      c.createDocument(markdown: draft, completedMeetingId: checkpoint.id),
      throwsStateError,
    );
    final next = await c.beginMeeting([source], 'fixture', 'fixed', 2048);
    await c.saveDocument(source.id, '变更后的原文', expectedRevision: 1);
    expect(c.state.currentMeeting, isNull);
    await expectLater(c.saveMeetingStep(next, 0, '晚到的结果'), throwsStateError);
    expect((await db.load()).currentMeeting, isNull);
  });
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
