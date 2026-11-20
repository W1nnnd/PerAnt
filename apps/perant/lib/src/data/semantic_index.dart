// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import 'bge_encoder.dart';
import 'library_search.dart';

typedef VectorProgress = ({int done, int total});

abstract interface class SemanticControl {
  Future<VectorProgress> vectorProgress();
  Future<void> indexSemantics({
    required bool Function() cancelled,
    required void Function(VectorProgress) onProgress,
    required void Function(int, int) downloadProgress,
  });
  Future<List<LibraryHit>> hybridSearch(String query);
}

class SemanticIndex {
  SemanticIndex(this.db);
  final Database db;
  bool _indexing = false;
  Future<BgeEncoder>? _opening;
  var _readers = 0;
  Future<BgeEncoder> _acquire() async {
    _readers++;
    try {
      return await (_opening ??= BgeEncoder.open());
    } catch (_) {
      if (--_readers == 0) _opening = null;
      rethrow;
    }
  }

  Future<void> _release(BgeEncoder encoder) async {
    if (--_readers > 0) return;
    _opening = null;
    await encoder.close();
  }

  static Future<void> create(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE library_embedding(id INTEGER PRIMARY KEY, digest TEXT NOT NULL UNIQUE, vector BLOB NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE library_vector(passage_id INTEGER PRIMARY KEY, embedding_id INTEGER NOT NULL)',
    );
    await db.execute(
      'CREATE INDEX library_vector_embedding ON library_vector(embedding_id)',
    );
    await db.execute(
      'CREATE TRIGGER remove_unused_embedding AFTER DELETE ON library_vector BEGIN DELETE FROM library_embedding WHERE id=OLD.embedding_id AND NOT EXISTS(SELECT 1 FROM library_vector WHERE embedding_id=OLD.embedding_id); END',
    );
    // A removed or rewritten source cannot leave a searchable embedding behind.
    await db.execute(
      'CREATE TRIGGER retire_library_vector AFTER DELETE ON library_passage BEGIN DELETE FROM library_vector WHERE passage_id=OLD.id; END',
    );
  }

  Future<VectorProgress> progress() async {
    final row = (await db.rawQuery(
      'SELECT (SELECT COUNT(*) FROM library_vector) AS done, (SELECT COUNT(*) FROM library_passage) AS total',
    )).single;
    return (done: row['done'] as int, total: row['total'] as int);
  }

  Future<void> index({
    required bool Function() cancelled,
    required void Function(VectorProgress) update,
    required void Function(int, int) downloadProgress,
  }) async {
    if (_indexing) throw StateError('正在建立语义索引。');
    _indexing = true;
    BgeEncoder? encoder;
    try {
      await EmbeddingFiles.install(
        cancelled: cancelled,
        progress: downloadProgress,
      );
      if (cancelled()) return;
      encoder = await _acquire();
      // Repeated paragraphs are common in office archives. The budget is 256 vectors per run.
      final cache = <String, Float32List>{};
      while (!cancelled()) {
        final rows = await db.rawQuery(
          'SELECT p.id,p.body,p.doc,p.offset,s.revision,s.title FROM library_passage p JOIN library_source s ON s.id=p.doc LEFT JOIN library_vector v ON v.passage_id=p.id WHERE v.passage_id IS NULL ORDER BY p.id LIMIT 16',
        );
        if (rows.isEmpty) break;
        final encoded =
            <({Map<String, Object?> row, String digest, Float32List vector})>[];
        for (final row in rows) {
          if (cancelled()) break;
          final body = row['body'] as String;
          final text = body.isEmpty ? row['title'] as String : body;
          var vector = cache[text];
          if (vector == null) {
            vector = await encoder.encode(text);
            if (cache.length >= 256) cache.remove(cache.keys.first);
            cache[text] = vector;
          }
          encoded.add((
            row: row,
            digest: sha256.convert(utf8.encode(text)).toString(),
            vector: vector,
          ));
        }
        if (encoded.isNotEmpty)
          await db.transaction((txn) async {
            final batch = txn.batch();
            for (final item in encoded) {
              final r = item.row;
              batch.rawInsert(
                'INSERT OR IGNORE INTO library_embedding(digest,vector) VALUES(?,?)',
                [item.digest, item.vector.buffer.asUint8List()],
              );
              batch.rawInsert(
                'INSERT OR IGNORE INTO library_vector(passage_id,embedding_id) SELECT p.id,(SELECT id FROM library_embedding WHERE digest=?) FROM library_passage p JOIN library_source s ON s.id=p.doc WHERE p.id=? AND p.doc=? AND p.offset=? AND p.body=? AND s.revision=? AND s.title=?',
                [
                  item.digest,
                  r['id'],
                  r['doc'],
                  r['offset'],
                  r['body'],
                  r['revision'],
                  r['title'],
                ],
              );
            }
            for (final digest in encoded.map((e) => e.digest).toSet()) {
              batch.rawDelete(
                'DELETE FROM library_embedding WHERE digest=? AND NOT EXISTS(SELECT 1 FROM library_vector WHERE embedding_id=library_embedding.id)',
                [digest],
              );
            }
            await batch.commit(noResult: true);
          });
        update(await progress());
      }
    } finally {
      try {
        if (encoder != null) await _release(encoder);
      } finally {
        _indexing = false;
      }
    }
  }

  Future<List<LibraryHit>> query(String text) async {
    final lexical = await LibrarySearch.query(db, text);
    if (text.trim().isEmpty ||
        text.runes.length > 128 ||
        (await progress()).done == 0)
      return lexical;
    final encoder = await _acquire();
    late Float32List query;
    try {
      query = await encoder.encode(text, query: true);
    } finally {
      await _release(encoder);
    }
    // Bound the result rows and vector memory. Only shortlisted passages are read as text.
    return db.transaction((txn) async {
      final best = <({int id, double score})>[];
      var after = 0;
      while (true) {
        final rows = await txn.rawQuery(
          'SELECT id,vector FROM library_embedding WHERE id>? ORDER BY id LIMIT 192',
          [after],
        );
        if (rows.isEmpty) break;
        for (final row in rows) {
          after = row['id'] as int;
          final bytes = row['vector'] as Uint8List;
          if (bytes.lengthInBytes != query.length * 4)
            throw const FormatException('索引向量大小无效。');
          final data = ByteData.sublistView(bytes);
          var score = 0.0;
          for (var i = 0; i < query.length; i++) {
            score += data.getFloat32(i * 4, Endian.host) * query[i];
          }
          if (score < 0.38 || (best.length == 20 && score <= best.last.score))
            continue;
          best.add((id: after, score: score));
          best.sort((a, b) => b.score.compareTo(a.score));
          if (best.length > 20) best.removeLast();
        }
      }
      final combined = <(String, int, int), ({LibraryHit hit, double score})>{};
      for (var i = 0; i < lexical.length; i++) {
        final hit = lexical[i];
        combined[(hit.documentId, hit.revision, hit.offset)] = (
          hit: hit,
          score: 1 / (25 + i),
        );
      }
      for (var i = 0; i < best.length; i++) {
        final r = (await txn.rawQuery(
          'SELECT p.doc,p.offset,p.body,s.title,s.revision FROM library_vector v JOIN library_passage p ON p.id=v.passage_id JOIN library_source s ON s.id=p.doc WHERE v.embedding_id=? ORDER BY v.passage_id LIMIT 1',
          [best[i].id],
        )).single;
        final doc = r['doc'] as String,
            rev = r['revision'] as int,
            offset = r['offset'] as int,
            body = r['body'] as String;
        final end = offset + body.length;
        final lex = lexical
            .where(
              (h) =>
                  h.documentId == doc &&
                  h.revision == rev &&
                  h.offset >= offset &&
                  h.offset < end,
            )
            .firstOrNull;
        final hit =
            lex ??
            (
              documentId: doc,
              revision: rev,
              title: r['title'] as String,
              offset: offset,
              excerpt: String.fromCharCodes(body.runes.take(90)),
            );
        final key = (doc, rev, hit.offset);
        // Overlapping windows can corroborate an existing lexical hit only once.
        final lexRank = lex == null ? -1 : lexical.indexOf(lex);
        final score = 1 / (25 + i) + (lexRank < 0 ? 0 : 1 / (25 + lexRank));
        if (score > (combined[key]?.score ?? 0))
          combined[key] = (hit: hit, score: score);
      }
      final ranked = combined.values.toList()
        ..sort((a, b) => b.score.compareTo(a.score));
      return ranked.take(10).map((v) => v.hit).toList();
    });
  }
}
