// SPDX-License-Identifier: GPL-3.0-only
import 'dart:ui' show ImageFilter;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perant_core/perant_core.dart';

import '../application/workspace_controller.dart';
import '../data/workspace_state.dart';
import 'document_editor.dart';
import 'container_actions.dart';
import 'container_screen.dart';
import 'desktop_screen.dart';
import 'computer_browser_screen.dart';
import 'local_text_task_dialog.dart';
import 'provider_settings.dart';
import 'terminal_screen.dart';
import 'theme.dart';

class WorkspaceShell extends StatefulWidget {
  const WorkspaceShell({super.key, required this.controller});
  final WorkspaceController controller;
  @override
  State<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<WorkspaceShell> {
  int _section = 0;
  bool _containerEnabled = false;
  final _scaffold = GlobalKey<ScaffoldState>();
  final _composer = TextEditingController();
  final _search = TextEditingController();
  static const _names = ['聊天', '资源库', '任务', '设置'];
  static const _icons = [
    Icons.chat_bubble_outline_rounded,
    Icons.folder_outlined,
    Icons.checklist_rounded,
    Icons.tune_rounded,
  ];
  WorkspaceController get controller => widget.controller;
  bool get _mutationBusy =>
      controller.isSending ||
      controller.isConfiguring ||
      controller.manualTerminalActive;
  @override
  void initState() {
    super.initState();
    _composer.addListener(_composerChanged);
  }

  void _composerChanged() => setState(() {});
  @override
  void dispose() {
    _composer.removeListener(_composerChanged);
    _composer.dispose();
    _search.dispose();
    super.dispose();
  }

  void _toast(String text) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openDocument(MarkdownDocument document) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) =>
              DocumentEditor(controller: controller, document: document),
        ),
      );

  Future<void> _newDocument({String markdown = ''}) async {
    var title = markdown.isEmpty ? '' : '对话整理';
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('新建 Markdown 文档'),
        content: TextFormField(
          initialValue: title,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(
            labelText: '文档名称',
            hintText: '例如：产品讨论记录',
          ),
          onChanged: (value) => title = value,
          onFieldSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(c, value.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (title.trim().isNotEmpty) Navigator.pop(c, title.trim());
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null) return;
    try {
      final document = await controller.createDocument(
        title: name,
        markdown: markdown,
      );
      if (mounted) await _openDocument(document);
    } catch (_) {
      _toast('创建失败，请检查设备空间。');
    }
  }

  Future<void> _importDocument() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: '文本与 Markdown',
            extensions: ['md', 'markdown', 'txt'],
            uniformTypeIdentifiers: ['public.plain-text'],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > 1024 * 1024) {
        _toast('初步框架暂支持 1 MB 以内的文本文件。');
        return;
      }
      final text = await file.readAsString();
      if (text.runes.length > 20000) {
        _toast('单份输入请控制在 2 万字以内。');
        return;
      }
      final document = await controller.createDocument(
        title: file.name,
        markdown: text,
      );
      if (mounted) await _openDocument(document);
    } catch (_) {
      _toast('无法读取文件，请选择 UTF-8 编码的 TXT 或 Markdown。');
    }
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _mutationBusy) return;
    if (!controller.canChat) {
      setState(() => _section = 3);
      _toast('先配置模型，或在资料中直接编辑文档。');
      return;
    }
    var useContainer = _containerEnabled;
    final approved = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, updateDialog) => AlertDialog(
          title: const Text('允许本次任务使用云端模型？'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${controller.profile!.displayName} · ${controller.profile!.modelId}',
                  style: Theme.of(c).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                SelectableText(controller.profile!.baseUrl.host),
                const SizedBox(height: 16),
                Text(
                  useContainer
                      ? '本次允许模型操作 Linux 应用与浏览器的键鼠和文字输入，并浏览和修改共享 /workspace 文件。桌面及网页截图、文件内容、工具输出和容器协作历史会发送到以上服务。通过命令工具发起的 Shell 和关闭桌面会单独请求确认。登录、上传或提交等操作仍需你的明确指示。请选择支持图像和工具调用的模型；API 调用由你的服务账户计费。'
                      : '将发送本次文字及当前页面会话中保留的普通聊天上下文。不包含容器协作历史、资料库文件或长期记忆。API 调用由你的服务账户计费。',
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('允许模型操作容器电脑'),
                  subtitle: const Text('桌面与浏览器操作、截图及共享文件'),
                  value: useContainer,
                  onChanged: (value) =>
                      updateDialog(() => useContainer = value == true),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('授权并发送'),
            ),
          ],
        ),
      ),
    );
    if (approved != true || !mounted) return;
    setState(() => _containerEnabled = useContainer);
    _composer.clear();
    try {
      await controller.send(
        text,
        cloudApproved: true,
        containerEnabled: useContainer,
        approveContainerCommand: _approveContainerCommand,
      );
    } catch (_) {
      _toast('任务未能开始，请保留文字后重试。');
      _composer.text = text;
    }
  }

  Future<bool> _approveContainerCommand(String command) async {
    if (!mounted) return false;
    final stoppingDesktop = command.startsWith('关闭 Linux 图形桌面');
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => AlertDialog(
          title: Text(stoppingDesktop ? '关闭 Linux 桌面？' : '运行这条 Linux 命令？'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stoppingDesktop ? '模型请求结束当前图形桌面。请先确认 Linux 应用中需要保留的内容已经保存。' : '模型请求在本机容器中执行，起始目录为 /workspace。命令可以修改容器文件或访问网络；PRoot 不提供强隔离。',
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  color: PerantColors.soft,
                  child: SelectableText(
                    command,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
                if (!controller.isContainerTaskRunning) ...[
                  const SizedBox(height: 12),
                  const Text('本次任务已结束，不会执行这条命令。'),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                controller.cancelActiveTask();
                Navigator.pop(context, false);
              },
              child: const Text('停止任务'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('拒绝'),
            ),
            FilledButton(
              onPressed: controller.isContainerTaskRunning
                  ? () => Navigator.pop(context, true)
                  : null,
              child: Text(stoppingDesktop ? '关闭桌面' : '运行命令'),
            ),
          ],
        ),
      ),
    );
    return approved == true;
  }

  Future<void> _showContainer() => Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => ContainerScreen(controller: controller)),
  );

  Future<void> _showDesktop() => Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => DesktopScreen(controller: controller)),
  );

  Future<void> _showRuntime() async {
    String lease;
    try {
      lease = controller.acquireManualTerminal();
    } on StateError {
      _toast('请先结束当前请求或配置保存，再打开终端。');
      return;
    }
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => TerminalScreen(controller: controller, lease: lease),
        ),
      );
    } catch (_) {
      controller.releaseManualTerminal(lease);
      _toast('无法打开终端，请稍后重试。');
    }
  }

  Future<void> _runLocalTextTask() async {
    if (_mutationBusy || controller.isTesting) return;
    final input = await showDialog<LocalTextTaskInput>(
      context: context,
      barrierDismissible: false,
      builder: (_) => LocalTextTaskDialog(initialText: _composer.text),
    );
    if (input == null || !mounted) return;
    try {
      final running = controller.generateLocalMarkdown(
        title: input.title,
        text: input.text,
      );
      if (_composer.text == input.text) _composer.clear();
      FocusManager.instance.primaryFocus?.unfocus();
      final document = await running;
      if (document == null && mounted)
        _toast(controller.error ?? '本地整理未完成，原文保留在当前会话。');
    } catch (_) {
      if (mounted) {
        _composer.text = input.text;
        _toast('任务未能开始，原文已保留在输入框。请结束当前操作后重试。');
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final wide = MediaQuery.sizeOf(context).width >= 960;
      final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
      final content = switch (_section) {
        0 => _conversation(wide, keyboardOpen: keyboardOpen),
        1 => _documents(),
        2 => _tasks(),
        _ => ProviderSettings(
          key: ValueKey(controller.profile?.presetId),
          controller: controller,
        ),
      };
      return Scaffold(
        key: _scaffold,
        drawer: wide
            ? null
            : Drawer(
                backgroundColor: PerantColors.paper,
                child: SafeArea(child: _threadPanel()),
              ),
        body: SafeArea(
          bottom: false,
          child: Row(
            children: [
              if (wide) _iconRail(),
              if (wide && _section == 0)
                SizedBox(width: 252, child: _threadPanel()),
              Expanded(
                child: Column(
                  children: [
                    _section == 0 ? _chatHeader(wide) : _pageHeader(),
                    Expanded(child: content),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: wide || keyboardOpen
            ? null
            : _floatingNavigation(),
      );
    },
  );

  Widget _chatHeader(bool wide) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: Stack(
      alignment: Alignment.topCenter,
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: wide
              ? const SizedBox(width: 48, height: 48)
              : _roundButton(
                  icon: Icons.forum_outlined,
                  label: '会话',
                  onPressed: () => _scaffold.currentState?.openDrawer(),
                ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                button: true,
                label: 'PerAnt 状态',
                child: InkWell(
                  onTap: _showDesktop,
                  borderRadius: BorderRadius.circular(32),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: _Mark(size: 28),
                  ),
                ),
              ),
              const SizedBox(height: 3),
              const Text(
                'PerAnt',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                controller.isConfiguring
                    ? '正在保存模型配置'
                    : controller.isSending
                    ? controller.isContainerTaskRunning
                          ? '正在操作容器电脑'
                          : '正在写回复'
                    : controller.canChat
                    ? '等待你的消息'
                    : '连接模型，开始聊天',
                style: const TextStyle(fontSize: 12, color: PerantColors.muted),
              ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.topRight,
          child: PopupMenuButton<String>(
            tooltip: '更多',
            enabled: !controller.isConfiguring,
            icon: const Icon(Icons.more_horiz),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'new',
                enabled: !_mutationBusy,
                child: const Text('新聊天'),
              ),
              const PopupMenuItem(value: 'settings', child: Text('模型设置')),
              const PopupMenuItem(value: 'container', child: Text('容器电脑')),
              const PopupMenuItem(value: 'desktop', child: Text('查看模型电脑')),
              const PopupMenuItem(value: 'browser', child: Text('浏览器')),
              PopupMenuItem(
                value: 'terminal',
                enabled: !_mutationBusy && !controller.isTesting,
                child: const Text('本地终端'),
              ),
              PopupMenuItem(
                value: 'local-text',
                enabled: !_mutationBusy && !controller.isTesting,
                child: const Text('本地整理为 Markdown'),
              ),
              PopupMenuItem(
                value: 'document',
                enabled: !_mutationBusy,
                child: const Text('新建文档'),
              ),
            ],
            onSelected: (value) async {
              switch (value) {
                case 'new':
                  await _startConversation();
                case 'settings':
                  setState(() => _section = 3);
                case 'terminal':
                  await _showRuntime();
                case 'container':
                  await _showContainer();
                case 'desktop':
                  await _showDesktop();
                case 'browser':
                  if (mounted)
                    await Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) =>
                            ComputerBrowserScreen(controller: controller),
                      ),
                    );
                case 'local-text':
                  await _runLocalTextTask();
                case 'document':
                  await _newDocument();
              }
            },
          ),
        ),
      ],
    ),
  );

  Widget _pageHeader() => Padding(
    padding: const EdgeInsets.fromLTRB(24, 16, 16, 8),
    child: Row(
      children: [
        Text(_names[_section], style: Theme.of(context).textTheme.titleLarge),
        const Spacer(),
        IconButton(
          onPressed: () => setState(() => _section = 0),
          tooltip: '回到聊天',
          icon: const Icon(Icons.chat_bubble_outline_rounded),
        ),
      ],
    ),
  );

  Widget _roundButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) => Container(
    decoration: const BoxDecoration(
      color: PerantColors.soft,
      shape: BoxShape.circle,
    ),
    child: IconButton(
      onPressed: onPressed,
      tooltip: label,
      icon: Icon(icon, size: 21),
    ),
  );

  Future<void> _startConversation() async {
    try {
      await controller.newConversation();
      _composer.clear();
      if (mounted) {
        setState(() => _section = 0);
        if (_scaffold.currentState?.isDrawerOpen ?? false)
          _scaffold.currentState?.closeDrawer();
      }
    } catch (_) {
      _toast('请等待当前回复或配置保存完成，再开始新聊天。');
    }
  }

  Widget _threadPanel() => Material(
    color: PerantColors.soft,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 16, 20),
          child: Row(
            children: [
              const Text(
                '聊天',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              IconButton(
                onPressed: _mutationBusy ? null : _startConversation,
                tooltip: '新聊天',
                icon: const Icon(Icons.edit_square, size: 22),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final thread in controller.conversations)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    selected: controller.activeConversation.id == thread.id,
                    selectedTileColor: const Color(0xFFE4E4E9),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    leading: const Icon(
                      Icons.chat_bubble_outline_rounded,
                      size: 18,
                    ),
                    title: Text(
                      thread.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                    enabled: !_mutationBusy,
                    onTap: () async {
                      await controller.selectConversation(thread.id);
                      _composer.clear();
                      if (mounted && MediaQuery.sizeOf(context).width < 960)
                        _scaffold.currentState?.closeDrawer();
                    },
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            controller.persistence.description,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    ),
  );

  Widget _iconRail() => Material(
    color: PerantColors.paper,
    child: Container(
      width: 76,
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: PerantColors.line)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 10),
      child: Column(
        children: [
          const _Mark(size: 34),
          const SizedBox(height: 32),
          for (var index = 0; index < 4; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: _navigationButton(index),
            ),
          const Spacer(),
          IconButton(
            onPressed: _showDesktop,
            tooltip: '查看模型电脑',
            icon: const Icon(Icons.computer_outlined, size: 22),
          ),
        ],
      ),
    ),
  );

  Widget _navigationButton(int index) => IconButton(
    tooltip: _names[index],
    onPressed: () => setState(() => _section = index),
    style: IconButton.styleFrom(
      backgroundColor: _section == index
          ? PerantColors.ink
          : Colors.transparent,
      foregroundColor: _section == index ? Colors.white : PerantColors.muted,
      minimumSize: const Size(48, 48),
    ),
    icon: Icon(_icons[index], size: 22),
  );

  Widget _floatingNavigation() => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Align(
        heightFactor: 1,
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(34),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                height: 58,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .9),
                  borderRadius: BorderRadius.circular(34),
                  border: Border.all(color: PerantColors.line),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _navigationButton(0),
                    _navigationButton(1),
                    IconButton(
                      tooltip: '模型的电脑',
                      onPressed: _showDesktop,
                      style: IconButton.styleFrom(
                        foregroundColor: PerantColors.muted,
                        minimumSize: const Size(48, 48),
                      ),
                      icon: const Icon(Icons.computer_outlined, size: 22),
                    ),
                    _navigationButton(2),
                    _navigationButton(3),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _conversation(bool wide, {required bool keyboardOpen}) => Column(
    children: [
      Expanded(
        child: controller.messages.isEmpty
            ? _emptyConversation(showComputer: !keyboardOpen)
            : _messageList(),
      ),
      if (controller.error != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Text(
            controller.error!,
            style: const TextStyle(color: PerantColors.muted),
          ),
        ),
      if (controller.containerActions.isNotEmpty &&
          controller.isContainerTaskRunning)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            leading: const Icon(Icons.computer_outlined),
            title: Text(
              controller.containerActions.first.summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
            subtitle: Text(
              containerActionStatusLabel(
                controller.containerActions.first.status,
              ),
              style: const TextStyle(fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _showDesktop,
          ),
        ),
      _composerPanel(wide),
    ],
  );

  Widget _emptyConversation({required bool showComputer}) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '有什么想聊的，\n或者想交给我做的？',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  height: 1.7,
                  fontWeight: FontWeight.w500,
                  color: PerantColors.ink.withValues(alpha: .65),
                ),
              ),
              if (showComputer) ...[
                const SizedBox(height: 24),
                _computerCard(),
              ],
            ],
          ),
        ),
      ),
    ),
  );

  // Status only: the chat never subscribes to, captures or decodes desktop
  // frames. Opening DesktopScreen is the explicit foreground viewer action.
  Widget _computerCard() => ListenableBuilder(
    listenable: controller.desktop,
    builder: (context, _) {
      final desktop = controller.desktop;
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Material(
          color: PerantColors.soft,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _showDesktop,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.computer_outlined, size: 28),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '模型的电脑',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          desktop.busy
                              ? '正在准备 Linux 桌面'
                              : desktop.running
                              ? '桌面已启动 · 点击继续查看'
                              : '打开 Linux，一起处理文件与任务',
                          style: const TextStyle(
                            fontSize: 12,
                            color: PerantColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 20),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _composerPanel(bool wide) => Padding(
    padding: EdgeInsets.fromLTRB(16, 8, 16, wide ? 24 : 8),
    child: Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: wide ? 740 : 420),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!controller.canChat && !controller.state.onboardingDismissed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                      onPressed: () => setState(() => _section = 3),
                      child: const Text('连接你的模型'),
                    ),
                    TextButton(
                      onPressed: _mutationBusy
                          ? null
                          : controller.dismissOnboarding,
                      child: const Text('稍后'),
                    ),
                  ],
                ),
              ),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: PerantColors.soft,
                borderRadius: BorderRadius.circular(28),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    onPressed: _mutationBusy ? null : _importDocument,
                    tooltip: '添加文件',
                    icon: const Icon(Icons.add, size: 23),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      minLines: 1,
                      maxLines: 5,
                      maxLength: 20000,
                      buildCounter: (
                        context, {
                        required currentLength,
                        required isFocused,
                        maxLength,
                      }) => null,
                      enabled: !_mutationBusy,
                      decoration: const InputDecoration(
                        hintText: '给 PerAnt 发消息…',
                        fillColor: Colors.transparent,
                        border: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.fromLTRB(4, 12, 4, 12),
                      ),
                    ),
                  ),
                  IconButton.filled(
                    onPressed: controller.isSending
                        ? controller.canCancelActiveTask
                              ? controller.cancelActiveTask
                              : null
                        : controller.isConfiguring ||
                              controller.isTesting ||
                              _composer.text.trim().isEmpty
                        ? null
                        : _send,
                    tooltip: controller.isSending ? '停止生成' : '发送消息',
                    icon: Icon(
                      controller.isSending
                          ? Icons.stop_rounded
                          : Icons.arrow_upward_rounded,
                      size: 21,
                    ),
                  ),
                ],
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _mutationBusy
                          ? null
                          : () => setState(() => _section = 3),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              controller.profile?.modelId ?? '选择模型',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: PerantColors.muted,
                              ),
                            ),
                          ),
                          const Icon(
                            Icons.keyboard_arrow_down,
                            size: 16,
                            color: PerantColors.muted,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _mutationBusy
                      ? null
                      : () => setState(
                          () => _containerEnabled = !_containerEnabled,
                        ),
                  icon: Icon(
                    _containerEnabled
                        ? Icons.check_circle_outline
                        : Icons.computer_outlined,
                    size: 16,
                  ),
                  label: Text(
                    _containerEnabled ? '容器协作已开启' : '容器协作',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Widget _messageList() => ListView.builder(
    key: ValueKey(controller.activeConversation.id),
    reverse: true,
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
    itemCount: controller.messages.length,
    itemBuilder: (context, index) {
      final message =
          controller.messages[controller.messages.length - 1 - index];
      final isUser = message.role == ChatRole.user;
      return Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Container(
            margin: const EdgeInsets.only(bottom: 24),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: isUser ? PerantColors.ink : PerantColors.soft,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isUser
                      ? '你'
                      : message.source == ChatEntrySource.localPython
                      ? '本地工具 · Python'
                      : message.source == ChatEntrySource.container
                      ? '容器协作 · ${controller.profile?.displayName ?? '模型'}'
                      : controller.profile?.displayName ?? '模型',
                  style: TextStyle(
                    fontSize: 12,
                    color: isUser ? Colors.white70 : PerantColors.muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                if (message.text.isEmpty)
                  Text(
                    controller.isSending ? '正在等待模型回复…' : '本次未收到文字。',
                    style: const TextStyle(color: PerantColors.muted),
                  )
                else if (isUser)
                  SelectableText(
                    message.text,
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.7,
                      color: Colors.white,
                    ),
                  )
                else
                  MarkdownBody(
                    data: message.text,
                    selectable: true,
                    imageBuilder: (uri, title, alt) => Text(alt ?? '图片预览暂不加载'),
                  ),
                if (message.documentId != null && !controller.isSending)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TextButton.icon(
                      onPressed: _mutationBusy
                          ? null
                          : () async {
                              final matches = controller.documents.where(
                                (document) => document.id == message.documentId,
                              );
                              if (matches.isEmpty) {
                                _toast('文档已从资料库删除。');
                                return;
                              }
                              await _openDocument(matches.first);
                            },
                      icon: const Icon(Icons.description_outlined, size: 18),
                      label: const Text('打开文档'),
                    ),
                  )
                else if (!isUser &&
                    message.source != ChatEntrySource.localPython &&
                    message.text.isNotEmpty &&
                    !controller.isSending)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TextButton.icon(
                      onPressed: _mutationBusy
                          ? null
                          : () => _newDocument(markdown: message.text),
                      icon: const Icon(Icons.note_add_outlined, size: 18),
                      label: const Text('保存为文档'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _documents() {
    final query = _search.text.toLowerCase();
    final documents = controller.documents
        .where((d) => '${d.title}\n${d.markdown}'.toLowerCase().contains(query))
        .toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('全部文档', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              const Text(
                '当前支持 TXT 与 Markdown。语义检索、Word 与 PDF 导入将在后续开放。',
                style: TextStyle(color: PerantColors.muted),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: _mutationBusy ? null : () => _newDocument(),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('新建文档'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _mutationBusy ? null : _importDocument,
                    icon: const Icon(Icons.file_upload_outlined, size: 18),
                    label: const Text('导入 TXT / MD'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '查找标题或正文',
                ),
              ),
              const SizedBox(height: 24),
              Text(
                '${documents.length} 份文档',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              if (documents.isEmpty)
                _EmptyState(
                  icon: Icons.folder_open_outlined,
                  title: query.isEmpty ? '还没有资料' : '没有找到匹配的文档',
                  body: query.isEmpty ? '从一份空白文档开始，或导入已有的文本。' : '试试另一个关键词。',
                )
              else
                ...documents.map(_documentTile),
            ],
          ),
        ),
      ),
    );
  }

  Widget _documentTile(MarkdownDocument document) => ListTile(
    contentPadding: const EdgeInsets.symmetric(vertical: 4),
    leading: Container(
      width: 42,
      height: 46,
      decoration: BoxDecoration(
        color: PerantColors.soft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.description_outlined, color: PerantColors.accent),
    ),
    title: Text(document.title, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      'Markdown · v${document.revision} · ${document.isConfirmed ? '已确认' : '草稿'}',
      style: const TextStyle(fontSize: 12),
    ),
    onTap: () => _openDocument(document),
    trailing: PopupMenuButton<String>(
      tooltip: '文档操作',
      enabled: !_mutationBusy,
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'copy', child: Text('复制 Markdown')),
        const PopupMenuItem(value: 'delete', child: Text('删除文档')),
      ],
      onSelected: (value) async {
        if (value == 'copy') {
          await Clipboard.setData(ClipboardData(text: document.markdown));
          _toast('Markdown 已复制');
          return;
        }
        final approved = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('删除这份文档？'),
            content: Text('“${document.title}”将从本机资料中删除。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('保留'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        if (approved == true) {
          try {
            await controller.deleteDocument(document.id);
          } catch (_) {
            _toast('删除未能保存，请重试。');
          }
        }
      },
    ),
  );

  Widget _tasks() => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('任务记录', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            const Text(
              '查看请求状态与中断原因。中断的请求不会自动重新发送。',
              style: TextStyle(color: PerantColors.muted),
            ),
            const SizedBox(height: 32),
            if (controller.tasks.isEmpty)
              const _EmptyState(
                icon: Icons.checklist_rounded,
                title: '还没有任务记录',
                body: '从对话发起请求或本地整理任务，进度和结果会记录在这里。',
              )
            else
              ...controller.tasks.map(
                (task) => Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: PerantColors.soft,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              task.title,
                              style: Theme.of(context).textTheme.titleMedium,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            task.status.label,
                            style: const TextStyle(
                              fontSize: 12,
                              color: PerantColors.accent,
                            ),
                          ),
                        ],
                      ),
                      if (task.statusDetail != null) ...[
                        const SizedBox(height: 12),
                        Text(task.statusDetail!),
                      ],
                      const SizedBox(height: 10),
                      Text(
                        _time(task.createdAt),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _Mark extends StatelessWidget {
  const _Mark({required this.size});
  final double size;
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'PerAnt',
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: PerantColors.accent,
        borderRadius: BorderRadius.circular(size * .28),
      ),
      child: Icon(Icons.grain_rounded, color: Colors.white, size: size * .7),
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 44),
    child: Column(
      children: [
        Icon(icon, size: 36, color: PerantColors.muted),
        const SizedBox(height: 16),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          body,
          textAlign: TextAlign.center,
          style: const TextStyle(color: PerantColors.muted),
        ),
      ],
    ),
  );
}

String _time(DateTime value) =>
    '${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
