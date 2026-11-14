// SPDX-License-Identifier: GPL-3.0-only
import 'package:material_ui/material_ui.dart';

import 'application/workspace_controller.dart';
import 'presentation/theme.dart';
import 'presentation/workspace_shell.dart';

class PerantApp extends StatelessWidget {
  const PerantApp({super.key, required this.controller});
  final WorkspaceController controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PerAnt',
    debugShowCheckedModeBanner: false,
    theme: perantTheme(),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: WorkspaceShell(controller: controller),
  );
}
