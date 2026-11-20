// SPDX-License-Identifier: GPL-3.0-only
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

enum DeviceModel {
  small(
    '0.8B',
    '6ab461498e2023f6e3c1baea90a8f0fe38ab64d0',
    532517120,
    'bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517',
  ),
  medium(
    '2B',
    'f6d5376be1edb4d416d56da11e5397a961aca8ae',
    1280835840,
    'aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223',
  );

  const DeviceModel(this.size, this.revision, this.bytes, this.sha);
  final String size, revision, sha;
  final int bytes;
  String get id => 'Qwen3.5-$size';
  String get name => '$id-Q4_K_M.gguf';
  Uri get url =>
      Uri.https('huggingface.co', '/unsloth/$id-GGUF/resolve/$revision/$name');

  Future<File> file() async => File(
    '${(await getApplicationSupportDirectory()).path}/models/$revision/$name',
  );

  Future<bool> installed() async {
    final target = await file();
    return await target.exists() && await target.length() == bytes;
  }

  Future<void> download({
    required bool Function() stopped,
    required void Function(int) progress,
    Future<int?> Function()? availableBytes,
  }) async {
    await downloadVerifiedModel(
      url,
      await file(),
      bytes,
      sha,
      stopped: stopped,
      progress: progress,
      availableBytes: availableBytes,
    );
  }

  Future<void> install(
    Stream<List<int>> input, {
    required bool Function() stopped,
    required void Function(int) progress,
    Future<int?> Function()? availableBytes,
  }) async {
    await _requireModelSpace(availableBytes, bytes);
    final target = await file();
    await target.parent.create(recursive: true);
    final stage = await target.parent.createTemp('verify-');
    try {
      final temporary = File('${stage.path}/model.part');
      final writer = await temporary.open(mode: FileMode.write);
      var count = 0;
      late Digest digest;
      try {
        digest = await sha256
            .bind(
              input.asyncMap((chunk) async {
                if (stopped()) throw StateError('安装已取消。');
                count += chunk.length;
                if (count > bytes) throw const FormatException('文件超出该模型大小。');
                await writer.writeFrom(chunk);
                progress(count);
                return chunk;
              }),
            )
            .first;
        await writer.flush();
      } finally {
        await writer.close();
      }
      if (stopped()) throw StateError('安装已取消。');
      if (count != bytes || digest.toString() != sha)
        throw const FormatException('模型长度或 SHA-256 不符。');
      await temporary.rename(target.path);
    } finally {
      await stage.delete(recursive: true);
    }
  }
}

final _activeDownloads = <String>{};

Future<void> _requireModelSpace(
  Future<int?> Function()? read,
  int needed,
) async {
  final free = await read?.call();
  if (free != null && free < needed) {
    final missing = ((needed - free) / 1000000).ceil();
    throw FormatException('存储空间不足，还需至少 $missing MB。释放空间后可重试。');
  }
}

Future<void> downloadVerifiedModel(
  Uri uri,
  File target,
  int size,
  String checksum, {
  required bool Function() stopped,
  required void Function(int) progress,
  Future<int?> Function()? availableBytes,
}) async {
  if (!_activeDownloads.add(target.path)) throw StateError('该模型正在下载。');
  final partial = File('${target.path}.download');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    await target.parent.create(recursive: true);
    var count = await partial.exists() ? await partial.length() : 0;
    if (count > size) {
      await partial.delete();
      count = 0;
    }
    progress(count);
    if (stopped()) throw StateError('下载已暂停。');
    await _requireModelSpace(availableBytes, size - count);
    if (count < size) {
      final request = await client.getUrl(uri);
      if (count > 0)
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$count-');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode == HttpStatus.ok) {
        count = 0;
      } else if (response.statusCode != HttpStatus.partialContent ||
          response.headers.value(HttpHeaders.contentRangeHeader) !=
              'bytes $count-${size - 1}/$size') {
        throw HttpException('未收到预期范围的数据（${response.statusCode}）。');
      }
      final writer = await partial.open(
        mode: count == 0 ? FileMode.write : FileMode.append,
      );
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          if (stopped()) throw StateError('下载已暂停。');
          if (count + chunk.length > size)
            throw const FormatException('下载超出模型清单大小。');
          await writer.writeFrom(chunk);
          count += chunk.length;
          progress(count);
        }
        await writer.flush();
      } finally {
        await writer.close();
      }
    }
    if (stopped()) throw StateError('下载已暂停。');
    if (count != size) throw const HttpException('下载中断，已保留收到的部分。');
    if ((await sha256.bind(partial.openRead()).first).toString() != checksum) {
      await partial.delete();
      throw const FormatException('模型 SHA-256 不符，请重新下载。');
    }
    if (stopped()) throw StateError('下载已暂停。');
    await partial.rename(target.path);
  } finally {
    client.close(force: true);
    _activeDownloads.remove(target.path);
  }
}
