// SPDX-License-Identifier: GPL-3.0-only

import 'package:perant_core/perant_core.dart';
import 'package:test/test.dart';

void main() {
  final endpoint = Uri.parse('https://example.com/v1/responses');
  final now = DateTime.utc(2026, 11, 13);
  const current = SourceVersion(sourceId: 'meeting', version: '1');
  const historical = SourceVersion(sourceId: 'previous-meeting', version: '2');
  CloudAuthorization grant() => CloudAuthorization(
        taskId: 'task',
        providerProfileId: 'profile',
        providerEndpoint: endpoint,
        modelId: 'model',
        scope: CloudDataScope.currentMaterials,
        grantedAt: now,
        currentSources: {current},
      );

  bool permits(
    CloudAuthorization authorization, {
    String taskId = 'task',
    String profileId = 'profile',
    Uri? providerEndpoint,
    String modelId = 'model',
    Iterable<SourceVersion> sources = const [current],
  }) =>
      authorization.permits(
        taskId: taskId,
        providerProfileId: profileId,
        providerEndpoint: providerEndpoint ?? endpoint,
        modelId: modelId,
        sources: sources,
      );

  group('CloudAuthorization', () {
    test('current-materials permission excludes history and later revisions',
        () {
      expect(permits(grant()), isTrue);
      expect(permits(grant(), sources: [historical]), isFalse);
      expect(
        permits(grant(), sources: const [
          SourceVersion(sourceId: 'meeting', version: '2'),
        ]),
        isFalse,
      );
    });

    test('task, endpoint, profile and model changes require new authorization',
        () {
      expect(permits(grant(), taskId: 'other'), isFalse);
      expect(permits(grant(), profileId: 'other'), isFalse);
      expect(permits(grant(), modelId: 'other-model'), isFalse);
      expect(
        permits(grant(), providerEndpoint: Uri.parse('https://other.com/v1/')),
        isFalse,
      );
    });

    test(
        'historical scope authorizes only explicitly selected source revisions',
        () {
      final authorization = CloudAuthorization(
        taskId: 'task',
        providerProfileId: 'profile',
        providerEndpoint: endpoint,
        modelId: 'model',
        scope: CloudDataScope.currentAndHistorical,
        grantedAt: now,
        currentSources: {current},
        historicalSources: {historical},
      );
      expect(permits(authorization, sources: [current, historical]), isTrue);
      expect(
        permits(authorization, sources: const [
          SourceVersion(sourceId: 'new-history', version: '1'),
        ]),
        isFalse,
      );
    });

    test('revocation prevents even an otherwise matching request', () {
      expect(permits(grant().revoke(now)), isFalse);
    });
  });

  group('ToolExecutionPolicy', () {
    const policy = ToolExecutionPolicy();

    test('controlled task-file operations can run automatically', () {
      expect(
        policy.evaluate(
          kind: ToolExecutionKind.controlledTool,
          effects: {ToolEffect.createTaskFiles},
        ),
        ToolAuthorizationDecision.automatic,
      );
    });

    test('arbitrary code does not inherit a safe-looking effect declaration',
        () {
      for (final kind in [
        ToolExecutionKind.generatedCode,
        ToolExecutionKind.arbitraryShell,
      ]) {
        expect(
          policy.evaluate(kind: kind, effects: {ToolEffect.createTaskFiles}),
          ToolAuthorizationDecision.confirmationRequired,
        );
      }
    });

    test('protected file and environment changes always need confirmation', () {
      const validated = ToolExecutionPolicy(executionBoundaryValidated: true);
      for (final effect in [
        ToolEffect.overwritePublishedFile,
        ToolEffect.deletePublishedFile,
        ToolEffect.changeEnvironment,
      ]) {
        expect(
          validated.evaluate(
            kind: ToolExecutionKind.generatedCode,
            effects: {effect},
            generatedCodeApproved: true,
          ),
          ToolAuthorizationDecision.confirmationRequired,
        );
      }
    });

    test('agent writes are denied while user has manual control', () {
      expect(
        policy.evaluate(
          kind: ToolExecutionKind.controlledTool,
          effects: {ToolEffect.createTaskFiles},
          taskIsInManualControl: true,
        ),
        ToolAuthorizationDecision.denied,
      );
    });
  });
}
