// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:perant_core/perant_core.dart';

const _escape = HtmlEscape();
const _p = 'http://schemas.openxmlformats.org/presentationml/2006/main';
const _a = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const _r =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _rels = 'http://schemas.openxmlformats.org/package/2006/relationships';
const _types = 'http://schemas.openxmlformats.org/package/2006/content-types';
const _ppt = 'application/vnd.openxmlformats-officedocument.presentationml.';
const _ns = 'xmlns:p="$_p" xmlns:a="$_a" xmlns:r="$_r"';
const _group =
    '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
    '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/>'
    '<a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>';
const _map =
    '<p:clrMap accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" '
    'accent5="accent5" accent6="accent6" bg1="lt1" bg2="lt2" folHlink="folHlink" hlink="hlink" tx1="dk1" tx2="dk2"/>';
const _inheritColors = '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>';

String _xml(String s) => _escape.convert(
  s.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff]'), '�'),
);

List<md.Node> _nodes(String source) => md.Document(
  extensionSet: md.ExtensionSet.gitHubFlavored,
  encodeHtml: false,
).parseLines(source.replaceAll('\r\n', '\n').split('\n'));

String _plain(md.Node node) {
  if (node is md.Text) return node.text;
  final el = node as md.Element;
  if (el.tag == 'br') return '\n';
  if (el.tag == 'img') return el.attributes['alt'] ?? '图片';
  final sep = switch (el.tag) {
    'tr' => ' | ',
    'ul' || 'ol' || 'table' || 'thead' || 'tbody' => '\n',
    _ => '',
  };
  return (el.children ?? []).map(_plain).join(sep);
}

String makeCourseOutline(ConfirmedDocument source) {
  final draft = StringBuffer('# ${source.title}\n\n');
  var hasSection = false;
  for (final node in _nodes(source.markdown)) {
    final value = _plain(node).trim();
    if (value.isEmpty) continue;
    final heading =
        node is md.Element && RegExp(r'^h[1-6]$').hasMatch(node.tag);
    if (heading) {
      draft.writeln('## $value\n');
      hasSection = true;
    } else {
      if (!hasSection) {
        draft.writeln('## 主要内容\n');
        hasSection = true;
      }
      for (final line in value.split('\n').where((s) => s.trim().isNotEmpty)) {
        draft.writeln('- $line');
      }
      draft.writeln();
    }
  }
  draft.write(
    '## 参考资料\n\n- ${source.title} · 版本 ${source.revision} · ${source.documentId}',
  );
  return draft.toString();
}

typedef _Slide = ({String title, List<String> lines});

int _width(int rune) => rune >= 0x2e80 ? 2 : 1;
Iterable<String> _wrap(String s, int width) sync* {
  var line = StringBuffer();
  var used = 0;
  for (final rune in s.runes) {
    final w = _width(rune);
    if (used + w > width) {
      yield line.toString();
      line = StringBuffer();
      used = 0;
    }
    line.writeCharCode(rune);
    used += w;
  }
  if (line.isNotEmpty) yield line.toString();
}

List<_Slide> _slides(ConfirmedDocument source) {
  final slides = <_Slide>[];
  var title = source.title;
  final lines = <String>[];
  void flush() {
    if (lines.isEmpty) return;
    final titles = _wrap(title, 42).toList();
    final body = [...titles.skip(1), ...lines];
    for (var i = 0; i < body.length; i += 7) {
      slides.add((
        title: titles.isEmpty ? '课件' : titles.first,
        lines: body.skip(i).take(7).toList(),
      ));
    }
    lines.clear();
  }

  var pendingHeading = false;
  for (final node in _nodes(source.markdown)) {
    final value = _plain(node).trim();
    if (value.isEmpty) continue;
    if (node is md.Element && RegExp(r'^h[1-6]$').hasMatch(node.tag)) {
      if (pendingHeading && lines.isEmpty)
        slides.add((title: title, lines: []));
      flush();
      title = value;
      pendingHeading = true;
    } else {
      for (final line in value.split('\n')) {
        lines.addAll(_wrap(line, 68));
      }
      pendingHeading = false;
    }
  }
  if (pendingHeading && lines.isEmpty) slides.add((title: title, lines: []));
  flush();
  if (slides.isEmpty || slides.length > 150)
    throw const FormatException('大纲应生成 1 至 150 页，请检查内容或分册导出。');
  return slides;
}

String _relationships(List<(String, String, String)> entries) =>
    '<Relationships xmlns="$_rels">${entries.map((e) => '<Relationship Id="${e.$1}" Type="$_r/${e.$2}" Target="${e.$3}"/>').join()}</Relationships>';

String _shape(
  int id,
  String name,
  List<String> lines,
  int y,
  int height,
  int size,
  String color, {
  bool bold = false,
}) {
  final paragraphs = lines
      .map(
        (line) =>
            '<a:p><a:pPr><a:lnSpc><a:spcPct val="125000"/></a:lnSpc></a:pPr>'
            '<a:r><a:rPr lang="zh-CN" sz="$size" b="${bold ? 1 : 0}"><a:solidFill><a:srgbClr val="$color"/></a:solidFill>'
            '<a:latin typeface="Aptos"/><a:ea typeface="Microsoft YaHei"/></a:rPr><a:t>${_xml(line)}</a:t></a:r>'
            '<a:endParaRPr lang="zh-CN" sz="$size"/></a:p>',
      )
      .join();
  return '<p:sp><p:nvSpPr><p:cNvPr id="$id" name="$name"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>'
      '<p:spPr><a:xfrm><a:off x="640080" y="$y"/><a:ext cx="10881360" cy="$height"/></a:xfrm>'
      '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody>'
      '<a:bodyPr wrap="square"><a:normAutofit/></a:bodyPr><a:lstStyle/>$paragraphs</p:txBody></p:sp>';
}

/// Build a native slide tree; each paragraph remains editable in PowerPoint.
Uint8List exportCourseSlides(ConfirmedDocument document) {
  final slides = _slides(document);
  final zip = Archive();
  void part(String path, String content) =>
      zip.addFile(ArchiveFile.string(path, content));
  final parts = <String, String>{
    'ppt/presentation.xml': '${_ppt}presentation.main+xml',
    'ppt/slideMasters/slideMaster1.xml': '${_ppt}slideMaster+xml',
    'ppt/slideLayouts/slideLayout1.xml': '${_ppt}slideLayout+xml',
    'ppt/theme/theme1.xml':
        'application/vnd.openxmlformats-officedocument.theme+xml',
    for (var i = 1; i <= slides.length; i++)
      'ppt/slides/slide$i.xml': '${_ppt}slide+xml',
  };
  part(
    '[Content_Types].xml',
    '<Types xmlns="$_types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>${parts.entries.map((e) => '<Override PartName="/${e.key}" ContentType="${e.value}"/>').join()}</Types>',
  );
  part(
    '_rels/.rels',
    _relationships([('rId1', 'officeDocument', 'ppt/presentation.xml')]),
  );
  part(
    'ppt/presentation.xml',
    '<p:presentation $_ns><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>'
        '<p:sldIdLst>${List.generate(slides.length, (i) => '<p:sldId id="${256 + i}" r:id="rId${2 + i}"/>').join()}</p:sldIdLst>'
        '<p:sldSz cx="12192000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>',
  );
  part(
    'ppt/_rels/presentation.xml.rels',
    _relationships([
      ('rId1', 'slideMaster', 'slideMasters/slideMaster1.xml'),
      for (var i = 0; i < slides.length; i++)
        ('rId${i + 2}', 'slide', 'slides/slide${i + 1}.xml'),
    ]),
  );
  part(
    'ppt/slideMasters/slideMaster1.xml',
    '<p:sldMaster $_ns><p:cSld name="PerAnt"><p:spTree>$_group</p:spTree></p:cSld>'
        '$_map<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>',
  );
  part(
    'ppt/slideMasters/_rels/slideMaster1.xml.rels',
    _relationships([
      ('rId1', 'slideLayout', '../slideLayouts/slideLayout1.xml'),
      ('rId2', 'theme', '../theme/theme1.xml'),
    ]),
  );
  part(
    'ppt/slideLayouts/slideLayout1.xml',
    '<p:sldLayout $_ns type="blank" preserve="1"><p:cSld name="Blank"><p:spTree>$_group</p:spTree></p:cSld>$_inheritColors</p:sldLayout>',
  );
  part(
    'ppt/slideLayouts/_rels/slideLayout1.xml.rels',
    _relationships([
      ('rId1', 'slideMaster', '../slideMasters/slideMaster1.xml'),
    ]),
  );
  part('ppt/theme/theme1.xml', _theme());
  for (var i = 0; i < slides.length; i++) {
    final page = slides[i];
    final slide =
        '<p:sld $_ns><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="FBFAF6"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>'
        '<p:spTree>$_group${_shape(2, "Title", [page.title], 400000, 1260000, 3400, "25463E", bold: true)}'
        '${_shape(3, "Content", page.lines.isEmpty ? [""] : page.lines, 1850000, 4200000, 2100, "22352F")}'
        '${_shape(4, "Page", ["${i + 1} / ${slides.length}"], 6270000, 370000, 1100, "527267")}'
        '</p:spTree></p:cSld>$_inheritColors</p:sld>';
    part('ppt/slides/slide${i + 1}.xml', slide);
    part(
      'ppt/slides/_rels/slide${i + 1}.xml.rels',
      _relationships([
        ('rId1', 'slideLayout', '../slideLayouts/slideLayout1.xml'),
      ]),
    );
  }
  return ZipEncoder().encodeBytes(zip);
}

String _theme() {
  const palette = {
    'dk1': '1F312B',
    'lt1': 'FFFFFF',
    'dk2': '25463E',
    'lt2': 'FBFAF6',
    'accent1': '336759',
    'accent2': 'A15C42',
    'accent3': '697EA0',
    'accent4': '806988',
    'accent5': 'C9A346',
    'accent6': '6E8279',
    'hlink': '285BA2',
    'folHlink': '694B89',
  };
  const solid = '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>';
  const fonts =
      '<a:latin typeface="Aptos"/><a:ea typeface="Microsoft YaHei"/><a:cs typeface="Arial"/>';
  return '<a:theme xmlns:a="$_a" name="PerAnt"><a:themeElements><a:clrScheme name="PerAnt">'
      '${palette.entries.map((e) => '<a:${e.key}><a:srgbClr val="${e.value}"/></a:${e.key}>').join()}</a:clrScheme>'
      '<a:fontScheme name="PerAnt"><a:majorFont>$fonts</a:majorFont><a:minorFont>$fonts</a:minorFont></a:fontScheme>'
      '<a:fmtScheme name="PerAnt"><a:fillStyleLst>${solid * 3}</a:fillStyleLst><a:lnStyleLst>${('<a:ln w="9525">$solid</a:ln>') * 3}</a:lnStyleLst>'
      '<a:effectStyleLst>${'<a:effectStyle><a:effectLst/></a:effectStyle>' * 3}</a:effectStyleLst><a:bgFillStyleLst>${solid * 3}</a:bgFillStyleLst>'
      '</a:fmtScheme></a:themeElements></a:theme>';
}

/// Only structural Markdown elements are emitted. Source markup is treated as
/// ordinary text and remote links/images are rendered as labels.
String courseHtml(ConfirmedDocument document) {
  const tags = {
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'p',
    'ul',
    'ol',
    'li',
    'blockquote',
    'pre',
    'code',
    'strong',
    'em',
    'table',
    'thead',
    'tbody',
    'tr',
    'th',
    'td',
    'del',
  };
  String html(md.Node n) {
    if (n is md.Text) return _escape.convert(n.text);
    final e = n as md.Element;
    if (e.tag == 'img') return _escape.convert(e.attributes['alt'] ?? '图片');
    if (e.tag == 'br' || e.tag == 'hr') return '<${e.tag}>';
    final body = (e.children ?? []).map(html).join();
    return tags.contains(e.tag) ? '<${e.tag}>$body</${e.tag}>' : body;
  }

  return '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
      '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'">'
      '<title>${_escape.convert(document.title)}</title><style>'
      'body{max-width:46rem;margin:auto;padding:2rem 1.3rem;background:#fbfaf6;color:#203a32;font:1rem/1.75 system-ui,sans-serif;overflow-wrap:anywhere}'
      'h1,h2{line-height:1.25}h2{margin-top:2rem}table{border-collapse:collapse}td,th{border:1px solid #aab9b2;padding:.4em .7em}pre{white-space:pre-wrap}'
      '</style></head><body><main>${_nodes(document.markdown).map(html).join('\n')}</main></body></html>';
}
