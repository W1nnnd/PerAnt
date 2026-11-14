// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perant/src/application/workspace_controller.dart';
import 'package:perant/src/data/credential_store.dart';
import 'package:perant/src/data/workspace_state.dart';
import 'package:perant/src/presentation/provider_settings.dart';
import 'package:perant/src/presentation/theme.dart';
import 'package:perant_core/perant_core.dart';
import 'package:perant_gateway/perant_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<WorkspaceController> launch(
    WidgetTester tester, {
    String? presetId,
  }) async {
    final credentials = MemoryCredentialStore();
    final client = MockClient((_) async {
      throw StateError('Saving settings must not call an API.');
    });
    final controller = WorkspaceController(
      persistence: MemoryWorkspacePersistence(),
      credentials: credentials,
      gateway: OpenAiGateway(client: client),
    );
    addTearDown(controller.dispose);
    addTearDown(client.close);
    final url = Uri.parse('https://example.invalid/custom/v1/');
    await controller.configure(
      ProviderProfile(
        id: 'primary',
        displayName: '自定义服务',
        baseUrl: url,
        protocol: ApiProtocol.chatCompletions,
        modelId: 'custom-model',
        storageKeyRef: 'perant.api.${Uri.encodeComponent(url.toString())}',
        presetId: presetId,
      ),
      'test-only-custom-key',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: perantTheme(),
        home: Scaffold(body: ProviderSettings(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('saved custom service reopens as custom and retains its key', (
    tester,
  ) async {
    final controller = await launch(tester);
    final service = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>),
    );
    expect(service.initialValue, 'custom');
    expect(find.text('自定义兼容服务'), findsOneWidget);
    await tester.enterText(
      find.byType(TextFormField).first,
      'updated-custom-model',
    );
    await tester.ensureVisible(find.text('保存配置'));
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();

    expect(controller.profile!.presetId, isNull);
    expect(controller.profile!.displayName, '自定义服务');
    expect(controller.profile!.modelId, 'updated-custom-model');
    expect(controller.hasKey, isTrue);
    expect(
      await controller.credentials.read(controller.profile!.storageKeyRef!),
      'test-only-custom-key',
    );
    expect(find.text('模型配置已保存，连接测试会单独发起请求。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removed preset falls back to custom without breaking the form', (
    tester,
  ) async {
    await launch(tester, presetId: 'no-longer-in-the-catalog');

    final service = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>),
    );
    expect(service.initialValue, 'custom');
    expect(find.text('自定义兼容服务'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
