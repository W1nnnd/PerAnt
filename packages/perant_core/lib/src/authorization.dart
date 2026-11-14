// SPDX-License-Identifier: GPL-3.0-only

/// Identifies a particular revision rather than a mutable document name.
final class SourceVersion {
  const SourceVersion({required this.sourceId, required this.version});

  final String sourceId;
  final String version;

  Map<String, Object?> toJson() => {
        'sourceId': sourceId,
        'version': version,
      };

  factory SourceVersion.fromJson(Map<String, Object?> json) => SourceVersion(
        sourceId: json['sourceId']! as String,
        version: json['version']! as String,
      );

  @override
  bool operator ==(Object other) =>
      other is SourceVersion &&
      sourceId == other.sourceId &&
      version == other.version;

  @override
  int get hashCode => Object.hash(sourceId, version);
}

enum CloudDataScope {
  currentMaterials,
  currentAndHistorical;

  String get label => switch (this) {
        currentMaterials => '仅当前材料',
        currentAndHistorical => '当前材料与相关历史资料',
      };
}

/// A grant is bound to one task, endpoint configuration and source revisions.
///
/// Granting historical access never grants permission to upload every document
/// added to the library afterwards: the allowed revisions remain explicit.
final class CloudAuthorization {
  CloudAuthorization({
    required this.taskId,
    required this.providerProfileId,
    required this.providerEndpoint,
    required this.modelId,
    required this.scope,
    required this.grantedAt,
    required Set<SourceVersion> currentSources,
    Set<SourceVersion> historicalSources = const {},
    this.revokedAt,
  })  : currentSources = Set.unmodifiable(currentSources),
        historicalSources = Set.unmodifiable(historicalSources) {
    if (scope == CloudDataScope.currentMaterials &&
        historicalSources.isNotEmpty) {
      throw ArgumentError(
        'A current-materials grant cannot include historical sources.',
      );
    }
  }

  final String taskId;
  final String providerProfileId;
  final Uri providerEndpoint;
  final String modelId;
  final CloudDataScope scope;
  final DateTime grantedAt;
  final Set<SourceVersion> currentSources;
  final Set<SourceVersion> historicalSources;
  final DateTime? revokedAt;

  bool get isRevoked => revokedAt != null;

  bool permits({
    required String taskId,
    required String providerProfileId,
    required Uri providerEndpoint,
    required String modelId,
    required Iterable<SourceVersion> sources,
  }) {
    if (isRevoked ||
        this.taskId != taskId ||
        this.providerProfileId != providerProfileId ||
        this.providerEndpoint != providerEndpoint ||
        this.modelId != modelId) {
      return false;
    }
    final allowed = {...currentSources, ...historicalSources};
    return sources.every(allowed.contains);
  }

  CloudAuthorization revoke(DateTime at) => CloudAuthorization(
        taskId: taskId,
        providerProfileId: providerProfileId,
        providerEndpoint: providerEndpoint,
        modelId: modelId,
        scope: scope,
        grantedAt: grantedAt,
        currentSources: currentSources,
        historicalSources: historicalSources,
        revokedAt: at,
      );
}

enum ToolExecutionKind { controlledTool, generatedCode, arbitraryShell }

enum ToolEffect {
  readTaskFiles,
  createTaskFiles,
  overwritePublishedFile,
  deletePublishedFile,
  changeEnvironment,
}

enum ToolAuthorizationDecision {
  automatic,
  confirmationRequired,
  denied;

  String get label => switch (this) {
        automatic => '可以自动执行',
        confirmationRequired => '需要确认',
        denied => '禁止执行',
      };
}

/// Classifies structured requests, not arbitrary shell text.
///
/// Native adapters must enforce the declared workspace boundary. This policy
/// does not claim that command parsing or PRoot is a security sandbox.
final class ToolExecutionPolicy {
  const ToolExecutionPolicy({this.executionBoundaryValidated = false});

  final bool executionBoundaryValidated;

  ToolAuthorizationDecision evaluate({
    required ToolExecutionKind kind,
    required Set<ToolEffect> effects,
    bool scopeKnown = true,
    bool taskIsInManualControl = false,
    bool generatedCodeApproved = false,
  }) {
    if (taskIsInManualControl) return ToolAuthorizationDecision.denied;
    if (!scopeKnown || effects.isEmpty) {
      return ToolAuthorizationDecision.confirmationRequired;
    }
    if (effects.any((effect) => switch (effect) {
          ToolEffect.overwritePublishedFile ||
          ToolEffect.deletePublishedFile ||
          ToolEffect.changeEnvironment =>
            true,
          ToolEffect.readTaskFiles || ToolEffect.createTaskFiles => false,
        })) {
      return ToolAuthorizationDecision.confirmationRequired;
    }
    if (kind == ToolExecutionKind.controlledTool) {
      return ToolAuthorizationDecision.automatic;
    }
    if (executionBoundaryValidated && generatedCodeApproved) {
      return ToolAuthorizationDecision.automatic;
    }
    return ToolAuthorizationDecision.confirmationRequired;
  }
}
