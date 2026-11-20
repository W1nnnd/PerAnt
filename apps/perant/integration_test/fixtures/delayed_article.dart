// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

const articlePlaceholder = '正文正在发布，请稍候。';

/// Serves one article whose URL and title stay fixed while its body changes.
/// The caller controls when the final paragraph becomes available.
Future<HttpServer> serveDelayedArticle({
  required Future<String> Function() loadParagraph,
  void Function()? onRendered,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final response = request.response;
    response.headers.set('Cache-Control', 'no-store');
    try {
      switch ((request.method, request.uri.path)) {
        case ('GET', '/article'):
          response.headers.contentType = ContentType.html;
          response.write('''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>会议资料</title></head><body>
<h1>会议资料</h1><p id="paragraph">$articlePlaceholder</p>
<script>
window.addEventListener('load', async () => {
  const response = await fetch('/paragraph');
  if (!response.ok) return;
  document.getElementById('paragraph').textContent = await response.text();
  await fetch('/rendered', {method: 'POST'});
});
</script></body></html>''');
        case ('GET', '/paragraph'):
          response.headers.contentType = ContentType.text;
          response.write(await loadParagraph());
        case ('POST', '/rendered'):
          onRendered?.call();
          response.statusCode = HttpStatus.noContent;
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    } on IOException {
      // The test or a manual browser can leave while the paragraph is pending.
    }
  });
  return server;
}

Future<void> withDelayedArticle(
  String paragraph,
  Future<void> Function(String url, Future<void> Function() publish) check,
) async {
  final release = Completer<String>();
  final rendered = Completer<void>();
  final server = await serveDelayedArticle(
    loadParagraph: () => release.future,
    onRendered: () {
      if (!rendered.isCompleted) rendered.complete();
    },
  );
  try {
    await check('http://127.0.0.1:${server.port}/article', () {
      release.complete(paragraph);
      return rendered.future.timeout(const Duration(seconds: 25));
    });
  } finally {
    if (!release.isCompleted) release.complete(paragraph);
    await server.close(force: true);
  }
}

/// Run with Dart on the host. Forward the printed port with adb reverse to
/// let a real model navigate the same fixture in the Android app.
Future<void> main() async {
  final server = await serveDelayedArticle(
    loadParagraph: () async {
      await Future<void>.delayed(const Duration(seconds: 5));
      return '会议决定在周五复核资料，负责人是林青。';
    },
  );
  stdout.writeln('adb reverse tcp:${server.port} tcp:${server.port}');
  stdout.writeln('http://127.0.0.1:${server.port}/article');
}
