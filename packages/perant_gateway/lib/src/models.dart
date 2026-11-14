// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';

enum GatewayProtocol { chatCompletions, responses }

/// Non-secret transport configuration. Credentials are injected per request.
final class GatewayConfiguration {
  GatewayConfiguration({
    required this.baseUrl,
    required this.model,
    this.protocol = GatewayProtocol.chatCompletions,
    Map<String, String> headers = const {},
    this.connectionTimeout = const Duration(seconds: 20),
    this.idleTimeout = const Duration(seconds: 45),
  }) : headers = Map.unmodifiable(headers) {
    final host = baseUrl.host.toLowerCase();
    final isLoopback = {
      'localhost',
      '127.0.0.1',
      '::1',
      '[::1]',
    }.contains(host);
    if (host.isEmpty ||
        (baseUrl.scheme != 'https' &&
            !(baseUrl.scheme == 'http' && isLoopback)) ||
        baseUrl.userInfo.isNotEmpty ||
        baseUrl.hasQuery ||
        baseUrl.hasFragment) {
      throw ArgumentError(
          'Use an HTTPS API base URL without credentials or query parameters.');
    }
    if (model.trim().isEmpty ||
        connectionTimeout <= Duration.zero ||
        idleTimeout <= Duration.zero) {
      throw ArgumentError(
          'A model and positive transport timeouts are required.');
    }
    for (final entry in headers.entries) {
      final name = entry.key.toLowerCase();
      if ({
            'authorization',
            'proxy-authorization',
            'api-key',
            'x-api-key',
          }.contains(name) ||
          entry.key.contains(RegExp(r'[\r\n:]')) ||
          entry.value.contains(RegExp(r'[\r\n]'))) {
        throw ArgumentError(
            'Configuration headers must be non-secret and valid HTTP headers.');
      }
    }
  }

  final Uri baseUrl;
  final String model;
  final GatewayProtocol protocol;
  final Map<String, String> headers;
  final Duration connectionTimeout;
  final Duration idleTimeout;

  Uri get endpoint {
    final suffix = switch (protocol) {
      GatewayProtocol.chatCompletions => '/chat/completions',
      GatewayProtocol.responses => '/responses',
    };
    final path = baseUrl.path.replaceFirst(RegExp(r'/+$'), '');
    return baseUrl.replace(path: path.endsWith(suffix) ? path : '$path$suffix');
  }
}

/// Native protocol input is retained so reasoning/tool context is not discarded.
final class GatewayRequest {
  GatewayRequest({
    required List<Map<String, Object?>> input,
    List<GatewayToolDefinition> tools = const [],
    Map<String, Object?> parameters = const {},
  })  : input = List.unmodifiable(input.map(Map<String, Object?>.unmodifiable)),
        tools = List.unmodifiable(tools),
        parameters = Map.unmodifiable(parameters) {
    if (input.isEmpty)
      throw ArgumentError('At least one input item is required.');
    if (parameters.keys.any({
      'model',
      'messages',
      'input',
      'stream',
      'tools',
    }.contains)) {
      throw ArgumentError(
          'Reserved transport parameters cannot be overridden.');
    }
  }

  final List<Map<String, Object?>> input;
  final List<GatewayToolDefinition> tools;
  final Map<String, Object?> parameters;

  Map<String, Object?> toPayload(GatewayConfiguration configuration) => {
        ...parameters,
        'model': configuration.model,
        'stream': true,
        if (configuration.protocol == GatewayProtocol.chatCompletions)
          'messages': input
        else
          'input': input,
        if (tools.isNotEmpty)
          'tools':
              tools.map((tool) => tool.toJson(configuration.protocol)).toList(),
      };
}

final class GatewayToolDefinition {
  GatewayToolDefinition({
    required this.name,
    required this.description,
    required Map<String, Object?> parameters,
    this.strict,
  }) : parameters = Map.unmodifiable(parameters) {
    if (name.trim().isEmpty) throw ArgumentError('A tool name is required.');
  }

  final String name;
  final String description;
  final Map<String, Object?> parameters;
  final bool? strict;

  Map<String, Object?> toJson(GatewayProtocol protocol) {
    final definition = <String, Object?>{
      'name': name,
      'description': description,
      'parameters': parameters,
      if (strict != null) 'strict': strict,
    };
    return switch (protocol) {
      GatewayProtocol.chatCompletions => {
          'type': 'function',
          'function': definition
        },
      GatewayProtocol.responses => {'type': 'function', ...definition},
    };
  }
}

/// A reusable cancellation token. Cancelling never initiates another request.
final class GatewayCancellation {
  bool _isCancelled = false;
  final _listeners = <void Function()>{};
  final _completion = Completer<void>();

  bool get isCancelled => _isCancelled;
  Future<void> get whenCancelled => _completion.future;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _completion.complete();
    final listeners = List.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  /// Returns a callback that unregisters the listener after a request finishes.
  void Function() listen(void Function() listener) {
    if (_isCancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

sealed class GatewayEvent {
  const GatewayEvent();
}

final class GatewayTextDelta extends GatewayEvent {
  const GatewayTextDelta(this.text);
  final String text;
}

/// This is a proposal, never a permission to execute a tool.
final class GatewayToolCall extends GatewayEvent {
  const GatewayToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final String arguments;

  Map<String, Object?> decodeArguments() {
    try {
      final value = jsonDecode(arguments);
      if (value is Map<String, dynamic>)
        return Map<String, Object?>.from(value);
    } on FormatException {
      throw const GatewayException('invalid_tool_arguments',
          'The model returned invalid tool arguments.');
    }
    throw const GatewayException(
        'invalid_tool_arguments', 'Tool arguments must be a JSON object.');
  }
}

/// Sensitive in-memory protocol context. Do not persist or log automatically.
final class GatewayMetadata extends GatewayEvent {
  const GatewayMetadata({required this.eventType, required this.data});
  final String? eventType;
  final Map<String, Object?> data;
}

final class GatewayCompleted extends GatewayEvent {
  const GatewayCompleted({
    this.responseId,
    this.finishReason,
    required this.continuation,
  });

  final String? responseId;
  final String? finishReason;

  /// Chat: {'assistantMessage': ...}; Responses: {'response': ...}.
  /// Preserves provider fields needed for the next turn; never log by default.
  final Map<String, Object?> continuation;
}

final class GatewayCancelled extends GatewayEvent {
  const GatewayCancelled();
}

/// Deliberately excludes raw response bodies, URLs, headers, and credentials.
final class GatewayException implements Exception {
  const GatewayException(this.code, this.message, {this.statusCode});
  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'GatewayException($code${statusCode == null ? '' : ', HTTP $statusCode'}): $message';
}

final class GatewayConnectionResult {
  const GatewayConnectionResult({
    required this.success,
    required this.elapsed,
    required this.model,
    required this.textReceived,
  });

  final bool success;
  final Duration elapsed;
  final String model;
  final bool textReceived;
}
