// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'workspace_state.dart';

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
    version: 1,
    onCreate: (db, version) async {
      await db.execute(
        'CREATE TABLE workspace_snapshot (id INTEGER PRIMARY KEY CHECK(id = 1), schema_version INTEGER NOT NULL, payload TEXT NOT NULL)',
      );
    },
  );
  return _SqliteWorkspacePersistence(db);
}

/// Bootstrap snapshot repository. Schema versioning leaves room for normalized
/// document/chunk tables when the knowledge repository is introduced.
final class _SqliteWorkspacePersistence implements WorkspacePersistence {
  _SqliteWorkspacePersistence(this.db);
  final Database db;
  @override
  String get description => '设备本地 SQLite';
  @override
  Future<WorkspaceState> load() async {
    final rows = await db.query(
      'workspace_snapshot',
      where: 'id = ?',
      whereArgs: [1],
    );
    if (rows.isEmpty) return WorkspaceState();
    return WorkspaceState.fromJson(
      Map<String, Object?>.from(
        jsonDecode(rows.single['payload']! as String) as Map,
      ),
    );
  }

  @override
  Future<void> save(Map<String, Object?> snapshot) async {
    final payload = jsonEncode(snapshot);
    await db.transaction((txn) async {
      await txn.insert('workspace_snapshot', {
        'id': 1,
        'schema_version': 1,
        'payload': payload,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  @override
  Future<void> close() => db.close();
}
