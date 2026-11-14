// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:perant_platform/perant_platform.dart';

/// Uses the official direct ELF path also supported by soffice's debug launcher.
/// It avoids oosplash's Linux /proc/version preflight; no sandbox is disabled.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('LibreOffice direct launcher reports its version', (_) async {
    expect(Platform.isAndroid, isTrue);
    final bridge = PerantPlatformBridge(
      initializationTimeout: const Duration(minutes: 5),
    );
    final nonce = DateTime.now().microsecondsSinceEpoch.toString();
    final task = 'office-direct-$nonce';
    final cleanup = 'office-direct-clean-$nonce';
    final directory = '/workspace/perant-office-direct-$nonce';
    final completions = <String, Completer<int>>{};
    var output = '';
    final subscription = bridge.events.listen((event) {
      if (event.type == 'linuxOutput' && event.taskId == task) {
        output += event.payload['text'] as String;
        if (output.length > 16384)
          output = output.substring(output.length - 16384);
      }
      if (event.type == 'linuxExit') {
        final completion = completions[event.taskId];
        if (completion != null && !completion.isCompleted) {
          completion.complete(event.payload['exitCode'] as int);
        }
      }
    });
    Future<int> run(String id, String command) async {
      final completed = Completer<int>();
      completions[id] = completed;
      var started = false;
      try {
        await bridge.runLinuxCommand(
          taskId: id,
          command: command,
          timeout: const Duration(seconds: 45),
        );
        started = true;
        return await completed.future.timeout(const Duration(seconds: 60));
      } finally {
        if (started && !completed.isCompleted) {
          await bridge.cancelTask(id);
          await completed.future.timeout(const Duration(seconds: 15));
        }
        completions.remove(id);
      }
    }

    var created = false;
    try {
      await bridge.ensureRuntimeEventsAttached();
      expect(
        (await bridge.getLinuxStatus()).active,
        isFalse,
        reason: 'The probe must not interrupt an existing Linux task.',
      );
      final initialized = await bridge.initializeLinux();
      expect(initialized.installed, isTrue, reason: initialized.reason);
      await bridge.createLinuxDirectory(directory);
      created = true;
      final code = await run(
        task,
        '/usr/lib/libreoffice/program/soffice.bin '
        '-env:URE_BOOTSTRAP=vnd.sun.star.pathname:/usr/lib/libreoffice/program/fundamentalrc '
        '-env:UserInstallation=file://$directory/profile --headless --version',
      );
      binding.reportData = {
        'suite': 'android-libreoffice-direct-launcher',
        'actualNativePty': true,
        'launcherPreflightSkipped': '/proc/version stat in oosplash only',
        'sandboxFlagsChanged': false,
        'exitCode': code,
        'output': output,
      };
      // ignore: avoid_print
      print('OFFICE_DIRECT_PROBE exit=$code output=$output');
      expect(code, 0, reason: output);
      expect(output, contains('LibreOffice'));
    } finally {
      if (created && !(await bridge.getLinuxStatus()).active) {
        expect(
          RegExp(r'^/workspace/perant-office-direct-[0-9]+$')
              .hasMatch(directory),
          isTrue,
        );
        expect(await run(cleanup, 'rm -rf -- $directory'), 0);
      }
      await subscription.cancel();
    }
  }, timeout: const Timeout(Duration(minutes: 7)));
}
