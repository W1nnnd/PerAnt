// SPDX-License-Identifier: GPL-3.0-only

enum ApiProtocol {
  chatCompletions,
  responses;

  String get label => switch (this) {
        chatCompletions => 'Chat Completions',
        responses => 'Responses',
      };

  String get endpointPath => switch (this) {
        chatCompletions => 'chat/completions',
        responses => 'responses',
      };
}

enum ModelCapability {
  streaming,
  toolCalling,
  parallelTools,
  thinking,
  structuredOutputs,
  vision,
}

enum ProviderVerification {
  documented,
  connectionVerified,
  toolsVerified;

  String get label => switch (this) {
        documented => '待连接验证',
        connectionVerified => '连接已验证',
        toolsVerified => '工具任务已验证',
      };
}

/// Serializable configuration. Credentials belong in platform secure storage.
final class ProviderProfile {
  ProviderProfile({
    required this.id,
    required this.displayName,
    required this.baseUrl,
    required this.protocol,
    required this.modelId,
    this.storageKeyRef,
    this.presetId,
    this.verification = ProviderVerification.documented,
    Set<ModelCapability> capabilities = const {},
    Map<String, String> headers = const {},
    Map<String, Object?> options = const {},
  })  : capabilities = Set.unmodifiable(capabilities),
        headers = Map.unmodifiable(headers),
        options = Map.unmodifiable(options) {
    if (id.trim().isEmpty || displayName.trim().isEmpty) {
      throw ArgumentError('Provider ID and display name must not be empty.');
    }
    if (modelId.trim().isEmpty) {
      throw ArgumentError('Choose a model before saving the provider.');
    }
    if (!baseUrl.hasAuthority ||
        !{'https', 'http'}.contains(baseUrl.scheme) ||
        baseUrl.host.isEmpty ||
        baseUrl.userInfo.isNotEmpty ||
        baseUrl.hasQuery ||
        baseUrl.hasFragment) {
      throw ArgumentError(
          'Use an HTTP(S) base URL without credentials or query.');
    }
    const credentialHeaders = {
      'authorization',
      'proxy-authorization',
      'x-api-key',
      'api-key',
    };
    if (headers.keys
        .any((name) => credentialHeaders.contains(name.toLowerCase()))) {
      throw ArgumentError(
          'Credential headers must use platform secure storage.');
    }
  }

  final String id;
  final String displayName;
  final Uri baseUrl;
  final ApiProtocol protocol;
  final String modelId;
  final String? storageKeyRef;
  final String? presetId;
  final ProviderVerification verification;
  final Set<ModelCapability> capabilities;
  final Map<String, String> headers;
  final Map<String, Object?> options;

  ProviderProfile withVerification(ProviderVerification status) =>
      status == verification
          ? this
          : ProviderProfile(
              id: id,
              displayName: displayName,
              baseUrl: baseUrl,
              protocol: protocol,
              modelId: modelId,
              storageKeyRef: storageKeyRef,
              presetId: presetId,
              verification: status,
              capabilities: capabilities,
              headers: headers,
              options: options);

  Map<String, Object?> get generationParameters {
    final result = <String, Object?>{};
    final temperature = options['temperature'];
    if (temperature != null) {
      if (temperature is! num ||
          !temperature.isFinite ||
          temperature < 0 ||
          temperature > 2) {
        throw ArgumentError('temperature must be between 0 and 2.');
      }
      result['temperature'] = temperature;
    }
    final topP = options['top_p'];
    if (topP != null) {
      if (topP is! num || !topP.isFinite || topP <= 0 || topP > 1) {
        throw ArgumentError('top_p must be greater than 0 and at most 1.');
      }
      result['top_p'] = topP;
    }
    return result;
  }

  /// Preserves a supplied API path, including provider-specific version paths.
  Uri get apiEndpoint {
    final path = baseUrl.path.endsWith('/') ? baseUrl.path : '${baseUrl.path}/';
    return baseUrl.replace(path: path).resolve(protocol.endpointPath);
  }

  Uri get modelsEndpoint {
    final path = baseUrl.path.endsWith('/') ? baseUrl.path : '${baseUrl.path}/';
    return baseUrl.replace(path: path).resolve('models');
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'displayName': displayName,
        'baseUrl': baseUrl.toString(),
        'protocol': protocol.name,
        'modelId': modelId,
        'storageKeyRef': storageKeyRef,
        'presetId': presetId,
        'verification': verification.name,
        'capabilities': capabilities.map((value) => value.name).toList(),
        'headers': headers,
        'options': options,
      };

  factory ProviderProfile.fromJson(Map<String, Object?> json) =>
      ProviderProfile(
        id: json['id']! as String,
        displayName: json['displayName']! as String,
        baseUrl: Uri.parse(json['baseUrl']! as String),
        protocol: ApiProtocol.values.byName(json['protocol']! as String),
        modelId: json['modelId']! as String,
        storageKeyRef: json['storageKeyRef'] as String?,
        presetId: json['presetId'] as String?,
        verification: ProviderVerification.values.byName(
          (json['verification'] as String?) ?? 'documented',
        ),
        capabilities: ((json['capabilities'] as List<Object?>?) ?? const [])
            .map((value) => ModelCapability.values.byName(value! as String))
            .toSet(),
        headers: (json['headers'] as Map<String, Object?>? ?? const {})
            .map((key, value) => MapEntry(key, value! as String)),
        options: json['options'] as Map<String, Object?>? ?? const {},
      );
}

/// A documented endpoint template, not a claim that all models were tested.
final class ProviderPreset {
  ProviderPreset({
    required this.id,
    required this.displayName,
    required this.baseUrl,
    required this.protocol,
    required this.documentationUrl,
    required this.configurationNote,
    this.region,
    Set<ModelCapability> capabilities = const {},
  }) : capabilities = Set.unmodifiable(capabilities);

  final String id;
  final String displayName;
  final Uri baseUrl;
  final ApiProtocol protocol;
  final Uri documentationUrl;
  final String configurationNote;
  final String? region;
  final Set<ModelCapability> capabilities;

  ProviderProfile createProfile({
    required String profileId,
    required String modelId,
    String? storageKeyRef,
  }) =>
      ProviderProfile(
        id: profileId,
        displayName: displayName,
        baseUrl: baseUrl,
        protocol: protocol,
        modelId: modelId,
        storageKeyRef: storageKeyRef,
        presetId: id,
        capabilities: capabilities,
      );
}

abstract final class ProviderCatalog {
  static const version = '2026-11-13';

  /// All presets start unverified. Runtime probes determine usable capabilities.
  static final List<ProviderPreset> presets = List.unmodifiable([
    ProviderPreset(
      id: 'openai',
      displayName: 'OpenAI',
      baseUrl: Uri.parse('https://api.openai.com/v1/'),
      protocol: ApiProtocol.responses,
      documentationUrl: Uri.parse(
        'https://developers.openai.com/api/docs/guides/function-calling',
      ),
      configurationNote: '部分模型的工具调用需使用 Responses；请填写实际可用模型。',
    ),
    ProviderPreset(
      id: 'anthropic',
      displayName: 'Claude',
      baseUrl: Uri.parse('https://api.anthropic.com/v1/'),
      protocol: ApiProtocol.chatCompletions,
      documentationUrl: Uri.parse(
        'https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/openai-sdk',
      ),
      configurationNote: '使用官方 OpenAI 兼容入口；部分原生能力和参数不适用。',
    ),
    ProviderPreset(
      id: 'gemini',
      displayName: 'Gemini',
      baseUrl: Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/openai/',
      ),
      protocol: ApiProtocol.chatCompletions,
      documentationUrl:
          Uri.parse('https://ai.google.dev/gemini-api/docs/openai'),
      configurationNote: '使用 OpenAI 兼容入口；工具与思考能力按具体模型验证。',
    ),
    ProviderPreset(
      id: 'deepseek',
      displayName: 'DeepSeek',
      baseUrl: Uri.parse('https://api.deepseek.com/v1/'),
      protocol: ApiProtocol.chatCompletions,
      documentationUrl: Uri.parse('https://api-docs.deepseek.com/'),
      configurationNote: '思考与工具调用须保留服务返回的必要扩展上下文。',
    ),
    ProviderPreset(
      id: 'qwen',
      displayName: '通义千问 / 百炼',
      baseUrl: Uri.parse('https://dashscope.aliyuncs.com/compatible-mode/v1/'),
      protocol: ApiProtocol.chatCompletions,
      documentationUrl: Uri.parse(
        'https://help.aliyun.com/zh/model-studio/base-url',
      ),
      configurationNote: '此为中国内地入口；Key、地域和业务空间必须匹配。',
      region: '中国内地',
    ),
    ProviderPreset(
      id: 'kimi',
      displayName: 'Kimi',
      baseUrl: Uri.parse('https://api.moonshot.ai/v1/'),
      protocol: ApiProtocol.chatCompletions,
      documentationUrl: Uri.parse(
        'https://platform.kimi.ai/docs/get-your-api-key',
      ),
      configurationNote: '思考模型需完整保留 assistant 消息及必要扩展字段。',
    ),
    ProviderPreset(
      id: 'glm',
      displayName: 'GLM / 智谱',
      baseUrl: Uri.parse('https://open.bigmodel.cn/api/paas/v4/'),
      protocol: ApiProtocol.chatCompletions,
      documentationUrl: Uri.parse(
        'https://docs.bigmodel.cn/cn/guide/develop/openai/introduction',
      ),
      configurationNote: '使用 OpenAI 格式入口；工具选择参数按服务实际支持配置。',
    ),
    ProviderPreset(
      id: 'minimax',
      displayName: 'MiniMax',
      baseUrl: Uri.parse('https://api.minimax.io/v1/'),
      protocol: ApiProtocol.chatCompletions,
      documentationUrl: Uri.parse(
        'https://platform.minimax.io/docs/api-reference/text-openai-api',
      ),
      configurationNote: '保留工具调用与思考上下文；其他地域或入口可手动调整。',
    ),
  ]);

  static ProviderPreset? find(String id) {
    for (final preset in presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }
}
