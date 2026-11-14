// SPDX-License-Identifier: GPL-3.0-only

import 'authorization.dart';
import 'providers.dart';

enum ModelRole { system, developer, user, assistant, tool }

final class ToolDefinition {
  ToolDefinition({
    required this.name,
    required this.description,
    required Map<String, Object?> parameters,
  }) : parameters = Map.unmodifiable(parameters);

  final String name;
  final String description;
  final Map<String, Object?> parameters;
}

final class ModelToolCall {
  ModelToolCall({
    required this.id,
    required this.name,
    required Map<String, Object?> arguments,
  }) : arguments = Map.unmodifiable(arguments);

  final String id;
  final String name;
  final Map<String, Object?> arguments;
}

/// Provider extensions remain intact across tool turns (for example,
/// reasoning_content). Adapters must not silently discard required state.
final class ModelMessage {
  ModelMessage({
    required this.role,
    this.content,
    this.toolCallId,
    List<ModelToolCall> toolCalls = const [],
    Map<String, Object?> extensions = const {},
  })  : toolCalls = List.unmodifiable(toolCalls),
        extensions = Map.unmodifiable(extensions);

  final ModelRole role;
  final String? content;
  final String? toolCallId;
  final List<ModelToolCall> toolCalls;
  final Map<String, Object?> extensions;
}

final class ModelRequest {
  ModelRequest({
    required this.id,
    required this.taskId,
    required List<ModelMessage> messages,
    List<ToolDefinition> tools = const [],
    Set<SourceVersion> sources = const {},
    this.maxOutputTokens = 512,
    Map<String, Object?> parameters = const {},
  })  : messages = List.unmodifiable(messages),
        tools = List.unmodifiable(tools),
        sources = Set.unmodifiable(sources),
        parameters = Map.unmodifiable(parameters) {
    if (maxOutputTokens < 1) {
      throw ArgumentError.value(maxOutputTokens, 'maxOutputTokens');
    }
  }

  final String id;
  final String taskId;
  final List<ModelMessage> messages;
  final List<ToolDefinition> tools;
  final Set<SourceVersion> sources;
  final int maxOutputTokens;
  final Map<String, Object?> parameters;
}

enum ModelEventType { textDelta, toolCall, usage, completed }

final class ModelEvent {
  const ModelEvent.textDelta(this.text)
      : type = ModelEventType.textDelta,
        toolCall = null,
        usage = null,
        finishReason = null;

  const ModelEvent.toolCall(this.toolCall)
      : type = ModelEventType.toolCall,
        text = null,
        usage = null,
        finishReason = null;

  const ModelEvent.usage(this.usage)
      : type = ModelEventType.usage,
        text = null,
        toolCall = null,
        finishReason = null;

  const ModelEvent.completed({this.finishReason})
      : type = ModelEventType.completed,
        text = null,
        toolCall = null,
        usage = null;

  final ModelEventType type;
  final String? text;
  final ModelToolCall? toolCall;
  final ModelUsage? usage;
  final String? finishReason;
}

final class ModelUsage {
  const ModelUsage({this.inputTokens, this.outputTokens});

  final int? inputTokens;
  final int? outputTokens;
}

abstract interface class ModelProvider {
  Stream<ModelEvent> generate({
    required ProviderProfile profile,
    required ModelRequest request,
    required CloudAuthorization authorization,
  });

  Future<void> cancel(String requestId);
}
