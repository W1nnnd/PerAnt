// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';

/// Whether an execution capability is actually connected in this build.
final class CapabilityAvailability {
  const CapabilityAvailability({required this.available, required this.reason});

  final bool available;
  final String reason;

  factory CapabilityAvailability.fromMap(Map<Object?, Object?> map) {
    return CapabilityAvailability(
      available: _readBool(map, 'available'),
      reason: _readString(map, 'reason'),
    );
  }
}

/// Runtime information reported by the host, rather than inferred by the UI.
final class PlatformCapabilities {
  const PlatformCapabilities({
    required this.platform,
    required this.systemVersion,
    required this.nativeBridgeAvailable,
    required this.linux,
    required this.localInference,
    required this.backgroundTasks,
    this.schemaVersion = 1,
  });

  final int schemaVersion;
  final String platform;
  final String systemVersion;
  final bool nativeBridgeAvailable;
  final CapabilityAvailability linux;
  final CapabilityAvailability localInference;
  final CapabilityAvailability backgroundTasks;

  factory PlatformCapabilities.fromMap(Map<Object?, Object?> map) {
    if (map['schemaVersion'] != 1) {
      throw const FormatException('Unsupported runtime channel schema.');
    }
    return PlatformCapabilities(
      platform: _readString(map, 'platform'),
      systemVersion: _readString(map, 'systemVersion'),
      nativeBridgeAvailable: _readBool(map, 'nativeBridgeAvailable'),
      linux: CapabilityAvailability.fromMap(_readMap(map, 'linux')),
      localInference: CapabilityAvailability.fromMap(
        _readMap(map, 'localInference'),
      ),
      backgroundTasks: CapabilityAvailability.fromMap(
        _readMap(map, 'backgroundTasks'),
      ),
    );
  }

  factory PlatformCapabilities.unsupported({
    required String platform,
    required String reason,
  }) {
    final unavailable = CapabilityAvailability(
      available: false,
      reason: reason,
    );
    return PlatformCapabilities(
      platform: platform,
      systemVersion: '未连接原生平台',
      nativeBridgeAvailable: false,
      linux: unavailable,
      localInference: unavailable,
      backgroundTasks: unavailable,
    );
  }
}

/// The installed distribution and process state reported by the native host.
///
/// An unavailable host never becomes supported merely because these types exist.
final class LinuxStatus {
  const LinuxStatus({
    required this.supported,
    required this.installed,
    bool? workspaceAvailable,
    required this.active,
    required this.distribution,
    required this.version,
    required this.workspace,
    required this.reason,
    this.sessionId,
    this.pythonAvailable = false,
    this.pythonVersion,
    this.desktopAvailable = false,
    this.desktopVersion,
    this.desktopSessionId,
  }) : workspaceAvailable = workspaceAvailable ?? installed;

  final bool supported;
  final bool installed;
  final bool workspaceAvailable;
  final bool active;
  final String? sessionId;
  final String distribution;
  final String version;
  final String workspace;
  final String reason;
  final bool pythonAvailable;
  final String? pythonVersion;
  final bool desktopAvailable;
  final String? desktopVersion;
  final String? desktopSessionId;

  factory LinuxStatus.fromMap(Map<Object?, Object?> map) {
    final supported = _readBool(map, 'supported');
    final installed = _readBool(map, 'installed');
    final active = _readBool(map, 'active');
    final sessionId = _readOptionalId(map, 'sessionId');
    // Older hosts have no Python fields; absence must never invent support.
    final pythonAvailable = map['pythonAvailable'] == null
        ? false
        : _readBool(map, 'pythonAvailable');
    final pythonVersion =
        map['pythonVersion'] == null ? null : _readString(map, 'pythonVersion');
    final desktopAvailable = map['desktopAvailable'] == null
        ? false
        : _readBool(map, 'desktopAvailable');
    final desktopVersion = map['desktopVersion'] == null
        ? null
        : _readString(map, 'desktopVersion');
    final desktopSessionId = _readOptionalId(map, 'desktopSessionId');
    if ((!supported &&
            (installed ||
                active ||
                sessionId != null ||
                desktopSessionId != null)) ||
        (active && !installed) ||
        (desktopAvailable &&
            (!supported || !installed || desktopVersion == null)) ||
        (desktopSessionId != null &&
            (!active || !desktopAvailable || sessionId != null)) ||
        (pythonAvailable &&
            (!supported ||
                !installed ||
                pythonVersion == null ||
                pythonVersion.trim().isEmpty))) {
      throw const FormatException('Inconsistent native Linux status.');
    }
    return LinuxStatus(
      supported: supported,
      installed: installed,
      workspaceAvailable: map.containsKey('workspaceAvailable')
          ? _readBool(map, 'workspaceAvailable')
          : installed,
      active: active,
      sessionId: sessionId,
      distribution: _readString(map, 'distribution'),
      version: _readString(map, 'version'),
      workspace: _readWorkspace(map),
      reason: _readText(map, 'reason'),
      pythonAvailable: pythonAvailable,
      pythonVersion: pythonVersion,
      desktopAvailable: desktopAvailable,
      desktopVersion: desktopVersion,
      desktopSessionId: desktopSessionId,
    );
  }

  factory LinuxStatus.unsupported({required String reason}) => LinuxStatus(
        supported: false,
        installed: false,
        active: false,
        distribution: 'Alpine',
        version: 'unavailable',
        workspace: '/workspace',
        reason: reason,
      );
}

/// A real Xvnc endpoint in the application's private filesystem. No TCP
/// listener, password or credentials are exposed by this contract.
final class LinuxDesktopSession {
  const LinuxDesktopSession({
    required this.sessionId,
    required this.pid,
    required this.socketPath,
    required this.width,
    required this.height,
    required this.display,
    this.workspace = '/workspace',
  });
  final String sessionId;
  final int pid;
  final String socketPath;
  final int width;
  final int height;
  final int display;
  final String workspace;

  factory LinuxDesktopSession.fromMap(Map<Object?, Object?> map) {
    final id = _readString(map, 'sessionId');
    final pid = map['pid'];
    final socket = _readString(map, 'socketPath');
    final width = map['width'];
    final height = map['height'];
    final display = map['display'];
    if (id.trim().isEmpty ||
        id.length > 128 ||
        pid is! int ||
        pid <= 0 ||
        !socket.startsWith('/') ||
        !socket.endsWith('/rfb.sock') ||
        utf8.encode(socket).length >= 104 ||
        socket.split('/').contains('..') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(socket) ||
        width is! int ||
        height is! int ||
        width < 640 ||
        width > 1600 ||
        height < 480 ||
        height > 1200 ||
        width * height > 1920000 ||
        display is! int ||
        display < 0 ||
        display > 65535) {
      throw const FormatException('Invalid native desktop session.');
    }
    return LinuxDesktopSession(
        sessionId: id,
        pid: pid,
        socketPath: socket,
        width: width,
        height: height,
        display: display,
        workspace: _readWorkspace(map));
  }
}

/// A process acknowledged by the host, rather than a locally invented session.
final class LinuxSession {
  const LinuxSession({
    required this.sessionId,
    required this.pid,
    required this.workspace,
  });

  final String sessionId;
  final int pid;
  final String workspace;

  factory LinuxSession.fromMap(Map<Object?, Object?> map) => LinuxSession(
        sessionId: _readId(map, 'sessionId'),
        pid: _readPid(map),
        workspace: _readWorkspace(map),
      );
}

/// A started command. Completion is reported separately through native events.
final class LinuxCommandHandle {
  const LinuxCommandHandle({required this.taskId, required this.pid});

  final String taskId;
  final int pid;

  factory LinuxCommandHandle.fromMap(Map<Object?, Object?> map) =>
      LinuxCommandHandle(
        taskId: _readId(map, 'taskId'),
        pid: _readPid(map),
      );
}

/// An actual Markdown file read back from a completed, controlled native task.
/// PTY output is deliberately not used as the document transport.
final class LinuxTextTaskResult {
  const LinuxTextTaskResult({
    required this.taskId,
    required this.markdown,
    required this.workspacePath,
    required this.sizeBytes,
  });

  final String taskId;
  final String markdown;
  final String workspacePath;
  final int sizeBytes;

  factory LinuxTextTaskResult.fromMap(Map<Object?, Object?> map) {
    final taskId = _readId(map, 'taskId');
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$').hasMatch(taskId)) {
      throw const FormatException('Invalid native text task ID.');
    }
    final markdown = _readString(map, 'markdown');
    final bytes = utf8.encode(markdown);
    final sizeBytes = map['sizeBytes'];
    if (markdown.trim().isEmpty ||
        utf8.decode(bytes) != markdown ||
        sizeBytes is! int ||
        sizeBytes <= 0 ||
        sizeBytes > 262144 ||
        bytes.length != sizeBytes) {
      throw const FormatException('Invalid native Markdown file content.');
    }
    final workspacePath = _readString(map, 'workspacePath');
    if (workspacePath != '/workspace/.perant-tasks/$taskId/output.md') {
      throw const FormatException('Unexpected native Markdown file path.');
    }
    return LinuxTextTaskResult(
      taskId: taskId,
      markdown: markdown,
      workspacePath: workspacePath,
      sizeBytes: sizeBytes,
    );
  }
}

enum TaskCancellationStatus { cancelled, notRunning, unavailable }

/// A cancellation request is not evidence that a task has run or completed.
final class TaskCancellation {
  const TaskCancellation({
    required this.taskId,
    required this.status,
    required this.reason,
  });

  final String taskId;
  final TaskCancellationStatus status;
  final String reason;

  factory TaskCancellation.fromMap(Map<Object?, Object?> map) {
    final statusName = _readString(map, 'status');
    final status = switch (statusName) {
      'cancelled' => TaskCancellationStatus.cancelled,
      'notRunning' => TaskCancellationStatus.notRunning,
      'unavailable' => TaskCancellationStatus.unavailable,
      _ => throw const FormatException('Unknown task cancellation status.'),
    };
    return TaskCancellation(
      taskId: _readString(map, 'taskId'),
      status: status,
      reason: _readString(map, 'reason'),
    );
  }
}

/// Native events use a string type so new events can reach older Dart clients.
final class RuntimeEvent {
  RuntimeEvent({
    required this.type,
    required this.emittedAt,
    required Map<Object?, Object?> payload,
    this.taskId,
  }) : payload = Map<Object?, Object?>.unmodifiable(payload);

  final String type;
  final DateTime emittedAt;
  final String? taskId;
  final Map<Object?, Object?> payload;

  factory RuntimeEvent.fromMap(Map<Object?, Object?> map) {
    final timestamp = map['emittedAtEpochMs'];
    if (timestamp is! int || timestamp < 0) {
      throw const FormatException('Invalid native event timestamp.');
    }
    final taskId = _readOptionalId(map, 'taskId');
    final type = _readString(map, 'type');
    final payload = _readMap(map, 'payload');
    if (type == 'linuxOutput' || type == 'linuxExit') {
      final sessionId = _readOptionalId(payload, 'sessionId');
      if (sessionId == null && taskId == null) {
        throw const FormatException('Linux events require a process owner ID.');
      }
      if (type == 'linuxOutput') {
        _readText(payload, 'text');
      } else {
        if (payload['exitCode'] is! int) {
          throw const FormatException('Expected an integer Linux exit code.');
        }
        _readBool(payload, 'cancelled');
        _readBool(payload, 'timedOut');
      }
    }
    return RuntimeEvent(
      type: type,
      emittedAt: DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true),
      taskId: taskId,
      payload: payload,
    );
  }
}

final class RuntimeBridgeException implements Exception {
  const RuntimeBridgeException({required this.code, required this.message});

  final String code;
  final String message;

  @override
  String toString() => 'RuntimeBridgeException($code): $message';
}

String _readString(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Expected a non-empty string for $key.');
  }
  return value;
}

String _readText(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is! String) throw FormatException('Expected a string for $key.');
  return value;
}

String _readId(Map<Object?, Object?> map, String key) {
  final value = _readString(map, key);
  if (value.trim().isEmpty || value.length > 128) {
    throw FormatException('Invalid process ID for $key.');
  }
  return value;
}

String? _readOptionalId(Map<Object?, Object?> map, String key) =>
    map[key] == null ? null : _readId(map, key);

int _readPid(Map<Object?, Object?> map) {
  final value = map['pid'];
  if (value is! int || value <= 0) {
    throw const FormatException('Expected a positive native process ID.');
  }
  return value;
}

String _readWorkspace(Map<Object?, Object?> map) {
  if (map['workspace'] != '/workspace') {
    throw const FormatException('Unexpected Linux workspace path.');
  }
  return '/workspace';
}

bool _readBool(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is! bool) throw FormatException('Expected a boolean for $key.');
  return value;
}

Map<Object?, Object?> _readMap(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is! Map) throw FormatException('Expected a map for $key.');
  return Map<Object?, Object?>.from(value);
}
