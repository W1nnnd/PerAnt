// SPDX-License-Identifier: GPL-3.0-only
import 'package:material_ui/material_ui.dart';

import '../data/workspace_state.dart';
import 'theme.dart';

String containerActionStatusLabel(ContainerActionStatus status) =>
    switch (status) {
      ContainerActionStatus.queued => '等待执行',
      ContainerActionStatus.running => '正在执行',
      ContainerActionStatus.awaitingApproval => '等待你的确认',
      ContainerActionStatus.succeeded => '已完成',
      ContainerActionStatus.failed => '执行失败',
      ContainerActionStatus.denied => '已拒绝',
      ContainerActionStatus.interrupted => '已中断',
      ContainerActionStatus.cancelled => '已取消',
    };

class ContainerActions extends StatelessWidget {
  const ContainerActions({super.key, required this.actions});
  final List<ContainerAction> actions;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            '模型的文件操作和命令会记录在这里。\n返回对话，开启容器协作后发送任务。',
            textAlign: TextAlign.center,
            style: TextStyle(color: PerantColors.muted, height: 1.7),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: actions.length,
      separatorBuilder: (_, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final action = actions[index];
        final working =
            action.status == ContainerActionStatus.running ||
            action.status == ContainerActionStatus.awaitingApproval;
        return ExpansionTile(
          key: ValueKey(action.id),
          tilePadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          childrenPadding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
          leading: Icon(
            action.tool == 'container_run_command'
                ? Icons.terminal_rounded
                : Icons.insert_drive_file_outlined,
          ),
          title: Text(
            action.summary,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${containerActionStatusLabel(action.status)}${action.exitCode == null ? '' : ' · 退出码 ${action.exitCode}'}',
            style: TextStyle(
              color: working ? PerantColors.ink : PerantColors.muted,
              fontWeight: working ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                action.summary,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            if (action.output?.isNotEmpty == true) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 280),
                padding: const EdgeInsets.all(12),
                color: PerantColors.soft,
                child: SingleChildScrollView(
                  child: SelectableText(
                    action.output!,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
