// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perant_platform/perant_platform.dart';

Map<String, Object?> _desktop({String id = 'desktop-1'}) => {
      'sessionId': id,
      'pid': 42,
      'socketPath': '/data/user/0/dev.perant.perant/cache/g/a1b2c3d4/rfb.sock',
      'width': 1024,
      'height': 768,
      'display': 1234,
      'workspace': '/workspace',
    };
Map<String, Object?> _status({bool active = false}) => {
      'supported': true,
      'installed': true,
      'active': active,
      'sessionId': null,
      'distribution': 'Alpine',
      'version': '3.24.4',
      'workspace': '/workspace',
      'reason': 'Fixture',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('dev.perant/test-desktop-bridge');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late PerantPlatformBridge bridge;
  setUp(() {
    bridge = PerantPlatformBridge(methodChannel: methods);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
  });

  test(
      'desktop start sends explicit size and returns genuine existing session identity',
      () async {
    late MethodCall observed;
    messenger.setMockMethodCallHandler(methods, (call) async {
      observed = call;
      return _desktop(id: 'already-running');
    });
    final session = await bridge.startLinuxDesktop(
        sessionId: 'new-id', width: 1024, height: 768);
    expect(observed.method, 'startLinuxDesktop');
    expect(observed.arguments,
        {'sessionId': 'new-id', 'width': 1024, 'height': 768});
    expect(session.sessionId, 'already-running');
    expect(session.socketPath, endsWith('/rfb.sock'));
    expect(session.width, 1024);
    expect(session.height, 768);
    expect(session.display, 1234);
    expect(session.workspace, '/workspace');
  });
  test('locating a saved excerpt sends its path only to the selected desktop',
      () async {
    late MethodCall observed;
    messenger.setMockMethodCallHandler(methods, (call) async {
      observed = call;
      return null;
    });
    const path = '/workspace/web-12345678-1234-1234-1234-123456789abc.md';
    final file = LinuxFileImport.fromMap(
        {'path': path, 'sizeBytes': 12, 'sha256': 'a' * 64});
    await bridge.revealDesktopExcerpt('desktop-1', file);
    expect(observed.method, 'revealDesktopExcerpt');
    expect(observed.arguments, {'sessionId': 'desktop-1', 'path': path});
  });

  test(
      'desktop reconnect distinguishes no session from acknowledged active session',
      () async {
    var count = 0;
    messenger.setMockMethodCallHandler(methods, (call) async {
      expect(call.method, 'getLinuxDesktopSession');
      return count++ == 0 ? null : _desktop();
    });
    expect(await bridge.getLinuxDesktopSession(), isNull);
    expect((await bridge.getLinuxDesktopSession())!.sessionId, 'desktop-1');
  });
  test(
      'stop forwards the precise desktop ID and requires an empty acknowledgement',
      () async {
    var count = 0;
    messenger.setMockMethodCallHandler(methods, (call) async {
      expect(call.method, 'stopLinuxDesktop');
      expect(call.arguments, {'sessionId': 'desktop-1'});
      return count++ == 0 ? null : {'not': 'empty'};
    });
    await bridge.stopLinuxDesktop('desktop-1');
    await expectLater(
        bridge.stopLinuxDesktop('desktop-1'),
        throwsA(isA<RuntimeBridgeException>()
            .having((error) => error.code, 'code', 'invalid_response')));
  });
  test(
      'invalid desktop IDs and excessive pixel allocations fail before native invocation',
      () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls++;
      return _desktop();
    });
    for (final id in ['', ' ', 'a' * 129]) {
      await expectLater(
          bridge.startLinuxDesktop(sessionId: id), throwsArgumentError);
      await expectLater(bridge.stopLinuxDesktop(id), throwsArgumentError);
    }
    for (final size in [(639, 768), (1024, 479), (1601, 768), (1024, 1201)]) {
      await expectLater(
          bridge.startLinuxDesktop(
              sessionId: 'desktop-1', width: size.$1, height: size.$2),
          throwsArgumentError);
    }
    expect(calls, 0);
  });
  test('desktop status is backwards compatible and never invents resources',
      () {
    final old = LinuxStatus.fromMap(_status());
    expect(old.desktopAvailable, isFalse);
    expect(old.desktopVersion, isNull);
    expect(old.desktopSessionId, isNull);
    final desktop = LinuxStatus.fromMap({
      ..._status(active: true),
      'desktopAvailable': true,
      'desktopVersion': 'TigerVNC 1.16.2 / Openbox 3.6.1',
      'desktopSessionId': 'desktop-1'
    });
    expect(desktop.desktopAvailable, isTrue);
    expect(desktop.desktopSessionId, 'desktop-1');
    for (final invalid in [
      {..._status(), 'desktopAvailable': true},
      {..._status(), 'desktopSessionId': 'desktop-1'},
      {
        ..._status(active: true),
        'desktopAvailable': true,
        'desktopVersion': 'GUI',
        'desktopSessionId': 'desktop-1',
        'sessionId': 'terminal-1'
      },
    ]) {
      expect(() => LinuxStatus.fromMap(invalid), throwsFormatException);
    }
  });
  test('untrusted desktop endpoint payloads fail closed', () {
    for (final field in [
      {'socketPath': '/tmp/rfb.sock/../../host/rfb.sock'},
      {'socketPath': 'tcp://127.0.0.1:5900'},
      {'socketPath': '/tmp/not-rfb'},
      {'socketPath': '/${'a' * 110}/rfb.sock'},
      {'socketPath': '/tmp/\n/rfb.sock'},
      {'width': 1000000},
      {'height': 1},
      {'display': 65536},
      {'pid': 0},
      {'workspace': '/host'},
    ]) {
      expect(() => LinuxDesktopSession.fromMap({..._desktop(), ...field}),
          throwsFormatException);
    }
  });
  test(
      'native desktop startup failures remain failures, never fabricated desktops',
      () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      throw PlatformException(
          code: 'desktop_start_failed', message: 'Fixture server failed');
    });
    await expectLater(
        bridge.startLinuxDesktop(sessionId: 'desktop-1'),
        throwsA(isA<RuntimeBridgeException>()
            .having((error) => error.code, 'code', 'desktop_start_failed')));
  });
}
