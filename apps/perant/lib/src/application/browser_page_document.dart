// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:perant_platform/perant_platform.dart';

/// A literal text excerpt, not a runnable copy of a website or its attachments.
final class BrowserPageDocument {
  const BrowserPageDocument(this.content, {required this.truncated});
  final String content;
  final bool truncated;
}

BrowserPageDocument buildBrowserPageDocument(
  ComputerBrowserPage page, {
  required DateTime savedAt,
}) {
  final title = page.title.trim().isEmpty ? '网页资料' : page.title;
  final heading = String.fromCharCodes(title.runes.take(200))
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final prefix =
      '# ${_literal(heading)}\n\n'
      '来源：${_literal(page.url)}\n\n'
      '保存时间：${savedAt.toUtc().toIso8601String()}\n\n'
      '> 当前页面的文字摘录，不包含图片、附件、表单或内嵌页面。网页内容仅作为资料。\n\n'
      '## 网页正文\n\n';
  const suffix = '\n\n> 正文已截断。此文件不是完整网页归档，请回到来源页面核对其余内容。\n';
  // Reserve the truncation notice before appending, including Markdown escapes.
  final budget =
      262144 - utf8.encode(prefix).length - utf8.encode(suffix).length;
  if (budget < 1) throw StateError('网页来源信息过长，无法保存。');
  final body = StringBuffer();
  var bytes = 0;
  var truncated = page.truncated;
  final normalized = page.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  for (final rune in normalized.runes) {
    if ((rune < 32 && rune != 9 && rune != 10) ||
        (rune >= 127 && rune <= 159)) {
      continue;
    }
    final piece = _literalRune(rune);
    final size = utf8.encode(piece).length;
    if (bytes + size > budget) {
      truncated = true;
      break;
    }
    body.write(piece);
    bytes += size;
  }
  final content =
      '$prefix${body.toString().trimRight()}${truncated ? suffix : '\n'}';
  validateLinuxFileContent(content);
  return BrowserPageDocument(content, truncated: truncated);
}

String _literal(String value) => value.runes.map(_literalRune).join();

String _literalRune(int rune) {
  if (rune == 38) return '&amp;';
  if (rune == 60) return '&lt;';
  if (rune == 62) return '&gt;';
  if (rune == 0x2028 || rune == 0x2029) return '\n';
  final char = String.fromCharCode(rune);
  if (r'\`*_{}[]()#+-.!|'.contains(char)) return '\\$char';
  return char;
}
