// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'normalizer.dart';
import 'sse.dart';

/// HTTP/SSE transport only: no files, model routing, or tool execution.
final class OpenAiGateway {
  OpenAiGateway({http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final _activeRuns = <void Function()>{};
  bool _closed = false;

  Stream<GatewayEvent> stream({
    required GatewayConfiguration configuration,
    required String apiKey,
    required GatewayRequest request,
    GatewayCancellation? cancellation,
  }) {
    late final StreamController<GatewayEvent> controller;
    StreamSubscription<SseMessage>? subscription;
    final abort = Completer<void>();
    final normalizer = GatewayNormalizer(configuration.protocol);
    bool ended = false;
    void Function()? unregisterCancellation;
    late final void Function() cancelRun;

    Future<void> finish({
      GatewayEvent? event,
      GatewayException? error,
      bool silent = false,
    }) async {
      if (ended) return;
      ended = true;
      unregisterCancellation?.call();
      _activeRuns.remove(cancelRun);
      if (!abort.isCompleted) abort.complete();
      await subscription?.cancel();
      if (!silent && !controller.isClosed) {
        if (event != null) controller.add(event);
        if (error != null) controller.addError(error);
      }
      unawaited(controller.close());
    }

    cancelRun = () => unawaited(finish(event: const GatewayCancelled()));

    Future<void> run() async {
      if (ended) return;
      if (_closed) {
        await finish(
            error: const GatewayException(
                'closed', 'The gateway has been closed.'));
        return;
      }
      if (apiKey.trim().isEmpty || apiKey.contains(RegExp(r'[\r\n]'))) {
        await finish(
            error: const GatewayException(
                'missing_credentials', 'A valid API key is required.'));
        return;
      }
      try {
        final outbound = http.AbortableRequest(
          'POST',
          configuration.endpoint,
          abortTrigger: abort.future,
        )
          ..followRedirects = false
          ..headers.addAll({
            ...configuration.headers,
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
          })
          ..body = jsonEncode(request.toPayload(configuration));
        final response = await _client
            .send(outbound)
            .timeout(configuration.connectionTimeout);
        if (ended) {
          await response.stream.listen((_) {}).cancel();
          return;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.stream.listen((_) {}).cancel();
          await finish(
              error: GatewayException(
            'http_error',
            _statusMessage(response.statusCode),
            statusCode: response.statusCode,
          ));
          return;
        }
        final contentType = response.headers['content-type'];
        if (contentType != null &&
            !contentType.toLowerCase().contains('text/event-stream')) {
          await response.stream.listen((_) {}).cancel();
          await finish(
              error: const GatewayException('invalid_content_type',
                  'The API did not return an event stream.'));
          return;
        }
        subscription =
            decodeSse(response.stream.timeout(configuration.idleTimeout))
                .listen(
          (frame) {
            if (ended) return;
            try {
              for (final event in normalizer.accept(frame)) {
                controller.add(event);
              }
              if (normalizer.isComplete) unawaited(finish());
            } catch (error) {
              unawaited(finish(error: _safeException(error)));
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            unawaited(finish(error: _safeException(error)));
          },
          onDone: () {
            if (!ended) {
              unawaited(finish(
                  error: const GatewayException(
                'stream_interrupted',
                'The connection ended before the model completed its response.',
              )));
            }
          },
        );
      } catch (error) {
        if (!ended) await finish(error: _safeException(error));
      }
    }

    controller = StreamController<GatewayEvent>(
      onListen: () {
        _activeRuns.add(cancelRun);
        unregisterCancellation = cancellation?.listen(cancelRun);
        unawaited(run());
      },
      onCancel: () => finish(silent: true),
    );
    return controller.stream;
  }

  /// Sends only a fixed, non-private text prompt. Normal API token charges apply.
  Future<GatewayConnectionResult> testConnection({
    required GatewayConfiguration configuration,
    required String apiKey,
    GatewayCancellation? cancellation,
  }) async {
    final stopwatch = Stopwatch()..start();
    bool textReceived = false;
    bool completed = false;
    await for (final event in stream(
      configuration: configuration,
      apiKey: apiKey,
      cancellation: cancellation,
      request: GatewayRequest(
        input: const [
          {'role': 'user', 'content': 'Reply with the single word OK.'}
        ],
      ),
    )) {
      if (event is GatewayTextDelta && event.text.trim().isNotEmpty)
        textReceived = true;
      if (event is GatewayCompleted) completed = true;
    }
    stopwatch.stop();
    return GatewayConnectionResult(
      success: completed && textReceived,
      elapsed: stopwatch.elapsed,
      model: configuration.model,
      textReceived: textReceived,
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final cancel in List.of(_activeRuns)) {
      cancel();
    }
    if (_ownsClient) _client.close();
  }
}

GatewayException _safeException(Object error) {
  if (error is GatewayException) return error;
  if (error is TimeoutException) {
    return const GatewayException(
        'timeout', 'The model service did not respond in time.');
  }
  if (error is FormatException || error is TypeError) {
    return const GatewayException(
        'invalid_stream', 'The API returned invalid stream data.');
  }
  return const GatewayException(
      'connection_failed', 'Unable to communicate with the model service.');
}

String _statusMessage(int status) => switch (status) {
      401 ||
      403 =>
        'The service rejected the supplied credentials or access permissions.',
      404 => 'The configured endpoint or model was not found.',
      429 => 'The service rate limit or quota was reached.',
      >= 500 => 'The model service is temporarily unavailable.',
      _ => 'The model service rejected the request.',
    };
