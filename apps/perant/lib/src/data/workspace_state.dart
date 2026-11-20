// SPDX-License-Identifier: GPL-3.0-only
import 'package:perant_core/perant_core.dart';

import 'local_memories.dart';

enum ChatRole { user, assistant }

enum ChatEntrySource { cloud, localPython, container }

enum ContainerActionStatus {
  queued,
  running,
  awaitingApproval,
  succeeded,
  failed,
  denied,
  interrupted,
  cancelled;

  bool get isTerminal => switch (this) {
    queued || running || awaitingApproval => false,
    succeeded || failed || denied || interrupted || cancelled => true,
  };
}

/// A local audit receipt, never replayed as a command or silently uploaded.
final class ContainerAction {
  const ContainerAction({
    required this.id,
    required this.taskId,
    required this.conversationId,
    required this.tool,
    required this.summary,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.output,
    this.exitCode,
  });
  final String id;
  final String taskId;
  final String conversationId;
  final String tool;
  final String summary;
  final ContainerActionStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? output;
  final int? exitCode;

  ContainerAction withResult(
    ContainerActionStatus value, {
    String? output,
    int? exitCode,
  }) => ContainerAction(
    id: id,
    taskId: taskId,
    conversationId: conversationId,
    tool: tool,
    summary: summary,
    status: value,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
    output: output ?? this.output,
    exitCode: exitCode ?? this.exitCode,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'taskId': taskId,
    'conversationId': conversationId,
    'tool': tool,
    'summary': summary,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'output': output,
    'exitCode': exitCode,
  };
  factory ContainerAction.fromJson(Map<String, Object?> json) =>
      ContainerAction(
        id: json['id']! as String,
        taskId: json['taskId']! as String,
        conversationId: json['conversationId']! as String,
        tool: json['tool']! as String,
        summary: json['summary']! as String,
        status: ContainerActionStatus.values.byName(json['status']! as String),
        createdAt: DateTime.parse(json['createdAt']! as String),
        updatedAt: DateTime.parse(json['updatedAt']! as String),
        output: json['output'] as String?,
        exitCode: json['exitCode'] as int?,
      );
}

final class ConversationThread {
  const ConversationThread({
    required this.id,
    required this.title,
    required this.createdAt,
  });

  final String id;
  final String title;
  final DateTime createdAt;

  ConversationThread withTitle(String value) =>
      ConversationThread(id: id, title: value, createdAt: createdAt);

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
  };

  factory ConversationThread.fromJson(Map<String, Object?> json) =>
      ConversationThread(
        id: json['id']! as String,
        title: json['title']! as String,
        createdAt: DateTime.parse(json['createdAt']! as String),
      );
}

final class ChatEntry {
  const ChatEntry({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
    this.conversationId = 'main',
    this.source = ChatEntrySource.cloud,
    this.documentId,
  });
  final String id;
  final ChatRole role;
  final String text;
  final DateTime createdAt;
  final String conversationId;
  final ChatEntrySource source;
  final String? documentId;
  ChatEntry withText(String value) => ChatEntry(
    id: id,
    role: role,
    text: value,
    createdAt: createdAt,
    conversationId: conversationId,
    source: source,
    documentId: documentId,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'role': role.name,
    'text': text,
    'createdAt': createdAt.toIso8601String(),
    'conversationId': conversationId,
    'source': source.name,
    'documentId': documentId,
  };
  factory ChatEntry.fromJson(Map<String, Object?> json) => ChatEntry(
    id: json['id']! as String,
    role: ChatRole.values.byName(json['role']! as String),
    text: json['text']! as String,
    createdAt: DateTime.parse(json['createdAt']! as String),
    conversationId: json['conversationId'] as String? ?? 'main',
    source: ChatEntrySource.values.byName(json['source'] as String? ?? 'cloud'),
    documentId: json['documentId'] as String?,
  );
}

final class WorkspaceState {
  static const defaultCompanionName = '小蚁';
  static const defaultCompanionTone = '随和搭子';
  static const companionTones = ['随和搭子', '利落助手', '脑洞伙伴'];

  WorkspaceState({
    this.profile,
    this.onboardingDismissed = false,
    String companionName = defaultCompanionName,
    String companionTone = defaultCompanionTone,
    this.hapticsEnabled = true,
    LocalMemoryBook? memories,
    List<MarkdownDocument> documents = const [],
    List<ChatEntry> messages = const [],
    List<TaskRecord> tasks = const [],
    List<ContainerAction> containerActions = const [],
    List<ConversationThread> conversations = const [],
    this.activeConversationId = 'main',
  }) : memories = memories ?? LocalMemoryBook(),
       companionName = normalizeCompanionName(companionName),
       companionTone = validateCompanionTone(companionTone),
       documents = List.of(documents),
       messages = List.of(messages),
       tasks = List.of(tasks),
       containerActions = List.of(containerActions),
       conversations = List.of(conversations) {
    _ensureConversations();
  }
  ProviderProfile? profile;
  bool onboardingDismissed;
  String companionName;
  String companionTone;
  bool hapticsEnabled;
  LocalMemoryBook memories;
  final _preparedFacts = <DocumentVersion, String>{};
  void releasePreparedFacts() => _preparedFacts.clear();
  Iterable<MemoryEvidence> get memorySources sync* {
    for (final d in documents) {
      yield (
        id: 'doc:' + d.id,
        revision: d.revision,
        text: d.isConfirmed && memories.needsScan('doc:' + d.id, d.revision)
            ? (_preparedFacts[d.currentVersion] ?? d.markdown)
            : '',
        at: d.confirmedAt ?? d.updatedAt,
        confirmed: d.isConfirmed,
      );
    }
    for (final m in messages.where((m) => m.role == ChatRole.user)) {
      yield (
        id: 'msg:' + m.id,
        revision: 1,
        text: m.text,
        at: m.createdAt,
        confirmed: true,
      );
    }
  }

  final List<MarkdownDocument> documents;
  final List<ChatEntry> messages;
  final List<TaskRecord> tasks;
  final List<ContainerAction> containerActions;
  final List<ConversationThread> conversations;
  String activeConversationId;

  static String normalizeCompanionName(String value) {
    final name = value.trim();
    final characters = name.runes.toList();
    if (characters.isEmpty ||
        characters.length > 12 ||
        characters.any(
          (character) =>
              character < 0x20 ||
              (character >= 0x7f && character <= 0x9f) ||
              character == 0x2028 ||
              character == 0x2029 ||
              (character >= 0xd800 && character <= 0xdfff),
        )) {
      throw ArgumentError.value(value, 'name', '昵称需为 1–12 个字符，且不能包含换行或控制字符。');
    }
    return name;
  }

  static String validateCompanionTone(String value) {
    if (!companionTones.contains(value)) {
      throw ArgumentError.value(value, 'tone', '请选择随和搭子、利落助手或脑洞伙伴。');
    }
    return value;
  }

  /// Additive v1 migration: old messages belong to the main conversation.
  /// Recover missing thread records instead of hiding their existing messages.
  void _ensureConversations() {
    final ids = <String>{};
    for (final conversation in conversations) {
      if (conversation.id.trim().isEmpty || !ids.add(conversation.id)) {
        throw const FormatException('会话标识无效或重复；原数据未被覆盖。');
      }
    }
    final entriesByConversation = <String, List<ChatEntry>>{};
    for (final message in messages) {
      if (message.conversationId.trim().isEmpty) {
        throw const FormatException('消息缺少有效会话标识；原数据未被覆盖。');
      }
      entriesByConversation
          .putIfAbsent(message.conversationId, () => [])
          .add(message);
    }
    for (final group in entriesByConversation.entries) {
      if (!ids.add(group.key)) continue;
      final entries = group.value;
      var title = '新对话';
      for (final entry in entries) {
        if (entry.role == ChatRole.user && entry.text.trim().isNotEmpty) {
          title = String.fromCharCodes(
            entry.text.trim().replaceAll(RegExp(r'\s+'), ' ').runes.take(26),
          );
          break;
        }
      }
      final createdAt = entries
          .map((entry) => entry.createdAt)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      conversations.add(
        ConversationThread(id: group.key, title: title, createdAt: createdAt),
      );
    }
    if (conversations.isEmpty) {
      conversations.add(
        ConversationThread(id: 'main', title: '新对话', createdAt: DateTime.now()),
      );
    }
    if (!conversations.any((thread) => thread.id == activeConversationId)) {
      activeConversationId = conversations.first.id;
    }
  }

  Future<void> loadMemorySources() async {
    for (final d in List.of(documents)) {
      if (d.isConfirmed &&
          memories.needsScan('doc:' + d.id, d.revision) &&
          !d.currentVersion.isLoaded) {
        _preparedFacts[d.currentVersion] = LocalMemoryBook.factLines(
          await d.currentVersion.readOnce(),
        ).join('\n');
      }
    }
  }

  Map<String, Object?> toJson({bool forStorage = false}) => {
    'schemaVersion': 1,
    if (forStorage) 'localMemoryScans': memories.scanned,
    'profile': profile?.toJson(),
    'onboardingDismissed': onboardingDismissed,
    'companionName': companionName,
    'companionTone': companionTone,
    'hapticsEnabled': hapticsEnabled,
    'memoryBook': memories.toJson(),
    'conversations': conversations.map((thread) => thread.toJson()).toList(),
    'activeConversationId': activeConversationId,
    'documents': documents
        .map(
          (d) => {
            'id': d.id,
            'title': d.title,
            'markdown': forStorage && d.currentVersion.storedReference
                ? d.currentVersion
                : d.markdown,
            'revision': d.revision,
            'updatedAt': d.updatedAt.toUtc().toIso8601String(),
            'confirmedRevision': d.confirmedRevision,
            'confirmedAt': d.confirmedAt?.toUtc().toIso8601String(),
            'history': [
              for (final version in d.history)
                {
                  'revision': version.revision,
                  'markdown': forStorage && version.storedReference
                      ? version
                      : version.markdown,
                  'updatedAt': version.updatedAt.toUtc().toIso8601String(),
                },
            ],
          },
        )
        .toList(),
    'messages': messages.map((m) => m.toJson()).toList(),
    'containerActions': containerActions
        .map((action) => action.toJson())
        .toList(),
    'tasks': tasks
        .map(
          (t) => {
            'id': t.id,
            'title': t.title,
            'status': t.status.name,
            'createdAt': t.createdAt.toIso8601String(),
            'updatedAt': t.updatedAt.toIso8601String(),
            'detail': t.statusDetail,
            'steps': t.steps
                .map(
                  (s) => {
                    'id': s.id,
                    'title': s.title,
                    'status': s.status.name,
                    'hasSideEffects': s.hasSideEffects,
                    'executionId': s.executionId,
                    'resultSummary': s.resultSummary,
                  },
                )
                .toList(),
          },
        )
        .toList(),
  };

  factory WorkspaceState.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != 1)
      throw const FormatException('不支持的数据版本；原数据未被覆盖。');
    final companionName = json.containsKey('companionName')
        ? json['companionName']
        : defaultCompanionName;
    final companionTone = json.containsKey('companionTone')
        ? json['companionTone']
        : defaultCompanionTone;
    final hapticsEnabled = json.containsKey('hapticsEnabled')
        ? json['hapticsEnabled']
        : true;
    if (companionName is! String ||
        companionTone is! String ||
        hapticsEnabled is! bool) {
      throw const FormatException('伴侣偏好数据无效；原数据未被覆盖。');
    }
    try {
      normalizeCompanionName(companionName);
      validateCompanionTone(companionTone);
    } on ArgumentError {
      throw const FormatException('伴侣偏好数据无效；原数据未被覆盖。');
    }
    List<Map<String, Object?>> rows(String key) =>
        (json[key] as List<Object?>? ?? [])
            .map((v) => Map<String, Object?>.from(v! as Map))
            .toList();
    DocumentVersion version(String id, Map row) {
      final body = row['markdown'], rev = row['revision'] as int;
      final at = DateTime.parse(row['updatedAt'] as String);
      if (body is DocumentVersion &&
          body.documentId == id &&
          body.revision == rev &&
          body.updatedAt == at)
        return body;
      return DocumentVersion(
        documentId: id,
        revision: rev,
        updatedAt: at,
        markdown: body as String,
      );
    }

    return WorkspaceState(
      profile: json['profile'] == null
          ? null
          : ProviderProfile.fromJson(
              Map<String, Object?>.from(json['profile']! as Map),
            ),
      onboardingDismissed: json['onboardingDismissed'] as bool? ?? false,
      companionName: companionName,
      companionTone: companionTone,
      hapticsEnabled: hapticsEnabled,
      memories: json['memoryBook'] == null
          ? null
          : LocalMemoryBook.fromJson(
              Map<String, Object?>.from(json['memoryBook'] as Map),
              scanned:
                  (json['localMemoryScans'] as Map?)?.cast<String, int>() ??
                  const {},
            ),
      conversations: rows('conversations')
          .map(ConversationThread.fromJson)
          .toList(),
      activeConversationId: json['activeConversationId'] as String? ?? 'main',
      documents: rows('documents')
          .map(
            (d) => MarkdownDocument.versioned(
              title: d['title']! as String,
              currentVersion: version(d['id'] as String, d),
              history: [
                for (final raw in (d['history'] as List? ?? const []))
                  version(d['id'] as String, raw as Map),
              ],
              confirmedRevision: d['confirmedRevision'] as int?,
              confirmedAt: d['confirmedAt'] == null
                  ? null
                  : DateTime.parse(d['confirmedAt']! as String),
            ),
          )
          .toList(),
      messages: rows('messages').map(ChatEntry.fromJson).toList(),
      containerActions: rows('containerActions')
          .map(ContainerAction.fromJson)
          .toList(),
      tasks: rows('tasks')
          .map(
            (t) => TaskRecord(
              id: t['id']! as String,
              title: t['title']! as String,
              status: TaskStatus.values.byName(t['status']! as String),
              createdAt: DateTime.parse(t['createdAt']! as String),
              updatedAt: DateTime.parse(t['updatedAt']! as String),
              statusDetail: t['detail'] as String?,
              steps: (t['steps'] as List<Object?>? ?? []).map((value) {
                final s = Map<String, Object?>.from(value! as Map);
                return TaskStep(
                  id: s['id']! as String,
                  title: s['title']! as String,
                  status: TaskStepStatus.values.byName(s['status']! as String),
                  hasSideEffects: s['hasSideEffects'] as bool? ?? false,
                  executionId: s['executionId'] as String?,
                  resultSummary: s['resultSummary'] as String?,
                );
              }).toList(),
            ),
          )
          .toList(),
    );
  }
}

abstract interface class WorkspacePersistence {
  String get description;
  Future<WorkspaceState> load();
  Future<void> save(Map<String, Object?> snapshot);
  Future<void> close();
}

abstract interface class WorkspaceCatalog {
  Future<WorkspaceState> loadCatalog();
}

final class MemoryWorkspacePersistence implements WorkspacePersistence {
  Map<String, Object?>? snapshot;
  @override
  String get description => '会话内存（测试）';
  @override
  Future<WorkspaceState> load() async =>
      snapshot == null ? WorkspaceState() : WorkspaceState.fromJson(snapshot!);
  @override
  Future<void> save(Map<String, Object?> value) async {
    snapshot = value;
  }

  @override
  Future<void> close() async {}
}
