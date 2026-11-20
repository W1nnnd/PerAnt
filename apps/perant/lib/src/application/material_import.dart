// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

const materialByteLimit = 10 * 1024 * 1024;
const materialCharacterLimit = 20000;
const _xmlLimit = 3 * 1024 * 1024;

String checkMaterialText(String value) {
  if (value.trim().isEmpty) throw const FormatException('没有可导入的文字。');
  if (value.contains('\u0000')) throw const FormatException('资料包含无效的文本字符。');
  if (value.runes.length > materialCharacterLimit) {
    throw const FormatException('正文超过 2 万字，请拆分后导入。');
  }
  return value;
}

String importDocx(Uint8List bytes) {
  if (bytes.length > materialByteLimit)
    throw const FormatException('DOCX 超过 10 MB。');
  final archive = ZipDirectory()..read(InputMemoryStream(bytes), verify: true);
  if (archive.fileHeaders.length > 4096)
    throw const FormatException('DOCX 内部文件过多。');
  final main = archive.fileHeaders.where(
    (h) => h.filename == 'word/document.xml',
  );
  if (main.length != 1) throw const FormatException('找不到唯一的 Word 主文档。');
  final header = main.single;
  if (header.uncompressedSize <= 0 ||
      header.uncompressedSize > _xmlLimit ||
      header.generalPurposeBitFlag.isOdd ||
      ![0, 8].contains(header.compressionMethod)) {
    throw const FormatException('不支持此 DOCX 的压缩方式、加密或正文大小。');
  }
  final compressed = header.file!.getStream(decompress: false).toUint8List();
  final raw = header.compressionMethod == 0
      ? compressed
      : ZLibDecoder().decodeBytes(
          compressed,
          raw: true,
          maxOutputSize: _xmlLimit,
          throwOnError: true,
        );
  if (raw.length != header.uncompressedSize || getCrc32(raw) != header.crc32) {
    throw const FormatException('Word 正文完整性校验失败。');
  }
  final source = utf8.decode(raw);
  if (source.contains('<!DOCTYPE'))
    throw const FormatException('不支持包含 DTD 的文档。');
  final xml = XmlDocument.parse(source);
  final ns = xml.rootElement.name.namespaceUri;
  if (xml.rootElement.name.local != 'document' ||
      !{
        'http://schemas.openxmlformats.org/wordprocessingml/2006/main',
        'http://purl.oclc.org/ooxml/wordprocessingml/main',
      }.contains(ns))
    throw const FormatException('不是支持的 Word 正文。');
  final output = <String>[];
  var paragraphNumber = 0;
  var length = 0;
  for (final p in xml.findAllElements('p', namespaceUri: ns)) {
    paragraphNumber++;
    final line = StringBuffer();
    for (final el in p.descendantElements) {
      if (el.name.namespaceUri != ns) continue;
      switch (el.name.local) {
        case 't':
          line.write(el.innerText);
        case 'tab':
          line.write('\t');
        case 'br':
        case 'cr':
          line.write('\n');
      }
    }
    final value = line.toString().trim();
    if (value.isEmpty) continue;
    length += value.runes.length;
    if (length > materialCharacterLimit)
      throw const FormatException('Word 正文超过 2 万字，请拆分后导入。');
    output.add('【段落 $paragraphNumber】\n$value');
  }
  if (output.isEmpty) throw const FormatException('Word 文档没有可提取的正文。');
  return output.join('\n\n');
}

String importPdfPages(List<String> pages) {
  if (pages.isEmpty || pages.length > 200)
    throw const FormatException('每份 PDF 支持 1 至 200 页。');
  final blocks = <String>[];
  final empty = <int>[];
  var characters = 0;
  for (var i = 0; i < pages.length; i++) {
    final text = pages[i].trim();
    if (text.isEmpty) {
      empty.add(i + 1);
      continue;
    }
    characters += text.runes.length;
    if (characters > materialCharacterLimit)
      throw const FormatException('PDF 正文超过 2 万字，请拆分后导入。');
    blocks.add('【第 ${i + 1} 页】\n$text');
  }
  if (blocks.isEmpty)
    throw const FormatException('此 PDF 没有可提取的文字层，扫描件需要先做 OCR。');
  if (empty.isNotEmpty) blocks.add('未提取到文字的页码：${empty.join("、")}。');
  return blocks.join('\n\n');
}
