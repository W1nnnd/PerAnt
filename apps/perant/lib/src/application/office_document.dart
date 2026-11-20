// SPDX-License-Identifier: GPL-3.0-only
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:perant_core/perant_core.dart';
import 'package:xml/xml.dart';

const officeFontAsset = 'assets/fonts/LXGWWenKai-Regular.ttf';

String officeFileName(ConfirmedDocument document, DocumentFormat format) {
  final title = document.title
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .trim();
  final base = String.fromCharCodes(title.runes.take(50));
  return '${base.isEmpty ? 'PerAnt' : base}-v${document.revision}.${format.name}';
}

Future<Uint8List> renderOfficePdf((ConfirmedDocument, ByteData) input) =>
    exportPdf(input.$1, input.$2);

/// Uses the same GitHub-flavored Markdown dialect as the editor. Both formats
/// consume the reviewed snapshot; no images, fonts or links are fetched.
List<md.Node> _parse(ConfirmedDocument document) => md.Document(
  extensionSet: md.ExtensionSet.gitHubFlavored,
  encodeHtml: false,
).parseLines(document.markdown.replaceAll('\r\n', '\n').split('\n'));

typedef _Run = ({String text, bool bold, bool italic, bool code});
typedef _Paragraph = List<_Run>;
typedef _Block = ({int heading, _Paragraph runs, List<List<_Paragraph>> rows});

_Run _text(
  String value, {
  bool bold = false,
  bool italic = false,
  bool code = false,
}) => (text: value, bold: bold, italic: italic, code: code);

Iterable<_Run> _inline(
  md.Node node, {
  bool bold = false,
  bool italic = false,
  bool code = false,
}) sync* {
  if (node is md.Text) {
    yield _text(node.text, bold: bold, italic: italic, code: code);
  } else if (node is md.Element) {
    if (node.tag == 'br') {
      yield _text('\n');
      return;
    }
    if (node.tag == 'img') {
      yield _text('【图片：' + (node.attributes['alt'] ?? '未命名') + '】');
      return;
    }
    if (node.tag == 'input') {
      yield _text(node.attributes.containsKey('checked') ? '☑ ' : '☐ ');
      return;
    }
    for (final child in node.children ?? <md.Node>[]) {
      yield* _inline(
        child,
        bold: bold || node.tag == 'strong',
        italic: italic || node.tag == 'em',
        code: code || node.tag == 'code',
      );
    }
    final href = node.attributes['href'];
    if (node.tag == 'a' && href != null && node.textContent != href) {
      yield _text(' (' + href + ')');
    }
  }
}

Iterable<_Block> _blocks(List<md.Node> nodes, {String prefix = ''}) sync* {
  for (final node in nodes) {
    if (node is md.Text && node.text.trim().isEmpty) continue;
    final el = node is md.Element ? node : null;
    final children = el?.children ?? <md.Node>[];
    final tag = el?.tag;
    if (tag == 'table') {
      final rows = <List<_Paragraph>>[];
      for (final section in children.whereType<md.Element>()) {
        for (final row in (section.children ?? []).whereType<md.Element>()) {
          rows.add([
            for (final cell in (row.children ?? []).whereType<md.Element>())
              _inline(cell, bold: cell.tag == 'th').toList(),
          ]);
        }
      }
      if (rows.isNotEmpty) yield (heading: 0, runs: <_Run>[], rows: rows);
    } else if (tag == 'ul' || tag == 'ol') {
      var index = int.tryParse(el!.attributes['start'] ?? '') ?? 1;
      for (final item in children.whereType<md.Element>()) {
        final marker = tag == 'ol' ? (index++).toString() + '. ' : '• ';
        var runs = <_Run>[_text(prefix + marker)];
        for (final child in item.children ?? <md.Node>[]) {
          if (child is md.Element && (child.tag == 'ul' || child.tag == 'ol')) {
            if (runs.isNotEmpty) yield (heading: 0, runs: runs, rows: []);
            runs = [];
            yield* _blocks([child], prefix: prefix + '    ');
          } else {
            if (child is md.Element && child.tag == 'p' && runs.length > 1) {
              runs.add(_text('\n'));
            }
            runs.addAll(_inline(child));
          }
        }
        if (runs.isNotEmpty) yield (heading: 0, runs: runs, rows: []);
      }
    } else if (tag == 'blockquote') {
      yield* _blocks(children, prefix: prefix + '│ ');
    } else {
      final level = tag != null && RegExp(r'^h[1-6]$').hasMatch(tag)
          ? int.parse(tag.substring(1))
          : 0;
      yield (
        heading: level,
        runs: [
          if (prefix.isNotEmpty) _text(prefix),
          if (tag == 'hr')
            _text('────────')
          else
            ..._inline(node, bold: level > 0),
        ],
        rows: [],
      );
    }
  }
}

const _word = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

Uint8List exportDocx(ConfirmedDocument document) {
  final xml = XmlBuilder();
  void w(
    String name, {
    Map<String, String> attrs = const {},
    void Function()? body,
  }) => xml.element(
    'w:' + name,
    attributes: {for (final a in attrs.entries) 'w:' + a.key: a.value},
    nest: body,
  );
  void paragraph(_Paragraph runs, {int heading = 0}) {
    w(
      'p',
      body: () {
        w(
          'pPr',
          body: () {
            if (heading > 0)
              w('outlineLvl', attrs: {'val': (heading - 1).toString()});
            w('spacing', attrs: {'after': '120'});
          },
        );
        for (final run in runs) {
          w(
            'r',
            body: () {
              w(
                'rPr',
                body: () {
                  w(
                    'rFonts',
                    attrs: {
                      'ascii': run.code ? 'Courier New' : 'Calibri',
                      'eastAsia': '等线',
                    },
                  );
                  if (run.bold) w('b');
                  if (run.italic) w('i');
                  w(
                    'sz',
                    attrs: {
                      'val': heading == 0
                          ? '22'
                          : (40 - 3 * heading).toString(),
                    },
                  );
                },
              );
              var first = true;
              for (final line in run.text.split('\n')) {
                if (!first) w('br');
                first = false;
                xml.element(
                  'w:t',
                  attributes: {'xml:space': 'preserve'},
                  nest: line.replaceAll(
                    RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff]'),
                    '�',
                  ),
                );
              }
            },
          );
        }
      },
    );
  }

  xml.element(
    'w:document',
    attributes: {'xmlns:w': _word},
    nest: () {
      w(
        'body',
        body: () {
          for (final block in _blocks(_parse(document))) {
            if (block.rows.isEmpty) {
              paragraph(block.runs, heading: block.heading);
            } else {
              final cols = block.rows.fold(
                1,
                (n, r) => n > r.length ? n : r.length,
              );
              w(
                'tbl',
                body: () {
                  w(
                    'tblPr',
                    body: () {
                      w('tblW', attrs: {'w': '5000', 'type': 'pct'});
                      w(
                        'tblBorders',
                        body: () {
                          for (final edge in [
                            'top',
                            'left',
                            'bottom',
                            'right',
                            'insideH',
                            'insideV',
                          ]) {
                            w(
                              edge,
                              attrs: {
                                'val': 'single',
                                'sz': '4',
                                'color': '999999',
                              },
                            );
                          }
                        },
                      );
                    },
                  );
                  w(
                    'tblGrid',
                    body: () {
                      for (var i = 0; i < cols; i++) {
                        w('gridCol', attrs: {'w': (9000 ~/ cols).toString()});
                      }
                    },
                  );
                  for (final row in block.rows) {
                    w(
                      'tr',
                      body: () {
                        for (final cell in row) {
                          w('tc', body: () => paragraph(cell));
                        }
                      },
                    );
                  }
                },
              );
            }
          }
          w(
            'sectPr',
            body: () {
              w('pgSz', attrs: {'w': '11906', 'h': '16838'});
              w(
                'pgMar',
                attrs: {
                  'top': '1440',
                  'bottom': '1440',
                  'left': '1440',
                  'right': '1440',
                },
              );
            },
          );
        },
      );
    },
  );
  final zip = Archive()
    ..addFile(
      ArchiveFile.string(
        '[Content_Types].xml',
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        '_rels/.rels',
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'word/document.xml',
        xml.buildDocument().toXmlString(),
      ),
    );
  return ZipEncoder().encodeBytes(zip);
}

Future<Uint8List> exportPdf(
  ConfirmedDocument document,
  ByteData fontData,
) async {
  final font = pw.Font.ttf(fontData);
  final pdf = pw.Document(title: document.title, author: 'PerAnt');
  pw.RichText paragraph(_Paragraph runs, {int heading = 0}) => pw.RichText(
    overflow: pw.TextOverflow.span,
    text: pw.TextSpan(
      style: pw.TextStyle(
        font: font,
        fontSize: heading == 0 ? 11 : 21.0 - heading,
      ),
      children: [
        for (final run in runs)
          pw.TextSpan(
            text: run.text,
            style: pw.TextStyle(
              font: font,
              renderingMode: run.bold
                  ? PdfTextRenderingMode.fillAndStroke
                  : PdfTextRenderingMode.fill,
              fontItalic: pw.Font.helveticaOblique(),
              fontStyle: run.italic ? pw.FontStyle.italic : pw.FontStyle.normal,
              fontFallback: [font],
              background: run.code
                  ? const pw.BoxDecoration(color: PdfColors.grey200)
                  : null,
            ),
          ),
      ],
    ),
  );
  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      maxPages: 500,
      margin: const pw.EdgeInsets.all(44),
      build: (_) => [
        for (final block in _blocks(_parse(document))) ...[
          if (block.rows.isEmpty)
            paragraph(block.runs, heading: block.heading)
          else
            pw.Table(
              border: pw.TableBorder.all(width: .4, color: PdfColors.grey600),
              children: [
                for (final row in block.rows)
                  pw.TableRow(
                    children: [
                      for (final cell in row)
                        pw.Padding(
                          padding: const pw.EdgeInsets.all(4),
                          child: paragraph(cell),
                        ),
                    ],
                  ),
              ],
            ),
          pw.SizedBox(height: 5),
        ],
      ],
    ),
  );
  return pdf.save();
}
