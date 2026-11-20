// SPDX-License-Identifier: GPL-3.0-only
import 'package:perant_core/perant_core.dart';
import 'package:sqflite/sqflite.dart';

abstract interface class PassageSearch {
  Future<List<LibraryHit>> searchPassages(String query);
}

typedef LibraryHit = ({
  String documentId,
  int revision,
  String title,
  int offset,
  String excerpt,
});

abstract interface class PassageEvidence {
  Future<String?> readWindow(String id, int revision, int start, int units);
}

/// SQLite's standard tokenizers do not identify arbitrary two-character Chinese
/// terms. Add adjacent ideograph pairs plus single ideographs and Latin words.
final _searchWords = RegExp(
  r'[\u3400-\u9fff\uf900-\ufaff\u{20000}-\u{2fa1f}]+|[a-z0-9\u00c0-\u024f]+',
  unicode: true,
);

List<String> _terms(String text, {bool forQuery = false}) {
  final tokens = <String>{};

  for (final match in _searchWords.allMatches(text.toLowerCase())) {
    final word = match.group(0)!;
    final codes = word.runes.toList();
    if (codes.first >= 0x3400) {
      for (var i = 0; i < codes.length; i++) {
        if (!forQuery || codes.length == 1)
          tokens.add('u${codes[i].toRadixString(16)}');
        if (i + 1 < codes.length)
          tokens.add(
            'b${codes[i].toRadixString(16)}z${codes[i + 1].toRadixString(16)}',
          );
      }
    } else {
      tokens.add('w' + codes.map((c) => c.toRadixString(16)).join('z'));
    }
    if (forQuery && tokens.length >= 32) break;
  }
  return forQuery ? tokens.take(32).toList() : tokens.toList();
}

Iterable<(int, String)> _passages(String body) sync* {
  var start = 0;
  while (start < body.length) {
    final runes = RuneIterator.at(body, start);
    var pos = start;
    var next = start;
    for (var i = 0; i < 400 && runes.moveNext(); i++) {
      pos += runes.current > 0xffff ? 2 : 1;
      if (i == 271) next = pos;
    }
    yield (start, body.substring(start, pos));
    if (pos == body.length) break;
    start = next;
  }
}

class LibrarySearch {
  static Future<String?> readWindow(
    DatabaseExecutor db,
    String id,
    int rev,
    int start,
    int units,
  ) async {
    if (start < 0 || units < 1 || units > 804) throw ArgumentError('无效的引用范围。');
    // A 400-code-point passage spans at most 800 UTF-16 units.
    final rows = await db.rawQuery(
      'SELECT p.offset,p.body FROM library_passage p JOIN library_source s ON s.id=p.doc '
      'WHERE p.doc=? AND s.revision=? AND p.offset BETWEEN ? AND ? ORDER BY p.offset',
      [id, rev, (start - 800).clamp(0, start), start + units - 1],
    );
    var cursor = start;
    final value = StringBuffer();
    for (final row in rows) {
      final offset = row['offset'] as int, body = row['body'] as String;
      if (offset > cursor) return null;
      final end = (offset + body.length).clamp(0, start + units);
      if (end > cursor) {
        value.write(body.substring(cursor - offset, end - offset));
        cursor = end;
      }
      if (cursor == start + units) break;
    }
    return cursor == start ? null : value.toString();
  }

  static Future<void> create(DatabaseExecutor db) async {
    // Android uses the system SQLite build, whose FTS modules vary by OS.
    final options = await db.rawQuery('PRAGMA compile_options');
    final fts5 = options.any((r) => r.values.contains('ENABLE_FTS5'));
    try {
      await db.execute(
        'CREATE VIRTUAL TABLE library_terms USING ${fts5 ? "fts5" : "fts4"}(terms)',
      );
    } on DatabaseException catch (e) {
      if (!e.toString().toLowerCase().contains('no such module')) rethrow;
      await db.execute('CREATE TABLE library_terms(terms TEXT NOT NULL)');
    }
    await db.execute(
      'CREATE TABLE library_source(id TEXT PRIMARY KEY, revision INTEGER NOT NULL, title TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE library_passage(id INTEGER PRIMARY KEY, doc TEXT NOT NULL, offset INTEGER NOT NULL, body TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE INDEX library_passage_doc ON library_passage(doc)',
    );
  }

  static Future<void> sync(
    Transaction txn,
    List<Map<String, Object?>> docs,
    Set<(String, int)> changedBodies,
    Future<String> Function((String, int)) readBody,
  ) async {
    final prior = {
      for (final row in await txn.query('library_source'))
        row['id'] as String: row,
    };
    final currentIds = <String>{};
    final changed = <Map<String, Object?>>[];
    for (final d in docs) {
      final id = d['id'] as String, rev = d['revision'] as int;
      currentIds.add(id);
      if (prior[id]?['revision'] != rev ||
          prior[id]?['title'] != d['title'] ||
          changedBodies.contains((id, rev)))
        changed.add(d);
    }
    final removed = prior.keys.where((id) => !currentIds.contains(id));
    if (changed.isEmpty && removed.isEmpty) return;
    var nextId =
        (Sqflite.firstIntValue(
              await txn.rawQuery('SELECT MAX(id) FROM library_passage'),
            ) ??
            0) +
        1;
    var batch = txn.batch();
    var pending = 0;
    Future<void> flush() async {
      if (pending == 0) return;
      await batch.commit(noResult: true);
      batch = txn.batch();
      pending = 0;
    }

    for (final id in [
      ...removed,
      ...changed.map((d) => d['id'] as String).where(prior.containsKey),
    ]) {
      batch.rawDelete(
        'DELETE FROM library_terms WHERE rowid IN (SELECT id FROM library_passage WHERE doc=?)',
        [id],
      );
      batch.delete('library_passage', where: 'doc=?', whereArgs: [id]);
      batch.delete('library_source', where: 'id=?', whereArgs: [id]);
      pending += 3;
      if (pending >= 128) await flush();
    }
    for (final d in changed) {
      final id = d['id'] as String, title = d['title'] as String;
      batch.insert('library_source', {
        'id': id,
        'revision': d['revision'],
        'title': title,
      });
      pending++;
      final titleTerms = _terms(title);
      final value = d['markdown'];
      final body = value is String
          ? value
          : await readBody((id, d['revision'] as int));
      final parts = body.isEmpty ? [(0, '')] : _passages(body);
      for (final part in parts) {
        batch.insert('library_passage', {
          'id': nextId,
          'doc': id,
          'offset': part.$1,
          'body': part.$2,
        });
        batch.rawInsert('INSERT INTO library_terms(rowid,terms) VALUES (?,?)', [
          nextId,
          [...titleTerms, ..._terms(part.$2)].join(' '),
        ]);
        nextId++;
        pending += 2;
        if (pending >= 128) await flush();
      }
    }
    await flush();
  }

  static Future<List<LibraryHit>> query(Database db, String query) async {
    final text = query.trim();
    if (text.isEmpty || text.runes.length > 128) return [];
    final terms = _terms(text, forQuery: true);
    if (terms.isEmpty) return [];
    final schema = await db.rawQuery(
      "SELECT sql FROM sqlite_master WHERE name='library_terms'",
    );
    final hasFts = (schema.single['sql'] as String).toUpperCase().contains(
      'VIRTUAL TABLE',
    );
    final filter = hasFts
        ? 'library_terms MATCH ?'
        : '(instr(lower(p.body),lower(?))>0 OR instr(lower(s.title),lower(?))>0)';
    final rows = await db.rawQuery(
      'SELECT s.id AS doc,s.title,s.revision,p.offset,p.body FROM library_terms '
      'JOIN library_passage p ON p.id=library_terms.rowid JOIN library_source s ON s.id=p.doc '
      'WHERE $filter ORDER BY (instr(lower(p.body),lower(?))>0) DESC, '
      '(instr(lower(s.title),lower(?))>0) DESC,s.id,p.offset LIMIT 100',
      [
        if (hasFts) terms.join(' ') else ...[text, text],
        text,
        text,
      ],
    );
    final hits = <LibraryHit>[];
    final seen = <String, int>{};
    for (final row in rows) {
      final id = row['doc'] as String;
      final body = row['body'] as String;
      final offset = row['offset'] as int;
      final hit = _hit(
        id,
        row['revision'] as int,
        row['title'] as String,
        body,
        offset,
        text,
      );
      if (seen.containsKey(id) && hit.offset - seen[id]! < 50) continue;
      seen[id] = hit.offset;
      hits.add(hit);
      if (hits.length == 10) break;
    }
    return hits;
  }

  static List<LibraryHit> inMemory(
    List<MarkdownDocument> documents,
    String query,
  ) {
    final text = query.trim().toLowerCase();
    if (text.isEmpty || text.runes.length > 128) return [];
    return [
      for (final d in documents)
        if (d.title.toLowerCase().contains(text) ||
            d.markdown.toLowerCase().contains(text))
          _hit(d.id, d.revision, d.title, d.markdown, 0, text),
    ].take(10).toList();
  }

  static LibraryHit _hit(
    String id,
    int revision,
    String title,
    String body,
    int start,
    String query,
  ) {
    final ix =
        RegExp(
          RegExp.escape(query),
          caseSensitive: false,
          unicode: true,
        ).firstMatch(body)?.start ??
        -1;
    var cut = ix > 16 ? ix - 16 : 0;
    if (cut < body.length && body.codeUnitAt(cut) & 0xfc00 == 0xdc00) cut--;
    return (
      documentId: id,
      revision: revision,
      title: title,
      offset: start + (ix < 0 ? 0 : ix.clamp(0, body.length)),
      excerpt: String.fromCharCodes(
        body.substring(cut.clamp(0, body.length)).runes.take(90),
      ),
    );
  }
}
