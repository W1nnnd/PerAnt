// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show RenderImage;
import 'package:material_ui/material_ui.dart';
import 'package:perant_platform/perant_platform.dart';

import '../application/shared_desktop_service.dart';
import '../application/workspace_controller.dart';
import 'install_storage.dart';
import 'theme.dart';
import 'computer_browser_screen.dart';

class _DesktopSize {
  const _DesktopSize(this.label, this.width, this.height, this.description);
  final String label;
  final int width;
  final int height;
  final String description;
}

const _desktopSizes = [
  _DesktopSize('手机竖屏', 720, 1080, '更大的文字和图标，适合竖着使用手机'),
  _DesktopSize('横屏桌面', 1120, 700, '适合横屏查看和多窗口操作'),
  _DesktopSize('大屏桌面', 1280, 800, '适合平板、外接屏或更大的工作区'),
];

class DesktopScreen extends StatefulWidget {
  const DesktopScreen({super.key, required this.controller});
  final WorkspaceController controller;
  @override
  State<DesktopScreen> createState() => _DesktopScreenState();
}

class _DesktopScreenState extends State<DesktopScreen>
    with WidgetsBindingObserver {
  final _text = TextEditingController();
  final _keyboardFocus = FocusNode();
  final _transform = TransformationController();
  final _imageKey = GlobalKey();
  ui.Image? _image;
  final _retiredImages = <ui.Image>{};
  DesktopFrame? _decodingFrame;
  bool _decoding = false;
  int _decodeGeneration = 0;
  int _buttons = 0;
  Offset? _touchOrigin;
  Offset? _touchPosition;
  int _pointerX = 0;
  int _pointerY = 0;
  bool _zoom = false;
  bool _keyboard = false;
  bool _rightClick = false;
  bool _foreground = true;
  bool _viewerRequested = false;
  bool _browserOpen = false;
  bool _fullscreen = false;
  _DesktopSize _preferredSize = _desktopSizes.first;
  String? _inputError;
  WorkspaceController get controller => widget.controller;
  SharedDesktopService get desktop => controller.desktop;
  bool get _manual =>
      !controller.isSending &&
      !desktop.modelHasControl &&
      desktop.viewerConnected;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    desktop.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_viewerRequested) return;
    _viewerRequested = true;
    final size = MediaQuery.sizeOf(context);
    _preferredSize = size.width >= 700 || size.width > size.height
        ? _desktopSizes[1]
        : _desktopSizes.first;
    // The previous chat route still listens to desktop status. Starting while
    // this route builds would notify that sibling/offstage route during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_connect());
    });
  }

  Future<void> _connect() => desktop.setViewerVisible(
    _foreground && !_browserOpen,
    width: _preferredSize.width,
    height: _preferredSize.height,
  );

  bool get _canManage =>
      !controller.isSending && !desktop.modelHasControl && !desktop.busy;

  void _fitToScreen() {
    _releaseHeldPointer();
    _transform.value = _transform.value.clone()..setIdentity();
    setState(() => _zoom = false);
  }

  void _releaseHeldPointer() {
    if (_buttons == 0) return;
    _buttons = 0;
    unawaited(_input(() => desktop.pointerFromUser(_pointerX, _pointerY, 0)));
  }

  void _toggleZoom() {
    _releaseHeldPointer();
    setState(() => _zoom = !_zoom);
  }

  void _toggleKeyboard() {
    _releaseHeldPointer();
    setState(() {
      _keyboard = !_keyboard;
      _fullscreen = false;
    });
    if (_keyboard) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _keyboard && _manual) _keyboardFocus.requestFocus();
      });
    } else {
      _keyboardFocus.unfocus();
    }
  }

  Future<void> _shortcut(String key, List<String> modifiers) async {
    if (!_manual) return;
    _releaseHeldPointer();
    _keyboardFocus.unfocus();
    setState(() {
      _keyboard = false;
      _zoom = false;
      _rightClick = false;
    });
    await _input(() => desktop.keyFromUser(key, modifiers));
  }

  // A rendered image remains valid through its last foreground frame. If the
  // app pauses before that frame runs, release its native pixels immediately.
  void _retireImage(ui.Image image) {
    if (!_foreground || !mounted) {
      image.dispose();
      return;
    }
    _retiredImages.add(image);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_retiredImages.remove(image)) image.dispose();
    });
  }

  void _releaseImages({bool detachRenderedImage = false}) {
    // RawImage gives RenderImage its own cloned handle. A paused engine may not
    // rebuild the now-empty widget tree, so release that handle synchronously.
    if (detachRenderedImage) {
      final rendered = _imageKey.currentContext?.findRenderObject();
      if (rendered is RenderImage) rendered.image = null;
    }
    final current = _image;
    _image = null;
    current?.dispose();
    for (final image in _retiredImages) {
      image.dispose();
    }
    _retiredImages.clear();
  }

  void _changed() {
    if (!mounted) return;
    final frame = desktop.frame;
    if (frame == null) {
      ++_decodeGeneration;
      _decodingFrame = null;
      final old = _image;
      _image = null;
      if (old != null) _retireImage(old);
    } else if (_foreground && !_decoding && !identical(frame, _decodingFrame)) {
      _decoding = true;
      _decodingFrame = frame;
      final generation = ++_decodeGeneration;
      ui.decodeImageFromPixels(
        frame.rgba,
        frame.width,
        frame.height,
        ui.PixelFormat.rgba8888,
        (value) {
          _decoding = false;
          if (!mounted || !_foreground || generation != _decodeGeneration) {
            value.dispose();
            // A replacement connection may already have delivered its one
            // idle framebuffer while this obsolete decode was pending.
            if (mounted && _foreground && desktop.frame != null) {
              scheduleMicrotask(() {
                if (mounted && _foreground && desktop.frame != null) _changed();
              });
            }
            return;
          }
          final old = _image;
          setState(() => _image = value);
          if (old != null) _retireImage(old);
          if (!identical(desktop.frame, _decodingFrame)) _changed();
        },
      );
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _buttons = 0;
      ++_decodeGeneration;
      _decodingFrame = null;
      _releaseImages(detachRenderedImage: true);
    }
    unawaited(desktop.setViewerVisible(_foreground && !_browserOpen));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    desktop.removeListener(_changed);
    ++_decodeGeneration;
    _decodingFrame = null;
    _releaseImages();
    unawaited(desktop.setViewerVisible(false));
    _text.dispose();
    _keyboardFocus.dispose();
    _transform.dispose();
    super.dispose();
  }

  Future<void> _input(Future<void> Function() action) async {
    if (!_manual) return;
    try {
      await action();
      if (mounted && _inputError != null) setState(() => _inputError = null);
    } catch (_) {
      if (mounted) setState(() => _inputError = '输入未完成，请核对桌面后重试。');
    }
  }

  Future<void> _sendText() async {
    final value = _text.text;
    if (value.isEmpty || !_manual) return;
    await _input(() => desktop.textFromUser(value));
    if (mounted && _inputError == null) _text.clear();
  }

  Future<void> _stop() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('停止 Linux 桌面？'),
        content: const Text('图形应用会关闭，未保存的窗口内容可能丢失。已保存到 Linux 的文件保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('停止桌面'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    controller.cancelActiveTask();
    try {
      await desktop.stop();
    } catch (_) {
      /* The service retains a diagnosable state for retry. */
    }
  }

  Future<void> _showDisplaySettings() async {
    if (!_canManage) return;
    final current = desktop.session;
    final choice = await showModalBottomSheet<_DesktopSize>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text(
                  '桌面大小',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Text('切换大小需要重新启动桌面，请先保存窗口中的文件。'),
              ),
              for (final size in _desktopSizes)
                ListTile(
                  title: Text(size.label),
                  subtitle: Text(
                    '${size.description}\n${size.width} × ${size.height}',
                  ),
                  isThreeLine: true,
                  leading: Icon(
                    size.width < size.height
                        ? Icons.stay_current_portrait
                        : Icons.desktop_windows_outlined,
                  ),
                  trailing:
                      current?.width == size.width &&
                          current?.height == size.height
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.pop(context, size),
                ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted || !_canManage) return;
    if (current?.width == choice.width && current?.height == choice.height)
      return;
    if (desktop.running) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('切换为${choice.label}？'),
          content: const Text('当前桌面窗口会关闭。已保存文件会保留，未保存内容会丢失。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('重启并切换'),
            ),
          ],
        ),
      );
      if (approved != true || !mounted || !_canManage) return;
    }
    try {
      if (desktop.running) await desktop.stop();
      if (!mounted) return;
      setState(() => _preferredSize = choice);
      _fitToScreen();
      await _connect();
    } catch (_) {
      if (mounted) setState(() => _inputError = '桌面未能切换，请重新连接后再试。');
    }
  }

  Future<void> _selectMenu(String action) async {
    switch (action) {
      case 'apps':
        await _showApplications();
      case 'start':
        await _shortcut(' ', ['Super']);
      case 'desktop':
        await _shortcut('d', ['Super']);
      case 'maximize':
        await _shortcut('F10', ['Alt']);
      case 'settings':
        await _shortcut('i', ['Super']);
      case 'right-click':
        if (_manual) setState(() => _rightClick = !_rightClick);
      case 'fit':
        _fitToScreen();
      case 'size':
        await _showDisplaySettings();
      case 'reconnect':
        if (!desktop.busy) await _connect();
      case 'stop':
        if (_canManage && desktop.running) await _stop();
    }
  }

  Future<void> _showApplications() async {
    if (!_manual) return;
    final excerpt = controller.browser.lastSavedFile;
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Text(
                    '电脑应用',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                ),
                if (excerpt != null)
                  ListTile(
                    leading: const Icon(Icons.find_in_page_outlined),
                    title: const Text('定位最近保存的网页摘录'),
                    subtitle: Text(excerpt.path),
                    onTap: () => Navigator.pop(context, 'excerpt'),
                  ),
                for (final app in const [
                  (
                    'browser',
                    Icons.language_outlined,
                    '浏览器',
                    '打开网页、查找资料',
                    'browser',
                  ),
                  ('writer', Icons.description_outlined, '文档', '撰写和编辑文档', 'w'),
                  ('calc', Icons.table_chart_outlined, '表格', '整理数据与计算', 'c'),
                  ('impress', Icons.slideshow_outlined, '演示文稿', '制作和编辑课件', 'p'),
                  (
                    'editor',
                    Icons.edit_note_outlined,
                    '文本编辑器',
                    '编辑纯文本、Markdown 和代码',
                    'n',
                  ),
                  (
                    'settings',
                    Icons.settings_outlined,
                    '系统设置',
                    '调整 Linux 桌面',
                    'i',
                  ),
                ])
                  ListTile(
                    key: ValueKey('desktop-app-${app.$1}'),
                    leading: Icon(app.$2),
                    title: Text(app.$3),
                    subtitle: Text(app.$4),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.pop(context, app.$5),
                  ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    '文档和表格建议横屏编辑。保存到共享工作区后，可从“文件”继续打开。',
                    style: TextStyle(fontSize: 13, color: PerantColors.muted),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (choice != null && mounted && _manual) {
      if (choice == 'excerpt' && excerpt != null) {
        await _reveal(excerpt);
      } else if (choice == 'browser') {
        await _openBrowser();
      } else {
        await _shortcut(choice, ['Super']);
      }
    }
  }

  Future<void> _reveal(LinuxFileImport file) async {
    if (!_manual || !_foreground) return;
    try {
      await desktop.revealFromUser(file);
      if (mounted && _foreground)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已请求文件管理器定位摘录，打开选中的文件即可核对原文。')),
        );
    } catch (failure) {
      if (mounted)
        setState(
          () => _inputError = failure is RuntimeBridgeException
              ? failure.message
              : '定位未完成，请先核对当前桌面。',
        );
    }
  }

  Future<void> _openBrowser() async {
    if (!_manual || _browserOpen) return;
    _browserOpen = true;
    _releaseHeldPointer();
    _keyboardFocus.unfocus();
    ++_decodeGeneration;
    _decodingFrame = null;
    _releaseImages(detachRenderedImage: true);
    setState(() => _keyboard = false);
    LinuxFileImport? excerpt;
    try {
      await desktop.setViewerVisible(false);
      if (!mounted) return;
      excerpt = await Navigator.of(context).push<LinuxFileImport>(
        MaterialPageRoute(
          builder: (_) => ComputerBrowserScreen(
            controller: controller,
            returnToDesktop: true,
          ),
        ),
      );
    } finally {
      _browserOpen = false;
      if (mounted && _foreground) await _connect();
    }
    if (mounted && excerpt != null) await _reveal(excerpt);
  }

  Widget _quickAction(
    String label,
    IconData icon,
    String id,
    VoidCallback? action, {
    bool selected = false,
  }) => Expanded(
    child: TextButton(
      key: ValueKey(id),
      onPressed: action,
      style: TextButton.styleFrom(
        foregroundColor: PerantColors.ink,
        backgroundColor: selected ? PerantColors.soft : null,
        minimumSize: const Size(48, 60),
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 23),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    ),
  );

  Widget _quickActions() => Padding(
    padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
    child: Row(
      children: [
        _quickAction(
          '文件',
          Icons.folder_open_outlined,
          'desktop-open-files',
          _manual ? () => _shortcut('e', ['Super']) : null,
        ),
        _quickAction(
          '终端',
          Icons.terminal_outlined,
          'desktop-open-terminal',
          _manual ? () => _shortcut('t', ['Ctrl', 'Alt']) : null,
        ),
        _quickAction(
          '应用',
          Icons.apps_outlined,
          'desktop-open-apps',
          _manual ? _showApplications : null,
        ),
        _quickAction(
          '窗口',
          Icons.window_outlined,
          'desktop-switch-window',
          _manual ? () => _shortcut('Tab', ['Alt']) : null,
        ),
        _quickAction(
          '键盘',
          Icons.keyboard_outlined,
          'desktop-toggle-keyboard',
          _manual ? _toggleKeyboard : null,
          selected: _keyboard,
        ),
      ],
    ),
  );

  Widget _keyboardPanel() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('desktop-text-input'),
                controller: _text,
                focusNode: _keyboardFocus,
                enabled: _manual,
                maxLength: 2000,
                minLines: 1,
                maxLines: 3,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  hintText: '输入到当前窗口',
                  counterText: '',
                  contentPadding: EdgeInsets.all(12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: '发送桌面文字',
              onPressed: _manual ? _sendText : null,
              icon: const Icon(Icons.arrow_upward),
            ),
            IconButton(
              tooltip: '收起键盘',
              onPressed: _toggleKeyboard,
              icon: const Icon(Icons.keyboard_hide_outlined),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(child: _key('Esc', 'Escape')),
            Expanded(child: _key('Tab', 'Tab')),
            Expanded(child: _key('Ctrl+C', 'c', ['Ctrl'])),
            Expanded(child: _key('退格', 'Backspace')),
            Expanded(child: _key('回车', 'Return')),
          ],
        ),
      ],
    ),
  );

  Widget _statusBar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 2, 8, 6),
    child: Row(
      children: [
        Icon(
          desktop.viewerConnected ? Icons.circle : Icons.circle_outlined,
          size: 8,
          color: PerantColors.muted,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            desktop.modelHasControl
                ? '模型正在操作'
                : !desktop.viewerConnected
                ? desktop.busy
                      ? '正在启动本地电脑'
                      : '画面未连接'
                : _zoom
                ? '缩放模式 · 双指缩放，拖动平移'
                : _rightClick
                ? '右键模式 · 点击打开菜单'
                : '轻点操作 · 长按右键',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: PerantColors.muted),
          ),
        ),
        TextButton.icon(
          key: const ValueKey('desktop-toggle-zoom'),
          onPressed: desktop.viewerConnected ? _toggleZoom : null,
          icon: Icon(
            _zoom ? Icons.touch_app_outlined : Icons.zoom_in,
            size: 18,
          ),
          label: Text(
            _zoom ? '操作' : '缩放',
            style: const TextStyle(fontSize: 12),
          ),
          style: TextButton.styleFrom(
            minimumSize: const Size(68, 44),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
        ),
      ],
    ),
  );

  Widget _display() {
    final image = _image;
    if (image == null)
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.desktop_windows_outlined,
                size: 44,
                color: PerantColors.ink,
              ),
              const SizedBox(height: 20),
              Text(
                desktop.error != null
                    ? '电脑未能连接'
                    : desktop.busy
                    ? '正在启动本地电脑'
                    : desktop.running
                    ? '正在连接画面'
                    : '电脑已关闭',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                desktop.error ??
                    (desktop.busy
                        ? '首次使用需要准备桌面，可能需要几分钟。'
                        : desktop.running
                        ? '文件和窗口仍在原来的电脑中。'
                        : '打开文件、编辑内容，或在终端中运行任务。'),
                textAlign: TextAlign.center,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: PerantColors.muted),
              ),
              if (!desktop.running && !desktop.busy)
                InstallStorage(
                  bridge: controller.bridge,
                  estimate: '首次使用：$linuxInstallEstimate',
                ),
              const SizedBox(height: 20),
              if (desktop.busy)
                const SizedBox(
                  width: 160,
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              if (!desktop.busy)
                FilledButton.icon(
                  onPressed: _connect,
                  icon: Icon(
                    desktop.running ? Icons.refresh : Icons.power_settings_new,
                  ),
                  label: Text(desktop.running ? '重新连接' : '启动电脑'),
                ),
            ],
          ),
        ),
      );
    return ColoredBox(
      color: const Color(0xFFE9EDF3),
      child: Center(
        child: AspectRatio(
          aspectRatio: image.width / image.height,
          child: InteractiveViewer(
            transformationController: _transform,
            panEnabled: _zoom,
            scaleEnabled: _zoom,
            minScale: 1,
            maxScale: 4,
            child: LayoutBuilder(
              builder: (context, box) {
                final frame = desktop.frame;
                final width = frame?.width ?? image.width;
                final height = frame?.height ?? image.height;
                (int, int) point(Offset p) => (
                  (p.dx / box.maxWidth * width).floor().clamp(0, width - 1),
                  (p.dy / box.maxHeight * height).floor().clamp(0, height - 1),
                );
                void send(Offset p, int buttons) {
                  if (_zoom || !_manual) return;
                  final (x, y) = point(p);
                  _pointerX = x;
                  _pointerY = y;
                  unawaited(
                    _input(() => desktop.pointerFromUser(x, y, buttons)),
                  );
                }

                return MouseRegion(
                  cursor: _zoom
                      ? SystemMouseCursors.grab
                      : SystemMouseCursors.precise,
                  child: Listener(
                    onPointerDown: (event) {
                      if (!_manual || _zoom) return;
                      if (event.kind == ui.PointerDeviceKind.touch) {
                        _touchOrigin = event.localPosition;
                        _touchPosition = event.localPosition;
                        return;
                      }
                      _buttons = _rightClick
                          ? 4
                          : event.buttons & 2 != 0
                          ? 4
                          : event.buttons & 4 != 0
                          ? 2
                          : 1;
                      send(event.localPosition, _buttons);
                    },
                    onPointerMove: (event) {
                      if (event.kind == ui.PointerDeviceKind.touch) return;
                      if (_buttons != 0) send(event.localPosition, _buttons);
                    },
                    onPointerHover: (event) => send(event.localPosition, 0),
                    onPointerUp: (event) {
                      if (event.kind == ui.PointerDeviceKind.touch) return;
                      send(event.localPosition, 0);
                      _buttons = 0;
                    },
                    onPointerCancel: (event) {
                      if (event.kind == ui.PointerDeviceKind.touch) return;
                      send(event.localPosition, 0);
                      _buttons = 0;
                    },
                    onPointerSignal: (event) {
                      if (event is PointerScrollEvent && _manual && !_zoom) {
                        send(
                          event.localPosition,
                          event.scrollDelta.dy < 0 ? 8 : 16,
                        );
                        send(event.localPosition, 0);
                      }
                    },
                    child: GestureDetector(
                      dragStartBehavior: DragStartBehavior.down,
                      supportedDevices: const {ui.PointerDeviceKind.touch},
                      onTapUp: _manual && !_zoom
                          ? (details) {
                              send(details.localPosition, _rightClick ? 4 : 1);
                              send(details.localPosition, 0);
                            }
                          : null,
                      onLongPressStart: _manual && !_zoom
                          ? (details) {
                              _buttons = 0;
                              send(details.localPosition, 0);
                              send(details.localPosition, 4);
                              send(details.localPosition, 0);
                            }
                          : null,
                      onPanStart: _manual && !_zoom
                          ? (details) {
                              _buttons = _rightClick ? 4 : 1;
                              _touchPosition =
                                  _touchOrigin ?? details.localPosition;
                              send(_touchPosition!, _buttons);
                            }
                          : null,
                      onPanUpdate: _manual && !_zoom
                          ? (details) {
                              _touchPosition = details.localPosition;
                              send(details.localPosition, _buttons);
                            }
                          : null,
                      onPanEnd: _manual && !_zoom
                          ? (_) {
                              if (_touchPosition case final position?)
                                send(position, 0);
                              _buttons = 0;
                            }
                          : null,
                      onPanCancel: _manual && !_zoom
                          ? () {
                              if (_buttons != 0 && _touchPosition != null)
                                send(_touchPosition!, 0);
                              _buttons = 0;
                            }
                          : null,
                      child: RawImage(
                        key: _imageKey,
                        image: image,
                        fit: BoxFit.fill,
                        filterQuality: FilterQuality.low,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _key(String label, String key, [List<String> modifiers = const []]) =>
      TextButton(
        key: ValueKey(
          key == 'Return' ? 'desktop-key-enter' : 'desktop-key-$key',
        ),
        onPressed: _manual
            ? () => _input(() => desktop.keyFromUser(key, modifiers))
            : null,
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 44),
          padding: const EdgeInsets.symmetric(horizontal: 4),
        ),
        child: Text(label, style: const TextStyle(fontSize: 13)),
      );

  PopupMenuButton<String> _computerMenu() => PopupMenuButton<String>(
    tooltip: '电脑菜单',
    onSelected: _selectMenu,
    itemBuilder: (context) => [
      PopupMenuItem(value: 'apps', enabled: _manual, child: const Text('电脑应用')),
      PopupMenuItem(
        value: 'start',
        enabled: _manual,
        child: const Text('开始菜单'),
      ),
      PopupMenuItem(
        value: 'desktop',
        enabled: _manual,
        child: const Text('显示桌面'),
      ),
      PopupMenuItem(
        value: 'maximize',
        enabled: _manual,
        child: const Text('最大化当前窗口'),
      ),
      PopupMenuItem(
        value: 'settings',
        enabled: _manual,
        child: const Text('Linux 系统设置'),
      ),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: 'right-click',
        enabled: _manual,
        child: Text(_rightClick ? '切回左键操作' : '切换右键操作'),
      ),
      PopupMenuItem(
        value: 'fit',
        enabled: desktop.viewerConnected,
        child: const Text('适应屏幕'),
      ),
      PopupMenuItem(
        value: 'size',
        enabled: _canManage,
        child: const Text('显示设置'),
      ),
      PopupMenuItem(
        value: 'reconnect',
        enabled: !desktop.busy,
        child: const Text('重新连接画面'),
      ),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: 'stop',
        enabled: _canManage && desktop.running,
        child: const Text('停止 Linux 桌面'),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([desktop, controller]),
    builder: (context, _) => Scaffold(
      appBar: _fullscreen
          ? null
          : AppBar(
              title: const Text(
                '模型的电脑',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
              ),
              actions: [
                if (controller.isContainerTaskRunning)
                  TextButton.icon(
                    onPressed: controller.canCancelActiveTask
                        ? controller.cancelActiveTask
                        : null,
                    icon: const Icon(Icons.pan_tool_outlined, size: 18),
                    label: const Text('接管'),
                  ),
                IconButton(
                  tooltip: '全屏查看',
                  onPressed: desktop.viewerConnected
                      ? () {
                          _keyboardFocus.unfocus();
                          setState(() {
                            _keyboard = false;
                            _fullscreen = true;
                          });
                        }
                      : null,
                  icon: const Icon(Icons.fullscreen),
                ),
                _computerMenu(),
              ],
            ),
      body: SafeArea(
        top: _fullscreen,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Android's keyboard can leave very little height in landscape.
            // Keep text and keys reachable without overflowing the viewport.
            if (_keyboard && !_fullscreen && constraints.maxHeight < 270) {
              return SingleChildScrollView(
                child: Column(children: [_keyboardPanel(), _quickActions()]),
              );
            }
            return Stack(
              children: [
                Column(
                  children: [
                    if (!_fullscreen) _statusBar(),
                    Expanded(child: _display()),
                    if (_inputError != null && !_fullscreen)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
                        child: Text(
                          _inputError!,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    if (!_fullscreen) ...[
                      const Divider(height: 1),
                      if (_keyboard) _keyboardPanel(),
                      _quickActions(),
                    ],
                  ],
                ),
                if (_fullscreen)
                  Positioned(
                    right: 8,
                    top: 8,
                    child: FilledButton.tonalIcon(
                      onPressed: () => setState(() => _fullscreen = false),
                      icon: const Icon(Icons.fullscreen_exit, size: 20),
                      label: const Text('退出全屏'),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
