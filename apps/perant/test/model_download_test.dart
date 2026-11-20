// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perant/src/data/gguf_models.dart';

void main() {
  test('partial downloads resume from the exact range and only verified bytes publish', () async {
    final root = await Directory.systemTemp.createTemp('perant-model-');
    final file = File('${root.path}/fixture.gguf');
    final partial = File('${file.path}.download');
    final data = utf8.encode('模型测试资料1234567890');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final url = Uri.parse('http://127.0.0.1:${server.port}/model');
    final ranges = <String?>[];
    var round = 0;
    server.listen((request) async {
      ranges.add(request.headers.value(HttpHeaders.rangeHeader));
      if (round == 0) {
        request.response.add(data.sublist(0, 4));
      } else if (round == 1) {
        request.response.statusCode = 206;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 4-${data.length - 1}/${data.length}',
        );
        request.response.add(data.sublist(4));
      } else {
        request.response.add(data);
      }
      round++;
      await request.response.close();
    });
    Future<void> download(String hash) => downloadVerifiedModel(
      url,
      file,
      data.length,
      hash,
      stopped: () => false,
      progress: (_) {},
    );
    try {
      final digest = sha256.convert(data).toString();
      await expectLater(download(digest), throwsA(isA<HttpException>()));
      expect(await file.exists(), false);
      expect(await partial.length(), 4);
      await download(digest);
      expect(ranges, [null, 'bytes=4-']);
      expect(await file.readAsBytes(), data);
      await partial.writeAsBytes([0, 1]);
      await expectLater(download('0' * 64), throwsFormatException);
      expect(ranges.last, 'bytes=2-');
      expect(await partial.exists(), false);
      expect(await file.readAsBytes(), data);
    } finally {
      await server.close(force: true);
      await root.delete(recursive: true);
    }
  });
}
