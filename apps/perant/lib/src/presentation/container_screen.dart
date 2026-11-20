// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:perant_platform/perant_platform.dart';

import '../application/workspace_controller.dart';
import 'container_actions.dart';
import 'container_file_editor.dart';
import 'desktop_screen.dart';
import 'terminal_screen.dart';
import 'theme.dart';

/// A native file workbench over the same /workspace used by PRoot and tools.
class ContainerScreen extends StatefulWidget {
  const ContainerScreen({super.key, required this.controller});
  final WorkspaceController controller;

  @override
  State<ContainerScreen> createState() => _ContainerScreenState();
}

class _ContainerScreenState extends State<ContainerScreen> {
  LinuxStatus? _status;
  LinuxDirectoryListing? _directory;
  String _path = '/workspace';
  String? _error;
  bool _busy = false;
  int _tab = 0;
  WorkspaceController get controller => widget.controller;
  bool get _blocked =>
      _busy ||
      _status?.active == true ||
      controller.isSending ||
      controller.isTesting ||
      controller.isConfiguring ||
      controller.manualTerminalActive;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<T> _ownWorkspace<T>(Future<T> Function() action) async {
    final lease = controller.acquireManualTerminal();
    try {
      return await action();
    } finally {
      controller.releaseManualTerminal(lease);
    }
  }

  Future<void> _showDesktop() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => DesktopScreen(controller: controller)),
    );
    if (mounted) await _refresh();
  }

  String _errorText(Object error) => error is RuntimeBridgeException
      ? error.message
      : '暂时无法访问工作区，请结束正在运行的任务后重试。';

  Future<void> _refresh({String? path}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await controller.bridge.getLinuxStatus();
      if (!mounted) return;
      setState(() => _status = status);
      if (!status.workspaceAvailable) return;
      if (controller.isSending ||
          controller.manualTerminalActive ||
          status.active) {
        setState(
          () => _error = status.desktopSessionId != null
              ? '图形桌面正在运行。可在桌面的文件管理器中查看文件，或停止桌面后在此编辑。'
              : 'Linux 正被使用。可在操作记录中查看进度，结束后刷新文件。',
        );
        return;
      }
      final listing = await _ownWorkspace(
        () => controller.bridge.listLinuxDirectory(path ?? _path),
      );
      if (!mounted) return;
      setState(() {
        _directory = listing;
        _path = listing.path;
      });
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _initialize() async {
    if (_blocked) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await _ownWorkspace(
        () => controller.bridge.initializeLinux(),
      );
      if (mounted) setState(() => _status = status);
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _status?.installed == true) await _refresh();
  }

  Future<void> _openFile(LinuxFileEntry entry) async {
    if (_blocked) return;
    if (entry.isDirectory) {
      await _refresh(path: entry.path);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    LinuxTextFile? file;
    try {
      file = await _ownWorkspace(
        () => controller.bridge.readLinuxFile(entry.path),
      );
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted || file == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ContainerFileEditor(
          controller: controller,
          path: entry.path,
          file: file,
        ),
      ),
    );
    if (mounted) await _refresh();
  }

  Future<String?> _nameDialog({required bool directory}) async {
    var text = '';
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(directory ? '新建文件夹' : '新建文件'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '保存位置：$_path',
              style: const TextStyle(fontSize: 12, color: PerantColors.muted),
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const ValueKey('container-new-name'),
              initialValue: '',
              onChanged: (value) => text = value,
              autofocus: true,
              maxLength: 128,
              decoration: InputDecoration(
                labelText: directory ? '文件夹名称' : '文件名称',
                hintText: directory ? '例如：project' : '例如：notes.md 或 index.html',
              ),
              onFieldSubmitted: (value) => Navigator.pop(context, value),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, text),
            child: Text(directory ? '创建' : '开始编辑'),
          ),
        ],
      ),
    );
    final name = result?.trim();
    if (name == null) return null;
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(name)) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('请输入有效名称，不含斜杠或控制字符。')));
      return null;
    }
    return '$_path/$name';
  }

  Future<void> _newFile() async {
    if (_blocked) return;
    final path = await _nameDialog(directory: false);
    if (path == null || !mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ContainerFileEditor(controller: controller, path: path),
      ),
    );
    if (mounted) await _refresh();
  }

  Future<void> _newDirectory() async {
    if (_blocked) return;
    final path = await _nameDialog(directory: true);
    if (path == null || !mounted || _blocked) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _ownWorkspace(() => controller.bridge.createLinuxDirectory(path));
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _refresh();
  }

  Future<void> _terminal() async {
    if (_blocked) return;
    String lease;
    try {
      lease = controller.acquireManualTerminal();
    } catch (_) {
      return;
    }
    if (!mounted) {
      controller.releaseManualTerminal(lease);
      return;
    }
    try {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => TerminalScreen(controller: controller, lease: lease),
        ),
      );
    } catch (_) {
      controller.releaseManualTerminal(lease);
    }
    if (mounted) await _refresh();
  }

  String _bytes(int bytes) =>
      bytes < 1024 ? '$bytes B' : '${(bytes / 1024).toStringAsFixed(1)} KiB';

  Widget _environment() {
    final status = _status;
    final installed = status?.installed == true;
    final detail = _busy
        ? '正在检查工作区…'
        : controller.isContainerTaskRunning
        ? '模型正在操作 · 可随时停止'
        : installed
        ? '本机运行 · ${status?.pythonVersion == null ? 'Shell' : 'Python ${status!.pythonVersion}'}'
        : status?.supported == false
        ? '此设备无法运行 Linux'
        : '等待初始化';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: PerantColors.ink,
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(
              Icons.computer_outlined,
              color: Colors.white,
              size: 26,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'PerAnt Linux',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: const TextStyle(
                    fontSize: 12,
                    color: PerantColors.muted,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '与模型共用 /workspace',
                  style: TextStyle(fontSize: 12, color: PerantColors.muted),
                ),
              ],
            ),
          ),
          if (controller.isContainerTaskRunning)
            IconButton(
              tooltip: '停止容器任务',
              onPressed: controller.canCancelActiveTask
                  ? controller.cancelActiveTask
                  : null,
              icon: const Icon(Icons.stop_circle_outlined),
            ),
        ],
      ),
    );
  }

  Widget _files() {
    final ready = _status?.workspaceAvailable == true;
    if (!ready)
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.inventory_2_outlined,
                size: 40,
                color: PerantColors.muted,
              ),
              const SizedBox(height: 20),
              Text(
                _status?.supported == false
                    ? '此平台尚未接入 Linux'
                    : '准备你的 Linux 工作区',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              Text(
                _status?.supported == false
                    ? _status!.reason
                    : '从 APK 离线初始化 Shell 与 Python，之后可浏览文件、打开终端，或交给模型处理。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              if (_status?.supported == true)
                FilledButton.icon(
                  onPressed: _blocked ? null : _initialize,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(_busy ? '正在准备…' : '初始化 Linux'),
                ),
            ],
          ),
        ),
      );
    final entries = _directory?.entries ?? const <LinuxFileEntry>[];
    return Column(
      children: [
        if (_status?.supported == true && _status?.installed == false)
          TextButton.icon(
            onPressed: _blocked ? null : _initialize,
            icon: const Icon(Icons.terminal_rounded),
            label: const Text('初始化 Linux'),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Row(
            children: [
              IconButton(
                tooltip: '上一级文件夹',
                onPressed: _blocked || _path == '/workspace'
                    ? null
                    : () => _refresh(
                        path: _path.substring(0, _path.lastIndexOf('/')),
                      ),
                icon: const Icon(Icons.arrow_upward_rounded, size: 20),
              ),
              Expanded(
                child: Text(
                  _path,
                  maxLines: 2,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              IconButton(
                tooltip: '新建文件夹',
                onPressed: _blocked ? null : _newDirectory,
                icon: const Icon(Icons.create_new_folder_outlined, size: 22),
              ),
              IconButton(
                tooltip: '新建容器文件',
                onPressed: _blocked ? null : _newFile,
                icon: const Icon(Icons.note_add_outlined, size: 22),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        if (_directory?.truncated == true)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '当前仅显示前 500 项，可在终端中查看其他文件。',
              style: TextStyle(fontSize: 12),
            ),
          ),
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.folder_open_outlined,
                          size: 40,
                          color: PerantColors.muted,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _directory == null ? '刷新后查看文件' : '这个文件夹还是空的',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '新建文件，或返回对话让模型在这里创建内容。',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: PerantColors.muted),
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          onPressed: _blocked ? null : _newFile,
                          icon: const Icon(Icons.add),
                          label: const Text('新建文件'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: entries.length,
                  separatorBuilder: (_, index) =>
                      const Divider(height: 1, indent: 64),
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return ListTile(
                      minVerticalPadding: 14,
                      enabled: !_blocked,
                      leading: Icon(
                        entry.isDirectory
                            ? Icons.folder_outlined
                            : Icons.description_outlined,
                        color: PerantColors.ink,
                      ),
                      title: Text(
                        entry.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        entry.isDirectory ? '文件夹' : _bytes(entry.sizeBytes),
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: Icon(
                        entry.isDirectory
                            ? Icons.chevron_right
                            : Icons.open_in_new,
                        size: 18,
                        color: PerantColors.muted,
                      ),
                      onTap: () => _openFile(entry),
                    );
                  },
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('容器电脑'),
        actions: [
          IconButton(
            tooltip: '刷新容器',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '打开容器终端',
            onPressed: _blocked ? null : _terminal,
            icon: const Icon(Icons.terminal_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _environment(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: FilledButton.icon(
                onPressed: _showDesktop,
                icon: const Icon(Icons.desktop_windows_outlined),
                label: const Text('查看模型电脑'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(
                    value: 0,
                    icon: Icon(Icons.folder_outlined, size: 18),
                    label: Text('文件'),
                  ),
                  ButtonSegment(
                    value: 1,
                    icon: Icon(Icons.history_rounded, size: 18),
                    label: Text('操作记录'),
                  ),
                ],
                selected: {_tab},
                onSelectionChanged: (value) =>
                    setState(() => _tab = value.single),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: PerantColors.muted,
                  ),
                ),
              ),
            if (_busy) const LinearProgressIndicator(),
            Expanded(
              child: _tab == 0
                  ? _files()
                  : ContainerActions(actions: controller.containerActions),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Text(
                controller.isContainerTaskRunning
                    ? '停止任务后即可接手编辑，已完成的文件会保留。'
                    : '文件、终端与预览共用一个 Linux 工作区。',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: PerantColors.muted),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
