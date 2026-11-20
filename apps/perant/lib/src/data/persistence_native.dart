// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'workspace_state.dart';
import 'library_search.dart';

Future<WorkspacePersistence> openPersistence({
  String databaseName = 'perant.sqlite',
}) async {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*\.sqlite$').hasMatch(databaseName)) {
    throw ArgumentError.value(
      databaseName,
      'databaseName',
      'Use a SQLite filename without directory components.',
    );
  }
  final directory = await getApplicationSupportDirectory();
  final db = await openDatabase(
    '${directory.path}/$databaseName',
    version: 4,
    singleInstance: false,
    onUpgrade: (db, oldVersion, newVersion) async {
      if (oldVersion < 2) await _createDocumentChunks(db);
      if (oldVersion < 3)
        await db.execute(
          'ALTER TABLE workspace_snapshot ADD COLUMN generation INTEGER NOT NULL DEFAULT 0',
        );
      await LibrarySearch.create(db);
    },
    onCreate: (db, version) async {
      await db.execute(
        'CREATE TABLE workspace_snapshot (id INTEGER PRIMARY KEY CHECK(id = 1), schema_version INTEGER NOT NULL, payload TEXT NOT NULL, generation INTEGER NOT NULL DEFAULT 0)',
      );
      await _createDocumentChunks(db);
      await LibrarySearch.create(db);
    },
  );
  return _SqliteWorkspacePersistence(db);
}

Future<void> _createDocumentChunks(Database db) => db.execute(
  'CREATE TABLE document_chunk (document_id TEXT NOT NULL, revision INTEGER NOT NULL, '
  'part INTEGER NOT NULL, body TEXT NOT NULL, PRIMARY KEY(document_id,revision,part))',
);

final class _SqliteWorkspacePersistence
    implements WorkspacePersistence, PassageSearch {
  _SqliteWorkspacePersistence(this.db);
  final Database db;
  Map<(String, int), String> _stored = {};
  int? _generation;
  @override
  String get description => '设备本地 SQLite';
  @override
  Future<List<LibraryHit>> searchPassages(String query) =>
      LibrarySearch.query(db, query);
  @override
  Future<WorkspaceState> load() => db.transaction((txn) async {
    final rows = await txn.rawQuery(
      'SELECT schema_version, generation, length(CAST(payload AS BLOB)) AS n FROM workspace_snapshot WHERE id=1',
    );
    if (rows.isEmpty) {
      _generation = 0;
      _stored = {};
      return WorkspaceState();
    }
    // Android CursorWindow cannot return one arbitrarily large TEXT cell.
    final payload = BytesBuilder(copy: false);
    for (var offset = 0; offset < (rows.single['n'] as int); offset += 65536) {
      final part = await txn.rawQuery(
        'SELECT substr(CAST(payload AS BLOB), ?, 65536) AS bytes FROM workspace_snapshot WHERE id=1',
        [offset + 1],
      );
      payload.add(part.single['bytes'] as Uint8List);
    }
    final json =
        jsonDecode(utf8.decode(payload.takeBytes())) as Map<String, dynamic>;
    if (rows.single['schema_version'] == 1) {
      final state = WorkspaceState.fromJson(json);
      _generation = rows.single['generation'] as int;
      _stored = {};
      return state;
    }
    if (rows.single['schema_version'] != 2)
      throw const FormatException('不支持的工作区存储格式。');
    final chunks = await txn.query(
      'document_chunk',
      orderBy: 'document_id,revision,part',
    );
    final buffers = <(String, int), StringBuffer>{};
    for (final chunk in chunks) {
      final key = (chunk['document_id'] as String, chunk['revision'] as int);
      (buffers[key] ??= StringBuffer()).write(chunk['body'] as String);
    }
    final stored = buffers.map((key, body) => MapEntry(key, body.toString()));
    for (final doc in (json['documents'] as List).cast<Map>()) {
      for (final version in [doc, ...(doc['history'] as List).cast<Map>()]) {
        final body = stored[(doc['id'] as String, version['revision'] as int)];
        if (body == null) throw const FormatException('缺少文档修订正文。');
        version['markdown'] = body;
      }
    }
    final state = WorkspaceState.fromJson(json);
    _stored = stored;
    _generation = rows.single['generation'] as int;
    return state;
  });

  @override
  Future<void> save(Map<String, Object?> snapshot) async {
    if (_generation == null) await load();
    final expectedGeneration = _generation!;
    final next = <(String, int), String>{};
    final docs = <Map<String, Object?>>[];
    for (final raw
        in (snapshot['documents'] as List).cast<Map<String, Object?>>()) {
      Map<String, Object?> metadata(Map<String, Object?> version) {
        final meta = Map<String, Object?>.of(version);
        next[(raw['id'] as String, meta['revision'] as int)] =
            meta.remove('markdown') as String;
        return meta;
      }

      docs.add(
        metadata(raw)
          ..['history'] = [
            for (final v
                in (raw['history'] as List? ?? []).cast<Map<String, Object?>>())
              metadata(v),
          ],
      );
    }
    final payload = jsonEncode({...snapshot, 'documents': docs});
    await db.transaction((txn) async {
      final generation =
          Sqflite.firstIntValue(
            await txn.rawQuery(
              'SELECT generation FROM workspace_snapshot WHERE id=1',
            ),
          ) ??
          0;
      if (generation != expectedGeneration)
        throw StateError('工作区已被其他实例修改，请重新打开。');
      final batch = txn.batch();
      for (final key in _stored.keys.where((key) => !next.containsKey(key))) {
        batch.delete(
          'document_chunk',
          where: 'document_id=? AND revision=?',
          whereArgs: [key.$1, key.$2],
        );
      }
      for (final entry in next.entries) {
        final key = entry.key;
        if (_stored[key] == entry.value) continue;
        batch.delete(
          'document_chunk',
          where: 'document_id=? AND revision=?',
          whereArgs: [key.$1, key.$2],
        );
        final body = entry.value;
        var start = 0;
        var part = 0;
        do {
          var end = (start + 8192).clamp(0, body.length);
          if (end < body.length && body.codeUnitAt(end) & 0xfc00 == 0xdc00)
            end--;
          batch.insert('document_chunk', {
            'document_id': key.$1,
            'revision': key.$2,
            'part': part++,
            'body': body.substring(start, end),
          });
          start = end;
        } while (start < body.length);
      }
      await batch.commit(noResult: true);
      await LibrarySearch.sync(
        txn,
        (snapshot['documents'] as List).cast<Map<String, Object?>>(),
        _stored,
      );
      await txn.insert('workspace_snapshot', {
        'id': 1,
        'schema_version': 2,
        'generation': expectedGeneration + 1,
        'payload': payload,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    _stored = next;
    _generation = expectedGeneration + 1;
  }

  @override
  Future<void> close() => db.close();
}
