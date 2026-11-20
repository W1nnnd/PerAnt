// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:perant/src/application/device_inference.dart';
import 'package:perant/src/application/local_document_work.dart';
import 'package:perant/src/application/meeting_evidence.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant/src/data/meeting_progress.dart';
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
  test(
    'malformed selections fall back and corrupt restored selectors fail closed',
    () {
      for (final value in [
        '0',
        '5',
        '1,1',
        '1,2,3,4',
        '2 and a date',
        '',
        '9999999999999999999999999999999999',
      ]) {
        final picked = QuoteSelection.fromModel(value, 4, 3);
        expect(picked.indices, [1, 2, 3]);
        expect(picked.fallback, isTrue);
        expect(
          QuoteSelection.restore(picked.checkpoint, 4, 3).fallback,
          isTrue,
        );
      }
      final valid = QuoteSelection.fromModel(' 3，1 ', 4, 3);
      expect(QuoteSelection.restore(valid.checkpoint, 4, 3).indices, [3, 1]);
      for (final broken in ['一段旧模型正文', 'S:5', 'F:0', 'X:1', 'S:2,2']) {
        expect(
          () => QuoteSelection.restore(broken, 4, 3),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'windowing keeps a negation with its sentence and labels long excerpts',
    () {
      final src = ('甲' * 468 + '。' + '此事仍未批准，待李明在周五查证。' + '乙' * 600).runes
          .toList();
      final first = meetingWindowEnd(src, 0);
      expect(first, 469);
      final end = meetingWindowEnd(src, first);
      final quotes = meetingQuotes(src, 1, first, end);
      expect(quotes.first.text, '此事仍未批准，待李明在周五查证。');
      expect(quotes.first.partial, isFalse);
      expect(formatMeetingQuote(quotes.last), contains('长句节选'));
    },
  );
  test(
    'invented decisions cannot enter the draft at either reduction level',
    () async {
      const invented = '负责人：技术团队。期限：2024-10-27。';
      const source = '🙂会议尚未批准预算。周五前由小陈核对。';
      final docs = List.generate(
        5,
        (i) => MarkdownDocument(
          id: 'e$i',
          title: '原资料$i',
          markdown: source,
          updatedAt: DateTime.utc(2026),
        ),
      );
      final model = _Recorder()..response = invented;
      final draft = await synthesizeMeeting(docs)(
        model,
        'probe',
        () => false,
        (_) {},
      );
      expect(draft, isNot(contains('技术团队')));
      expect(draft, isNot(contains('2024-10-27')));
      expect(draft, contains('尚未批准预算'));
      expect(draft, contains('部分步骤未取得有效选句'));
      final evidence = RegExp(r'\[S(\d+) · 第 (\d+)–(\d+) 字\]\n\n> ([^\n]+)')
          .allMatches(draft)
          .toList();
      expect(evidence.length, greaterThan(5));
      for (final m in evidence) {
        final points = docs[int.parse(m[1]!) - 1].markdown.runes.toList();
        expect(
          m[4],
          String.fromCharCodes(points, int.parse(m[2]!) - 1, int.parse(m[3]!)),
        );
      }
      model.response = '2';
      final chosen = await synthesizeMeeting([docs.first])(
        model,
        'valid',
        () => false,
        (_) {},
      );
      expect(chosen, contains('周五前由小陈核对。'));
      expect(chosen, isNot(contains('尚未批准预算')));
      expect(chosen, isNot(contains('未取得有效选句')));
    },
  );

  test(
    'a v1 meeting preserves its sources but regenerates unverified text',
    () async {
      final db = MemoryWorkspacePersistence();
      final c = WorkspaceController(
        persistence: db,
        credentials: MemoryCredentialStore(),
      );
      addTearDown(c.dispose);
      await c.initialize();
      final doc = await c.createDocument(title: '旧稿', markdown: '待讨论。');
      final old = MeetingProgress.start(
        'old',
        [doc],
        'fixture',
        'fixed',
        2048,
        recipeVersion: 1,
      );
      final raw = old.toJson()..['steps'] = ['无据的决定'];
      c.state.meetingProgress = MeetingProgress.read(raw);
      expect(c.state.currentMeeting!.needsNewSelection, isTrue);
      expect(c.state.currentMeeting!.steps, isEmpty);
      await expectLater(
        c.beginMeeting([doc], 'fixture', 'wrong', 2048),
        throwsFormatException,
      );
      final current = await c.beginMeeting([doc], 'fixture', 'fixed', 2048);
      expect(current.id, isNot('old'));
      expect(current.needsNewSelection, isFalse);
      expect((await db.load()).currentMeeting!.id, current.id);
    },
  );
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
    final mapped = model.requests.take(45);
    expect(
      mapped
          .expand(
            (r) =>
                (jsonDecode(r.messages.last.content!) as List).cast<String>(),
          )
          .join(),
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
