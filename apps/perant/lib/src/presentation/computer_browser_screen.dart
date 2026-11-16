// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perant_platform/perant_platform.dart';

import '../application/computer_browser_service.dart';
import '../application/workspace_controller.dart';
import 'theme.dart';

class ComputerBrowserScreen extends StatefulWidget {
  const ComputerBrowserScreen({super.key, required this.controller});
  final WorkspaceController controller;

  @override
  State<ComputerBrowserScreen> createState() => _ComputerBrowserScreenState();
}

class _ComputerBrowserScreenState extends State<ComputerBrowserScreen>
    with WidgetsBindingObserver {
  final _address = TextEditingController();
  final _addressFocus = FocusNode();
  Timer? _statusTimer;
  bool _foreground = true;
  bool _refreshing = false;
  bool _saving = false;
  BrowserSavedPage? _savedPage;
  String? _error;

  // Rows shown above the page are frozen while a save is running. Adding or
  // removing one resizes the web view, and the native reader treats a resize
  // as a changed page and rejects the save that is in progress.
  String? _heldError;
  bool _heldSavedRow = false;
  ComputerBrowserService get browser => widget.controller.browser;
  bool get _manual =>
      !browser.modelHasControl &&
      !widget.controller.isSending &&
      !browser.busy &&
      !_saving;

  bool _addressFocused = false;

  /// Entering the address bar selects the current address, so typing a new
  /// one replaces it instead of being inserted into the old text.
  void _addressFocusChanged() {
    final focused = _addressFocus.hasFocus;
    if (focused && !_addressFocused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_addressFocus.hasFocus) return;
        _address.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _address.text.length,
        );
      });
    }
    _addressFocused = focused;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    browser.addListener(_changed);
    _addressFocus.addListener(_addressFocusChanged);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  Future<void> _start() async {
    await _run(() async {
      if (!browser.running) await browser.open();
      if (!mounted) return;
      await browser.setVisible(_foreground);
      _changed();
      _statusTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (_foreground && !_refreshing) unawaited(_refresh());
      });
    });
  }

  Future<void> _refresh() async {
    _refreshing = true;
    try {
      await browser.refreshState();
    } catch (_) {
      /* Retry on the next visible tick. */
    } finally {
      _refreshing = false;
    }
  }

  void _changed() {
    if (!mounted) return;
    if (!_addressFocus.hasFocus) {
      final url = browser.state?.url ?? '';
      _address.text = url == 'about:blank' ? '' : url;
    }
    setState(() {});
  }

  Future<void> _run(Future<void> Function() action) async {
    if (mounted) setState(() => _error = null);
    try {
      await action();
    } on RuntimeBridgeException catch (error) {
      if (mounted) {
        setState(
          () => _error = error.code == 'cleartext_not_permitted'
              ? '远程网站需要 HTTPS，HTTP 仅支持本机测试。'
              : '页面操作未完成，请检查网址或网络后重试。',
        );
      }
    } catch (_) {
      if (mounted) setState(() => _error = '页面操作未完成，请检查网址或网络后重试。');
    }
  }

  Future<void> _navigate() async {
    if (!_manual) return;
    var value = _address.text.trim();
    if (value.isEmpty) return;
    if (!value.contains('://') && value != 'about:blank')
      value = 'https://$value';
    final uri = Uri.tryParse(value);
    if (uri == null ||
        (value != 'about:blank' &&
            (!{'http', 'https'}.contains(uri.scheme) ||
                uri.host.isEmpty ||
                uri.userInfo.isNotEmpty))) {
      setState(() => _error = '请输入有效的 http 或 https 网址。');
      return;
    }
    _addressFocus.unfocus();
    await _run(() => browser.navigate(value));
  }

  Future<void> _closeBrowser() async {
    if (!_manual) return;
    final close = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('关闭浏览器？'),
        content: const Text('当前页面会关闭，未提交的表单内容可能丢失。Linux 文档和窗口会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (close != true || !mounted || !_manual) return;
    await _run(() async {
      await browser.close();
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> _savePage() async {
    if (!_manual || !_foreground) return;
    _addressFocus.unfocus();
    setState(() {
      _heldError = _displayedError;
      _heldSavedRow = _savedPage != null;
      _saving = true;
      _error = null;
    });
    try {
      final saved = await browser.savePage();
      if (!mounted) return;
      setState(() {
        _savedPage = saved;
        _saving = false;
      });
      if (_foreground) await _showSavedPage(saved);
    } catch (_) {
      if (mounted) {
        setState(() => _error = browser.error ?? '网页文字未能保存，请检查页面和工作区。');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _showSavedPage(BrowserSavedPage saved) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('已保存网页文字'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(saved.page.title.isEmpty ? '网页资料' : saved.page.title),
            const SizedBox(height: 12),
            SelectableText(saved.file.path),
            const SizedBox(height: 12),
            Text('${saved.file.sizeBytes} 字节 · Markdown'),
            const SizedBox(height: 12),
            Text(saved.truncated ? '正文已截断，请回到网页核对剩余内容。' : '已保存当前页面的文字摘录与来源网址。'),
            const SizedBox(height: 8),
            const Text('可在电脑的“工作文件”中打开。图片、附件、表单和内嵌页面不包含在内。'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: saved.file.path));
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('复制路径'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    ),
  );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    unawaited(browser.setVisible(_foreground).catchError((Object _) {}));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    browser.removeListener(_changed);
    _statusTimer?.cancel();
    unawaited(browser.setVisible(false).catchError((Object _) {}));
    _address.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  String? get _displayedError {
    final state = browser.state;
    return _error ??
        browser.error ??
        (state?.error.isNotEmpty == true ? state!.error : null);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final state = browser.state;
      final error = _saving ? _heldError : _displayedError;
      return Scaffold(
        appBar: AppBar(
          title: Text(
            state?.title.isNotEmpty == true ? state!.title : '浏览器',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          actions: [
            if (browser.modelHasControl)
              TextButton(
                onPressed: widget.controller.canCancelActiveTask
                    ? widget.controller.cancelActiveTask
                    : null,
                child: const Text('接管'),
              ),
            IconButton(
              key: const ValueKey('computer-browser-save-page'),
              tooltip: '保存网页文字',
              onPressed:
                  _manual &&
                      _foreground &&
                      state != null &&
                      !state.loading &&
                      state.error.isEmpty &&
                      state.url != 'about:blank'
                  ? _savePage
                  : null,
              icon: const Icon(Icons.note_add_outlined),
            ),
            IconButton(
              tooltip: '关闭浏览器',
              onPressed: _manual ? _closeBrowser : null,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '后退',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: _manual && state?.canGoBack == true
                        ? () => _run(browser.back)
                        : null,
                  ),
                  IconButton(
                    tooltip: '前进',
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: _manual && state?.canGoForward == true
                        ? () => _run(browser.forward)
                        : null,
                  ),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('computer-browser-address'),
                      controller: _address,
                      focusNode: _addressFocus,
                      enabled: _manual,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.go,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        hintText: '输入网址',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                      onSubmitted: (_) => _navigate(),
                    ),
                  ),
                  IconButton(
                    tooltip: '打开网址',
                    onPressed: _manual ? _navigate : null,
                    icon: const Icon(Icons.arrow_upward),
                  ),
                ],
              ),
            ),
            if (_saving ? _heldSavedRow : _savedPage != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: TextButton.icon(
                  onPressed: _saving || _savedPage == null
                      ? null
                      : () => _showSavedPage(_savedPage!),
                  icon: const Icon(Icons.description_outlined, size: 18),
                  label: const Text('已保存到工作区 · 查看文件路径'),
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  error,
                  style: const TextStyle(color: PerantColors.muted),
                ),
              ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: state == null
                        ? Center(
                            child: TextButton(
                              onPressed: _start,
                              child: Text(browser.busy ? '正在打开浏览器' : '打开浏览器'),
                            ),
                          )
                        : defaultTargetPlatform == TargetPlatform.android &&
                              !kIsWeb
                        ? Listener(
                            onPointerDown: (_) => browser.noteUserInput(),
                            child: AbsorbPointer(
                              absorbing: !_manual,
                              child: AndroidView(
                                key: ValueKey('computer-browser-${state.id}'),
                                viewType: 'dev.perant/computer-browser',
                                creationParams: {'id': state.id},
                                creationParamsCodec:
                                    const StandardMessageCodec(),
                              ),
                            ),
                          )
                        : const Center(child: Text('此构建尚未接入原生浏览器。')),
                  ),
                  // Progress is drawn over the page so it never resizes it.
                  if (state?.loading == true || _saving)
                    const Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  if (_saving)
                    const Positioned(
                      top: 2,
                      left: 0,
                      right: 0,
                      child: Material(
                        color: PerantColors.surface,
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 6,
                          ),
                          child: Text('正在保存网页文字到共享工作区…'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
