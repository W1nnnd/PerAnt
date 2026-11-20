// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:file_picker/file_picker.dart' show FilePicker;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perant_core/perant_core.dart';

import '../application/material_import.dart';
import '../application/meeting_minutes.dart';
import '../application/workspace_controller.dart';
import '../data/workspace_state.dart';
import '../data/portable_documents.dart';
import 'document_editor.dart';
import 'companion_avatar.dart';
import 'computer_workspace_page.dart';
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

class _WorkspaceShellState extends State<WorkspaceShell>
    with WidgetsBindingObserver {
  int _section = 0;
  bool _containerEnabled = false;
  String? _containerIntentText;
  final _scaffold = GlobalKey<ScaffoldState>();
  final _composer = TextEditingController();
  final _search = TextEditingController();
  final _composerFocus = FocusNode();
  bool _doing = false;
  bool _resting = false;
  bool _quickOpen = false;
  bool _foreground = true;
  bool _authorizing = false;
  int _starterSet = 0;
  int _filesTab = 0;
  int _pokeToken = 0;
  String? _pokeText;
  ProviderProfile? _chatGrantProfile;
  String? _chatGrantConversation;
  String? _pendingCommand;
  Completer<bool>? _commandDecision;
  static const _names = ['对话', '电脑', '文件'];
  static const _icons = [
    Icons.chat_bubble_outline_rounded,
    Icons.computer_outlined,
    Icons.folder_outlined,
  ];
  WorkspaceController get controller => widget.controller;
  bool get _mutationBusy =>
      controller.isSending ||
      controller.isConfiguring ||
      controller.manualTerminalActive;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _composer.addListener(_composerChanged);
    _composerFocus.addListener(_composerChanged);
  }

  void _composerChanged() {
    if (mounted)
      setState(() {
        if (_composer.text == '/') _quickOpen = true;
        if (_composer.text.trim() != _containerIntentText)
          _containerEnabled = false;
      });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted)
      setState(() => _foreground = state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _composerFocus.removeListener(_composerChanged);
    _composerFocus.dispose();
    final pending = _commandDecision;
    if (pending != null && !pending.isCompleted) pending.complete(false);
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
            label: '文档资料',
            extensions: ['md', 'markdown', 'txt', 'docx', 'pdf'],
            mimeTypes: [
              'text/plain',
              'text/markdown',
              'application/pdf',
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            ],
            uniformTypeIdentifiers: [
              'public.plain-text',
              'net.daringfireball.markdown',
              'org.openxmlformats.wordprocessingml.document',
              'com.adobe.pdf',
            ],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > materialByteLimit)
        throw const FormatException('文件超过 10 MB。');
      final bytes = await file.readAsBytes();
      if (bytes.length > materialByteLimit)
        throw const FormatException('文件超过 10 MB。');
      final ext = file.name.split('.').last.toLowerCase();
      final text = switch (ext) {
        'docx' => await compute(importDocx, bytes),
        'pdf' => importPdfPages(
          await const MethodChannel('dev.perant/pdf')
                  .invokeListMethod<String>('readPages', bytes) ??
              [],
        ),
        'md' || 'markdown' || 'txt' => checkMaterialText(utf8.decode(bytes)),
        _ => throw const FormatException('请选择 TXT、Markdown、DOCX 或文字 PDF。'),
      };
      final document = await controller.createDocument(
        title: file.name,
        markdown: text,
      );
      if (mounted) await _openDocument(document);
    } on FormatException catch (error) {
      _toast(error.message);
    } on PlatformException catch (error) {
      _toast(error.message ?? '无法从文件中提取文字。');
    } catch (_) {
      _toast('无法导入，请检查文件格式和设备存储空间。');
    }
  }

  Future<void> _portableFiles(String action) async {
    try {
      if (action == 'restore') {
        final file = await openFile(
          acceptedTypeGroups: [
            const XTypeGroup(
              label: '资料备份',
              extensions: ['json'],
              mimeTypes: ['application/json'],
              uniformTypeIdentifiers: ['public.json'],
            ),
          ],
        );
        if (file == null) return;
        if (await file.length() > backupByteLimit)
          throw const FormatException('资料备份超过 64 MB。');
        final incoming = await compute(
          readWorkspaceBackup,
          await file.readAsBytes(),
        );
        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('用备份替换本机工作区？'),
            content: Text(
              '备份含 ${incoming.documents.length} 份文档及其历史、${incoming.messages.length} 条消息和 ${incoming.tasks.length} 项任务。本机现有资料、对话、任务记录与偏好将被替换。恢复后需要重新配置模型与授权。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('替换并恢复'),
              ),
            ],
          ),
        );
        if (ok != true || !mounted) return;
        await controller.restoreWorkspace(incoming);
        _chatGrantProfile = null;
        _chatGrantConversation = null;
        _containerEnabled = false;
        _containerIntentText = null;
        _composer.clear();
        _search.clear();
        _toast('工作区已恢复。');
        return;
      }
      final backup = action == 'backup';
      final bytes = backup
          ? await compute(backupWorkspace, controller.state)
          : localDiagnostics(controller.state, defaultTargetPlatform.name);
      if (!mounted) return;
      final result = await FilePicker.saveFile(
        fileName: backup ? 'perant-workspace.json' : 'perant-diagnostics.json',
        bytes: bytes,
        mimeType: 'application/json',
      );
      if (result != null) _toast(backup ? '工作区已备份。' : '已导出本机诊断统计。');
    } on FormatException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('操作失败，请检查文件格式、位置和可用空间。');
    }
  }

  Future<void> _meeting() async {
    final docs = controller.documents;
    final selected = <String>{};
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) {
          final size = docs
              .where((d) => selected.contains(d.id))
              .fold(0, (n, d) => n + d.markdown.runes.length);
          return AlertDialog(
            title: const Text('从本机资料整理会议纪要'),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('已选 ${selected.length}/5 份 · $size/20000 字'),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final d in docs)
                          CheckboxListTile(
                            value: selected.contains(d.id),
                            title: Text(d.title),
                            subtitle: Text('版本 ${d.revision}'),
                            onChanged:
                                !selected.contains(d.id) && selected.length == 5
                                ? null
                                : (on) => update(() {
                                    if (on == true) {
                                      selected.add(d.id);
                                    } else {
                                      selected.remove(d.id);
                                    }
                                  }),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: selected.isEmpty || size > materialCharacterLimit
                    ? null
                    : () => Navigator.pop(dialog, true),
                child: const Text('生成本机草稿'),
              ),
            ],
          );
        },
      ),
    );
    if (approved != true || !mounted) return;
    try {
      final materials = docs.where((d) => selected.contains(d.id)).toList();
      for (final d in materials) {
        if (!controller.documents.any(
          (current) => current.id == d.id && current.revision == d.revision,
        )) {
          throw const FormatException('所选资料已有变化，请重新选择。');
        }
      }
      final result = await controller.createDocument(
        title: '会议纪要',
        markdown: meetingOutline(materials),
      );
      if (mounted) await _openDocument(result);
    } on FormatException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('会议纪要未能保存，请检查设备空间。');
    }
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _mutationBusy || controller.isTesting || _authorizing)
      return;
    if (!controller.canChat) {
      _composerFocus.unfocus();
      setState(() => _section = 3);
      _toast('先连接你的模型，输入的文字会保留。');
      return;
    }
    final selected = controller.profile!;
    var useContainer = _containerEnabled && _containerIntentText == text;
    var remember = false;
    if (!_hasChatGrant || useContainer) {
      _composerFocus.unfocus();
      _authorizing = true;
      bool? approved;
      try {
        approved = await _sheet<bool>(
          title: '允许本次任务使用云端模型？',
          child: StatefulBuilder(
            builder: (c, update) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${selected.displayName} · ${selected.modelId}',
                  style: Theme.of(c).textTheme.titleMedium,
                ),
                Text(
                  selected.baseUrl.host,
                  style: const TextStyle(
                    fontSize: 12,
                    color: PerantColors.muted,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  '将要发送',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: PerantColors.soft,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    text,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  useContainer
                      ? '本次允许模型操作 Linux 应用与浏览器的键鼠和文字输入，并浏览和修改共享 /workspace 文件。桌面及网页截图、文件内容、工具输出和容器协作历史会发送到以上服务。通过命令工具发起的 Shell 和关闭桌面会单独请求确认。登录、上传或提交等操作仍需你的明确指示。请选择支持图像和工具调用的模型；API 调用由你的服务账户计费。'
                      : '将发送这段文字及本次对话保留的普通聊天上下文，不包含电脑协作历史、资料库文件或长期记忆。API 调用由你的服务账户计费。',
                  style: const TextStyle(
                    fontSize: 13,
                    color: PerantColors.muted,
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('允许模型操作容器电脑'),
                  subtitle: const Text(
                    '桌面与浏览器操作、截图及共享文件',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: useContainer,
                  onChanged: (v) => update(() {
                    useContainer = v == true;
                    if (useContainer) remember = false;
                  }),
                ),
                if (!useContainer)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      '这次对话里的聊天，不用每次问我',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: const Text(
                      '仅限本次运行、同一模型；电脑操作仍单独授权',
                      style: TextStyle(fontSize: 11),
                    ),
                    value: remember,
                    onChanged: (v) => update(() => remember = v == true),
                  ),
              ],
            ),
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('改一改再发'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('授权并发送'),
            ),
          ],
        );
      } finally {
        _authorizing = false;
      }
      if (approved != true || !mounted) {
        if (mounted)
          setState(() {
            _containerEnabled = false;
            _containerIntentText = null;
          });
        return;
      }
      if (!identical(selected, controller.profile) ||
          !controller.canChat ||
          _mutationBusy) {
        _toast('模型或任务状态已变化，请重新确认后发送。');
        return;
      }
    }
    if (remember && !useContainer) {
      _chatGrantProfile = selected;
      _chatGrantConversation = controller.activeConversation.id;
    }
    setState(() {
      _containerEnabled = false;
      _containerIntentText = null;
      _resting = false;
      _quickOpen = false;
    });
    _composer.clear();
    _composerFocus.unfocus();
    unawaited(_haptic());
    try {
      await controller.send(
        text,
        cloudApproved: true,
        containerEnabled: useContainer,
        approveContainerCommand: _approveContainerCommand,
      );
    } catch (_) {
      if (mounted) {
        _toast('任务未能开始，请保留文字后重试。');
        _composer.text = text;
      }
    } finally {
      final pending = _commandDecision;
      if (pending != null && !pending.isCompleted) pending.complete(false);
      if (mounted)
        setState(() {
          _pendingCommand = null;
          _commandDecision = null;
        });
    }
  }

  Future<bool> _approveContainerCommand(String command) async {
    if (!mounted) return false;
    final decision = Completer<bool>();
    setState(() {
      _pendingCommand = command;
      _commandDecision = decision;
    });
    unawaited(_haptic());
    try {
      return await decision.future;
    } finally {
      if (mounted && identical(_commandDecision, decision)) {
        setState(() {
          _pendingCommand = null;
          _commandDecision = null;
        });
      }
    }
  }

  Future<void> _showCommandSheet() async {
    final decision = _commandDecision;
    final command = _pendingCommand;
    if (decision == null || decision.isCompleted || command == null) return;
    final stopping = command.startsWith('关闭 Linux 图形桌面');
    final approved = await _sheet<bool>(
      title: stopping ? '关闭 Linux 桌面？' : '运行这条 Linux 命令？',
      child: ListenableBuilder(
        listenable: controller,
        builder: (c, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              stopping
                  ? '请先确认 Linux 应用中需要保留的内容已经保存。'
                  : '模型请求在本机 /workspace 中执行。这条命令可能修改文件或访问网络；PRoot 不提供强隔离。',
              style: const TextStyle(fontSize: 13, color: PerantColors.muted),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: PerantColors.soft,
                borderRadius: BorderRadius.circular(14),
              ),
              child: SelectableText(
                command,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
            if (!controller.isContainerTaskRunning)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('本次任务已结束，不会执行这条命令。'),
              ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('拒绝'),
        ),
        ListenableBuilder(
          listenable: controller,
          builder: (c, _) => FilledButton(
            onPressed:
                controller.isContainerTaskRunning && !decision.isCompleted
                ? () => Navigator.pop(context, true)
                : null,
            child: Text(stopping ? '关闭桌面' : '运行命令'),
          ),
        ),
      ],
    );
    if (approved != null &&
        identical(_commandDecision, decision) &&
        !decision.isCompleted) {
      decision.complete(approved && controller.isContainerTaskRunning);
    }
  }

  void _stopTask() {
    controller.cancelActiveTask();
    final decision = _commandDecision;
    if (decision != null && !decision.isCompleted) decision.complete(false);
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
    setState(() {
      _resting = false;
      _quickOpen = false;
    });
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

  TaskRecord? get _conversationTask {
    final ids = controller.messages.map((m) => m.id).toSet();
    final actionTasks = controller.containerActions
        .map((a) => a.taskId)
        .toSet();
    for (final task in controller.tasks) {
      if (actionTasks.contains(task.id) ||
          (task.cloudAuthorization?.currentSources.any(
                (s) => ids.contains(s.sourceId),
              ) ??
              false) ||
          controller.messages.any(
            (m) =>
                m.source == ChatEntrySource.localPython &&
                m.createdAt == task.createdAt,
          ))
        return task;
    }
    return null;
  }

  CompanionMood get _mood {
    if (_pendingCommand != null) return CompanionMood.waiting;
    if (controller.isSending &&
        !controller.isLocalTaskRunning &&
        !controller.isContainerTaskRunning)
      return CompanionMood.thinking;
    if (controller.isSending || controller.isConfiguring)
      return CompanionMood.working;
    if (_resting) return CompanionMood.paused;
    final task = _conversationTask;
    if (task?.status == TaskStatus.completed) return CompanionMood.happy;
    if (task?.status == TaskStatus.manualControl) return CompanionMood.takeover;
    return CompanionMood.idle;
  }

  String get _status => switch (_mood) {
    CompanionMood.thinking => '正在准备回复',
    CompanionMood.working => controller.isConfiguring ? '正在保存设置' : '正在做事',
    CompanionMood.waiting => '等你确认',
    CompanionMood.paused => '坐一会儿',
    CompanionMood.takeover => '由你接管',
    CompanionMood.happy => '成果已放好',
    _ => '',
  };

  bool get _hasChatGrant =>
      _chatGrantProfile != null &&
      identical(_chatGrantProfile, controller.profile) &&
      _chatGrantConversation == controller.activeConversation.id;

  Future<void> _haptic() async {
    if (controller.state.hapticsEnabled) await HapticFeedback.selectionClick();
  }

  void _poke() {
    unawaited(_haptic());
    if (controller.isSending || controller.isConfiguring) return;
    final token = ++_pokeToken;
    setState(() => _pokeText = _resting ? '好，陪你坐一会儿。' : '我在呢。想聊聊，还是一起做点事？');
    unawaited(
      Future<void>.delayed(const Duration(seconds: 3), () {
        if (mounted && token == _pokeToken) setState(() => _pokeText = null);
      }),
    );
  }

  Future<T?> _sheet<T>({
    required String title,
    required Widget child,
    List<Widget> actions = const [],
  }) => showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: BoxConstraints(
      maxWidth: 480,
      maxHeight: MediaQuery.sizeOf(context).height * .88,
    ),
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: '关闭弹层',
                onPressed: () => Navigator.pop(sheetContext),
                icon: const Icon(Icons.close, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Flexible(child: SingleChildScrollView(child: child)),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 20),
            Row(
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(child: actions[i]),
                ],
              ],
            ),
          ],
        ],
      ),
    ),
  );

  Future<void> _openMenu() async {
    final action = await _sheet<String>(
      title: 'PerAnt',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('陪你想，一起做。', style: TextStyle(color: PerantColors.muted)),
          const SizedBox(height: 16),
          _menuRow(Icons.add, '开始新对话', 'new', enabled: !_mutationBusy),
          const Divider(height: 24),
          const Text(
            '最近对话',
            style: TextStyle(fontSize: 12, color: PerantColors.muted),
          ),
          for (final thread in controller.conversations.take(5))
            _menuRow(
              Icons.chat_bubble_outline_rounded,
              thread.title,
              'thread:${thread.id}',
              enabled: !_mutationBusy,
            ),
          const Divider(height: 24),
          _menuRow(Icons.face_outlined, '认识小蚁', 'persona'),
          _menuRow(Icons.tune_rounded, '模型与偏好设置', 'settings'),
          _menuRow(Icons.checklist_rounded, '任务与操作记录', 'tasks'),
          _menuRow(Icons.info_outline, '关于 PerAnt', 'about'),
        ],
      ),
    );
    if (action == null || !mounted) return;
    if (action.startsWith('thread:')) {
      await controller.selectConversation(action.substring(7));
      if (!mounted) return;
      _composer.clear();
      setState(() {
        _section = 0;
        _resting = false;
        _chatGrantProfile = null;
      });
      return;
    }
    switch (action) {
      case 'new':
        await _startConversation();
      case 'persona':
        await _showPersona();
      case 'settings':
        setState(() => _section = 3);
      case 'tasks':
        setState(() => _section = 4);
      case 'about':
        await _sheet<void>(
          title: '关于 PerAnt',
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('一个陪你想，也陪你做的个人智能体。'),
              SizedBox(height: 12),
              Text(
                'PerAnt 来自 Personal Agent，也藏着一点 Parent 的亲近感。重要决定由你做主，任务进展和操作范围会清楚说明。',
              ),
              SizedBox(height: 12),
              Text(
                '当前为 Android 开发预览版。本地小模型、长期后台、语义检索和 iOS 运行时仍在开发。自研代码采用 GPL-3.0-only。',
                style: TextStyle(color: PerantColors.muted),
              ),
            ],
          ),
        );
    }
  }

  Widget _menuRow(
    IconData icon,
    String title,
    String value, {
    bool enabled = true,
  }) => Builder(
    builder: (sheetContext) => ListTile(
      contentPadding: EdgeInsets.zero,
      minTileHeight: 50,
      leading: Icon(icon, color: PerantColors.accent, size: 20),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14),
      ),
      trailing: const Icon(
        Icons.chevron_right,
        size: 18,
        color: PerantColors.muted,
      ),
      enabled: enabled,
      onTap: () => Navigator.pop(sheetContext, value),
    ),
  );

  Future<void> _showPersona() async {
    final name = TextEditingController(text: controller.state.companionName);
    var tone = controller.state.companionTone;
    var haptics = controller.state.hapticsEnabled;
    String? error;
    var saving = false;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.sizeOf(context).height * .88,
        ),
        builder: (sheetContext) => ListenableBuilder(
          listenable: controller,
          builder: (context, _) => StatefulBuilder(
            builder: (c, update) => Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                0,
                20,
                20 + MediaQuery.viewInsetsOf(c).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '认识小蚁',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭弹层',
                        onPressed: saving ? null : () => Navigator.pop(c),
                        icon: const Icon(Icons.close, size: 20),
                      ),
                    ],
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: CompanionAvatar(
                              diameter: 104,
                              mood: _mood,
                              label: controller.state.companionName,
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            '一个陪你想，也陪你做的个人智能体。',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'PerAnt 来自 Personal Agent，也藏着一点 Parent 的亲近感。能一起做事，也能聊聊日常。要紧的决定留给你。',
                            style: TextStyle(color: PerantColors.muted),
                          ),
                          const SizedBox(height: 20),
                          TextField(
                            controller: name,
                            maxLength: 12,
                            enabled: !saving,
                            decoration: const InputDecoration(
                              labelText: '怎么称呼小蚁',
                            ),
                          ),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String>(
                            initialValue: tone,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: '界面语气',
                            ),
                            items: [
                              for (final t in ['随和搭子', '利落助手', '脑洞伙伴'])
                                DropdownMenuItem(value: t, child: Text(t)),
                            ],
                            onChanged: saving
                                ? null
                                : (v) => update(() => tone = v!),
                          ),
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text(
                              '称呼和语气保存在本机，用于界面问候与轻互动；不会改写模型提示词。',
                              style: TextStyle(
                                fontSize: 12,
                                color: PerantColors.muted,
                              ),
                            ),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('震动反馈'),
                            value: haptics,
                            onChanged: saving
                                ? null
                                : (v) => update(() => haptics = v),
                          ),
                          if (error != null)
                            Text(
                              error!,
                              style: const TextStyle(
                                color: PerantColors.warning,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: saving || _mutationBusy
                        ? null
                        : () async {
                            update(() {
                              saving = true;
                              error = null;
                            });
                            try {
                              await controller.saveCompanionPreferences(
                                name: name.text,
                                tone: tone,
                                hapticsEnabled: haptics,
                              );
                              if (c.mounted) Navigator.pop(c);
                            } on ArgumentError {
                              if (c.mounted)
                                update(() => error = '请填写 1–12 字的称呼。');
                            } catch (_) {
                              if (c.mounted)
                                update(() => error = '偏好未能保存，请结束当前任务或检查设备空间。');
                            } finally {
                              if (c.mounted) update(() => saving = false);
                            }
                          },
                    child: Text(saving ? '正在保存…' : '就这样认识你'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } finally {
      // The route's closing animation may still reference its controller.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      name.dispose();
    }
  }

  Future<void> _startConversation() async {
    try {
      await controller.newConversation();
      _composer.clear();
      if (mounted)
        setState(() {
          _section = 0;
          _resting = false;
          _quickOpen = false;
          _chatGrantProfile = null;
          _chatGrantConversation = null;
          _containerEnabled = false;
          _containerIntentText = null;
          _pokeText = null;
        });
    } catch (_) {
      _toast('请等待当前回复或配置保存完成，再开始新对话。');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      controller,
      controller.desktop,
      controller.browser,
    ]),
    builder: (context, _) {
      final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
      final availableHeight =
          MediaQuery.sizeOf(context).height -
          MediaQuery.viewInsetsOf(context).bottom -
          MediaQuery.paddingOf(context).vertical;
      final home =
          _section == 0 && controller.messages.isEmpty && !keyboardOpen;
      final disc = home
          ? ((MediaQuery.sizeOf(context).height -
                        MediaQuery.paddingOf(context).vertical -
                        600) /
                    1.3)
                .clamp(84.0, 200.0)
          : _section == 0 && !keyboardOpen
          ? 76.0
          : 52.0;
      final content = switch (_section) {
        0 => _conversation(keyboardOpen: keyboardOpen),
        1 => ComputerWorkspacePage(
          controller: controller,
          onViewDesktop: _showDesktop,
          onOpenBrowser: _showBrowser,
          onOpenTerminal: _showRuntime,
          onOpenFiles: _showContainer,
        ),
        2 => _documents(),
        3 => Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.face_outlined,
                  color: PerantColors.accent,
                ),
                title: const Text('称呼与界面偏好'),
                subtitle: Text(
                  '${controller.state.companionName} · ${controller.state.companionTone}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _showPersona,
              ),
            ),
            Expanded(
              child: ProviderSettings(
                key: ValueKey(controller.profile?.presetId),
                controller: controller,
              ),
            ),
          ],
        ),
        _ => _tasks(),
      };
      return PopScope(
        canPop: _section == 0 && !_quickOpen,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) {
            if (_composerFocus.hasFocus) _composerFocus.unfocus();
            setState(() {
              _quickOpen = false;
              _section = 0;
            });
          }
        },
        child: Scaffold(
          key: _scaffold,
          backgroundColor: PerantColors.paper,
          body: SafeArea(
            bottom: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  children: [
                    _assistantHeader(
                      disc,
                      compact: keyboardOpen && availableHeight < 260,
                    ),
                    Expanded(child: content),
                    if (_section != 0 && !keyboardOpen && controller.isSending)
                      _taskDock(),
                  ],
                ),
              ),
            ),
          ),
          bottomNavigationBar: keyboardOpen ? null : _navigation(),
        ),
      );
    },
  );

  Widget _assistantHeader(double disc, {bool compact = false}) {
    if (compact)
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              IconButton(
                tooltip: '菜单',
                onPressed: _openMenu,
                icon: const Icon(Icons.menu_rounded, size: 20),
              ),
              Expanded(
                child: Text(
                  controller.state.companionName,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _mutationBusy ? null : _startConversation,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新对话'),
              ),
            ],
          ),
        ),
      );
    return SizedBox(
      width: double.infinity,
      height: disc * 1.314 + 40,
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          Positioned(
            left: 12,
            top: 10,
            child: _topButton(
              icon: Icons.menu_rounded,
              label: '菜单',
              onPressed: _openMenu,
            ),
          ),
          Positioned(
            right: 12,
            top: 10,
            child: OutlinedButton.icon(
              onPressed: _mutationBusy ? null : _startConversation,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('新对话', style: TextStyle(fontSize: 13)),
              style: OutlinedButton.styleFrom(
                backgroundColor: PerantColors.surface,
                minimumSize: const Size(88, 44),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: const StadiumBorder(),
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CompanionAvatar(
                diameter: disc,
                mood: _mood,
                animate: _foreground,
                onTap: _poke,
                label:
                    '${controller.state.companionName}，${_status.isEmpty ? '等你开始' : _status}',
              ),
              Transform.translate(
                offset: const Offset(0, -8),
                child: SizedBox(
                  height: 40,
                  child: TextButton(
                    onPressed: _showPersona,
                    style: TextButton.styleFrom(
                      backgroundColor: PerantColors.surface,
                      foregroundColor: PerantColors.ink,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      shape: const StadiumBorder(),
                      elevation: 1,
                      shadowColor: const Color(0x22455C3E),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: _mood == CompanionMood.waiting
                                ? const Color(0xFFCE943B)
                                : PerantColors.success,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '${controller.state.companionName}${_status.isEmpty ? '' : ' · $_status'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        if (_status.isEmpty) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.keyboard_arrow_down, size: 14),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _topButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) => DecoratedBox(
    decoration: BoxDecoration(
      color: PerantColors.surface,
      shape: BoxShape.circle,
      border: Border.all(color: PerantColors.line),
      boxShadow: const [
        BoxShadow(
          color: Color(0x12455C3E),
          blurRadius: 16,
          offset: Offset(0, 5),
        ),
      ],
    ),
    child: IconButton(
      tooltip: label,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
    ),
  );

  Widget _navigation() => SafeArea(
    top: false,
    child: Center(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SizedBox(
          height: 64,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (var i = 0; i < 3; i++)
                Expanded(
                  child: Semantics(
                    selected: _section == i,
                    child: InkWell(
                      key: ValueKey('nav-$i'),
                      onTap: () {
                        unawaited(_haptic());
                        setState(() {
                          _section = i;
                          _quickOpen = false;
                        });
                      },
                      child: Tooltip(
                        message: _names[i],
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 54,
                              height: 30,
                              decoration: BoxDecoration(
                                color: _section == i
                                    ? PerantColors.tintStrong
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Icon(
                                _icons[i],
                                color: _section == i
                                    ? PerantColors.accentDark
                                    : PerantColors.muted,
                                size: 21,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              _names[i],
                              style: TextStyle(
                                fontSize: 11,
                                color: _section == i
                                    ? PerantColors.accentDark
                                    : PerantColors.muted,
                                fontWeight: _section == i
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _conversation({required bool keyboardOpen}) => Column(
    children: [
      Expanded(
        child: LayoutBuilder(
          builder: (context, box) => Stack(
            children: [
              Positioned.fill(
                child: controller.messages.isEmpty
                    ? _emptyConversation()
                    : _messageList(),
              ),
              if (_quickOpen && box.maxHeight >= 96)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: _quickCommands(),
                ),
            ],
          ),
        ),
      ),
      if (controller.error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text(
            controller.error!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: PerantColors.warning),
          ),
        ),
      _composerPanel(keyboardOpen),
    ],
  );

  String get _homeSubtitle => switch (controller.state.companionTone) {
    '利落助手' => '先理清目标，再一起完成。',
    '脑洞伙伴' => '从一个小念头，试试新的可能。',
    _ => '陪你想，一起做。',
  };

  Widget _emptyConversation() => LayoutBuilder(
    builder: (context, box) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: (box.maxHeight - 4).clamp(0, double.infinity),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _resting ? '好，坐一会儿。' : '嗨，我是${controller.state.companionName}。',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 24,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _pokeText ?? (_resting ? '准备好了，随时一起继续。' : _homeSubtitle),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: PerantColors.muted),
            ),
            SizedBox(height: box.maxHeight < 380 ? 16 : 20),
            if (!_resting) ...[
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: PerantColors.soft,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          for (var i = 0; i < 2; i++)
                            Expanded(
                              child: InkWell(
                                onTap: () => setState(() => _doing = i == 1),
                                borderRadius: BorderRadius.circular(13),
                                child: Container(
                                  height: 40,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: _doing == (i == 1)
                                        ? PerantColors.surface
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(13),
                                  ),
                                  child: Text(
                                    i == 0 ? '聊一会儿' : '一起做事',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: _doing == (i == 1)
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                      color: _doing == (i == 1)
                                          ? PerantColors.ink
                                          : PerantColors.muted,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: PerantColors.soft,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: IconButton(
                      onPressed: () =>
                          setState(() => _starterSet = 1 - _starterSet),
                      tooltip: '换一组开场',
                      icon: const Icon(Icons.refresh_rounded, size: 20),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (_doing) ...[
                _starter(
                  Icons.description_outlined,
                  '整理一段文字',
                  '保留原文，整理为 Markdown',
                  _runLocalTextTask,
                ),
                _starter(Icons.language, '保存一页网页', '浏览、阅读，把正文收好', _showBrowser),
                _starter(
                  Icons.terminal_rounded,
                  '一起写个小脚本',
                  '在电脑中创建并运行 Python',
                  () => _startPrompt(
                    '请在电脑的 /workspace 中创建 hello.py，输出一条问候，再运行并检查结果。',
                    container: true,
                  ),
                ),
              ] else if (_starterSet == 0) ...[
                _starter(
                  Icons.layers_outlined,
                  '脑子有点乱',
                  '陪我把想法捋一捋',
                  () => _startPrompt('我脑子有点乱，陪我把眼前的想法和事情捋一捋。'),
                ),
                _starter(
                  Icons.auto_awesome_outlined,
                  '来一点小灵感',
                  '给今天一个有趣的开场',
                  () => _startPrompt('给我一个十分钟就能试试的小灵感。'),
                ),
                _starter(
                  Icons.chat_bubble_outline,
                  '先轻松一下',
                  '来个不费脑的小互动',
                  () => _startPrompt('我们来玩一个三词故事吧，请先给我三个词。'),
                ),
              ] else ...[
                _starter(
                  Icons.lightbulb_outline,
                  '换个角度想想',
                  '一起寻找另一种可能',
                  () => _startPrompt('我想换个角度思考一件事，请先问我一个简单的问题。'),
                ),
                _starter(
                  Icons.checklist_rounded,
                  '安排一件小事',
                  '把想做的事拆成几步',
                  () => _startPrompt('陪我安排一件今天能完成的小事，请先问问我的目标。'),
                ),
                _starter(
                  Icons.edit_outlined,
                  '写一句今天',
                  '给此刻留一小段文字',
                  () => _startPrompt('陪我给今天写一句话，请用一个问题帮我开始。'),
                ),
              ],
            ],
            const SizedBox(height: 5),
            TextButton.icon(
              onPressed: controller.isSending
                  ? null
                  : () {
                      unawaited(_haptic());
                      setState(() {
                        _resting = !_resting;
                        _pokeText = null;
                      });
                    },
              icon: Icon(
                _resting ? Icons.wb_sunny_outlined : Icons.coffee_outlined,
                size: 16,
              ),
              label: Text(
                _resting ? '准备开工' : '坐一会儿',
                style: const TextStyle(fontSize: 12, color: PerantColors.muted),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _starter(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Material(
      color: PerantColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: PerantColors.line),
      ),
      child: InkWell(
        onTap: _mutationBusy ? null : onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: PerantColors.soft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: PerantColors.accentDark, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      subtitle,
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
      ),
    ),
  );

  Future<void> _startPrompt(String prompt, {bool container = false}) async {
    _composer.text = prompt;
    setState(() {
      _containerEnabled = container;
      _containerIntentText = container ? prompt.trim() : null;
      _resting = false;
      _quickOpen = false;
    });
    await _send();
  }

  Future<void> _showBrowser() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => ComputerBrowserScreen(controller: controller),
    ),
  );

  Future<void> _composerActions() async {
    final action = await _sheet<String>(
      title: '添加与工具',
      child: Column(
        children: [
          _menuRow(
            Icons.file_upload_outlined,
            '导入文档资料',
            'import',
            enabled: !_mutationBusy,
          ),
          _menuRow(
            Icons.note_add_outlined,
            '新建文档',
            'document',
            enabled: !_mutationBusy,
          ),
          _menuRow(
            Icons.description_outlined,
            '本地整理为 Markdown',
            'local',
            enabled: !_mutationBusy && !controller.isTesting,
          ),
          _menuRow(
            Icons.terminal_rounded,
            '本地终端',
            'terminal',
            enabled: !_mutationBusy && !controller.isTesting,
          ),
        ],
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'import':
        await _importDocument();
      case 'document':
        await _newDocument();
      case 'local':
        await _runLocalTextTask();
      case 'terminal':
        await _showRuntime();
    }
  }

  Widget _quickCommands() => Container(
    margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: PerantColors.surface,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: PerantColors.line),
    ),
    child: Material(
      color: PerantColors.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Expanded(
                child: Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Text(
                    '快捷指令',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              IconButton(
                tooltip: '关闭快捷指令',
                onPressed: () => setState(() => _quickOpen = false),
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 150),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.lightbulb_outline),
                      title: const Text('聊聊灵感'),
                      onTap: () => _startPrompt('给我一个十分钟就能试试的小灵感。'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.description_outlined),
                      title: const Text('整理文字'),
                      onTap: () {
                        setState(() => _quickOpen = false);
                        unawaited(_runLocalTextTask());
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.language),
                      title: const Text('打开浏览器'),
                      onTap: () {
                        setState(() => _quickOpen = false);
                        unawaited(_showBrowser());
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.computer_outlined),
                      title: const Text('查看电脑'),
                      onTap: () {
                        setState(() => _quickOpen = false);
                        unawaited(_showDesktop());
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _composerPanel(bool keyboardOpen) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: PerantColors.surface,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: PerantColors.line),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0D24301B),
                blurRadius: 18,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                onPressed: _mutationBusy ? null : _composerActions,
                tooltip: '添加文件与工具',
                icon: const Icon(Icons.add, size: 21),
                style: IconButton.styleFrom(minimumSize: const Size(40, 44)),
              ),
              Expanded(
                child: TextField(
                  key: const ValueKey('chat-composer'),
                  controller: _composer,
                  focusNode: _composerFocus,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 20000,
                  buildCounter: (
                    context, {
                    required currentLength,
                    required isFocused,
                    maxLength,
                  }) => null,
                  enabled: !_mutationBusy,
                  decoration: const InputDecoration(
                    hintText: '聊聊今天，或交给我一件事',
                    hintMaxLines: 1,
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: PerantColors.muted,
                    ),
                    fillColor: Colors.transparent,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('composer-use-computer'),
                onPressed:
                    _mutationBusy ||
                        controller.isSending ||
                        controller.isTesting ||
                        _composer.text.trim().isEmpty
                    ? null
                    : () => unawaited(
                        _startPrompt(_composer.text.trim(), container: true),
                      ),
                tooltip: '用电脑做这件事',
                icon: const Icon(Icons.computer_outlined, size: 20),
                style: IconButton.styleFrom(minimumSize: const Size(40, 40)),
              ),
              IconButton(
                onPressed: _mutationBusy
                    ? null
                    : () {
                        _composerFocus.unfocus();
                        setState(() => _quickOpen = !_quickOpen);
                      },
                tooltip: '快捷指令',
                icon: const Text(
                  '/',
                  style: TextStyle(
                    fontSize: 20,
                    color: PerantColors.accentDark,
                  ),
                ),
                style: IconButton.styleFrom(
                  backgroundColor: PerantColors.soft,
                  minimumSize: const Size(40, 40),
                ),
              ),
              const SizedBox(width: 3),
              IconButton.filled(
                onPressed: controller.isSending
                    ? controller.canCancelActiveTask
                          ? _stopTask
                          : null
                    : _mutationBusy ||
                          controller.isTesting ||
                          _composer.text.trim().isEmpty
                    ? null
                    : _send,
                tooltip: controller.isSending ? '停止生成' : '发送消息',
                style: IconButton.styleFrom(minimumSize: const Size(40, 40)),
                icon: Icon(
                  controller.isSending
                      ? Icons.stop_rounded
                      : Icons.arrow_upward_rounded,
                  size: 20,
                ),
              ),
            ],
          ),
        ),
        if (!keyboardOpen)
          SizedBox(
            height: 36,
            child: Center(
              child: _hasChatGrant
                  ? TextButton(
                      onPressed: () => setState(() {
                        _chatGrantProfile = null;
                        _chatGrantConversation = null;
                      }),
                      child: const Text(
                        '本次对话的聊天已授权 · 撤销',
                        style: TextStyle(
                          fontSize: 11,
                          color: PerantColors.muted,
                        ),
                      ),
                    )
                  : TextButton.icon(
                      onPressed: () => setState(() => _section = 3),
                      icon: Icon(
                        controller.canChat
                            ? Icons.verified_user_outlined
                            : Icons.link,
                        size: 13,
                        color: PerantColors.muted,
                      ),
                      label: Text(
                        controller.canChat ? '每次任务单独授权' : '连接你的模型 · 也可先使用本地工具',
                        style: const TextStyle(
                          fontSize: 11,
                          color: PerantColors.muted,
                        ),
                      ),
                    ),
            ),
          ),
        if (keyboardOpen) const SizedBox(height: 6),
      ],
    ),
  );

  Widget _messageList() {
    final task = _conversationTask;
    final messages = controller.messages;
    final offset = task == null ? 0 : 1;
    return ListView.builder(
      key: ValueKey(controller.activeConversation.id),
      reverse: true,
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
      itemCount: messages.length + offset,
      itemBuilder: (context, index) {
        if (task != null && index == 0)
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _taskCard(task),
          );
        return _messageBubble(messages[messages.length - 1 - (index - offset)]);
      },
    );
  }

  Widget _messageBubble(ChatEntry message) {
    final user = message.role == ChatRole.user;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: user ? PerantColors.tintStrong : PerantColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: user ? null : Border.all(color: PerantColors.line),
        ),
        child: GestureDetector(
          onLongPress: user || message.text.isEmpty
              ? null
              : () => _messageMenu(message),
          onSecondaryTap: user || message.text.isEmpty
              ? null
              : () => _messageMenu(message),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message.text.isEmpty)
                const Text(
                  '正在准备回复…',
                  style: TextStyle(color: PerantColors.muted),
                )
              else if (user)
                SelectableText(
                  message.text,
                  style: const TextStyle(fontSize: 14.5, height: 1.65),
                )
              else
                MarkdownBody(
                  data: message.text,
                  selectable: false,
                  styleSheet: MarkdownStyleSheet(
                    p: const TextStyle(
                      fontSize: 14.5,
                      height: 1.65,
                      color: PerantColors.ink,
                    ),
                  ),
                  imageBuilder: (uri, title, alt) => Text(alt ?? '图片预览暂不加载'),
                ),
              if (message.source == ChatEntrySource.localPython && !user)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    '本地 Python 工具',
                    style: TextStyle(fontSize: 11, color: PerantColors.muted),
                  ),
                ),
              if (message.documentId != null && !controller.isSending)
                TextButton.icon(
                  onPressed: () => _openMessageDocument(message),
                  icon: const Icon(Icons.description_outlined, size: 17),
                  label: const Text('已收好，打开文档'),
                )
              else if (!user &&
                  message.text.isNotEmpty &&
                  !controller.isSending &&
                  message == controller.messages.last)
                TextButton.icon(
                  onPressed: _mutationBusy
                      ? null
                      : () => _newDocument(markdown: message.text),
                  icon: const Icon(Icons.description_outlined, size: 17),
                  label: const Text('把这个灵感收好'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openMessageDocument(ChatEntry message) async {
    final matches = controller.documents.where(
      (d) => d.id == message.documentId,
    );
    if (matches.isEmpty) {
      _toast('文档已从资料中删除。');
      return;
    }
    await _openDocument(matches.first);
  }

  Future<void> _messageMenu(ChatEntry message) async {
    final value = await _sheet<String>(
      title: '这段回复',
      child: Column(
        children: [
          _menuRow(Icons.copy_outlined, '复制文字', 'copy'),
          _menuRow(
            Icons.bookmark_border,
            message.documentId == null ? '把这个灵感收好' : '打开已保存文档',
            'save',
            enabled: !_mutationBusy,
          ),
        ],
      ),
    );
    if (value == 'copy') {
      await Clipboard.setData(ClipboardData(text: message.text));
      if (mounted) _toast('文字已复制');
    }
    if (value == 'save' && mounted) {
      if (message.documentId != null)
        await _openMessageDocument(message);
      else
        await _newDocument(markdown: message.text);
    }
  }

  Widget _taskCard(TaskRecord task) {
    final waiting =
        _pendingCommand != null && controller.isContainerTaskRunning;
    final done = task.status == TaskStatus.completed;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: PerantColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: PerantColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: waiting ? PerantColors.peach : PerantColors.soft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  waiting
                      ? Icons.terminal
                      : done
                      ? Icons.check_rounded
                      : Icons.task_alt,
                  size: 20,
                  color: waiting ? PerantColors.warning : PerantColors.accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  task.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                waiting ? '等你确认' : task.status.label,
                style: TextStyle(
                  fontSize: 11,
                  color: waiting ? PerantColors.warning : PerantColors.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (task.steps.length > 3)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '最近 3 步 · 共 ${task.steps.length} 步',
                style: const TextStyle(fontSize: 11, color: PerantColors.muted),
              ),
            ),
          for (final step in task.steps.skip(
            task.steps.length > 3 ? task.steps.length - 3 : 0,
          ))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Icon(
                    step.status == TaskStepStatus.succeeded
                        ? Icons.check_circle_outline
                        : step.status == TaskStepStatus.running
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 17,
                    color: step.status == TaskStepStatus.succeeded
                        ? PerantColors.accent
                        : PerantColors.muted,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      step.title.replaceFirst(RegExp(r'\s*·\s*画面\s+.*$'), ''),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          if (task.statusDetail != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                task.statusDetail!,
                style: const TextStyle(fontSize: 12, color: PerantColors.muted),
              ),
            ),
          if (waiting)
            FilledButton.icon(
              onPressed: _showCommandSheet,
              icon: const Icon(Icons.terminal, size: 18),
              label: const Text('查看并确认命令'),
            ),
          if (controller.isSending)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: controller.canCancelActiveTask ? _stopTask : null,
                icon: const Icon(Icons.stop_rounded, size: 16),
                label: const Text('停止任务'),
              ),
            ),
          if (controller.containerActions.isNotEmpty)
            TextButton(
              onPressed: _showContainer,
              child: const Text('查看操作记录与工作文件'),
            ),
        ],
      ),
    );
  }

  Widget _taskDock() {
    final task = _conversationTask;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: PerantColors.surface,
        border: Border.all(color: PerantColors.line),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(
            _pendingCommand != null ? Icons.terminal : Icons.pending_outlined,
            color: PerantColors.accent,
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              task?.title ?? '任务正在进行',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: () {
              setState(() => _section = 0);
            },
            child: Text(_pendingCommand != null ? '查看命令' : '回到对话'),
          ),
        ],
      ),
    );
  }

  Widget _documents() {
    final query = _search.text.toLowerCase();
    final documents = controller.documents
        .where((d) => '${d.title}\n${d.markdown}'.toLowerCase().contains(query))
        .toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '我的文件',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _mutationBusy ? null : () => _newDocument(),
                icon: const Icon(Icons.add, size: 17),
                label: const Text('新建'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '每次协作的成果，都有迹可循。',
            style: TextStyle(color: PerantColors.muted, fontSize: 13),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search, size: 20),
              hintText: '搜索文件名称或正文',
              contentPadding: EdgeInsets.symmetric(vertical: 12),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              for (var i = 0; i < 2; i++)
                Semantics(
                  selected: _filesTab == i,
                  button: true,
                  child: InkWell(
                    onTap: () => setState(() => _filesTab = i),
                    child: Container(
                      height: 44,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: _filesTab == i
                                ? PerantColors.accent
                                : Colors.transparent,
                            width: 1.5,
                          ),
                        ),
                      ),
                      child: Text(
                        i == 0 ? '文档资料' : '电脑工作区',
                        style: TextStyle(
                          fontSize: 13,
                          color: _filesTab == i
                              ? PerantColors.accent
                              : PerantColors.muted,
                          fontWeight: _filesTab == i
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const Divider(height: 1),
          const SizedBox(height: 14),
          if (_filesTab == 1) ...[
            const Text(
              'Linux 的 /workspace 与文档资料分别存储。网页文字保存在电脑工作区，未自动导入这里。',
              style: TextStyle(fontSize: 13, color: PerantColors.muted),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _showContainer,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('打开工作文件'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _showDesktop,
              child: const Text('桌面运行中？在电脑的文件管理器查看'),
            ),
          ] else ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${documents.length} 份本机文档',
                    style: const TextStyle(
                      fontSize: 12,
                      color: PerantColors.muted,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _mutationBusy ? null : _importDocument,
                  child: const Text('导入'),
                ),
                if (controller.documents.isNotEmpty)
                  TextButton(
                    onPressed: _mutationBusy ? null : _meeting,
                    child: const Text('整理纪要'),
                  ),
                PopupMenuButton<String>(
                  tooltip: '资料备份与诊断',
                  enabled: !_mutationBusy,
                  onSelected: _portableFiles,
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'backup', child: Text('备份资料、对话与任务记录')),
                    PopupMenuItem(value: 'restore', child: Text('从备份恢复整个工作区')),
                    PopupMenuItem(
                      value: 'diagnostics',
                      child: Text('导出诊断统计（无正文）'),
                    ),
                  ],
                ),
              ],
            ),
            if (documents.isEmpty)
              _EmptyState(
                icon: Icons.description_outlined,
                title: query.isEmpty ? '还没有资料' : '没有找到匹配的文档',
                body: query.isEmpty ? '新建一份文档，或把对话中的灵感收好。' : '试试另一个关键词。',
              )
            else
              ...documents.map(_documentTile),
          ],
        ],
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
