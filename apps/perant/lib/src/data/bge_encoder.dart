// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

const embeddingRevision = '75c43b069aac4d136ba6bc1122f995fedcfd2781';
const _model = 'model_quantized.onnx';
const _vocab = 'vocab.txt';
const _assets = {
  _model: (
    path: 'onnx/model_quantized.onnx',
    size: 24010842,
    sha: '15b717c382bcb518ba457b93ea6850ede7f4f1cd8937454aa06972366cd19bcc',
  ),
  _vocab: (
    path: 'vocab.txt',
    size: 109540,
    sha: '45bbac6b341c319adc98a532532882e91a9cefc0329aa57bac9ae761c27b291c',
  ),
};

class EmbeddingFiles {
  static Future<Directory> directory() async => Directory(
    '${(await getApplicationSupportDirectory()).path}/embedding/$embeddingRevision',
  );
  static Future<void> importFiles(
    Map<String, Stream<List<int>>> files, {
    required bool Function() cancelled,
  }) async {
    if (files.length != _assets.length ||
        !_assets.keys.every(files.containsKey))
      throw const FormatException('请选择 model_quantized.onnx 和 vocab.txt。');
    final dir = await directory();
    await dir.create(recursive: true);
    final staging = await dir.createTemp('import-');
    try {
      for (final asset in _assets.entries) {
        final file = File('${staging.path}/${asset.key}');
        final sink = file.openWrite();
        var bytes = 0;
        try {
          await sink.addStream(
            files[asset.key]!.map((chunk) {
              if (cancelled()) throw StateError('导入已暂停。');
              bytes += chunk.length;
              if (bytes > asset.value.size)
                throw const FormatException('文件超出清单大小。');
              return chunk;
            }),
          );
        } finally {
          await sink.close();
        }
        if (bytes != asset.value.size ||
            (await sha256.bind(file.openRead()).first).toString() !=
                asset.value.sha)
          throw const FormatException('模型文件与指定版本的 SHA-256 不符。');
      }
      if (cancelled()) throw StateError('导入已暂停。');
      for (final name in _assets.keys) {
        await File('${staging.path}/$name').rename('${dir.path}/$name');
      }
    } finally {
      await staging.delete(recursive: true);
    }
  }

  static Future<void> install({
    required bool Function() cancelled,
    required void Function(int, int) progress,
  }) async {
    final dir = await directory();
    await dir.create(recursive: true);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    var completed = 0;
    final total = _assets.values.fold<int>(0, (v, e) => v + e.size);
    try {
      for (final e in _assets.entries) {
        final info = e.value;
        final file = File('${dir.path}/${e.key}');
        if (await file.exists() &&
            await file.length() == info.size &&
            (await sha256.bind(file.openRead()).first).toString() == info.sha) {
          completed += info.size;
          progress(completed, total);
          continue;
        }
        final tmp = File(
          '${file.path}.${DateTime.now().microsecondsSinceEpoch}.part',
        );
        try {
          final uri = Uri.https(
            'huggingface.co',
            '/Xenova/bge-small-zh-v1.5/resolve/$embeddingRevision/${info.path}',
          );
          final response = await (await client.getUrl(uri))
              .close()
              .timeout(const Duration(seconds: 30));
          if (response.statusCode != 200) throw const HttpException('模型下载失败。');
          var n = 0;
          final sink = tmp.openWrite();
          try {
            await sink.addStream(
              response.timeout(const Duration(seconds: 30)).map((chunk) {
                if (cancelled()) throw StateError('已暂停下载。');
                n += chunk.length;
                if (n > info.size) throw const FormatException('下载超出模型清单大小。');
                progress(completed + n, total);
                return chunk;
              }),
            );
          } finally {
            await sink.close();
          }
          if (cancelled()) throw StateError('已暂停下载。');
          if (n != info.size ||
              (await sha256.bind(tmp.openRead()).first).toString() != info.sha)
            throw const FormatException('模型文件未通过 SHA-256 校验。');
          await tmp.rename(file.path);
          completed += n;
        } finally {
          if (await tmp.exists()) await tmp.delete();
        }
      }
    } finally {
      client.close(force: true);
    }
  }
}

/// Uncased BERT tokenizer with greedy longest-match WordPiece and singleton CJK punctuation.
class ChineseWordPiece {
  ChineseWordPiece(List<String> vocabulary)
    : ids = {for (var i = 0; i < vocabulary.length; i++) vocabulary[i]: i};
  final Map<String, int> ids;
  static final _units = RegExp(
    r'[\u3400-\u9fff\uf900-\ufaff\u{20000}-\u{2fa1f}]|[\p{L}\p{N}]+|[^\p{C}\s]',
    unicode: true,
  );
  List<int> encode(String source, {required bool query}) {
    // Split before the greedy word pattern can consume adjacent Chinese text.
    final separated = source.replaceAllMapped(
      RegExp(r'[\u3400-\u9fff\uf900-\ufaff\u{20000}-\u{2fa1f}]', unicode: true),
      (m) => ' ${m[0]} ',
    );
    final sentence = (query ? '为这个句子生成表示以用于检索相关文章：' : '') + separated;
    final tokens = <int>[ids['[CLS]']!];
    for (final match in _units.allMatches(sentence.toLowerCase())) {
      final word = match[0]!;
      if (ids.containsKey(word)) {
        tokens.add(ids[word]!);
      } else {
        final chars = word.runes.toList();
        final pieces = <int>[];
        var start = 0;
        while (start < chars.length && chars.length <= 100) {
          var end = chars.length;
          int? piece;
          for (; end > start; end--) {
            piece =
                ids[(start == 0 ? '' : '##') +
                    String.fromCharCodes(chars, start, end)];
            if (piece != null) break;
          }
          if (piece == null) break;
          pieces.add(piece);
          start = end;
        }
        tokens.addAll(start == chars.length ? pieces : [ids['[UNK]']!]);
      }
      if (tokens.length >= 511) break;
    }
    return [...tokens.take(511), ids['[SEP]']!];
  }
}

class BgeEncoder {
  BgeEncoder._(this.session, this.tokenizer);
  final OrtSession session;
  final ChineseWordPiece tokenizer;
  static Future<BgeEncoder> open() async {
    final dir = await EmbeddingFiles.directory();
    for (final e in _assets.entries) {
      final f = File('${dir.path}/${e.key}');
      if ((await sha256.bind(f.openRead()).first).toString() != e.value.sha)
        throw const FormatException('嵌入模型校验失败，请重新下载。');
    }
    final vocab = await File('${dir.path}/$_vocab').readAsLines(encoding: utf8);
    final session = await OnnxRuntime().createSession(
      '${dir.path}/$_model',
      options: OrtSessionOptions(intraOpNumThreads: 2, interOpNumThreads: 1),
    );
    return BgeEncoder._(session, ChineseWordPiece(vocab));
  }

  Future<void> _pending = Future.value();
  Future<Float32List> encode(String text, {bool query = false}) {
    final next = _pending.then((_) => _encode(text, query: query));
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<Float32List> _encode(String text, {required bool query}) async {
    final ids = tokenizer.encode(text, query: query);
    final shape = [1, ids.length];
    final inputs = <String, OrtValue>{};
    var outputs = <String, OrtValue>{};
    try {
      for (final name in session.inputNames) {
        final values = switch (name) {
          'input_ids' => ids,
          'attention_mask' => List.filled(ids.length, 1),
          'token_type_ids' => List.filled(ids.length, 0),
          _ => throw const FormatException('模型输入与清单不符。'),
        };
        inputs[name] = await OrtValue.fromList(
          Int64List.fromList(values),
          shape,
        );
      }
      outputs = await session.run(inputs);
      final hidden = outputs['last_hidden_state'];
      if (hidden == null ||
          hidden.shape.length != 3 ||
          hidden.shape.last != 512)
        throw const FormatException('模型输出维度不符。');
      final values = await hidden.asFlattenedList();
      final vector = Float32List.fromList(
        values.take(512).cast<double>().toList(),
      );
      final length = sqrt(vector.fold<double>(0, (sum, x) => sum + x * x));
      if (!length.isFinite || length == 0)
        throw const FormatException('模型返回空向量。');
      for (var i = 0; i < vector.length; i++) vector[i] /= length;
      return vector;
    } finally {
      for (final v in [...outputs.values, ...inputs.values]) {
        await v.dispose();
      }
    }
  }

  Future<void> close() => session.close();
}
