// SPDX-License-Identifier: GPL-3.0-only
import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'src/application/screenshot_grid.dart';
import 'src/application/workspace_controller.dart';
import 'src/data/credential_store.dart';
import 'src/data/persistence.dart';
import 'src/perant_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'LXGW WenKai',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  try {
    final controller = WorkspaceController(
      persistence: await openWorkspacePersistence(),
      credentials: createCredentialStore(),
      screenshotAnnotator: gridScreenshotAnnotator,
    );
    await controller.initialize();
    runApp(PerantApp(controller: controller));
  } catch (_) {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.storage_outlined, size: 40),
                    SizedBox(height: 20),
                    Text('暂时无法打开本地工作区', style: TextStyle(fontSize: 20)),
                    SizedBox(height: 12),
                    Text(
                      '请检查设备空间或存储权限后重新打开应用。已有数据不会被自动清空。',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
