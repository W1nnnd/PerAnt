// SPDX-License-Identifier: GPL-3.0-only

import 'package:perant_core/perant_core.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 13);
  MarkdownDocument document() => MarkdownDocument(
        id: 'minutes',
        title: '会议纪要',
        markdown: '# 会议纪要\n\n待确认。',
        updatedAt: now,
      );

  test('unconfirmed drafts cannot produce an export snapshot', () {
    expect(() => document().confirmedSnapshot(), throwsStateError);
  });

  test('an edit increments revision and invalidates previous confirmation', () {
    final confirmed = document().confirm(at: now);
    final edited = confirmed.edit('# 修改后的纪要', at: now);
    expect(confirmed.isConfirmed, isTrue);
    expect(edited.revision, 2);
    expect(edited.isConfirmed, isFalse);
    expect(edited.confirmedSnapshot, throwsStateError);
  });

  test('a snapshot stays bound to the version the user actually reviewed', () {
    final confirmed = document().confirm(at: now);
    final snapshot = confirmed.confirmedSnapshot();
    final edited = confirmed.edit('后来新增但未确认的内容', at: now);
    expect(snapshot.revision, 1);
    expect(snapshot.markdown, confirmed.markdown);
    expect(snapshot.markdown, isNot(edited.markdown));
  });

  test('saving unchanged text preserves confirmation', () {
    final confirmed = document().confirm(at: now);
    expect(confirmed.edit(confirmed.markdown, at: now), same(confirmed));
  });
}
