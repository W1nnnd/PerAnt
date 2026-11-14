// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';

import 'package:perant_core/perant_core.dart';
import 'package:test/test.dart';

void main() {
  test('all built-in profiles are documented but never falsely verified', () {
    expect(ProviderCatalog.presets, hasLength(8));
    expect(
      ProviderCatalog.presets.map((preset) => preset.id).toSet(),
      hasLength(8),
    );
    for (final preset in ProviderCatalog.presets) {
      final profile = preset.createProfile(
        profileId: 'profile-${preset.id}',
        modelId: 'user-selected-model',
      );
      expect(profile.verification, ProviderVerification.documented);
      expect(profile.baseUrl.scheme, 'https');
      expect(profile.capabilities, isEmpty);
    }
  });

  test('endpoint generation preserves custom version path', () {
    final profile = ProviderProfile(
      id: 'custom',
      displayName: '自定义接口',
      baseUrl: Uri.parse('https://example.com/custom/v4'),
      protocol: ApiProtocol.chatCompletions,
      modelId: 'model',
    );
    expect(
      profile.apiEndpoint.toString(),
      'https://example.com/custom/v4/chat/completions',
    );
  });

  test('profile round-trip contains a key reference, never a key value', () {
    final profile = ProviderCatalog.presets.first.createProfile(
      profileId: 'openai-personal',
      modelId: 'my-model',
      storageKeyRef: 'credential:openai-personal',
    );
    final encoded = jsonEncode(profile.toJson());
    final restored = ProviderProfile.fromJson(
      jsonDecode(encoded) as Map<String, Object?>,
    );
    expect(restored.storageKeyRef, 'credential:openai-personal');
    expect(restored.apiEndpoint, profile.apiEndpoint);
    expect(restored.protocol, ApiProtocol.responses);
    expect(restored.toJson().containsKey('apiKey'), isFalse);
  });

  test('secret-bearing URL and ordinary authorization headers are rejected',
      () {
    ProviderProfile create(Uri url, {Map<String, String> headers = const {}}) =>
        ProviderProfile(
          id: 'custom',
          displayName: '自定义接口',
          baseUrl: url,
          protocol: ApiProtocol.chatCompletions,
          modelId: 'model',
          headers: headers,
        );
    expect(
      () => create(Uri.parse('https://user:secret@example.com/v1/')),
      throwsArgumentError,
    );
    expect(
      () => create(Uri.parse('https://example.com/v1/?key=secret')),
      throwsArgumentError,
    );
    expect(
      () => create(Uri.parse('https://example.com/v1/'), headers: {
        'Authorization': 'Bearer secret',
      }),
      throwsArgumentError,
    );
  });
}
