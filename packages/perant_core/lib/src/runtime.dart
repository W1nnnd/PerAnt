// SPDX-License-Identifier: GPL-3.0-only

import 'models.dart';

enum RuntimeAvailability {
  unavailable,
  notInstalled,
  initializing,
  ready,
  busy,
  error;

  String get label => switch (this) {
        unavailable => '尚未接入',
        notInstalled => '尚未安装',
        initializing => '初始化中',
        ready => '就绪',
        busy => '运行中',
        error => '不可用',
      };
}

final class RuntimeCapability {
  const RuntimeCapability({
    required this.id,
    required this.displayName,
    required this.availability,
    required this.detail,
  });

  final String id;
  final String displayName;
  final RuntimeAvailability availability;
  final String detail;

  bool get isAvailable =>
      availability == RuntimeAvailability.ready ||
      availability == RuntimeAvailability.busy;
}

final class RuntimeUnavailableException implements Exception {
  const RuntimeUnavailableException(this.capability, this.reason);

  final String capability;
  final String reason;

  @override
  String toString() => '$capability unavailable: $reason';
}

final class CommandRequest {
  CommandRequest({
    required this.executionId,
    required this.taskId,
    required this.workspaceId,
    required this.executable,
    List<String> arguments = const [],
    this.timeout = const Duration(seconds: 60),
  }) : arguments = List.unmodifiable(arguments) {
    if (timeout <= Duration.zero) {
      throw ArgumentError('Command timeout must be positive.');
    }
  }

  final String executionId;
  final String taskId;
  final String workspaceId;
  final String executable;
  final List<String> arguments;
  final Duration timeout;
}

enum CommandEventType { standardOutput, standardError, exited }

final class CommandEvent {
  const CommandEvent.output(this.text, {bool isError = false})
      : type = isError
            ? CommandEventType.standardError
            : CommandEventType.standardOutput,
        exitCode = null;

  const CommandEvent.exited(this.exitCode)
      : type = CommandEventType.exited,
        text = null;

  final CommandEventType type;
  final String? text;
  final int? exitCode;
}

abstract interface class TerminalSession {
  String get id;
  Stream<CommandEvent> get events;
  Future<void> write(String input);
  Future<void> resize({required int columns, required int rows});
  Future<void> close();
}

abstract interface class LinuxRuntime {
  Future<RuntimeCapability> inspect();
  Future<void> start();
  Stream<CommandEvent> execute(CommandRequest request);
  Future<void> cancel(String executionId);
  Future<TerminalSession> openTerminal(String workspaceId);
  Future<void> stop();
}

final class LocalModelConfiguration {
  const LocalModelConfiguration({
    required this.modelId,
    required this.modelFile,
    this.contextTokens = 2048,
    this.threads = 2,
  })  : assert(contextTokens > 0),
        assert(threads > 0);

  final String modelId;
  final Uri modelFile;
  final int contextTokens;
  final int threads;
}

abstract interface class LocalInference {
  Future<RuntimeCapability> inspect();
  Future<void> load(LocalModelConfiguration configuration);
  Stream<ModelEvent> generate(ModelRequest request);
  Future<void> cancel(String requestId);
  Future<void> unload();
}

/// Explicitly unsupported until a native runtime has actually been linked.
final class UnavailableLinuxRuntime implements LinuxRuntime {
  const UnavailableLinuxRuntime({
    this.reason = 'PRoot / iSH 原生运行时尚未集成。',
  });

  final String reason;

  RuntimeUnavailableException get _error =>
      RuntimeUnavailableException('Linux', reason);

  @override
  Future<RuntimeCapability> inspect() async => RuntimeCapability(
        id: 'linux',
        displayName: 'Linux 工作区',
        availability: RuntimeAvailability.unavailable,
        detail: reason,
      );

  @override
  Future<void> start() async => throw _error;

  @override
  Stream<CommandEvent> execute(CommandRequest request) => Stream.error(_error);

  @override
  Future<void> cancel(String executionId) async => throw _error;

  @override
  Future<TerminalSession> openTerminal(String workspaceId) async =>
      throw _error;

  @override
  Future<void> stop() async {}
}

/// This adapter never fabricates a local model response or a loaded state.
final class UnavailableLocalInference implements LocalInference {
  const UnavailableLocalInference({
    this.reason = 'llama.cpp 与本地模型资源尚未集成。',
  });

  final String reason;

  RuntimeUnavailableException get _error =>
      RuntimeUnavailableException('Local inference', reason);

  @override
  Future<RuntimeCapability> inspect() async => RuntimeCapability(
        id: 'local-inference',
        displayName: '本地主模型',
        availability: RuntimeAvailability.unavailable,
        detail: reason,
      );

  @override
  Future<void> load(LocalModelConfiguration configuration) async =>
      throw _error;

  @override
  Stream<ModelEvent> generate(ModelRequest request) => Stream.error(_error);

  @override
  Future<void> cancel(String requestId) async => throw _error;

  @override
  Future<void> unload() async {}
}

/// Credentials stay outside serializable domain models and guest filesystems.
abstract interface class CredentialStore {
  Future<String?> read(String reference);
  Future<void> write(String reference, String secret);
  Future<void> delete(String reference);
}

abstract interface class PlatformServices {
  Future<RuntimeCapability> backgroundCapability();
  Future<Uri?> importFile();
  Future<void> exportFile(Uri workspaceFile);
  Future<void> cancelBackgroundTask(String taskId);
}
