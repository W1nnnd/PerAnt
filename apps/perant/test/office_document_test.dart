// SPDX-License-Identifier: GPL-3.0-only
import 'dart:io';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perant/src/application/material_import.dart';
import 'package:perant/src/application/office_document.dart';
import 'package:perant_core/perant_core.dart';
import 'package:xml/xml.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final at = DateTime.utc(2026, 11, 20);
  final markdown = [
    '# 中文会议记录',
    '',
    '记录 **决定** 和 *follow-up*。',
    '',
    '| 负责人 | 截止时间 |',
    '| --- | --- |',
    '| 小林 | 周三 |',
    ...List.generate(72, (i) => '| 表格第${i + 1}行 | 已核对 |'),
    '',
    '长段开头${'资料核查' * 500}长段结尾',
    '',
    ...List.generate(100, (i) => '第${i + 1}段，确认导出不会遗漏多页中文内容。\n'),
    '终稿校验结束',
  ].join('\n');
  final confirmed = MarkdownDocument(
    id: 'office',
    title: '例/会',
    markdown: markdown,
    updatedAt: at,
  ).confirm(at: at).confirmedSnapshot();
  test(
    'Word roundtrip preserves content, paragraphs, emphasis, table and A4',
    () {
      final bytes = exportDocx(confirmed);
      final recovered = importDocx(bytes);
      expect(recovered, contains('【段落 1】\n中文会议记录'));
      expect(recovered, contains('小林'));
      expect(recovered, endsWith('终稿校验结束'));
      final zip = ZipDecoder().decodeBytes(bytes, verify: true);
      final doc = XmlDocument.parse(
        utf8.decode(zip.findFile('word/document.xml')!.content),
      );
      expect(doc.findAllElements('w:tbl'), hasLength(1));
      expect(doc.findAllElements('w:b'), isNotEmpty);
      expect(doc.findAllElements('w:i'), isNotEmpty);
      expect(doc.findAllElements('w:pgSz').single.getAttribute('w:h'), '16838');
      expect(officeFileName(confirmed, DocumentFormat.docx), '例_会-v1.docx');
      _writeSample('sample.docx', bytes);
    },
  );
  test(
    'PDF uses reviewed Chinese text and writes a multipage document offline',
    () async {
      // tool/check runs Flutter from the workspace root without an app bundle.
      final packageFont = File(officeFontAsset);
      final file = packageFont.existsSync()
          ? packageFont
          : File('apps/perant/$officeFontAsset');
      final font = ByteData.sublistView(await file.readAsBytes());
      final bytes = await exportPdf(confirmed, font);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(
        RegExp(r'/Type\s*/Page\b')
            .allMatches(String.fromCharCodes(bytes))
            .length,
        greaterThan(1),
      );
      _writeSample('sample.pdf', bytes);
    },
  );
  test(
    'imports preserve physical PDF pages and explain omissions and limits',
    () {
      expect(
        importPdfPages([' 第一页 ', '', '第三页']),
        '【第 1 页】\n第一页\n\n【第 3 页】\n第三页\n\n未提取到文字的页码：2。',
      );
      expect(() => importPdfPages([' ', '']), throwsFormatException);
      expect(() => importPdfPages(['字' * 20001]), throwsFormatException);
      expect(
        () => importDocx(Uint8List.fromList([0, 1, 2])),
        throwsA(anything),
      );
      expect(() => checkMaterialText('a\u0000'), throwsFormatException);
    },
  );
}

void _writeSample(String name, Uint8List bytes) {
  const path = String.fromEnvironment('PERANT_OFFICE_SAMPLES');
  if (path.isNotEmpty) File('$path/$name').writeAsBytesSync(bytes, flush: true);
}
