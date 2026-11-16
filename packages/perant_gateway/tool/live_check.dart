// SPDX-License-Identifier: GPL-3.0-only

// Live provider check. Sends real, billable requests with a fixed non-private
// prompt set. The key is read from the environment and is never printed.
//
//   PERANT_LIVE_API_KEY=... PERANT_LIVE_MODEL=deepseek-flash \
//     tool/dartw run packages/perant_gateway/tool/live_check.dart
//
// Optional: PERANT_LIVE_BASE_URL (default https://api.deepseek.com/v1/),
// PERANT_LIVE_PROTOCOL (chat | responses), PERANT_LIVE_VERBOSE=1.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:perant_gateway/perant_gateway.dart';

final _verbose = Platform.environment['PERANT_LIVE_VERBOSE'] == '1';

/// Records only status codes and, for rejected requests, the provider's error
/// text so a failing check explains itself. Request bodies are not logged.
final class _RecordingClient extends http.BaseClient {
  _RecordingClient(this._inner);
  final http.Client _inner;
  String? lastRejection;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    final bytes = await response.stream.toBytes();
    final text = utf8.decode(bytes, allowMalformed: true);
    lastRejection =
        'HTTP ${response.statusCode}: ${text.length > 600 ? text.substring(0, 600) : text}';
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      headers: response.headers,
      request: response.request,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}

final class _Turn {
  String text = '';
  final calls = <GatewayToolCall>[];
  GatewayCompleted? completion;
  Duration? firstText;
  Duration elapsed = Duration.zero;
  int reasoningCharacters = 0;
  Object? error;
}

Future<_Turn> _run(
  OpenAiGateway gateway,
  GatewayConfiguration configuration,
  String key,
  GatewayRequest request,
) async {
  final turn = _Turn();
  final watch = Stopwatch()..start();
  try {
    await for (final event in gateway.stream(
      configuration: configuration,
      apiKey: key,
      request: request,
    )) {
      if (event is GatewayTextDelta) {
        turn.firstText ??= watch.elapsed;
        turn.text += event.text;
      } else if (event is GatewayToolCall) {
        turn.calls.add(event);
      } else if (event is GatewayCompleted) {
        turn.completion = event;
      } else if (event is GatewayMetadata) {
        final choices = event.data['choices'];
        if (choices is List && choices.isNotEmpty && choices.first is Map) {
          final delta = (choices.first as Map)['delta'];
          final reasoning = delta is Map ? delta['reasoning_content'] : null;
          if (reasoning is String) turn.reasoningCharacters += reasoning.length;
        }
      }
    }
  } catch (error) {
    turn.error = error;
  }
  turn.elapsed = watch.elapsed;
  return turn;
}

var _failures = 0;

void _report(String name, bool ok, String detail) {
  if (!ok) _failures++;
  stdout.writeln('${ok ? 'PASS' : 'FAIL'}  $name  $detail');
}

String _timing(_Turn turn) =>
    'first text ${turn.firstText?.inMilliseconds ?? '-'} ms, '
    'total ${turn.elapsed.inMilliseconds} ms, '
    'reasoning ${turn.reasoningCharacters} chars';

Future<void> main() async {
  final environment = Platform.environment;
  final key = environment['PERANT_LIVE_API_KEY'] ?? '';
  final model = environment['PERANT_LIVE_MODEL'] ?? '';
  if (key.isEmpty || model.isEmpty) {
    stderr.writeln('Set PERANT_LIVE_API_KEY and PERANT_LIVE_MODEL.');
    exitCode = 64;
    return;
  }
  final protocol = environment['PERANT_LIVE_PROTOCOL'] == 'responses'
      ? GatewayProtocol.responses
      : GatewayProtocol.chatCompletions;
  final configuration = GatewayConfiguration(
    baseUrl: Uri.parse(
      environment['PERANT_LIVE_BASE_URL'] ?? 'https://api.deepseek.com/v1/',
    ),
    model: model,
    protocol: protocol,
  );
  final client = _RecordingClient(http.Client());
  final gateway = OpenAiGateway(client: client);
  stdout.writeln(
    'endpoint ${configuration.endpoint}  model $model  ${protocol.name}',
  );

  String why(_Turn turn) => '${turn.error ?? 'no completion'}'
      '${client.lastRejection == null ? '' : ' | ${client.lastRejection}'}';

  try {
    // 1. The same request the settings page sends for "test connection".
    client.lastRejection = null;
    final watch = Stopwatch()..start();
    try {
      final result = await gateway.testConnection(
        configuration: configuration,
        apiKey: key,
      );
      _report(
        'connection test',
        result.success,
        '${watch.elapsedMilliseconds} ms, text ${result.textReceived}',
      );
    } catch (error) {
      _report(
        'connection test',
        false,
        '$error${client.lastRejection == null ? '' : ' | ${client.lastRejection}'}',
      );
    }

    if (protocol != GatewayProtocol.chatCompletions) return;

    // 2. Two chat turns; the second replays the stored assistant message the
    //    way the app keeps protocol history.
    client.lastRejection = null;
    final history = <Map<String, Object?>>[
      {'role': 'user', 'content': '用一句话介绍杭州。'},
    ];
    final first = await _run(
      gateway,
      configuration,
      key,
      GatewayRequest(input: history),
    );
    final firstOk = first.completion != null && first.text.trim().isNotEmpty;
    _report(
      'chat turn 1',
      firstOk,
      firstOk ? _timing(first) : why(first),
    );
    if (_verbose) stdout.writeln('  text: ${first.text}');
    if (firstOk) {
      final assistant = first.completion!.continuation['assistantMessage'];
      history
        ..add(Map<String, Object?>.from(assistant! as Map))
        ..add({'role': 'user', 'content': '它在哪个省？只回答省名。'});
      if (_verbose) {
        stdout.writeln(
          '  stored keys: ${(assistant as Map).keys.join(', ')}',
        );
      }
      client.lastRejection = null;
      final second = await _run(
        gateway,
        configuration,
        key,
        GatewayRequest(input: history),
      );
      final secondOk = second.completion != null && second.text.contains('浙江');
      _report(
        'chat turn 2 (history replay)',
        secondOk,
        secondOk ? _timing(second) : '${why(second)} text=${second.text}',
      );
    }

    // 3. Tool proposal, tool result, final answer.
    client.lastRejection = null;
    final tools = [
      GatewayToolDefinition(
        name: 'read_note',
        description: 'Read the text of a named note.',
        parameters: {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
          },
          'required': ['name'],
          'additionalProperties': false,
        },
      ),
    ];
    final input = <Map<String, Object?>>[
      {'role': 'system', 'content': 'Use the tool before answering.'},
      {'role': 'user', 'content': '读取名为 plan 的便签，然后原样告诉我其中的口令。'},
    ];
    final proposal = await _run(
      gateway,
      configuration,
      key,
      GatewayRequest(input: input, tools: tools),
    );
    final proposed = proposal.completion != null &&
        proposal.calls.length == 1 &&
        proposal.calls.single.name == 'read_note';
    _report(
      'tool proposal',
      proposed,
      proposed
          ? '${proposal.calls.single.arguments} · ${_timing(proposal)}'
          : '${why(proposal)} calls=${proposal.calls.length} text=${proposal.text}',
    );
    if (proposed) {
      final assistant = proposal.completion!.continuation['assistantMessage'];
      if (_verbose) {
        stdout.writeln(
          '  stored keys: ${(assistant! as Map).keys.join(', ')}',
        );
      }
      input
        ..add(Map<String, Object?>.from(assistant! as Map))
        ..add({
          'role': 'tool',
          'tool_call_id': proposal.calls.single.id,
          'content': jsonEncode({'ok': true, 'text': '口令是 蓝莓-4821'}),
        });
      client.lastRejection = null;
      final answer = await _run(
        gateway,
        configuration,
        key,
        GatewayRequest(input: input, tools: tools),
      );
      final answered =
          answer.completion != null && answer.text.contains('蓝莓-4821');
      _report(
        'tool result round trip',
        answered,
        answered ? _timing(answer) : '${why(answer)} text=${answer.text}',
      );
    }
  } finally {
    gateway.close();
    client.close();
    stdout.writeln(
        _failures == 0 ? 'LIVE CHECK PASSED' : 'LIVE CHECK FAILED: $_failures');
    if (_failures != 0) exitCode = 1;
  }
}
