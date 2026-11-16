// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant_core/perant_core.dart';

void main() {
  final now = DateTime.utc(2026, 11, 13, 12);

  test(
    'workspace round-trip preserves confirmed revisions and Unicode text',
    () {
      final document = MarkdownDocument(
        id: 'document-1',
        title: '周会纪要',
        markdown: '# 周会\n\n- 决策：保留 Markdown。',
        updatedAt: now,
      ).confirm(at: now);
      final state = WorkspaceState(
        onboardingDismissed: true,
        documents: [document],
        messages: [
          ChatEntry(
            id: 'message-1',
            role: ChatRole.user,
            text: '请整理会议记录。',
            createdAt: now,
          ),
        ],
      );

      final restored = WorkspaceState.fromJson(
        jsonDecode(jsonEncode(state.toJson())) as Map<String, Object?>,
      );

      expect(restored.onboardingDismissed, isTrue);
      expect(restored.documents.single.markdown, document.markdown);
      expect(restored.documents.single.isConfirmed, isTrue);
      expect(restored.documents.single.confirmedRevision, document.revision);
      expect(restored.documents.single.confirmedAt, now);
      expect(restored.messages.single.text, '请整理会议记录。');
      expect(restored.messages.single.role, ChatRole.user);
    },
  );

  test(
    'workspace metadata stores a credential reference without a key value',
    () {
      final profile = ProviderCatalog.presets.first.createProfile(
        profileId: 'personal',
        modelId: 'chosen-model',
        storageKeyRef: 'credential:personal',
      );
      final snapshot = WorkspaceState(profile: profile).toJson();
      final encoded = jsonEncode(snapshot);
      final restored = WorkspaceState.fromJson(
        jsonDecode(encoded) as Map<String, Object?>,
      );

      expect(restored.profile!.storageKeyRef, 'credential:personal');
      expect(restored.profile!.modelId, 'chosen-model');
      expect(encoded, isNot(contains('apiKey')));
      expect(encoded, isNot(contains('Authorization')));
    },
  );

  test(
    'task journal preserves uncertain outcomes but not reusable cloud grants',
    () {
      final profile = ProviderCatalog.presets.first.createProfile(
        profileId: 'personal',
        modelId: 'chosen-model',
      );
      final task = TaskRecord(
        id: 'task-1',
        title: '整理资料',
        createdAt: now,
        status: TaskStatus.interrupted,
        statusDetail: '请先核对已经生成的文件。',
        steps: const [
          TaskStep(
            id: 'write',
            title: '生成草稿',
            status: TaskStepStatus.uncertain,
            hasSideEffects: true,
            executionId: 'execution-1',
            resultSummary: '写入结果尚未核对。',
          ),
        ],
        cloudAuthorization: CloudAuthorization(
          taskId: 'task-1',
          providerProfileId: profile.id,
          providerEndpoint: profile.apiEndpoint,
          modelId: profile.modelId,
          scope: CloudDataScope.currentMaterials,
          grantedAt: now,
          currentSources: {
            const SourceVersion(sourceId: 'source-1', version: '1'),
          },
        ),
      );

      final restored = WorkspaceState.fromJson(
        jsonDecode(jsonEncode(WorkspaceState(tasks: [task]).toJson()))
            as Map<String, Object?>,
      );

      expect(restored.tasks.single.status, TaskStatus.interrupted);
      expect(
        restored.tasks.single.steps.single.status,
        TaskStepStatus.uncertain,
      );
      expect(restored.tasks.single.steps.single.executionId, 'execution-1');
      expect(restored.tasks.single.steps.single.hasSideEffects, isTrue);
      expect(restored.tasks.single.cloudAuthorization, isNull);
      expect(
        restored.tasks.single.recoveryDisposition,
        RecoveryDisposition.inspectionRequired,
      );
    },
  );

  test('unknown storage schema is rejected instead of resetting data', () {
    expect(
      () => WorkspaceState.fromJson({'schemaVersion': 99}),
      throwsFormatException,
    );
  });

  test('legacy workspace uses companion defaults without dropping history', () {
    final restored = WorkspaceState.fromJson({
      'schemaVersion': 1,
      'messages': [
        {
          'id': 'retained-message',
          'role': 'user',
          'text': '保留我的旧对话。',
          'createdAt': now.toIso8601String(),
        },
      ],
    });

    expect(restored.companionName, '小蚁');
    expect(restored.companionTone, '随和搭子');
    expect(restored.hapticsEnabled, isTrue);
    expect(restored.messages.single.text, '保留我的旧对话。');
    expect(restored.toJson()['schemaVersion'], 1);
  });

  test('companion preferences round-trip and count Unicode characters', () {
    final name = List.filled(12, '🐜').join();
    final state = WorkspaceState(
      companionName: '  $name  ',
      companionTone: '脑洞伙伴',
      hapticsEnabled: false,
    );
    final restored = WorkspaceState.fromJson(
      jsonDecode(jsonEncode(state.toJson())) as Map<String, Object?>,
    );

    expect(restored.companionName, name);
    expect(restored.companionTone, '脑洞伙伴');
    expect(restored.hapticsEnabled, isFalse);
  });

  test('malformed stored preferences fail without resetting the workspace', () {
    for (final values in <Map<String, Object?>>[
      {'companionName': '  '},
      {'companionName': '十三个汉字的昵称超过十二字了'},
      {'companionName': '小\n蚁'},
      {'companionName': null},
      {'companionTone': '任意新语气'},
      {'companionTone': 1},
      {'hapticsEnabled': 'true'},
    ]) {
      expect(
        () => WorkspaceState.fromJson({'schemaVersion': 1, ...values}),
        throwsFormatException,
        reason: values.toString(),
      );
    }
  });

  test(
    'saving and reloading a draft keeps edits and invalidated confirmation',
    () async {
      final original = MarkdownDocument(
        id: 'document-1',
        title: '草稿',
        markdown: '已确认的旧内容',
        updatedAt: now,
      ).confirm(at: now);
      final edited = original.edit(
        '尚未确认的新内容',
        at: now.add(const Duration(minutes: 1)),
      );
      final persistence = MemoryWorkspacePersistence();
      await persistence.save(WorkspaceState(documents: [edited]).toJson());

      final restored = await persistence.load();

      expect(restored.documents.single.markdown, '尚未确认的新内容');
      expect(restored.documents.single.revision, 2);
      expect(restored.documents.single.isConfirmed, isFalse);
    },
  );

  test(
    'multiple conversations round-trip without mixing message ownership',
    () async {
      final noteMessage = ChatEntry(
        id: 'message-notes',
        role: ChatRole.user,
        text: '整理这次周会。',
        createdAt: now,
        conversationId: 'notes',
      );
      final editedReply = ChatEntry(
        id: 'message-research',
        role: ChatRole.assistant,
        text: '正在查找资料。',
        createdAt: now.add(const Duration(minutes: 1)),
        conversationId: 'research',
      ).withText('已找到相关资料。');
      final persistence = MemoryWorkspacePersistence();
      final state = WorkspaceState(
        conversations: [
          ConversationThread(id: 'notes', title: '周会纪要', createdAt: now),
          ConversationThread(
            id: 'research',
            title: '资料检索',
            createdAt: now.add(const Duration(minutes: 1)),
          ),
        ],
        activeConversationId: 'research',
        messages: [noteMessage, editedReply],
      );

      await persistence.save(
        jsonDecode(jsonEncode(state.toJson())) as Map<String, Object?>,
      );
      final restored = await persistence.load();

      expect(restored.activeConversationId, 'research');
      expect(
        restored.conversations
            .where((thread) => thread.id == 'notes')
            .single
            .title,
        '周会纪要',
      );
      expect(
        restored.conversations
            .where((thread) => thread.id == 'research')
            .single
            .createdAt,
        now.add(const Duration(minutes: 1)),
      );
      expect(
        restored.messages
            .where((message) => message.conversationId == 'notes')
            .map((message) => message.text),
        ['整理这次周会。'],
      );
      expect(
        restored.messages
            .where((message) => message.conversationId == 'research')
            .map((message) => message.text),
        ['已找到相关资料。'],
      );
      expect(editedReply.conversationId, 'research');
      expect(restored.toJson()['schemaVersion'], 1);
    },
  );

  test('legacy v1 messages migrate to main without losing history', () {
    final restored = WorkspaceState.fromJson({
      'schemaVersion': 1,
      'messages': [
        {
          'id': 'old-user',
          'role': 'user',
          'text': '请保留过去的对话。',
          'createdAt': now.toIso8601String(),
        },
        {
          'id': 'old-assistant',
          'role': 'assistant',
          'text': '旧纪要草稿。',
          'createdAt': now.add(const Duration(seconds: 1)).toIso8601String(),
        },
      ],
    });

    expect(restored.activeConversationId, 'main');
    expect(restored.conversations.any((thread) => thread.id == 'main'), isTrue);
    expect(restored.messages.map((message) => message.id), [
      'old-user',
      'old-assistant',
    ]);
    expect(restored.messages.map((message) => message.conversationId), [
      'main',
      'main',
    ]);
    expect(restored.messages.map((message) => message.text), [
      '请保留过去的对话。',
      '旧纪要草稿。',
    ]);

    final reloaded = WorkspaceState.fromJson(
      jsonDecode(jsonEncode(restored.toJson())) as Map<String, Object?>,
    );
    expect(reloaded.messages.length, 2);
    expect(reloaded.activeConversationId, 'main');
  });

  test('invalid active conversation falls back to an available thread', () {
    final state = WorkspaceState(
      conversations: [
        ConversationThread(id: 'retained', title: '保留的会话', createdAt: now),
      ],
      activeConversationId: 'removed',
      messages: [
        ChatEntry(
          id: 'retained-message',
          role: ChatRole.user,
          text: '仍然可见的内容。',
          createdAt: now,
          conversationId: 'retained',
        ),
      ],
    );

    final restored = WorkspaceState.fromJson(
      jsonDecode(jsonEncode(state.toJson())) as Map<String, Object?>,
    );

    expect(restored.activeConversationId, isNot('removed'));
    expect(
      restored.conversations.map((thread) => thread.id),
      contains(restored.activeConversationId),
    );
    expect(restored.messages.single.conversationId, 'retained');
    expect(restored.messages.single.text, '仍然可见的内容。');
  });

  test(
    'orphaned message ownership recovers a thread instead of hiding data',
    () {
      final restored = WorkspaceState.fromJson({
        'schemaVersion': 1,
        'activeConversationId': 'missing',
        'conversations': [
          {'id': 'main', 'title': '主会话', 'createdAt': now.toIso8601String()},
        ],
        'messages': [
          {
            'id': 'orphan-message',
            'role': 'user',
            'text': '这个会话的线程元数据曾缺失。',
            'createdAt': now.toIso8601String(),
            'conversationId': 'recovered',
          },
        ],
      });

      expect(
        restored.conversations.any((thread) => thread.id == 'recovered'),
        isTrue,
      );
      expect(restored.messages.single.conversationId, 'recovered');
      expect(restored.messages.single.text, '这个会话的线程元数据曾缺失。');
      expect(
        restored.conversations.map((thread) => thread.id),
        contains(restored.activeConversationId),
      );
    },
  );
}
