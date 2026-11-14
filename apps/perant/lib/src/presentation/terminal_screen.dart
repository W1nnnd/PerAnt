// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perant_platform/perant_platform.dart';
import 'package:xterm/xterm.dart';

import '../application/workspace_controller.dart';
import 'theme.dart';

/// Owns one native interactive session and the controller's manual-write lease.
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    super.key,
    required this.controller,
    required this.lease,
  });
  final WorkspaceController controller;
  final String lease;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

enum _TerminalPhase {
  checking,
  needsInstallation,
  initializing,
  starting,
  running,
  exited,
  unavailable,
  failed,
  closing,
}

class _TerminalScreenState extends State<TerminalScreen>
    with WidgetsBindingObserver {
  final _terminal = Terminal(maxLines: 2000);
  final _focus = FocusNode();
  StreamSubscription<RuntimeEvent>? _events;
  Future<void>? _opening;
  Future<void>? _restartOperation;
  Future<bool>? _cleanup;
  Future<void> _inputQueue = Future.value();
  Timer? _resizeTimer;
  LinuxStatus? _status;
  _TerminalPhase _phase = _TerminalPhase.checking;
  String? _sessionId;
  String? _exitMessage;
  String? _failure;
  bool _closing = false;
  bool _disposed = false;
  bool _leaseReleased = false;
  bool _allowPop = false;
  bool _exitRequested = false;
  bool _foreground = true;
  int _columns = 80;
  int _rows = 24;
  int _sessionSequence = 0;

  PerantPlatformBridge get _bridge => widget.controller.bridge;
  bool get _running => _phase == _TerminalPhase.running && !_closing;
  bool get _keyboardOpen => MediaQuery.viewInsetsOf(context).bottom > 0;
  bool get _working => {
    _TerminalPhase.checking,
    _TerminalPhase.initializing,
    _TerminalPhase.starting,
    _TerminalPhase.closing,
  }.contains(_phase);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _terminal.onOutput = _sendInput;
    _terminal.onResize = (columns, rows, pixelWidth, pixelHeight) {
      _columns = columns.clamp(2, 500).toInt();
      _rows = rows.clamp(2, 300).toInt();
      _resizeTimer?.cancel();
      _resizeTimer = Timer(const Duration(milliseconds: 80), _resize);
    };
    // Subscribe before starting: the native host may produce the prompt at once.
    _events = _bridge.events.listen(
      _onEvent,
      onError: (Object error, StackTrace stackTrace) {
        if (!_closing) _showFailure(_errorText(error));
      },
      onDone: () {
        if (_sessionId != null && !_closing) {
          _showFailure('终端输出通道已关闭，请关闭后重新打开。');
        }
      },
    );
    _opening = _loadAndOpen();
  }

  Future<void> _loadAndOpen() async {
    _update(() {
      _phase = _TerminalPhase.checking;
      _failure = null;
    });
    try {
      final status = await _bridge.getLinuxStatus();
      if (_closing || _disposed) return;
      _status = status;
      if (!status.supported) {
        _update(() => _phase = _TerminalPhase.unavailable);
      } else if (!status.installed) {
        _update(() => _phase = _TerminalPhase.needsInstallation);
      } else if (status.active) {
        _sessionId = status.sessionId;
        _showFailure('检测到仍在运行的会话。请先关闭它，再重新打开 Shell。');
      } else {
        await _startSession();
      }
    } catch (error) {
      if (!_closing) _showFailure(_errorText(error));
    }
  }

  Future<void> _initializeAndOpen() async {
    _update(() {
      _phase = _TerminalPhase.initializing;
      _failure = null;
    });
    try {
      final status = await _bridge.initializeLinux();
      if (_closing || _disposed) return;
      _status = status;
      if (!status.supported || !status.installed) {
        _showFailure(
          status.reason.isEmpty ? 'Linux 环境未能完成初始化。' : status.reason,
        );
        return;
      }
      await _startSession();
      unawaited(widget.controller.refreshCapabilities());
    } catch (error) {
      if (!_closing) _showFailure(_errorText(error));
    }
  }

  Future<void> _startSession() async {
    if (_closing || _disposed) return;
    final id =
        'terminal-${DateTime.now().microsecondsSinceEpoch}-${_sessionSequence++}';
    _sessionId = id;
    _exitMessage = null;
    _update(() => _phase = _TerminalPhase.starting);
    final session = await _bridge.startLinuxSession(
      sessionId: id,
      columns: _columns,
      rows: _rows,
    );
    if (_closing || _disposed) return;
    if (_exitMessage == null) {
      _update(() => _phase = _TerminalPhase.running);
      _resize();
    }
    if (session.sessionId != id) {
      _showFailure('原生终端返回了不匹配的会话，请关闭后重试。');
    }
  }

  Future<void> _restart() {
    final pending = _restartOperation;
    if (pending != null) return pending;
    if (_closing || _disposed) return _opening ?? Future.value();
    // Reuse the same future before the next frame disables the button. Keeping
    // _opening tied to that operation also lets close await the actual restart.
    return _restartOperation = _restartSession().whenComplete(() {
      _restartOperation = null;
    });
  }

  Future<void> _restartSession() async {
    try {
      _update(() {
        _phase = _TerminalPhase.starting;
        _failure = null;
      });
      final oldId = _sessionId;
      if (oldId != null) await _bridge.closeLinuxSession(oldId);
      _sessionId = null;
      await _startSession();
    } catch (error) {
      if (!_closing) _showFailure(_errorText(error));
    }
  }

  void _onEvent(RuntimeEvent event) {
    if (_disposed || event.payload['sessionId'] != _sessionId) return;
    if (event.type == 'linuxOutput') {
      final text = event.payload['text'];
      if (text is String) _terminal.write(text);
    } else if (event.type == 'linuxExit') {
      final code = event.payload['exitCode'];
      _exitMessage = event.payload['timedOut'] == true
          ? '会话已超时结束（退出码 $code）。'
          : event.payload['cancelled'] == true
          ? '会话已停止（退出码 $code）。'
          : 'Shell 已退出（退出码 $code）。';
      if (!_closing) _update(() => _phase = _TerminalPhase.exited);
    }
  }

  void _sendInput(String data) {
    final id = _sessionId;
    if (!_running || id == null || data.isEmpty) return;
    _inputQueue = _inputQueue.then((_) async {
      if (_closing || !_running || _sessionId != id) return;
      try {
        await _bridge.writeLinuxSession(id, data);
      } catch (error) {
        if (!_closing) _showFailure(_errorText(error));
      }
    });
  }

  void _resize() {
    final id = _sessionId;
    if (!_running || id == null) return;
    unawaited(
      _bridge.resizeLinuxSession(id, _columns, _rows).catchError((
        Object error,
      ) {
        if (!_closing) _showFailure(_errorText(error));
      }),
    );
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData('text/plain');
    if (!_running || !mounted || data?.text == null) return;
    final text = data!.text!;
    if (text.length > 65536) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('每次粘贴不能超过 65,536 个字符。')));
      return;
    }
    _terminal.paste(text);
    _focus.requestFocus();
  }

  void _showKeyboard() {
    if (!_running) return;
    _focus.requestFocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
  }

  void _key(TerminalKey key, {bool ctrl = false}) {
    if (_running) _terminal.keyInput(key, ctrl: ctrl);
  }

  Future<bool> _closeNative() async {
    _closing = true;
    _resizeTimer?.cancel();
    _update(() => _phase = _TerminalPhase.closing);
    try {
      await _opening;
      final id = _sessionId;
      if (id != null) await _bridge.closeLinuxSession(id);
      await _inputQueue;
      await _events?.cancel();
      _events = null;
      _sessionId = null;
      if (!_leaseReleased) {
        widget.controller.releaseManualTerminal(widget.lease);
        _leaseReleased = true;
      }
      return true;
    } catch (error) {
      // Keep the lease if native cleanup is uncertain; do not resume writes.
      if (_disposed) {
        await _events?.cancel();
        _events = null;
      } else {
        _closing = false;
        _cleanup = null;
        _showFailure('尚未确认终端关闭，请点击关闭重试。${_errorText(error)}');
      }
      return false;
    }
  }

  Future<void> _requestClose() async {
    if (_exitRequested || _allowPop) return;
    _exitRequested = true;
    final closed = await (_cleanup ??= _closeNative());
    if (!closed) {
      _exitRequested = false;
      return;
    }
    if (!mounted || _disposed) return;
    _focus.unfocus();
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_disposed) Navigator.of(context).pop();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _foreground = false;
    } else if (state == AppLifecycleState.resumed && !_foreground) {
      _foreground = true;
      unawaited(_checkAfterResume());
    }
  }

  Future<void> _checkAfterResume() async {
    if (_closing || _sessionId == null) return;
    try {
      final status = await _bridge.getLinuxStatus();
      if (_closing || _disposed) return;
      if (!status.active || status.sessionId != _sessionId) {
        _exitMessage = '返回前台后未检测到原会话，请重新打开 Shell。';
        _update(() => _phase = _TerminalPhase.exited);
      }
    } catch (error) {
      if (!_closing) _showFailure(_errorText(error));
    }
  }

  void _showFailure(String message) => _update(() {
    _failure = message;
    _phase = _TerminalPhase.failed;
  });

  String _errorText(Object error) => error is RuntimeBridgeException
      ? error.message
      : '无法连接本地 Linux 环境，请检查后重试。';

  void _update(VoidCallback change) {
    if (!mounted || _disposed) return;
    setState(change);
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _resizeTimer?.cancel();
    _terminal.onOutput = null;
    _terminal.onResize = null;
    _focus.dispose();
    if (!_leaseReleased) unawaited(_cleanup ??= _closeNative());
    super.dispose();
  }

  String get _phaseLabel => switch (_phase) {
    _TerminalPhase.checking => '正在检查 Linux 环境…',
    _TerminalPhase.needsInstallation => '首次使用需要初始化环境',
    _TerminalPhase.initializing => '正在解压并初始化 Linux 环境…',
    _TerminalPhase.starting => '正在启动 Shell…',
    _TerminalPhase.running => '手动接管中 · 云请求与文档修改已暂停',
    _TerminalPhase.exited => _exitMessage ?? 'Shell 已退出。',
    _TerminalPhase.unavailable => '此设备构建尚未提供 Linux 运行时',
    _TerminalPhase.failed => _failure ?? '终端连接失败。',
    _TerminalPhase.closing => '正在关闭 Shell 并清理进程…',
  };

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: _allowPop,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_requestClose());
    },
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: '关闭终端并返回',
          onPressed: _phase == _TerminalPhase.closing ? null : _requestClose,
          icon: const Icon(Icons.arrow_back),
        ),
        title: const Text('本地终端'),
        actions: [
          IconButton(
            tooltip: '关闭终端',
            onPressed: _phase == _TerminalPhase.closing ? null : _requestClose,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: PerantColors.soft,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _phaseLabel,
                      maxLines: _keyboardOpen ? 1 : null,
                      overflow: _keyboardOpen ? TextOverflow.ellipsis : null,
                    ),
                  ),
                  if (_status?.installed == true && !_keyboardOpen) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${_status!.distribution} ${_status!.version}'
                      '${_status!.pythonAvailable ? ' · Python ${_status!.pythonVersion}' : ''}'
                      ' · ${_status!.workspace}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    _keyboardOpen
                        ? '手动接管；返回将关闭 Shell。'
                        : '命令由你手动执行。PRoot 不提供强隔离；切到后台时会话可能暂停或结束。'
                              '${_status?.pythonAvailable == true ? '可用 Shell / BusyBox / Python 标准库。' : '可用 Shell / BusyBox；Python 尚不可用。'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (_working) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: _sessionId != null
                  ? TerminalView(
                      _terminal,
                      focusNode: _focus,
                      readOnly: !_running,
                      deleteDetection: true,
                      keyboardAppearance: Brightness.dark,
                      keyboardType: TextInputType.text,
                      textStyle: const TerminalStyle(fontSize: 13, height: 1.3),
                      padding: const EdgeInsets.all(12),
                    )
                  : _environmentState(),
            ),
            if (_phase == _TerminalPhase.exited ||
                (_phase == _TerminalPhase.failed && _sessionId != null))
              Padding(
                padding: const EdgeInsets.all(12),
                child: OutlinedButton(
                  onPressed: _closing ? null : () => _opening = _restart(),
                  child: const Text('关闭旧会话并重新打开'),
                ),
              ),
            _keyboardBar(),
          ],
        ),
      ),
    ),
  );

  Widget _environmentState() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.terminal_outlined, size: 36),
            const SizedBox(height: 16),
            Text(
              _phase == _TerminalPhase.needsInstallation
                  ? '准备本地 Linux 工作区'
                  : _phase == _TerminalPhase.unavailable
                  ? '本地环境暂不可用'
                  : _working
                  ? '正在准备环境'
                  : '无法打开终端',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              _phase == _TerminalPhase.needsInstallation
                  ? '初始化后可在手机上手动使用 Shell 和 BusyBox 命令，文件保存在 /workspace。'
                  : _status?.reason.isNotEmpty == true
                  ? _status!.reason
                  : _failure ?? _phaseLabel,
              textAlign: TextAlign.center,
            ),
            if (_phase == _TerminalPhase.needsInstallation) ...[
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => _opening = _initializeAndOpen(),
                child: const Text('初始化 Linux 环境'),
              ),
            ] else if (_phase == _TerminalPhase.failed) ...[
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: _closing ? null : () => _opening = _loadAndOpen(),
                child: const Text('重新检查环境'),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _keyboardBar() => Material(
    color: PerantColors.soft,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: '显示键盘',
            onPressed: _running ? _showKeyboard : null,
            icon: const Icon(Icons.keyboard_outlined),
          ),
          TextButton(
            onPressed: _running
                ? () => _key(TerminalKey.keyC, ctrl: true)
                : null,
            child: const Text('Ctrl-C'),
          ),
          TextButton(
            onPressed: _running ? () => _key(TerminalKey.tab) : null,
            child: const Text('Tab'),
          ),
          TextButton(
            onPressed: _running ? () => _key(TerminalKey.escape) : null,
            child: const Text('Esc'),
          ),
          for (final item in [
            (TerminalKey.arrowUp, Icons.arrow_upward, '向上'),
            (TerminalKey.arrowDown, Icons.arrow_downward, '向下'),
            (TerminalKey.arrowLeft, Icons.arrow_back, '向左'),
            (TerminalKey.arrowRight, Icons.arrow_forward, '向右'),
          ])
            IconButton(
              tooltip: item.$3,
              onPressed: _running ? () => _key(item.$1) : null,
              icon: Icon(item.$2, size: 20),
            ),
          IconButton(
            tooltip: '粘贴到终端',
            onPressed: _running ? _paste : null,
            icon: const Icon(Icons.content_paste_outlined, size: 20),
          ),
        ],
      ),
    ),
  );
}
