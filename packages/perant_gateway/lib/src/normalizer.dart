// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';

import 'models.dart';
import 'sse.dart';

final class GatewayNormalizer {
  GatewayNormalizer(this.protocol);
  final GatewayProtocol protocol;
  bool isComplete = false;
  String? _responseId;
  String? _finishReason;
  final _assistant = <String, Object?>{'role': 'assistant'};
  final _chatTools = <int, _ToolAssembly>{};
  final _responseTools = <String, _ToolAssembly>{};
  final _output = <int, Map<String, Object?>>{};

  Iterable<GatewayEvent> accept(SseMessage frame) sync* {
    if (isComplete || frame.data.isEmpty || frame.event == 'ping') return;
    if (frame.data.trim() == '[DONE]') {
      if (protocol == GatewayProtocol.chatCompletions) yield* _completeChat();
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(frame.data);
    } on FormatException {
      throw const GatewayException(
          'invalid_stream', 'The API returned malformed stream data.');
    }
    final data = asObject(decoded);
    final type = data['type'] is String ? data['type']! as String : frame.event;
    if (data['error'] != null || type == 'error' || type == 'response.failed') {
      throw const GatewayException(
          'upstream_error', 'The model service reported an error.');
    }
    if (type == 'response.incomplete') {
      throw const GatewayException(
          'incomplete_output', 'The model did not finish its response.');
    }
    yield GatewayMetadata(eventType: type, data: data);
    if (protocol == GatewayProtocol.chatCompletions) {
      yield* _chat(data);
    } else {
      yield* _responses(data, type);
    }
  }

  Iterable<GatewayEvent> _chat(Map<String, Object?> data) sync* {
    if (data['id'] is String) _responseId = data['id']! as String;
    final choices = data['choices'];
    if (choices is! List || choices.isEmpty) return;
    for (final rawChoice in choices) {
      final choice = asObject(rawChoice);
      if (choice['index'] != null && choice['index'] != 0) continue;
      final delta = asObject(choice['delta'] ?? const <String, Object?>{});
      final text = delta['content'];
      if (text is String && text.isNotEmpty) yield GatewayTextDelta(text);
      _mergeDelta(_assistant, {...delta}..remove('tool_calls'));
      final calls = delta['tool_calls'];
      if (calls is List) {
        for (final rawCall in calls) {
          final call = asObject(rawCall);
          final index = call['index'];
          if (index is! int) _invalidTool();
          final tool = _chatTools.putIfAbsent(index, _ToolAssembly.new);
          tool.addChat(call);
        }
      }
      final reason = choice['finish_reason'];
      if (reason is String) {
        _finishReason = reason;
        if (reason == 'length') {
          throw const GatewayException('output_limit',
              'The model reached its output limit before completion.');
        }
        if (reason == 'content_filter') {
          throw const GatewayException('content_filtered',
              'The service did not complete this response.');
        }
      }
    }
  }

  Iterable<GatewayEvent> _completeChat() sync* {
    final tools = _chatTools.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final entry in tools) {
      yield entry.value.event;
    }
    if (tools.isNotEmpty) {
      _assistant['tool_calls'] =
          tools.map((entry) => entry.value.chatMessage).toList();
      _assistant.putIfAbsent('content', () => null);
    }
    isComplete = true;
    yield GatewayCompleted(
      responseId: _responseId,
      finishReason: _finishReason,
      continuation: {
        'assistantMessage': Map<String, Object?>.unmodifiable(_assistant)
      },
    );
  }

  Iterable<GatewayEvent> _responses(
      Map<String, Object?> data, String? type) sync* {
    switch (type) {
      case 'response.created':
        final response = asObject(data['response']);
        if (response['id'] is String) _responseId = response['id']! as String;
      case 'response.output_text.delta':
        final delta = data['delta'];
        if (delta is String && delta.isNotEmpty) yield GatewayTextDelta(delta);
      case 'response.output_item.added':
      case 'response.output_item.done':
        final item = asObject(data['item']);
        final outputIndex = data['output_index'];
        if (outputIndex is int) _output[outputIndex] = item;
        if (item['type'] == 'function_call') {
          final id = item['id'];
          if (id is! String) _invalidTool();
          _responseTools.putIfAbsent(id, _ToolAssembly.new).addResponse(item);
        }
      case 'response.function_call_arguments.delta':
        final itemId = data['item_id'];
        final delta = data['delta'];
        if (itemId is! String || delta is! String) _invalidTool();
        _responseTools
            .putIfAbsent(itemId, _ToolAssembly.new)
            .appendArguments(delta);
      case 'response.function_call_arguments.done':
        final itemId = data['item_id'];
        final arguments = data['arguments'];
        if (itemId is! String || arguments is! String) _invalidTool();
        _responseTools
            .putIfAbsent(itemId, _ToolAssembly.new)
            .setArguments(arguments);
      case 'response.completed':
        final response = asObject(data['response']);
        if (response['id'] is String) _responseId = response['id']! as String;
        final status = response['status'];
        if (status != null && status != 'completed') {
          throw const GatewayException(
              'incomplete_output', 'The model did not finish its response.');
        }
        final completedOutput = response['output'];
        if (completedOutput is List) {
          for (final rawItem in completedOutput) {
            final item = asObject(rawItem);
            if (item['type'] == 'function_call') {
              final id = item['id'];
              if (id is! String) _invalidTool();
              _responseTools
                  .putIfAbsent(id, _ToolAssembly.new)
                  .addResponse(item);
            }
          }
        }
        for (final tool in _responseTools.values) {
          yield tool.event;
        }
        final indices = _output.keys.toList()..sort();
        isComplete = true;
        yield GatewayCompleted(
          responseId: _responseId,
          finishReason: 'completed',
          continuation: {
            'response': {
              ...response,
              if (completedOutput is! List)
                'output': indices.map((index) => _output[index]!).toList(),
            },
          },
        );
    }
  }
}

Map<String, Object?> asObject(Object? value) {
  if (value is Map<String, dynamic>) return Map<String, Object?>.from(value);
  throw const GatewayException(
      'invalid_stream', 'The API returned an invalid stream event.');
}

void _mergeDelta(Map<String, Object?> target, Map<String, Object?> delta) {
  for (final entry in delta.entries) {
    final prior = target[entry.key];
    final value = entry.value;
    if (entry.key == 'role') {
      target[entry.key] = value;
    } else if (value is String && prior is String) {
      target[entry.key] = prior + value;
    } else if (value is List && prior is List) {
      target[entry.key] = [...prior, ...value];
    } else if (value is Map<String, dynamic> && prior is Map<String, dynamic>) {
      final combined = Map<String, Object?>.from(prior);
      _mergeDelta(combined, Map<String, Object?>.from(value));
      target[entry.key] = combined;
    } else {
      target[entry.key] = value;
    }
  }
}

final class _ToolAssembly {
  static const maxArgumentCharacters = 1024 * 1024;
  String? id;
  String? name;
  String arguments = '';
  final _extra = <String, Object?>{};

  void appendArguments(String delta) => setArguments(arguments + delta);

  void setArguments(String value) {
    if (value.length > maxArgumentCharacters) {
      throw const GatewayException(
          'tool_too_large', 'The model returned oversized tool arguments.');
    }
    arguments = value;
  }

  void addChat(Map<String, Object?> delta) {
    if (delta['id'] is String) id = delta['id']! as String;
    final function = asObject(delta['function'] ?? const <String, Object?>{});
    if (function['name'] is String) name = '${name ?? ''}${function['name']}';
    if (function['arguments'] is String)
      appendArguments(function['arguments']! as String);
    _mergeDelta(_extra, {...delta}..remove('index'));
  }

  void addResponse(Map<String, Object?> item) {
    if (item['call_id'] is String) id = item['call_id']! as String;
    if (item['name'] is String) name = item['name']! as String;
    if (item['arguments'] is String) setArguments(item['arguments']! as String);
  }

  GatewayToolCall get event {
    if (id == null || id!.isEmpty || name == null || name!.isEmpty)
      _invalidTool();
    return GatewayToolCall(id: id!, name: name!, arguments: arguments);
  }

  Map<String, Object?> get chatMessage {
    final function = _extra['function'];
    return {
      ..._extra,
      'id': event.id,
      'type': 'function',
      'function': {
        if (function is Map<String, dynamic>) ...function,
        'name': name,
        'arguments': arguments,
      },
    };
  }
}

Never _invalidTool() => throw const GatewayException(
    'invalid_tool_call', 'The API returned an incomplete tool call.');
