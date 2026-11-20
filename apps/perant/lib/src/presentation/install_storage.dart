// SPDX-License-Identifier: GPL-3.0-only
import 'package:material_ui/material_ui.dart';
import 'package:perant_platform/perant_platform.dart';

/// v6 package sizes and install stages are documented in LINUX_RUNTIME_SOURCES.
const linuxInstallEstimate =
    'Linux 组件已随安装包提供，额外下载 0 MB。初始化会同时保存约 428 MB 的软件包和解压文件，建议预留 2 GB。';

class InstallStorage extends StatefulWidget {
  const InstallStorage({
    super.key,
    required this.bridge,
    required this.estimate,
  });
  final PerantPlatformBridge bridge;
  final String estimate;
  @override
  State<InstallStorage> createState() => _InstallStorageState();
}

class _InstallStorageState extends State<InstallStorage> {
  late Future<int?> available = widget.bridge.availableStorageBytes();
  @override
  Widget build(BuildContext context) => FutureBuilder<int?>(
    future: available,
    builder: (_, result) => Text(
      widget.estimate +
          (result.data == null
              ? ''
              : ' 当前可用 ${(result.data! / 1e9).toStringAsFixed(2)} GB。'),
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );
}
