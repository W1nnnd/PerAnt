// SPDX-License-Identifier: GPL-3.0-only
import 'dart:typed_data';

import 'package:perant_platform/perant_platform.dart';

import 'shared_desktop_service.dart';

/// Model access uses the same live desktop as the viewer. An injectable
/// contract lets protocol tests provide fixture observations without claiming
/// those fixtures came from the Android display server.
abstract interface class ContainerDesktopAgent {
  bool get modelHasControl;
  void takeModelControl();
  void releaseModelControl();
  Future<LinuxDesktopSession> start({int width = 1024, int height = 640});
  Future<ContainerDesktopObservation> observe();
  Future<Map<String, Object?>> perform({
    required String observationId,
    required String action,
    int? x,
    int? y,
    int? toX,
    int? toY,
    String? text,
    String? key,
    List<String> modifiers = const [],
    String button = 'left',
  });
  Future<void> stop();
}

final class ContainerDesktopObservation {
  const ContainerDesktopObservation({
    required this.id,
    required this.width,
    required this.height,
    required this.png,
    required this.capturedAt,
  });
  final String id;
  final int width;
  final int height;
  final Uint8List png;
  final DateTime capturedAt;
}

final class SharedContainerDesktopAgent implements ContainerDesktopAgent {
  SharedContainerDesktopAgent(this.service);
  final SharedDesktopService service;
  @override
  bool get modelHasControl => service.modelHasControl;
  @override
  void takeModelControl() => service.takeModelControl();
  @override
  void releaseModelControl() => service.releaseModelControl();
  @override
  Future<LinuxDesktopSession> start({int width = 1024, int height = 640}) =>
      service.start(width: width, height: height);
  @override
  Future<ContainerDesktopObservation> observe() async {
    final observation = await service.observe();
    return ContainerDesktopObservation(
      id: observation.id,
      width: observation.width,
      height: observation.height,
      png: observation.png,
      capturedAt: observation.capturedAt,
    );
  }

  @override
  Future<Map<String, Object?>> perform({
    required String observationId,
    required String action,
    int? x,
    int? y,
    int? toX,
    int? toY,
    String? text,
    String? key,
    List<String> modifiers = const [],
    String button = 'left',
  }) => service.perform(
    observationId: observationId,
    action: action,
    x: x,
    y: y,
    toX: toX,
    toY: toY,
    text: text,
    key: key,
    modifiers: modifiers
        .map(
          (value) => switch (value) {
            'ctrl' => 'Ctrl',
            'alt' => 'Alt',
            'shift' => 'Shift',
            'super' => 'Super',
            _ => value,
          },
        )
        .toList(),
    button: button,
  );
  @override
  Future<void> stop() => service.stop();
}
