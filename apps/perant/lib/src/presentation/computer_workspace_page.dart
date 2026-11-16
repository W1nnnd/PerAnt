// SPDX-License-Identifier: GPL-3.0-only
import 'package:material_ui/material_ui.dart';

import '../application/workspace_controller.dart';
import 'theme.dart';

/// A status and navigation page, never a background desktop viewer.
///
/// The shell owns navigation and workspace guards. Only an explicit view
/// action may mount the desktop screen and attach its framebuffer.
class ComputerWorkspacePage extends StatelessWidget {
  const ComputerWorkspacePage({
    super.key,
    required this.controller,
    required this.onViewDesktop,
    required this.onOpenBrowser,
    required this.onOpenTerminal,
    required this.onOpenFiles,
  });

  final WorkspaceController controller;
  final VoidCallback onViewDesktop;
  final VoidCallback onOpenBrowser;
  final VoidCallback onOpenTerminal;
  final VoidCallback onOpenFiles;

  bool get _terminalBlocked =>
      controller.isSending ||
      controller.isTesting ||
      controller.isConfiguring ||
      controller.manualTerminalActive ||
      controller.desktop.busy ||
      controller.desktop.running ||
      controller.desktop.modelHasControl ||
      controller.browser.modelHasControl;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      controller,
      controller.desktop,
      controller.browser,
    ]),
    builder: (context, _) {
      final desktop = controller.desktop;
      final modelHasControl =
          desktop.modelHasControl || controller.browser.modelHasControl;
      final unavailable = controller.capabilities?.linux.available == false;
      final status = modelHasControl
          ? '模型正在操作'
          : desktop.busy
          ? '正在准备本地电脑'
          : controller.isContainerTaskRunning
          ? '正在处理电脑任务'
          : controller.manualTerminalActive
          ? '终端正在使用'
          : desktop.running
          ? 'Linux 桌面已启动'
          : desktop.error != null
          ? '桌面连接需要检查'
          : unavailable
          ? '当前平台暂不支持 Linux'
          : '等待打开本地电脑';
      final detail = modelHasControl
          ? '可以查看进度；接管请使用电脑或浏览器中的接管入口。'
          : desktop.busy
          ? '正在准备真实运行环境，请稍候。'
          : controller.isContainerTaskRunning
          ? '任务仍在执行，已完成的操作可在工作文件中查看。'
          : controller.manualTerminalActive
          ? '请先关闭当前终端，再开始其他工作区操作。'
          : desktop.running
          ? '窗口与文件保留在同一个 /workspace 工作区。'
          : desktop.error != null
          ? '上次连接未完成，打开电脑查看原因并重试。'
          : unavailable
          ? '打开电脑可查看当前设备的实际运行时能力。'
          : '点击查看时连接桌面，离开画面后释放显示连接。';
      final terminalDetail = desktop.running
          ? '请在桌面内打开'
          : controller.manualTerminalActive
          ? '终端正在使用'
          : _terminalBlocked
          ? '当前操作结束后使用'
          : '运行 Linux 工具';

      return SingleChildScrollView(
        key: const ValueKey('computer-workspace-scroll'),
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '我们的工作区',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                letterSpacing: -.5,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '同一台电脑，一起把事情做好。',
              style: TextStyle(fontSize: 13, color: PerantColors.muted),
            ),
            const SizedBox(height: 20),
            Container(
              key: const ValueKey('computer-workspace-status'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: PerantColors.greenSoft,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: PerantColors.line),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    modelHasControl
                        ? Icons.smart_toy_outlined
                        : Icons.desktop_windows_outlined,
                    size: 22,
                    color: PerantColors.accent,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          status,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          detail,
                          style: const TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: PerantColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Material(
              color: PerantColors.soft,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: PerantColors.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: const ValueKey('computer-workspace-view-desktop'),
                onTap: onViewDesktop,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
                  child: Column(
                    children: [
                      const Row(
                        children: [
                          Expanded(
                            child: Text(
                              '本地电脑',
                              style: TextStyle(
                                fontSize: 12,
                                color: PerantColors.muted,
                              ),
                            ),
                          ),
                          Text(
                            '/workspace',
                            style: TextStyle(
                              fontSize: 12,
                              color: PerantColors.muted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 26),
                      const Icon(
                        Icons.desktop_windows_outlined,
                        size: 58,
                        color: PerantColors.accent,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        desktop.running ? '继续查看 Linux 桌面' : '点击查看 Linux 桌面',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '仅在查看时显示画面',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: PerantColors.muted,
                        ),
                      ),
                      const SizedBox(height: 22),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '查看电脑',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: PerantColors.accent,
                            ),
                          ),
                          SizedBox(width: 5),
                          Icon(
                            Icons.arrow_forward_rounded,
                            size: 18,
                            color: PerantColors.accent,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.verified_user_outlined,
                    size: 15,
                    color: PerantColors.muted,
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '查看电脑不会自动授予模型控制权限。模型操作仍需每次任务单独授权。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: PerantColors.muted,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _WorkspaceEntry(
                    key: const ValueKey('computer-workspace-browser'),
                    icon: Icons.language_rounded,
                    title: '浏览器',
                    detail: controller.browser.modelHasControl
                        ? '模型正在操作'
                        : controller.browser.running
                        ? '继续查看网页'
                        : '阅读与保存网页',
                    onTap: onOpenBrowser,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _WorkspaceEntry(
                    key: const ValueKey('computer-workspace-terminal'),
                    icon: Icons.terminal_rounded,
                    title: '终端',
                    detail: terminalDetail,
                    onTap: _terminalBlocked ? null : onOpenTerminal,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _WorkspaceEntry(
                    key: const ValueKey('computer-workspace-files'),
                    icon: Icons.folder_outlined,
                    title: '工作文件',
                    detail: '共享 /workspace',
                    onTap: onOpenFiles,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

class _WorkspaceEntry extends StatelessWidget {
  const _WorkspaceEntry({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: PerantColors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: PerantColors.line),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 16),
        child: Column(
          children: [
            Icon(
              icon,
              size: 25,
              color: onTap == null ? PerantColors.muted : PerantColors.accent,
            ),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                height: 1.5,
                color: PerantColors.muted,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
