// SPDX-License-Identifier: GPL-3.0-only
import 'dart:typed_data';

import 'computer_browser_service.dart';

/// The model uses the same native browser as the user, without exposing script
/// evaluation or a second, hidden browser. Tests can inject fixture frames.
abstract interface class ContainerBrowserAgent {
  bool get modelHasControl;
  void takeModelControl();
  void releaseModelControl();
  Future<void> open({required String url});
  Future<ContainerBrowserObservation> observe();
  Future<Map<String, Object?>> savePage({required String observationId});
  Future<Map<String, Object?>> perform({
    required String observationId,
    required String action,
    int? x,
    int? y,
    int? deltaY,
    String? text,
    String? key,
    List<String> modifiers = const [],
  });
}

final class ContainerBrowserObservation {
  const ContainerBrowserObservation({
    required this.id,
    required this.browserId,
    required this.url,
    required this.title,
    required this.revision,
    required this.width,
    required this.height,
    required this.png,
    required this.capturedAt,
    this.loading = false,
    this.error = '',
  });
  final String id;
  final String browserId;
  final String url;
  final String title;
  final int revision;
  final int width;
  final int height;
  final Uint8List png;
  final DateTime capturedAt;
  final bool loading;
  final String error;
}

final class SharedContainerBrowserAgent implements ContainerBrowserAgent {
  SharedContainerBrowserAgent(this.service);
  final ComputerBrowserService service;
  @override
  bool get modelHasControl => service.modelHasControl;
  @override
  void takeModelControl() => service.takeModelControl();
  @override
  void releaseModelControl() => service.releaseModelControl();
  @override
  Future<void> open({required String url}) =>
      service.open(url: url, fromModel: true);
  @override
  Future<Map<String, Object?>> savePage({
    required String observationId,
  }) async => (await service.savePage(
    fromModel: true,
    observationId: observationId,
  )).toToolReceipt();
  @override
  Future<ContainerBrowserObservation> observe() async {
    final observation = await service.observe();
    final frame = observation.frame;
    return ContainerBrowserObservation(
      id: observation.id,
      browserId: frame.state.id,
      url: frame.state.url,
      title: frame.state.title,
      revision: frame.state.revision,
      width: frame.width,
      height: frame.height,
      png: frame.png,
      capturedAt: observation.capturedAt,
      loading: frame.state.loading,
      error: frame.state.error,
    );
  }

  @override
  Future<Map<String, Object?>> perform({
    required String observationId,
    required String action,
    int? x,
    int? y,
    int? deltaY,
    String? text,
    String? key,
    List<String> modifiers = const [],
  }) => service.perform(
    observationId: observationId,
    action: action,
    x: x,
    y: y,
    deltaY: deltaY,
    text: text,
    key: key,
    modifiers: modifiers,
  );
}
