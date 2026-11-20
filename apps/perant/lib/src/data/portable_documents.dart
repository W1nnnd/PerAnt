// SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:typed_data';

import 'workspace_state.dart';

const backupByteLimit = 64 * 1024 * 1024;
const _backupFormat = 'perant-workspace/1';
const _portableFields = {
  'schemaVersion',
  'companionName',
  'companionTone',
  'hapticsEnabled',
  'conversations',
  'activeConversationId',
  'documents',
  'messages',
  'containerActions',
  'tasks',
};

Uint8List backupWorkspace(WorkspaceState state) {
  final data = state.toJson()
    ..removeWhere((key, value) => !_portableFields.contains(key));
  final bytes = utf8.encode(
    jsonEncode({'format': _backupFormat, 'workspace': data}),
  );
  if (bytes.length > backupByteLimit)
    throw const FormatException('工作区备份超过 64 MB。');
  return bytes;
}

WorkspaceState readWorkspaceBackup(Uint8List bytes) {
  if (bytes.length > backupByteLimit)
    throw const FormatException('工作区备份超过 64 MB。');
  final envelope = jsonDecode(utf8.decode(bytes));
  if (envelope is! Map ||
      envelope['format'] != _backupFormat ||
      envelope['workspace'] is! Map<String, dynamic>) {
    throw const FormatException('无法识别工作区备份。');
  }
  final body = envelope['workspace'] as Map<String, dynamic>;
  if (!body.keys.toSet().containsAll(_portableFields) ||
      body.keys.any((k) => !_portableFields.contains(k))) {
    throw const FormatException('备份字段不完整或存在不支持的配置。');
  }
  for (final section in [
    'conversations',
    'documents',
    'messages',
    'containerActions',
    'tasks',
  ]) {
    final records = body[section];
    if (records is! List) throw const FormatException('备份记录损坏。');
    final ids = <String>{};
    for (final row in records) {
      if (row is! Map ||
          row['id'] is! String ||
          (row['id'] as String).trim().isEmpty ||
          !ids.add(row['id'] as String)) {
        throw const FormatException('备份包含无效或重复的记录标识。');
      }
    }
  }
  return WorkspaceState.fromJson(body);
}

/// Use a field allowlist: free text, IDs, URLs, command arguments, screenshots,
/// provider settings and credential references never enter a diagnostics file.
Uint8List localDiagnostics(WorkspaceState state, String platform) {
  final counts = <String, int>{};
  for (final task in state.tasks) {
    counts.update(task.status.name, (n) => n + 1, ifAbsent: () => 1);
  }
  final actions = <String, int>{};
  for (final action in state.containerActions) {
    actions.update(action.status.name, (n) => n + 1, ifAbsent: () => 1);
  }
  return utf8.encode(
    const JsonEncoder.withIndent('  ').convert({
      'format': 'perant-diagnostics/1',
      'createdUtc': DateTime.now().toUtc().toIso8601String(),
      'platform':
          {
            'android',
            'iOS',
            'linux',
            'windows',
            'macOS',
            'fuchsia',
          }.contains(platform)
          ? platform
          : 'unknown',
      'documentCount': state.documents.length,
      'revisionCount': state.documents.fold<int>(
        0,
        (n, d) => n + 1 + d.history.length,
      ),
      'conversationCount': state.conversations.length,
      'taskStatusCounts': counts,
      'actionStatusCounts': actions,
      'recentTasks': [
        for (final task in state.tasks.reversed.take(100))
          {
            'createdUtc': task.createdAt.toUtc().toIso8601String(),
            'status': task.status.name,
          },
      ],
      'recentActions': [
        for (final action in state.containerActions.reversed.take(100))
          {
            'updatedUtc': action.updatedAt.toUtc().toIso8601String(),
            'status': action.status.name,
          },
      ],
    }),
  );
}
