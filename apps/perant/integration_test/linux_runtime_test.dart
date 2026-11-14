// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:perant_platform/perant_platform.dart';

/// Android-only tests of the real APK-packaged Alpine/PRoot and JNI PTY.
/// No model, HTTP client, production database, or credential store is used.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'suite': 'android-linux-runtime',
    'checks': <Map<String, dynamic>>[],
    'isolationClaim': false,
  };
  binding.reportData = report;
  late _LinuxHarness linux;

  setUpAll(() async {
    expect(
      Platform.isAndroid,
      isTrue,
      reason: 'Run on a real Android Flutter engine with the Linux resources.',
    );
    linux = _LinuxHarness(PerantPlatformBridge(), report);
    // Wait for the native EventChannel handshake before starting any guest.
    await linux.attach();
  });

  setUp(() async {
    final status = await linux.bridge.initializeLinux();
    expect(status.supported, isTrue, reason: status.reason);
    expect(status.installed, isTrue, reason: status.reason);
    expect(status.active, isFalse);
    expect(status.distribution, 'Alpine');
    expect(status.version, '3.24.4');
    expect(status.workspace, '/workspace');
    expect(status.pythonAvailable, isTrue, reason: status.reason);
    expect(status.pythonVersion, '3.14.10');
    report['initialized'] = true;
  });

  tearDown(() async {
    await linux.stopOwnedProcesses();
    await linux.cleanOwnedDirectories();
    expect(linux.streamError, isNull);
  });

  tearDownAll(() async {
    await linux.dispose();
  });

  testWidgets('offline Python stdlib writes a Chinese filename', (
    tester,
  ) async {
    final directory = await linux.createDirectory();
    final path = '$directory/会议记录🐜.txt';
    final code =
        'import sys,ssl,sqlite3,json,pathlib; '
        'p=pathlib.Path(${jsonEncode(path)}); '
        'p.write_text("离线 Python：你好 🐜",encoding="utf-8"); '
        'assert p.read_text(encoding="utf-8")=="离线 Python：你好 🐜"; '
        'assert ssl.create_default_context().cert_store_stats()["x509_ca"]>0; '
        'assert sqlite3.connect(":memory:").execute("select 42").fetchone()[0]==42; '
        'print("PYTHON:"+sys.version.split()[0]); print("STDLIB_AND_UTF8_OK")';
    final result = await linux.run('python3 -I -B -c ${_quote(code)}');
    expect(result.exitCode, 0, reason: result.output);
    expect(result.output, contains('PYTHON:3.14.10'));
    expect(result.output, contains('STDLIB_AND_UTF8_OK'));
    linux.record('python-stdlib-and-chinese-files', result, {
      'pythonVersion': '3.14.10',
      'tlsCaStoreLoaded': true,
      'sqliteStdlibPassed': true,
    });
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets(
    'fixed Python text task exchanges actual files without evaluating source',
    (tester) async {
      final directory = await linux.createDirectory();
      final marker = '$directory/SHOULD_NOT_EXIST';
      final text =
          '会议记录：李华负责周五提交 🐜\r\n\r\n'
          '\$(touch $marker)\n<script>alert("原文")</script>\n```\n原始内容';
      final task = await linux.startTextTask('会议原文整理', text);
      await task.waitForExit();
      expect(task.exitCode, 0, reason: task.output);
      final result = await linux.bridge.readLinuxTextTaskResult(task.id);
      expect(result.markdown, contains('会议记录：李华负责周五提交 🐜'));
      expect(result.markdown, contains('&lt;script&gt;'));
      expect(result.markdown, contains(r'\`\`\`'));
      expect(
        result.workspacePath,
        '/workspace/.perant-tasks/${task.id}/output.md',
      );
      final probe = await linux.run(
        'test ! -e ${_quote(marker)} && printf SOURCE_WAS_DATA',
      );
      expect(probe.exitCode, 0);
      expect(probe.output, contains('SOURCE_WAS_DATA'));
      linux.record('python-text-task-file-exchange', task, {
        'sourceWasNotEvaluated': true,
        'artifactBytes': result.sizeBytes,
        'artifactSample': result.markdown.substring(
          0,
          result.markdown.length.clamp(0, 700),
        ),
      });
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'twenty thousand Unicode characters exceed the old shell payload limit',
    (tester) async {
      final text = List.filled(20000, '🐜').join();
      expect(utf8.encode(text).length, greaterThan(65536));
      final task = await linux.startTextTask('两万字输入验收', text);
      await task.waitForExit();
      expect(task.exitCode, 0, reason: task.output);
      final result = await linux.bridge.readLinuxTextTaskResult(task.id);
      expect(result.markdown, contains(text));
      expect(result.sizeBytes, greaterThan(80000));
      linux.record('python-20000-unicode-characters', task, {
        'sourceCodePoints': text.runes.length,
        'sourceUtf8Bytes': utf8.encode(text).length,
        'artifactBytes': result.sizeBytes,
      });
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'real Alpine shell preserves UTF-8, workspace files and exit status',
    (tester) async {
      final directory = await linux.createDirectory();
      final file = '$directory/persisted.txt';
      const text = 'PerAnt 中文记录：你好，世界 🐜🚀';
      final first = await linux.run(
        'cat /etc/alpine-release; pwd; busybox | head -n 1; '
        "printf '%s\\n' ${_quote(text)} > ${_quote(file)}; "
        'cat ${_quote(file)}',
      );
      expect(first.exitCode, 0);
      expect(first.cancelled, isFalse);
      expect(first.timedOut, isFalse);
      expect(first.output, contains('3.24.4'));
      expect(first.output, matches(RegExp(r'(^|[\r\n])/workspace[\r\n]')));
      expect(first.output, contains('BusyBox v'));
      expect(first.output, contains(text));

      // A distinct native process must read the persisted file and retain 7.
      final second = await linux.run('cat ${_quote(file)}; exit 7');
      expect(second.id, isNot(first.id));
      expect(second.exitCode, 7);
      expect(second.output, contains(text));
      expect(second.cancelled, isFalse);
      expect(second.timedOut, isFalse);
      linux.record('alpine-unicode-persistence', second, {
        'alpineRelease': '3.24.4',
        'workspace': '/workspace',
        'firstOutput': first.output.trim(),
      });
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'immediate close follows an unawaited start and leaves runtime reusable',
    (tester) async {
      // Register event ownership before either channel request. Do not await
      // start: close must queue behind it even if spawning has not begun yet.
      final pending = linux.beginSession();
      final closing = linux.bridge.closeLinuxSession(pending.trace.id);
      await Future.wait<void>([
        pending.started.then<void>((trace) {
          expect(trace, same(pending.trace));
        }),
        closing,
      ]);
      await pending.trace.waitForExit();
      expect(pending.trace.cancelled, isTrue);
      expect(pending.trace.timedOut, isFalse);

      final closed = await linux.bridge.getLinuxStatus();
      expect(closed.active, isFalse);
      expect(closed.sessionId, isNull);
      final marker = 'FIFO_RECOVERED_${linux.nonce}';
      final recovered = await linux.run(
        "printf '%s\\n' ${_quote(marker)}; pwd",
      );
      expect(recovered.id, isNot(pending.trace.id));
      expect(recovered.exitCode, 0, reason: recovered.output);
      expect(recovered.output, contains(marker));
      expect(recovered.output, matches(RegExp(r'(^|[\r\n])/workspace[\r\n]')));
      final reusable = await linux.bridge.getLinuxStatus();
      expect(reusable.active, isFalse);
      expect(reusable.sessionId, isNull);
      linux.record('start-close-fifo-and-recovery', pending.trace, {
        'closeSentBeforeStartAcknowledged': true,
        'activeAfterClose': closed.active,
        'sessionIdAfterClose': closed.sessionId,
        'recoveryExitCode': recovered.exitCode,
        'recoveryOutput': recovered.output.trim(),
      });
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'cancel kills delayed children and timeout leaves runtime reusable',
    (tester) async {
      final directory = await linux.createDirectory();
      final marker = '$directory/late-child.txt';
      final ready = 'CANCEL_READY_${linux.nonce}';
      final cancelled = await linux.startCommand(
        "(sleep 3; printf '%s\\n' late-child > ${_quote(marker)}) & "
        "printf '%s\\n' ${_quote(ready)}; wait",
        timeout: const Duration(seconds: 30),
      );
      await cancelled.waitForOutput(ready);
      final cancellation = await linux.bridge.cancelTask(cancelled.id);
      expect(cancellation.taskId, cancelled.id);
      expect(cancellation.status, TaskCancellationStatus.cancelled);
      await cancelled.waitForExit();
      expect(cancelled.cancelled, isTrue);
      expect(cancelled.timedOut, isFalse);

      // Wait beyond the child's scheduled write, then inspect only our marker.
      final childProbe = await linux.run(
        'sleep 4; if test -e ${_quote(marker)}; then '
        "printf '%s\\n' CHILD_SURVIVED; exit 9; else "
        "printf '%s\\n' CHILD_STOPPED; fi",
      );
      expect(childProbe.exitCode, 0, reason: childProbe.output);
      expect(childProbe.output, contains('CHILD_STOPPED'));
      expect((await linux.bridge.getLinuxStatus()).active, isFalse);
      linux.record('cancel-and-child-cleanup', cancelled, {
        'lateChildMarkerPresent': false,
        'probeOutput': childProbe.output.trim(),
      });

      final timedOut = await linux.startCommand(
        "printf '%s\\n' TIMEOUT_STARTED; sleep 30",
        timeout: const Duration(seconds: 3),
      );
      await timedOut.waitForExit();
      expect(timedOut.timedOut, isTrue);
      expect(timedOut.cancelled, isFalse);
      final recovered = await linux.run("printf '%s\\n' AFTER_TIMEOUT");
      expect(recovered.exitCode, 0);
      expect(recovered.output, contains('AFTER_TIMEOUT'));
      expect((await linux.bridge.getLinuxStatus()).active, isFalse);
      linux.record('timeout-and-recovery', timedOut, {
        'recoveryOutput': recovered.output.trim(),
      });
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets('interactive PTY resizes, accepts Ctrl-C and closes its real process', (
    tester,
  ) async {
    final session = await linux.startSession();
    await linux.bridge.writeLinuxSession(
      session.id,
      "stty echo; printf '%s%s\\n' 'ECHO_' ${_quote('READY_${linux.nonce}')}\n",
    );
    await session.waitForOutput('ECHO_READY_${linux.nonce}');

    // Exercise a single large native write while terminal echo is enabled.
    // Each comment is short enough for canonical input; together they exceed
    // the PTY buffers and require the reader to drain echo during the write.
    final comment = '# ${List.filled(125, 'x').join()}\n';
    final paste = StringBuffer();
    for (var line = 0; line < 256; line++) {
      paste.write(comment);
    }
    expect(paste.length, 32768);
    final largeInputMarker = 'LARGE_INPUT_DONE_${linux.nonce}';
    paste.write(
      "printf '%s%s\\n' 'LARGE_INPUT_' ${_quote('DONE_${linux.nonce}')}\n",
    );
    await linux.bridge.writeLinuxSession(session.id, paste.toString());
    await session.waitForOutput(largeInputMarker);
    // The echoed printf source contains separated fragments. Only executing
    // the command produces the complete marker on its own output line.
    expect(
      session.output,
      matches(RegExp('(^|[\\r\\n])${RegExp.escape(largeInputMarker)}[\\r\\n]')),
    );
    final ready = 'TTY_OK_${linux.nonce}';
    await linux.bridge.writeLinuxSession(
      session.id,
      'stty -echo; if test -t 0; then '
      "printf '%s%s\\n' 'TTY_' ${_quote('OK_${linux.nonce}')}; fi\n",
    );
    await session.waitForOutput(ready);
    await linux.bridge.resizeLinuxSession(session.id, 101, 37);
    final sizeOutputStart = session.output.length;
    final sizeMarker = 'PTY_SIZE_${linux.nonce}';
    await linux.bridge.writeLinuxSession(
      session.id,
      "stty size; size=\$(stty size); printf '\\n%s%s:%s\\n' 'PTY_' "
      "${_quote('SIZE_${linux.nonce}')} \"\$size\"; "
      "printf '%s%s\\n' 'SIZE_' ${_quote('DONE_${linux.nonce}')}\n",
    );
    await session.waitForOutput('SIZE_DONE_${linux.nonce}');
    final sizeOutput = session.output.substring(sizeOutputStart);
    // A shell prompt can precede stty's raw line. Add an explicit newline and
    // a computed marker, then assert both observed numbers without relaxing
    // the requested dimensions or accepting echoed command text.
    final dimensions = RegExp(
      '(^|[\\r\\n])${RegExp.escape(sizeMarker)}:([0-9]+) ([0-9]+)[\\r\\n]',
    ).firstMatch(sizeOutput);
    // ignore: avoid_print
    print(
      'LINUX_RUNTIME_CHECKPOINT ${jsonEncode({'check': 'pty-size', 'output': _tail(sizeOutput)})}',
    );
    expect(dimensions, isNotNull, reason: _tail(sizeOutput));
    expect(int.parse(dimensions!.group(2)!), 37, reason: _tail(sizeOutput));
    expect(int.parse(dimensions.group(3)!), 101, reason: _tail(sizeOutput));

    final cwdOutputStart = session.output.length;
    final builtinBegin = 'PWD_BUILTIN_BEGIN_${linux.nonce}';
    final builtinEnd = 'PWD_BUILTIN_END_${linux.nonce}';
    final externalBegin = 'PWD_EXTERNAL_BEGIN_${linux.nonce}';
    final externalEnd = 'PWD_EXTERNAL_END_${linux.nonce}';
    await linux.bridge.writeLinuxSession(
      session.id,
      "printf '\\n%s%s\\n' 'PWD_BUILTIN_' ${_quote('BEGIN_${linux.nonce}')}; "
      "pwd -P; printf '%s%s:%s\\n' 'PWD_BUILTIN_' "
      "${_quote('END_${linux.nonce}')} \"\$?\"; "
      "printf '%s%s\\n' 'PWD_EXTERNAL_' ${_quote('BEGIN_${linux.nonce}')}; "
      "/bin/pwd; printf '%s%s:%s\\n' 'PWD_EXTERNAL_' "
      "${_quote('END_${linux.nonce}')} \"\$?\"; "
      "printf '%s%s\\n' 'PWD_CHECK_' ${_quote('DONE_${linux.nonce}')}\n",
    );
    await session.waitForOutput('PWD_CHECK_DONE_${linux.nonce}');
    final cwdOutput = session.output.substring(cwdOutputStart);
    for (final markers in [
      (builtinBegin, builtinEnd),
      (externalBegin, externalEnd),
    ]) {
      expect(
        cwdOutput,
        matches(
          RegExp(
            '(^|[\\r\\n])${RegExp.escape(markers.$1)}[\\r\\n]+'
            '/workspace[\\r\\n]+${RegExp.escape(markers.$2)}:0[\\r\\n]',
          ),
        ),
        reason: _tail(cwdOutput),
      );
    }
    final active = await linux.bridge.getLinuxStatus();
    expect(active.active, isTrue);
    expect(active.sessionId, session.id);

    await linux.bridge.writeLinuxSession(
      session.id,
      "printf '%s%s\\n' 'SLEEP_' ${_quote('READY_${linux.nonce}')}; "
      "sleep 30 && printf '%s%s\\n' 'SLEEP_' ${_quote('FINISHED_${linux.nonce}')}\n",
    );
    await session.waitForOutput('SLEEP_READY_${linux.nonce}');
    // Let the shell enter the foreground sleep before sending the PTY VINTR.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await linux.bridge.writeLinuxSession(session.id, '\x03');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await linux.bridge.writeLinuxSession(
      session.id,
      "printf '%s%s\\n' 'AFTER_' ${_quote('INTERRUPT_${linux.nonce}')}\n",
    );
    await session.waitForOutput('AFTER_INTERRUPT_${linux.nonce}');
    expect(session.output, isNot(contains('SLEEP_FINISHED_${linux.nonce}')));
    expect(session.exitCode, isNull);

    await linux.bridge.closeLinuxSession(session.id);
    await session.waitForExit();
    expect(session.cancelled, isTrue);
    expect(session.timedOut, isFalse);
    final closed = await linux.bridge.getLinuxStatus();
    expect(closed.active, isFalse);
    expect(closed.sessionId, isNull);
    expect(
      session.output,
      isNot(contains('getcwd: Function not implemented')),
      reason: _tail(session.output),
    );
    linux.record('interactive-pty-and-ctrl-c', session, {
      'rows': 37,
      'columns': 101,
      'stdinIsTty': true,
      'echoedPasteBytes': 32768,
      'largeInputCompletionObserved': true,
      'builtinPhysicalWorkingDirectory': '/workspace',
      'externalWorkingDirectory': '/workspace',
      'activeAfterClose': closed.active,
    });
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets(
    'controlled host-file probe records facts without asserting isolation',
    (tester) async {
      final directory = await getApplicationSupportDirectory();
      final marker = File(
        '${directory.path}/.perant-smoke-boundary-${linux.nonce}.txt',
      );
      final value = 'public-linux-boundary-probe-${linux.nonce}';
      expect(await marker.exists(), isFalse);
      await marker.writeAsString(value, flush: true);
      try {
        // This is our own harmless marker, never a key or user database.
        final guestPath = '/proc/$pid/root${marker.path}';
        final probe = await linux.run(
          'if test -r ${_quote(guestPath)} && '
          'test "\$(cat ${_quote(guestPath)})" = ${_quote(value)}; then '
          "printf '%s\\n' HOST_MARKER_READABLE; else "
          "printf '%s\\n' HOST_MARKER_UNREADABLE; fi",
        );
        expect(probe.exitCode, 0);
        final readable = probe.output.contains('HOST_MARKER_READABLE');
        expect(
          readable || probe.output.contains('HOST_MARKER_UNREADABLE'),
          isTrue,
          reason: 'The native probe must report an observed result.',
        );
        linux.record('controlled-host-file-boundary', probe, {
          'hostMarkerReadable': readable,
          'strongIsolationProven': false,
        });
      } finally {
        if (await marker.exists()) await marker.delete();
      }
      expect(await marker.exists(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

String _quote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

String _tail(String value) =>
    value.length > 1500 ? value.substring(value.length - 1500) : value;

final class _LinuxHarness {
  _LinuxHarness(this.bridge, this.report);

  final PerantPlatformBridge bridge;
  final Map<String, dynamic> report;
  final String nonce = DateTime.now().microsecondsSinceEpoch.toString();
  final _attached = Completer<void>();
  final _traces = <String, _ProcessTrace>{};
  final _directories = <String>{};
  final _textTaskDirectories = <String>{};
  StreamSubscription<RuntimeEvent>? _subscription;
  Object? streamError;
  int _sequence = 0;

  Future<void> attach() async {
    _subscription = bridge.events.listen(
      (event) {
        if (event.type == 'bridgeAttached' && !_attached.isCompleted) {
          _attached.complete();
        }
        if (event.type != 'linuxOutput' && event.type != 'linuxExit') return;
        final owner = event.taskId ?? event.payload['sessionId'];
        // Never retain output from a task/session not created by this test.
        final trace = _traces[owner];
        if (trace != null) trace.accept(event);
      },
      onError: (Object error, StackTrace stack) {
        streamError = error;
      },
    );
    await _attached.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw StateError(
        'Native event subscription did not attach: $streamError',
      ),
    );
  }

  _ProcessTrace _trace(bool interactive) {
    final id = 'perant-linux-smoke-$nonce-${_sequence++}';
    final trace = _ProcessTrace(id, interactive);
    _traces[id] = trace;
    return trace;
  }

  Future<_ProcessTrace> startCommand(
    String command, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final trace = _trace(false);
    final handle = await bridge.runLinuxCommand(
      taskId: trace.id,
      command: command,
      timeout: timeout,
    );
    expect(handle.taskId, trace.id);
    expect(handle.pid, greaterThan(0));
    return trace;
  }

  Future<_ProcessTrace> run(String command) async {
    final trace = await startCommand(command);
    await trace.waitForExit();
    return trace;
  }

  Future<_ProcessTrace> startTextTask(String title, String text) async {
    final trace = _trace(false);
    _textTaskDirectories.add(trace.id);
    final handle = await bridge.startLinuxTextTask(
      taskId: trace.id,
      title: title,
      text: text,
    );
    expect(handle.taskId, trace.id);
    expect(handle.pid, greaterThan(0));
    return trace;
  }

  ({_ProcessTrace trace, Future<_ProcessTrace> started}) beginSession() {
    final trace = _trace(true);
    return (trace: trace, started: _startSession(trace));
  }

  Future<_ProcessTrace> startSession() => beginSession().started;

  Future<_ProcessTrace> _startSession(_ProcessTrace trace) async {
    final session = await bridge.startLinuxSession(
      sessionId: trace.id,
      columns: 80,
      rows: 24,
    );
    expect(session.sessionId, trace.id);
    expect(session.pid, greaterThan(0));
    expect(session.workspace, '/workspace');
    return trace;
  }

  Future<String> createDirectory() async {
    final path = '/workspace/.perant-smoke-$nonce-${_sequence++}';
    _directories.add(path);
    final created = await run('mkdir -- ${_quote(path)}');
    expect(created.exitCode, 0, reason: created.output);
    return path;
  }

  Future<void> stopOwnedProcesses() async {
    for (final trace in _traces.values.toList().reversed) {
      if (trace.exitCode != null) continue;
      if (trace.interactive) {
        await bridge.closeLinuxSession(trace.id);
      } else {
        await bridge.cancelTask(trace.id);
      }
    }
  }

  Future<void> cleanOwnedDirectories() async {
    for (final id in _textTaskDirectories.toList()) {
      if (!RegExp('^perant-linux-smoke-$nonce-[0-9]+\$').hasMatch(id)) {
        throw StateError('Refusing cleanup of an unowned task.');
      }
      final removed = await run(
        'rm -rf -- ${_quote('/workspace/.perant-tasks/$id')}',
      );
      expect(removed.exitCode, 0, reason: removed.output);
      _textTaskDirectories.remove(id);
    }
    for (final path in _directories.toList()) {
      if (!RegExp('^/workspace/\\.perant-smoke-$nonce-[0-9]+\$')
          .hasMatch(path)) {
        throw StateError('Refusing cleanup of an unowned path.');
      }
      final removed = await run('rm -rf -- ${_quote(path)}');
      expect(removed.exitCode, 0, reason: removed.output);
      _directories.remove(path);
    }
  }

  void record(String check, _ProcessTrace trace, Map<String, dynamic> detail) {
    final result = <String, dynamic>{
      'check': check,
      'ownerId': trace.id,
      'eventOwnerMatched': trace.exitOwnerMatched,
      'exitCode': trace.exitCode,
      'cancelled': trace.cancelled,
      'timedOut': trace.timedOut,
      'output': trace.output.trim(),
      ...detail,
    };
    (report['checks'] as List<Map<String, dynamic>>).add(result);
    // Only output from explicit test commands and harmless generated markers.
    // ignore: avoid_print
    print('LINUX_RUNTIME_RESULT ${jsonEncode(result)}');
  }

  Future<void> dispose() async {
    await stopOwnedProcesses();
    await _subscription?.cancel();
  }
}

final class _ProcessTrace {
  _ProcessTrace(this.id, this.interactive);

  final String id;
  final bool interactive;
  final _output = StringBuffer();
  final _exited = Completer<void>();
  Object? error;
  int? exitCode;
  bool? cancelled;
  bool? timedOut;
  bool exitOwnerMatched = false;

  String get output => _output.toString();

  void accept(RuntimeEvent event) {
    final matches = interactive
        ? event.taskId == null && event.payload['sessionId'] == id
        : event.taskId == id && event.payload['sessionId'] == null;
    if (!matches) {
      error = StateError('Native Linux event owner mismatch for $id.');
      return;
    }
    if (event.type == 'linuxOutput') {
      _output.write(event.payload['text'] as String);
    } else if (event.type == 'linuxExit') {
      if (_exited.isCompleted) {
        error = StateError('Duplicate native Linux exit event for $id.');
        return;
      }
      exitCode = event.payload['exitCode'] as int;
      cancelled = event.payload['cancelled'] as bool;
      timedOut = event.payload['timedOut'] as bool;
      exitOwnerMatched = true;
      _exited.complete();
    }
  }

  Future<void> waitForOutput(String text) async {
    final timer = Stopwatch()..start();
    while (!output.contains(text)) {
      if (error != null) throw error!;
      if (exitCode != null || timer.elapsed > const Duration(seconds: 15)) {
        throw StateError('No expected output for $id: $text\n$output');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (error != null) throw error!;
  }

  Future<void> waitForExit() async {
    await _exited.future.timeout(
      const Duration(seconds: 25),
      onTimeout: () => throw StateError('No native exit for $id.\n$output'),
    );
    if (error != null) throw error!;
    expect(exitOwnerMatched, isTrue);
  }
}
