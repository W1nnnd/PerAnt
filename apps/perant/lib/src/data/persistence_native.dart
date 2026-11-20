// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:perant_core/perant_core.dart';
import 'package:sqflite/sqflite.dart';

import 'workspace_state.dart';
import 'library_search.dart';
import 'semantic_index.dart';

Future<WorkspacePersistence> openPersistence({
  String databaseName = 'perant.sqlite',
  Future<void> Function(Database)? onConfigure,
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
    version: 5,
    onConfigure: onConfigure,
    singleInstance: false,
    onUpgrade: (db, oldVersion, newVersion) async {
      if (oldVersion < 2) await _createDocumentChunks(db);
      if (oldVersion < 3)
        await db.execute(
          'ALTER TABLE workspace_snapshot ADD COLUMN generation INTEGER NOT NULL DEFAULT 0',
        );
      if (oldVersion < 4) await LibrarySearch.create(db);
      await SemanticIndex.create(db);
    },
    onCreate: (db, version) async {
      await db.execute(
        'CREATE TABLE workspace_snapshot (id INTEGER PRIMARY KEY CHECK(id = 1), schema_version INTEGER NOT NULL, payload TEXT NOT NULL, generation INTEGER NOT NULL DEFAULT 0)',
      );
      await _createDocumentChunks(db);
      await LibrarySearch.create(db);
      await SemanticIndex.create(db);
    },
  );
  return _SqliteWorkspacePersistence(db);
}

Future<void> _createDocumentChunks(Database db) => db.execute(
  'CREATE TABLE document_chunk (document_id TEXT NOT NULL, revision INTEGER NOT NULL, '
  'part INTEGER NOT NULL, body TEXT NOT NULL, PRIMARY KEY(document_id,revision,part))',
);

final class _SqliteWorkspacePersistence
    implements
        WorkspacePersistence,
        WorkspaceCatalog,
        PassageSearch,
        PassageEvidence,
        SemanticControl {
  _SqliteWorkspacePersistence(this.db);
  final Database db;
  @override
  Future<String?> readWindow(String id, int revision, int start, int units) =>
      db.transaction((txn) async {
        final current = Sqflite.firstIntValue(
          await txn.rawQuery(
            'SELECT generation FROM workspace_snapshot WHERE id=1',
          ),
        );
        if (current != _generation) throw StateError('工作区已变化，请重新打开。');
        return LibrarySearch.readWindow(txn, id, revision, start, units);
      });
  late final _semantic = SemanticIndex(db);
  @override
  Future<VectorProgress> vectorProgress() => _semantic.progress();
  @override
  Future<void> indexSemantics({
    required bool Function() cancelled,
    required void Function(VectorProgress) onProgress,
    required void Function(int, int) downloadProgress,
  }) => _semantic.index(
    cancelled: cancelled,
    update: onProgress,
    downloadProgress: downloadProgress,
  );
  @override
  Future<List<LibraryHit>> hybridSearch(String query) => _semantic.query(query);
  Map<(String, int), Object> _stored = {};
  int? _generation;
  @override
  String get description => '设备本地 SQLite';
  @override
  Future<List<LibraryHit>> searchPassages(String query) =>
      LibrarySearch.query(db, query);
  @override
  Future<WorkspaceState> load() => _load(eager: true);
  @override
  Future<WorkspaceState> loadCatalog() => _load(eager: false);

  Future<String> _readChunks(DatabaseExecutor txn, (String, int) key) async {
    final rows = await txn.query(
      'document_chunk',
      columns: ['part', 'body'],
      where: 'document_id=? AND revision=?',
      whereArgs: [key.$1, key.$2],
      orderBy: 'part',
    );
    final value = StringBuffer();
    for (var i = 0; i < rows.length; i++) {
      if (rows[i]['part'] != i) throw const FormatException('缺少文档修订分块。');
      value.write(rows[i]['body'] as String);
    }
    if (rows.isEmpty) throw const FormatException('缺少文档修订正文。');
    return value.toString();
  }

  Future<WorkspaceState> _load({required bool eager}) => db.transaction((
    txn,
  ) async {
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
    final generation = rows.single['generation'] as int;
    if (!eager) {
      final next = <(String, int), Object>{};
      final parts = await txn.rawQuery(
        'SELECT document_id,revision FROM document_chunk '
        'GROUP BY document_id,revision HAVING MIN(part)=0 AND MAX(part)+1=COUNT(*)',
      );
      final available = {
        for (final row in parts)
          (row['document_id'] as String, row['revision'] as int),
      };
      for (final doc in (json['documents'] as List).cast<Map>()) {
        for (final row in [doc, ...(doc['history'] as List).cast<Map>()]) {
          final key = (doc['id'] as String, row['revision'] as int);
          if (!available.remove(key))
            throw const FormatException('文档修订的分块缺失或重复。');
          final previous = _generation == generation ? _stored[key] : null;
          late final DocumentVersion ref;
          ref = previous is DocumentVersion
              ? previous
              : DocumentVersion.deferred(
                  documentId: key.$1,
                  revision: key.$2,
                  updatedAt: DateTime.parse(row['updatedAt'] as String),
                  read: () => db.transaction((reader) async {
                    final current = Sqflite.firstIntValue(
                      await reader.rawQuery(
                        'SELECT generation FROM workspace_snapshot WHERE id=1',
                      ),
                    );
                    if (current != _generation || !identical(_stored[key], ref))
                      throw StateError('该文档修订已变化，请重新打开。');
                    return _readChunks(reader, key);
                  }),
                );
          next[key] = ref;
          row['markdown'] = ref;
        }
      }
      final state = WorkspaceState.fromJson(json);
      _stored = next;
      _generation = generation;
      return state;
    }
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
    if (_generation != generation || _stored.isEmpty) _stored = stored;
    _generation = rows.single['generation'] as int;
    return state;
  });

  @override
  Future<void> save(Map<String, Object?> snapshot) async {
    if (_generation == null) await load();
    final expectedGeneration = _generation!;
    final next = <(String, int), Object>{};
    final docs = <Map<String, Object?>>[];
    for (final raw
        in (snapshot['documents'] as List).cast<Map<String, Object?>>()) {
      Map<String, Object?> metadata(Map<String, Object?> version) {
        final meta = Map<String, Object?>.of(version);
        final key = (raw['id'] as String, meta['revision'] as int);
        final body = meta.remove('markdown');
        if (body is String) {
          final old = _stored[key];
          next[key] =
              old is DocumentVersion && old.isLoaded && old.markdown == body
              ? old
              : body;
        } else if (body is DocumentVersion && identical(_stored[key], body)) {
          next[key] = body;
        } else {
          throw StateError('文档正文引用已失效，请重新打开工作区。');
        }
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
        final body = entry.value as String;
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
        {
          for (final entry in next.entries)
            if (_stored[entry.key] != entry.value) entry.key,
        },
        (key) => _readChunks(txn, key),
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
