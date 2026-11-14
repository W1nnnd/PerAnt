// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:perant_platform/perant_platform.dart';

/// Android-only office acceptance. Outputs must be saved by Writer through
/// real RFB input in a test-owned profile.
/// Python only creates known input templates and inspects completed ZIP/XML.
/// It never creates or converts the GUI output files.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'suite': 'android-linux-office',
    'transport': 'app-private-unix-rfb',
    'externalModelRequests': 0,
    'realProviderVerified': false,
    'physicalLowMemoryDeviceVerified': false,
    'checks': <Map<String, dynamic>>[],
  };
  binding.reportData = report;
  late _OfficeLinux linux;

  setUpAll(() async {
    expect(Platform.isAndroid, isTrue);
    linux = _OfficeLinux(
      PerantPlatformBridge(initializationTimeout: const Duration(minutes: 5)),
    );
    await linux.attach();
    expect(
      await linux.bridge.getLinuxDesktopSession(),
      isNull,
      reason: 'Close a personal desktop before running this isolated suite.',
    );
    final status = await linux.bridge.initializeLinux();
    expect(status.supported && status.installed, isTrue, reason: status.reason);
    expect(status.desktopAvailable, isTrue, reason: status.reason);
    expect(status.pythonAvailable, isTrue, reason: status.reason);
  });

  setUp(() async {
    expect(await linux.bridge.getLinuxDesktopSession(), isNull);
  });
  tearDown(() async {
    await linux.cleanup();
    expect(linux.streamError, isNull);
  });
  tearDownAll(() => linux.dispose());

  for (final format in ['odt', 'docx']) {
    testWidgets(
      'Writer creates edits saves and reopens a real $format document',
      (tester) async {
        final directory = await linux.createDirectory();
        final template = '$directory/template.$format';
        final output = '$directory/gui-created.$format';
        final profile = '$directory/office-profile';
        final ready = '$directory/writer-visible.json';
        await linux.bridge.createLinuxDirectory(profile);
        final seed = 'TEMPLATE_' + linux.nonce;
        final draft = 'GUI_CREATED_' + format.toUpperCase() + '_' + linux.nonce;
        final revision = 'GUI_REOPENED_AND_EDITED_' + linux.nonce;
        await linux.runPython(_createTemplate, [template, format, seed]);
        final originalTemplate = await linux.inspectDocument(template, format);
        expect(originalTemplate['text'], contains(seed));
        var session = await linux.start();
        DesktopRfbClient? viewer;
        String? createdArtifact;
        String? reopenedArtifact;
        try {
          viewer = await DesktopRfbClient.connectUnix(
            session.socketPath,
            continuous: false,
          );
          await _openWriterFile(viewer, template, profile, ready, linux);
          await _shortcut(viewer, 0x61, [0xffe3]); // Ctrl+a.
          // Writer dispatches accelerator commands asynchronously. Observe the
          // settled real selection before sending the next batch of key events.
          await _settledFrame(viewer, await viewer.capture());
          await viewer.text(draft + '\n');
          final edited = await _settledFrame(viewer, await viewer.capture());
          createdArtifact = await _saveFrame(
            'WRITER_' + format.toUpperCase() + '_CREATED',
            edited,
            linux,
          );
          final firstFormatConfirmed = await _saveAs(
            viewer,
            output,
            format,
            linux,
          );
          await _shortcut(viewer, 0xffc1, [0xffe9]); // Alt+F4.
          await _settledFrame(viewer, await viewer.capture());
          await viewer.close();
          viewer = null;
          await linux.stop(session.sessionId);

          final firstWindow = await linux.inspectReady(ready);
          expect(firstWindow['mappedLibreOfficeWindow'], isTrue);

          final firstSaved = await linux.inspectDocument(output, format);
          expect(firstSaved['text'], contains(draft));
          expect(firstSaved['text'], isNot(contains(seed)));
          expect(firstSaved['text'], isNot(contains(revision)));
          expect(firstSaved['sizeBytes'], greaterThan(0));
          expect(
            (await linux.inspectDocument(template, format))['sha256'],
            originalTemplate['sha256'],
            reason:
                'Save As must create a new file, not overwrite the fixture.',
          );

          final firstSession = session.sessionId;
          session = await linux.start();
          expect(session.sessionId, isNot(firstSession));
          viewer = await DesktopRfbClient.connectUnix(
            session.socketPath,
            continuous: false,
          );
          await _openWriterFile(viewer, output, profile, ready, linux);
          await _shortcut(viewer, 0xff57, [0xffe3]); // Ctrl+End.
          await _settledFrame(viewer, await viewer.capture());
          await viewer.text('\n' + revision + '\n');
          await _shortcut(viewer, 0x73, [0xffe3]); // Ctrl+s.
          final reopenedFormatConfirmed = await _confirmFormat(
            viewer,
            format,
            linux,
          );
          final reopened = await _settledFrame(viewer, await viewer.capture());
          reopenedArtifact = await _saveFrame(
            'WRITER_' + format.toUpperCase() + '_REOPENED',
            reopened,
            linux,
          );
          await _shortcut(viewer, 0xffc1, [0xffe9]);
          await _settledFrame(viewer, await viewer.capture());
          await viewer.close();
          viewer = null;
          await linux.stop(session.sessionId);
          final reopenedWindow = await linux.inspectReady(ready);
          expect(reopenedWindow['openedPath'], output);
          expect(reopenedWindow['mappedLibreOfficeWindow'], isTrue);
          final savedAgain = await linux.inspectDocument(output, format);
          expect(savedAgain['text'], contains(draft));
          expect(savedAgain['text'], contains(revision));
          expect(savedAgain['text'], isNot(contains(seed)));
          expect(savedAgain['sha256'], isNot(firstSaved['sha256']));
          _record(report, 'writer-gui-' + format + '-roundtrip', {
            'application': 'LibreOffice Writer',
            'format': format,
            'inputTemplateIsTestOwned': true,
            'outputCreatedFromTemplateThroughGuiSaveAs': true,
            'templateUnchanged': true,
            'outputPath': output,
            'inputTransport': 'RFB KeyEvent',
            'officeProfileIsTestOwned': true,
            'officeFileLockingEnabled': true,
            'mappedLibreOfficeWindowObservedByXdotool': true,
            'firstWindowTitle': firstWindow['windowTitle'],
            'reopenedWindowTitle': reopenedWindow['windowTitle'],
            'firstLaunchNormalRestartCodes': firstWindow['normalRestartCodes'],
            'reopenedLaunchNormalRestartCodes':
                reopenedWindow['normalRestartCodes'],
            'launchInput': 'RFB Terminal / verified office binary',
            'guiSaveAs': true,
            'desktopRestartedBeforeReopen': true,
            'guiReopenAppendAndSave': true,
            'containerAndXmlVerifiedAfterDesktopStopped': true,
            'firstSavedSha256': firstSaved['sha256'],
            'revisedSha256': savedAgain['sha256'],
            'revisedSizeBytes': savedAgain['sizeBytes'],
            'originalTextPreservedAfterReopen': true,
            'revisionFoundInSavedXml': true,
            'firstForeignFormatWarningClicked': firstFormatConfirmed,
            'reopenedForeignFormatWarningClicked': reopenedFormatConfirmed,
            'foreignFormatConfirmationInput': format == 'docx'
                ? 'RFB pointer on visually inspected Use Word 2007 Format button'
                : null,
            'createdScreenshotAppPath': createdArtifact,
            'reopenedScreenshotAppPath': reopenedArtifact,
            'headlessConversionUsedForOutput': false,
          });
        } catch (_) {
          await _failure(
            viewer,
            linux,
            session.sessionId,
            'WRITER_' + format.toUpperCase(),
          );
          await viewer?.close();
          viewer = null;
          await linux.stop(session.sessionId);
          try {
            final diagnostic = await linux.runPython(_inspectLaunchFailure, [
              ready,
            ]);
            // Only this fixture's marker and process log, after the desktop
            // stops; never bypass the workspace's active-session exclusion.
            // ignore: avoid_print
            print('DESKTOP_OFFICE_LAUNCH_DIAGNOSTIC ' + diagnostic.trim());
          } catch (diagnosticError) {
            // Keep the original GUI failure as the test's failure.
            // ignore: avoid_print
            print(
              'DESKTOP_OFFICE_DIAGNOSTIC_UNAVAILABLE ' + '$diagnosticError',
            );
          }
          rethrow;
        } finally {
          await viewer?.close();
          await linux.stop(session.sessionId);
        }
      },
      timeout: const Timeout(Duration(minutes: 15)),
    );
  }
}

Future<void> _openWriterFile(
  DesktopRfbClient viewer,
  String path,
  String profile,
  String ready,
  _OfficeLinux linux,
) async {
  final before = await _settledFrame(viewer, await viewer.firstFrame);
  await _shortcut(viewer, 0x74, [0xffe3, 0xffe9]); // Ctrl+Alt+t.
  await _changedFrame(viewer, before, 'The launch terminal did not open.');
  await _settledFrame(viewer, await viewer.capture());
  // Match the verified production binary/bootstrap but isolate this fixture's
  // settings, recovery state and IPC lock from the normal user's office profile.
  final command =
      'python3 -c ' +
      _quote(_launchWriter) +
      ' ' +
      [path, profile, ready].map(_quote).join(' ') +
      '\n';
  await viewer.text(command);
  await _writerFrame(viewer);
  await _settledFrame(viewer, await viewer.capture());
  await _shortcut(
    viewer,
    0xff1b,
  ); // Dismiss the normal initial tip, if present.
  await _saveFrame(
    'WRITER_OPENED_INPUT',
    await _settledFrame(viewer, await viewer.capture()),
    linux,
  );
}

Future<DesktopFrame> _writerFrame(DesktopRfbClient viewer) async {
  final deadline = DateTime.now().add(const Duration(seconds: 120));
  while (DateTime.now().isBefore(deadline)) {
    final frame = await viewer.capture(timeout: const Duration(seconds: 15));
    var paperPixels = 0;
    for (var i = 0; i < frame.rgba.length; i += 4) {
      if (frame.rgba[i] > 246 &&
          frame.rgba[i + 1] > 246 &&
          frame.rgba[i + 2] > 246) {
        paperPixels++;
      }
    }
    if (paperPixels > frame.width * frame.height ~/ 4) return frame;
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  fail('The real Writer document surface did not become visible.');
}

Future<bool> _saveAs(
  DesktopRfbClient viewer,
  String path,
  String format,
  _OfficeLinux linux,
) async {
  final before = await _settledFrame(viewer, await viewer.capture());
  await _shortcut(viewer, 0x53, [0xffe3, 0xffe1]); // Ctrl+Shift+S.
  await _changedFrame(viewer, before, 'Writer did not open Save As.');
  await _saveFrame(
    'WRITER_SAVE_AS_DIALOG',
    await _settledFrame(viewer, await viewer.capture()),
    linux,
  );
  await _shortcut(viewer, 0x6c, [0xffe3]); // GTK location entry: Ctrl+l.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await _shortcut(viewer, 0x61, [0xffe3]);
  await _settledFrame(viewer, await viewer.capture());
  await viewer.text(path);
  await _shortcut(viewer, 0xff0d);
  final confirmed = await _confirmFormat(viewer, format, linux);
  await _settledFrame(viewer, await viewer.capture());
  return confirmed;
}

Future<bool> _confirmFormat(
  DesktopRfbClient viewer,
  String format,
  _OfficeLinux linux,
) async {
  await Future<void>.delayed(const Duration(seconds: 2));
  if (format != 'docx') return false;
  final frame = await _settledFrame(viewer, await viewer.capture());
  expect(frame.width, 720);
  expect(frame.height, 1080);
  // Preserve the normal foreign-format warning. The captured zh-CN warning has
  // no Alt+U mnemonic: its actual right button ("使用 Word 2007 格式") is at
  // (575,740) in this fixed 720x1080 fixture. Detect its orange warning glyph
  // in the dialog's left column before clicking the visually inspected target.
  // A normal document/page has no such glyph there. Later ZIP/XML inspection
  // rejects cancellation, an accidental ODT save, or any wrong GUI target.
  var warningPixels = 0;
  for (var y = 480; y < 650; y++) {
    for (var x = 25; x < 160; x++) {
      final i = (y * frame.width + x) * 4;
      if (frame.rgba[i] > 220 &&
          frame.rgba[i + 1] >= 100 &&
          frame.rgba[i + 1] <= 200 &&
          frame.rgba[i + 2] < 100) {
        warningPixels++;
      }
    }
  }
  await _saveFrame('DOCX_FORMAT_DIALOG', frame, linux);
  if (warningPixels < 80) return false;
  await viewer.pointer(x: 575, y: 740, buttons: 1);
  await viewer.pointer(x: 575, y: 740);
  await _changedFrame(
    viewer,
    frame,
    'The real DOCX format warning did not close.',
  );
  await _settledFrame(viewer, await viewer.capture());
  return true;
}

Future<DesktopFrame> _settledFrame(
  DesktopRfbClient viewer,
  DesktopFrame initial,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  final elapsed = Stopwatch()..start();
  var before = initial;
  var stable = 0;
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final after = await viewer.capture(timeout: const Duration(seconds: 15));
    stable = _differentPixels(before, after) < 600 ? stable + 1 : 0;
    before = after;
    if (stable >= 3 && elapsed.elapsed > const Duration(seconds: 2))
      return after;
  }
  fail('The actual application frame did not settle.');
}

Future<DesktopFrame> _changedFrame(
  DesktopRfbClient viewer,
  DesktopFrame before,
  String reason, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final after = await viewer.capture(timeout: const Duration(seconds: 15));
    if (_differentPixels(before, after) >= 4096) return after;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  fail(reason);
}

int _differentPixels(DesktopFrame before, DesktopFrame after) {
  if (before.width != after.width || before.height != after.height) return 4096;
  var count = 0;
  for (var i = 0; i < before.rgba.length; i += 4) {
    if (before.rgba[i] != after.rgba[i] ||
        before.rgba[i + 1] != after.rgba[i + 1] ||
        before.rgba[i + 2] != after.rgba[i + 2]) {
      if (++count >= 4096) return count;
    }
  }
  return count;
}

Future<void> _shortcut(
  DesktopRfbClient viewer,
  int key, [
  List<int> modifiers = const [],
]) async {
  for (final modifier in modifiers) {
    await viewer.key(keysym: modifier, down: true);
  }
  await viewer.key(keysym: key, down: true);
  await viewer.key(keysym: key, down: false);
  for (final modifier in modifiers.reversed) {
    await viewer.key(keysym: modifier, down: false);
  }
}

Future<String> _saveFrame(
  String label,
  DesktopFrame frame,
  _OfficeLinux linux,
) async {
  final cache = await getTemporaryDirectory();
  final file = File(
    cache.path + '/perant-office-' + label + '-' + linux.nonce + '.png',
  );
  final png = frame.encodePng();
  await file.writeAsBytes(png, flush: true);
  // Actual fixture frames only, retained in redirected logs after test uninstall.
  // ignore: avoid_print
  print('DESKTOP_OFFICE_' + label + '_PNG_BASE64 ' + base64Encode(png));
  return file.path;
}

Future<void> _failure(
  DesktopRfbClient? viewer,
  _OfficeLinux linux,
  String session,
  String label,
) async {
  if (viewer != null) {
    try {
      await _saveFrame(label + '_FAILURE', await viewer.capture(), linux);
    } catch (_) {
      /* The failed app may also have disconnected Xvnc. */
    }
  }
  // ignore: avoid_print
  print(
    'DESKTOP_OFFICE_RUNTIME_LOG ' + jsonEncode(linux.desktopOutput(session)),
  );
}

void _record(
  Map<String, dynamic> report,
  String check,
  Map<String, dynamic> data,
) {
  final value = <String, dynamic>{'check': check, ...data};
  (report['checks'] as List<Map<String, dynamic>>).add(value);
  // ignore: avoid_print
  print('DESKTOP_OFFICE_RESULT ' + jsonEncode(value));
}

String _quote(String value) => "'" + value.replaceAll("'", "'\"'\"'") + "'";

final class _OfficeLinux {
  _OfficeLinux(this.bridge);
  final PerantPlatformBridge bridge;
  final nonce = DateTime.now().microsecondsSinceEpoch.toString();
  final _sessions = <String>{};
  final _directories = <String>[];
  final _commands = <String, _Command>{};
  final _desktopLogs = <String, String>{};
  StreamSubscription<RuntimeEvent>? _events;
  Object? streamError;
  int _sequence = 0;

  Future<void> attach() async {
    _events = bridge.events.listen((event) {
      if (event.type == 'linuxOutput') {
        final text = event.payload['text'] as String;
        final command = _commands[event.taskId];
        if (command != null) command.output.write(text);
        if (_sessions.contains(event.taskId)) {
          final id = event.taskId!;
          final output = (_desktopLogs[id] ?? '') + text;
          _desktopLogs[id] = output.length > 8192
              ? output.substring(output.length - 8192)
              : output;
        }
      } else if (event.type == 'linuxExit') {
        final command = _commands[event.taskId];
        if (command != null && !command.exit.isCompleted) {
          command.exit.complete(event.payload['exitCode'] as int);
        }
      }
    }, onError: (Object error) => streamError = error);
    await bridge.ensureRuntimeEventsAttached();
  }

  String desktopOutput(String session) => _desktopLogs[session] ?? '';

  Future<String> createDirectory() async {
    final path =
        '/workspace/perant-office-smoke-' +
        nonce +
        '-' +
        (_sequence++).toString();
    _directories.add(path);
    await bridge.createLinuxDirectory(path);
    return path;
  }

  Future<LinuxDesktopSession> start() async {
    final id = 'perant-office-smoke-' + nonce + '-' + (_sequence++).toString();
    _sessions.add(id);
    final session = await bridge.startLinuxDesktop(
      sessionId: id,
      width: 720,
      height: 1080,
    );
    expect(
      session.sessionId,
      id,
      reason: 'Do not attach to an unowned desktop.',
    );
    return session;
  }

  Future<void> stop(String id) async {
    if (!_sessions.contains(id)) return;
    await bridge.stopLinuxDesktop(id);
    _sessions.remove(id);
    expect(await bridge.getLinuxDesktopSession(), isNull);
    expect((await bridge.getLinuxStatus()).active, isFalse);
  }

  Future<String> run(String command) async {
    expect(await bridge.getLinuxDesktopSession(), isNull);
    final id =
        'perant-office-inspect-' + nonce + '-' + (_sequence++).toString();
    final pending = _Command();
    _commands[id] = pending;
    try {
      await bridge.runLinuxCommand(taskId: id, command: command);
      final code = await pending.exit.future.timeout(
        const Duration(seconds: 45),
      );
      expect(code, 0, reason: pending.output.toString());
      return pending.output.toString();
    } finally {
      if (!pending.exit.isCompleted) {
        final cancellation = await bridge.cancelTask(id);
        if (cancellation.status == TaskCancellationStatus.cancelled) {
          await pending.exit.future.timeout(const Duration(seconds: 20));
        }
        expect(
          (await bridge.getLinuxStatus()).active,
          isFalse,
          reason: 'Do not start cleanup while an inspection command is active.',
        );
      }
      _commands.remove(id);
    }
  }

  Future<String> runPython(String source, List<String> arguments) => run(
    'python3 -c ' + _quote(source) + ' ' + arguments.map(_quote).join(' '),
  );

  Future<Map<String, dynamic>> inspectDocument(
    String path,
    String format,
  ) async {
    final output = await runPython(_inspectDocument, [path, format]);
    final line = output
        .split('\n')
        .singleWhere((line) => line.startsWith('PERANT_OFFICE_DOCUMENT '));
    return Map<String, dynamic>.from(
      jsonDecode(line.substring('PERANT_OFFICE_DOCUMENT '.length)) as Map,
    );
  }

  Future<Map<String, dynamic>> inspectReady(String path) async {
    final output = await runPython(
      'import json,pathlib,sys; print("PERANT_OFFICE_READY " + json.dumps(json.loads(pathlib.Path(sys.argv[1]).read_text())))',
      [path],
    );
    final line = output
        .split('\n')
        .singleWhere((line) => line.startsWith('PERANT_OFFICE_READY '));
    return Map<String, dynamic>.from(
      jsonDecode(line.substring('PERANT_OFFICE_READY '.length)) as Map,
    );
  }

  Future<void> cleanup() async {
    for (final session in _sessions.toList()) {
      await stop(session);
    }
    for (final path in _directories.toList()) {
      if (!RegExp('^/workspace/perant-office-smoke-' + nonce + r'-[0-9]+$')
          .hasMatch(path)) {
        throw StateError('Refusing to delete an unowned fixture directory.');
      }
      await run('rm -rf -- ' + _quote(path));
      _directories.remove(path);
    }
  }

  Future<void> dispose() async {
    await cleanup();
    await _events?.cancel();
  }
}

final class _Command {
  final output = StringBuffer();
  final exit = Completer<int>();
}

const _createTemplate = r'''
import sys, zipfile
from xml.sax.saxutils import escape
path, kind, marker = sys.argv[1:]
text = escape(marker)
with zipfile.ZipFile(path, "x", compression=zipfile.ZIP_DEFLATED) as z:
    if kind == "odt":
        z.writestr("mimetype", "application/vnd.oasis.opendocument.text", compress_type=zipfile.ZIP_STORED)
        z.writestr("content.xml", '<?xml version="1.0" encoding="UTF-8"?><office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.3"><office:body><office:text><text:p>' + text + '</text:p></office:text></office:body></office:document-content>')
        z.writestr("META-INF/manifest.xml", '<?xml version="1.0"?><manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>')
    elif kind == "docx":
        z.writestr("[Content_Types].xml", '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
        z.writestr("_rels/.rels", '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
        z.writestr("word/document.xml", '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>' + text + '</w:t></w:r></w:p><w:sectPr/></w:body></w:document>')
    else:
        raise ValueError(kind)
''';

// LibreOffice 25.8.7.3 exithelper.h defines 81 as normal restart; its official
// desktop/unx/source/start.c restarts it with all original arguments. Preserve
// this finite startup behavior without retrying crashes or other failure codes.
const _launchWriter = r'''
import json, os, pathlib, subprocess, sys, time
path, profile, ready = sys.argv[1:]
marker = pathlib.Path(ready)
marker.unlink(missing_ok=True)
env = dict(os.environ, SAL_USE_VCLPLUGIN="gtk3", SAL_ENABLE_FILE_LOCKING="1", URE_BOOTSTRAP="vnd.sun.star.pathname:/usr/lib/libreoffice/program/fundamentalrc")
log = open(ready + ".log", "w")
command = ["/usr/lib/libreoffice/program/soffice.bin", "-env:UserInstallation=" + pathlib.Path(profile).as_uri(), "--nologo", "--writer", path]
process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
restarts = []
deadline = time.monotonic() + 115
while time.monotonic() < deadline:
    found = subprocess.run(["xdotool", "search", "--onlyvisible", "--class", "[Ll]ibre[Oo]ffice|soffice"], capture_output=True, text=True)
    for window in found.stdout.split():
        title = subprocess.run(["xdotool", "getwindowname", window], capture_output=True, text=True)
        if title.returncode == 0 and title.stdout.strip():
            subprocess.run(["xdotool", "windowactivate", "--sync", window], check=True)
            marker.write_text(json.dumps({"mappedLibreOfficeWindow": True, "windowId": window, "windowTitle": title.stdout.strip(), "openedPath": path, "normalRestartCodes": restarts}))
            sys.exit(0)
    if process.poll() is not None:
        if process.returncode == 81 and len(restarts) < 2:
            restarts.append(81)
            log.write("Test-owned launcher: normal LibreOffice restart 81" + chr(10))
            log.flush()
            process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
            continue
        raise RuntimeError("Writer exited before a mapped window: " + str(process.returncode))
    time.sleep(.25)
raise TimeoutError("No real mapped LibreOffice window was found")
''';

const _inspectDocument = r'''
import hashlib, json, pathlib, sys, zipfile
import xml.etree.ElementTree as ET
path, kind = sys.argv[1:]
data = pathlib.Path(path).read_bytes()
assert 0 < len(data) < 8 * 1024 * 1024
with zipfile.ZipFile(path) as z:
    part = "content.xml" if kind == "odt" else "word/document.xml"
    info = z.getinfo(part)
    assert info.file_size < 2 * 1024 * 1024
    if kind == "odt":
        assert z.read("mimetype") == b"application/vnd.oasis.opendocument.text"
    else:
        types = ET.fromstring(z.read("[Content_Types].xml"))
        assert any(x.get("PartName") == "/word/document.xml" and x.get("ContentType") == "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml" for x in types)
    root = ET.fromstring(z.read(part))
    text = "".join(root.itertext())
print("PERANT_OFFICE_DOCUMENT " + json.dumps({"format": kind, "containerPart": part, "sizeBytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "text": text}, ensure_ascii=True))
''';

const _inspectLaunchFailure = r'''
import json, pathlib, sys
marker = pathlib.Path(sys.argv[1])
log = pathlib.Path(str(marker) + ".log")
print(json.dumps({"markerExists": marker.is_file(), "marker": marker.read_text(errors="replace")[:4096] if marker.is_file() else None, "processLogExists": log.is_file(), "processLogTail": log.read_text(errors="replace")[-8192:] if log.is_file() else None}, ensure_ascii=True))
''';
