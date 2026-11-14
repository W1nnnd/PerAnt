// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:perant_gateway/perant_gateway.dart';
import 'package:test/test.dart';

const testKey = 'test-secret-do-not-log';

GatewayConfiguration config({
  GatewayProtocol protocol = GatewayProtocol.chatCompletions,
  Duration idleTimeout = const Duration(seconds: 1),
}) =>
    GatewayConfiguration(
      baseUrl: Uri.parse('https://example.invalid/v1/'),
      model: 'test-model',
      protocol: protocol,
      idleTimeout: idleTimeout,
    );

GatewayRequest request({List<GatewayToolDefinition> tools = const []}) =>
    GatewayRequest(
      input: const [
        {'role': 'user', 'content': 'test instruction'}
      ],
      tools: tools,
    );

String event(Map<String, Object?> data, {String? name}) =>
    '${name == null ? '' : 'event: $name\r\n'}data: ${jsonEncode(data)}\r\n\r\n';

http.StreamedResponse response(String body, {bool splitBytes = false}) {
  final bytes = utf8.encode(body);
  return http.StreamedResponse(
    splitBytes
        ? Stream.fromIterable(bytes.map((byte) => [byte]))
        : Stream.value(bytes),
    200,
    headers: {'content-type': 'text/event-stream; charset=utf-8'},
  );
}

void main() {
  test('Chat SSE reassembles UTF-8, tools and provider reasoning context',
      () async {
    final body = ': keepalive\r\n\r\n'
        '${event({
          'id': 'chat-1',
          'choices': [
            {
              'index': 0,
              'delta': {'role': 'assistant', 'reasoning_content': '先'}
            }
          ]
        })}'
        '${event({
          'choices': [
            {
              'index': 0,
              'delta': {
                'content': '你好',
                'reasoning_content': '检查',
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call-1',
                    'type': 'function',
                    'function': {'name': 'read_file', 'arguments': '{"path":'}
                  }
                ]
              }
            }
          ]
        })}'
        '${event({
          'choices': [
            {
              'index': 0,
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'arguments': '"notes.md"}'}
                  }
                ]
              },
              'finish_reason': 'tool_calls'
            }
          ]
        })}'
        'data: [DONE]\r\n\r\n';
    final client = MockClient.streaming((outbound, bytes) async {
      expect(outbound.url.path, '/v1/chat/completions');
      expect(outbound.followRedirects, isFalse);
      expect(outbound.headers['Authorization'], 'Bearer $testKey');
      final payload = jsonDecode(await utf8.decodeStream(bytes)) as Map;
      expect(payload['stream'], isTrue);
      expect(payload['messages'], isA<List>());
      expect(
          (payload['tools'] as List).single['function']['name'], 'read_file');
      return response(body, splitBytes: true);
    });
    final gateway = OpenAiGateway(client: client);
    addTearDown(gateway.close);
    final events = await gateway
        .stream(
          configuration: config(),
          apiKey: testKey,
          request: request(tools: [
            GatewayToolDefinition(
              name: 'read_file',
              description: 'Read an authorized file',
              parameters: {
                'type': 'object',
                'properties': {
                  'path': {'type': 'string'}
                }
              },
            )
          ]),
        )
        .toList();
    expect(
        events.whereType<GatewayTextDelta>().map((e) => e.text).join(), '你好');
    final tool = events.whereType<GatewayToolCall>().single;
    expect(tool.name, 'read_file');
    expect(tool.decodeArguments(), {'path': 'notes.md'});
    final completed = events.whereType<GatewayCompleted>().single;
    final assistant = completed.continuation['assistantMessage']! as Map;
    expect(assistant['reasoning_content'], '先检查');
    expect((assistant['tool_calls'] as List).single['id'], 'call-1');
    expect(events.last, isA<GatewayCompleted>());
  });

  test('Responses retains output items and waits for terminal completion',
      () async {
    final item = <String, Object?>{
      'type': 'function_call',
      'id': 'item-1',
      'call_id': 'call-2',
      'name': 'find_file',
      'arguments': '{"query":"纪要"}',
      'vendor_extension': {'signature': 'opaque-context'},
    };
    final body = '${event({
          'type': 'response.created',
          'response': {'id': 'response-1'}
        })}'
        '${event({
          'type': 'response.output_item.added',
          'output_index': 0,
          'item': {...item, 'arguments': ''}
        })}'
        '${event({'type': 'response.output_text.delta', 'delta': '查找中'})}'
        '${event({
          'type': 'response.function_call_arguments.delta',
          'item_id': 'item-1',
          'delta': '{"query":'
        })}'
        '${event({
          'type': 'response.function_call_arguments.done',
          'item_id': 'item-1',
          'arguments': '{"query":"纪要"}'
        })}'
        '${event({
          'type': 'response.output_item.done',
          'output_index': 0,
          'item': item
        })}'
        '${event({
          'type': 'response.completed',
          'response': {
            'id': 'response-1',
            'status': 'completed',
            'output': [item]
          }
        })}';
    final client = MockClient.streaming((outbound, bytes) async {
      expect(outbound.url.path, '/v1/responses');
      final payload = jsonDecode(await utf8.decodeStream(bytes)) as Map;
      expect(payload['input'], isA<List>());
      expect((payload['tools'] as List).single['name'], 'find_file');
      expect(
          (payload['tools'] as List).single.containsKey('function'), isFalse);
      return response(body);
    });
    final gateway = OpenAiGateway(client: client);
    addTearDown(gateway.close);
    final events = await gateway
        .stream(
          configuration: config(protocol: GatewayProtocol.responses),
          apiKey: testKey,
          request: request(tools: [
            GatewayToolDefinition(
                name: 'find_file',
                description: 'Find a file',
                parameters: {'type': 'object'})
          ]),
        )
        .toList();
    expect(events.whereType<GatewayToolCall>().single.decodeArguments(),
        {'query': '纪要'});
    expect(events.whereType<GatewayTextDelta>().single.text, '查找中');
    final native = events
        .whereType<GatewayCompleted>()
        .single
        .continuation['response']! as Map;
    expect((native['output'] as List).single['vendor_extension'],
        {'signature': 'opaque-context'});
    expect(events.last, isA<GatewayCompleted>());
  });

  test('HTTP errors never expose credential, response body or URL', () async {
    final gateway = OpenAiGateway(
        client: MockClient((_) async => http.Response(
              'upstream echoed Authorization: Bearer $testKey',
              401,
            )));
    addTearDown(gateway.close);
    await expectLater(
        gateway.stream(
            configuration: config(), apiKey: testKey, request: request()),
        emitsError(
          isA<GatewayException>()
              .having((e) => e.statusCode, 'HTTP status', 401)
              .having((e) => e.toString().contains(testKey), 'no credential',
                  isFalse)
              .having(
                  (e) => e.toString().contains('echoed'), 'no body', isFalse)
              .having((e) => e.toString().contains('example.invalid'), 'no URL',
                  isFalse),
        ));
  });

  test('network exceptions are replaced with a safe error', () async {
    final gateway = OpenAiGateway(
        client: MockClient((_) async =>
            throw http.ClientException('request $testKey failed')));
    addTearDown(gateway.close);
    await expectLater(
        gateway.stream(
            configuration: config(), apiKey: testKey, request: request()),
        emitsError(
          isA<GatewayException>()
              .having((e) => e.code, 'code', 'connection_failed')
              .having((e) => e.toString().contains(testKey), 'no credential',
                  isFalse),
        ));
  });

  test('EOF without a terminal marker is interrupted, not completed', () async {
    final gateway = OpenAiGateway(
        client: MockClient.streaming((_, __) async => response(event({
              'choices': [
                {
                  'delta': {'content': 'partial'}
                }
              ],
            }))));
    addTearDown(gateway.close);
    await expectLater(
        gateway.stream(
            configuration: config(), apiKey: testKey, request: request()),
        emitsInOrder([
          isA<GatewayMetadata>(),
          isA<GatewayTextDelta>(),
          emitsError(isA<GatewayException>()
              .having((e) => e.code, 'code', 'stream_interrupted')),
          emitsDone,
        ]));
  });

  test('cancellation stops a stalled response and emits cancelled', () async {
    final upstream = StreamController<List<int>>();
    final cancellation = GatewayCancellation();
    final gateway = OpenAiGateway(
        client: MockClient.streaming((_, __) async => http.StreamedResponse(
              upstream.stream,
              200,
              headers: {'content-type': 'text/event-stream'},
            )));
    addTearDown(gateway.close);
    final eventsFuture = gateway
        .stream(
          configuration: config(),
          apiKey: testKey,
          request: request(),
          cancellation: cancellation,
        )
        .toList();
    await Future<void>.delayed(Duration.zero);
    cancellation.cancel();
    final events = await eventsFuture.timeout(const Duration(seconds: 1));
    expect(events, [isA<GatewayCancelled>()]);
    await upstream.close();
  });

  test('already cancelled requests never contact the service', () async {
    var requests = 0;
    final gateway = OpenAiGateway(client: MockClient((_) async {
      requests++;
      return http.Response('', 500);
    }));
    addTearDown(gateway.close);
    final cancellation = GatewayCancellation()..cancel();
    final events = await gateway
        .stream(
          configuration: config(),
          apiKey: testKey,
          request: request(),
          cancellation: cancellation,
        )
        .toList();
    expect(events.single, isA<GatewayCancelled>());
    expect(requests, 0);
  });

  test('idle timeout cancels a stalled stream', () async {
    final upstream = StreamController<List<int>>();
    final gateway = OpenAiGateway(
        client: MockClient.streaming((_, __) async => http.StreamedResponse(
              upstream.stream,
              200,
              headers: {'content-type': 'text/event-stream'},
            )));
    addTearDown(gateway.close);
    await expectLater(
        gateway.stream(
          configuration: config(idleTimeout: const Duration(milliseconds: 20)),
          apiKey: testKey,
          request: request(),
        ),
        emitsError(
            isA<GatewayException>().having((e) => e.code, 'code', 'timeout')));
    await upstream.close();
  });

  test('multiline SSE JSON and comment frames decode correctly', () async {
    const body =
        ': ping\n\nevent: message\ndata: {"choices":\ndata: [{"delta":{"content":"OK"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n';
    final gateway = OpenAiGateway(
        client: MockClient.streaming((_, __) async => response(body)));
    addTearDown(gateway.close);
    final events = await gateway
        .stream(configuration: config(), apiKey: testKey, request: request())
        .toList();
    expect(events.whereType<GatewayTextDelta>().single.text, 'OK');
    expect(events.last, isA<GatewayCompleted>());
  });

  test('connection test sends only a fixed prompt, no tools or user material',
      () async {
    final gateway =
        OpenAiGateway(client: MockClient.streaming((_, bytes) async {
      final payload = jsonDecode(await utf8.decodeStream(bytes)) as Map;
      expect(payload['messages'], [
        {'role': 'user', 'content': 'Reply with the single word OK.'}
      ]);
      expect(payload.containsKey('tools'), isFalse);
      expect(payload.containsKey('max_tokens'), isFalse);
      expect(payload.containsKey('max_completion_tokens'), isFalse);
      return response('${event({
            'choices': [
              {
                'delta': {'content': 'OK'},
                'finish_reason': 'stop'
              }
            ]
          })}data: [DONE]\n\n');
    }));
    addTearDown(gateway.close);
    final result =
        await gateway.testConnection(configuration: config(), apiKey: testKey);
    expect(result.success, isTrue);
    expect(result.textReceived, isTrue);
  });

  test('invalid configuration and reserved payload fields fail without secrets',
      () {
    expect(
        () => GatewayConfiguration(
            baseUrl: Uri.parse('http://remote.invalid'), model: 'x'),
        throwsArgumentError);
    expect(
        () => GatewayConfiguration(
            baseUrl: Uri.parse('https://example.invalid/v1?key=$testKey'),
            model: 'x'),
        throwsArgumentError);
    expect(
        () => GatewayConfiguration(
            baseUrl: Uri.parse('https://example.invalid/v1'),
            model: 'x',
            headers: {'Authorization': testKey}),
        throwsArgumentError);
    expect(
        () => GatewayRequest(input: const [
              {'role': 'user', 'content': 'x'}
            ], parameters: {
              'model': 'override'
            }),
        throwsArgumentError);
    expect(
        GatewayConfiguration(
                baseUrl: Uri.parse('http://localhost:8080/v1'), model: 'x')
            .endpoint
            .path,
        '/v1/chat/completions');
    expect(
        GatewayConfiguration(
                baseUrl: Uri.parse('https://example.invalid/v1/responses'),
                model: 'x',
                protocol: GatewayProtocol.responses)
            .endpoint
            .path,
        '/v1/responses');
  });
}
