// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perant/src/application/courseware.dart';
import 'package:perant_core/perant_core.dart';
import 'package:xml/xml.dart';

void main() {
  final at = DateTime.utc(2026, 11, 20);
  final source = MarkdownDocument(
    id: 'perant-intro',
    title: 'PerAnt 入门',
    updatedAt: at,
    markdown:
        '## 选择资料\n\n从文件页导入 Word 或文字 PDF，再选择本次会议使用的资料。\n\n'
        '## 核对会议纪要\n\n检查决策候选和待办，根据行号回到资料核对。\n\n'
        '## 确认与导出\n\n保存并确认当前修订，再选择 DOCX 或 PDF。修改正文后需要重新确认。',
  );
  test('editable slides retain outline changes, citations, body and ordered relationships', () {
    final material = source.confirm(at: at).confirmedSnapshot();
    final outline = MarkdownDocument(
      id: 'outline',
      title: '入门课件',
      updatedAt: at,
      markdown: makeCourseOutline(material),
    );
    expect(outline.confirmedSnapshot, throwsStateError);
    final reviewed = outline
        .edit(outline.markdown.replaceFirst('检查决策候选', '逐条检查决策候选'), at: at)
        .confirm(at: at);
    final bytes = exportCourseSlides(reviewed.confirmedSnapshot());
    final zip = ZipDecoder().decodeBytes(bytes, verify: true);
    String part(String name) => utf8.decode(zip.findFile(name)!.content);
    final pres = XmlDocument.parse(part('ppt/presentation.xml'));
    final slides = pres.findAllElements('p:sldId').length;
    expect(slides, 5);
    final texts = <String>[];
    for (var i = 1; i <= slides; i++) {
      final doc = XmlDocument.parse(part('ppt/slides/slide$i.xml'));
      expect(doc.findAllElements('p:pic'), isEmpty);
      texts.addAll(doc.findAllElements('a:t').map((n) => n.innerText));
    }
    expect(texts.join(), contains('逐条检查决策候选'));
    expect(texts.join(), contains('perant-intro'));
    expect(texts.join(), contains('修改正文后需要重新确认'));
    const dir = String.fromEnvironment('PERANT_OFFICE_SAMPLES');
    if (dir.isNotEmpty) File('$dir/course.pptx').writeAsBytesSync(bytes);
  });
  test(
    'page renders structural Markdown and keeps supplied active markup inert',
    () {
      final unsafe = source.edit(
        source.markdown + '\n\n<script>alert(1)</script>\n\n![备注](https://example.invalid/image.png)',
        at: at,
      );
      final html = courseHtml(unsafe.confirm(at: at).confirmedSnapshot());
      expect(html, contains('<h2>核对会议纪要</h2>'));
      expect(html, contains('Content-Security-Policy'));
      expect(html, isNot(contains('<script')));
      expect(html, isNot(contains('src="https://')));
      expect(html, contains('备注'));
      const dir = String.fromEnvironment('PERANT_OFFICE_SAMPLES');
      if (dir.isNotEmpty) File('$dir/course.html').writeAsStringSync(html);
    },
  );
}
