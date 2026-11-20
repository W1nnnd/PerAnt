// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:perant_core/perant_core.dart';

import '../application/workspace_controller.dart';
import 'local_model_screen.dart';
import 'theme.dart';

class ProviderSettings extends StatefulWidget {
  const ProviderSettings({super.key, required this.controller});
  final WorkspaceController controller;
  @override
  State<ProviderSettings> createState() => _ProviderSettingsState();
}

class _ProviderSettingsState extends State<ProviderSettings> {
  final _form = GlobalKey<FormState>();
  late String _preset;
  late ApiProtocol _protocol;
  late final TextEditingController _url;
  late final TextEditingController _model;
  final _key = TextEditingController();
  final _temperature = TextEditingController();
  final _topP = TextEditingController();
  late String _profileId;
  bool _saving = false;
  bool _showKey = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final profile = widget.controller.profile;
    _profileId = profile?.id ?? 'primary';
    _temperature.text = profile?.options['temperature']?.toString() ?? '';
    _topP.text = profile?.options['top_p']?.toString() ?? '';
    _preset = profile == null
        ? 'openai'
        : ProviderCatalog.find(profile.presetId ?? '')?.id ?? 'custom';
    _protocol = profile?.protocol ?? ApiProtocol.responses;
    _url = TextEditingController(
      text:
          profile?.baseUrl.toString() ??
          ProviderCatalog.presets.first.baseUrl.toString(),
    );
    _model = TextEditingController(text: profile?.modelId ?? '');
  }

  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    _key.dispose();
    _temperature.dispose();
    _topP.dispose();
    super.dispose();
  }

  void _select(String value) {
    setState(() {
      _preset = value;
      final preset = ProviderCatalog.find(value);
      if (preset != null) {
        _url.text = preset.baseUrl.toString();
        _protocol = preset.protocol;
      }
      _key.clear();
    });
  }

  ProviderProfile? get _saved => widget.controller.state.savedProfiles
      .where((p) => p.id == _profileId)
      .firstOrNull;

  void _edit(ProviderProfile? p) {
    setState(() {
      _profileId = p?.id ?? 'profile-${DateTime.now().microsecondsSinceEpoch}';
      _preset = p == null
          ? 'openai'
          : ProviderCatalog.find(p.presetId ?? '')?.id ?? 'custom';
      _protocol = p?.protocol ?? ApiProtocol.responses;
      _url.text = (p?.baseUrl ?? ProviderCatalog.presets.first.baseUrl)
          .toString();
      _model.text = p?.modelId ?? '';
      _temperature.text = p?.options['temperature']?.toString() ?? '';
      _topP.text = p?.options['top_p']?.toString() ?? '';
      _key.clear();
      _showKey = false;
      _error = null;
    });
  }

  ProviderProfile _draft({bool forDirectory = false}) {
    final preset = ProviderCatalog.find(_preset);
    final saved = _saved;
    final url = Uri.parse(_url.text.trim());
    final options = {...?saved?.options}
      ..remove('temperature')
      ..remove('top_p');
    if (!forDirectory) {
      if (_temperature.text.trim().isNotEmpty)
        options['temperature'] = double.parse(_temperature.text.trim());
      if (_topP.text.trim().isNotEmpty)
        options['top_p'] = double.parse(_topP.text.trim());
    }
    return ProviderProfile(
      id: _profileId,
      displayName: preset?.displayName ?? '自定义服务',
      baseUrl: url,
      protocol: _protocol,
      modelId: forDirectory ? 'directory' : _model.text.trim(),
      storageKeyRef: saved?.storageKeyRef ?? 'perant.profile.$_profileId',
      presetId: preset?.id,
      options: options,
      headers: saved?.baseUrl == url && saved?.presetId == preset?.id
          ? saved!.headers
          : const {},
    );
  }

  Future<void> _listModels() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final ids = await widget.controller.availableModels(
        _draft(forDirectory: true),
        _key.text,
      );
      if (!mounted) return;
      if (ids.isEmpty) {
        setState(() => _error = '服务没有列出可用模型，可手动填写模型 ID。');
        return;
      }
      final id = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('选择可用模型'),
          content: SizedBox(
            width: 360,
            height: 320,
            child: ListView.builder(
              itemCount: ids.length,
              itemBuilder: (c, i) => ListTile(
                title: Text(ids[i]),
                onTap: () => Navigator.pop(c, ids[i]),
              ),
            ),
          ),
        ),
      );
      if (mounted && id != null) setState(() => _model.text = id);
    } catch (_) {
      if (mounted)
        setState(() => _error = '无法取得模型列表。请核对当前服务地址与 Key，也可手动填写模型 ID。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final profile = _draft();
      await widget.controller.configure(profile, _key.text);
      if (!mounted) return;
      _key.clear();
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('模型配置已保存，连接测试会单独发起请求。')));
    } on ArgumentError {
      if (mounted) setState(() => _error = '请填写有效的 HTTPS 地址、模型名和 API Key。');
    } catch (_) {
      if (mounted) setState(() => _error = '无法保存配置，请结束当前请求或检查安全存储。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// The result line sits below the fold on a phone, so it is also announced.
  Future<void> _test({bool tool = false}) async {
    await widget.controller.testConnection(verifyTool: tool);
    if (!mounted) return;
    final message = widget.controller.connectionMessage;
    if (message == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final preset = ProviderCatalog.find(_preset);
    final busy =
        _saving ||
        controller.isTesting ||
        controller.isSending ||
        controller.isConfiguring;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '连接你的模型',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const Text('使用自己的 API。先选服务，再填写模型和 Key；已有预设可直接使用默认接口地址。'),
                const SizedBox(height: 28),
                if (controller.profile != null)
                  PopupMenuButton<String>(
                    enabled: !busy,
                    onSelected: (id) {
                      final selected = controller.state.savedProfiles
                          .where((p) => p.id == id)
                          .firstOrNull;
                      _edit(selected);
                    },
                    itemBuilder: (_) => [
                      for (final p in controller.state.savedProfiles)
                        PopupMenuItem(
                          value: p.id,
                          child: Text('${p.displayName} · ${p.modelId}'),
                        ),
                      const PopupMenuItem(value: '', child: Text('新增配置')),
                    ],
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(_saved == null ? '新增模型配置' : '选择已保存的配置'),
                      subtitle: Text(
                        '当前使用 ${controller.profile!.modelId} · ${controller.hasKey ? controller.profile!.verification.label : "缺少 Key"} · 保存后切换',
                      ),
                      trailing: const Icon(Icons.expand_more),
                    ),
                  ),
                DropdownButtonFormField<String>(
                  key: ValueKey('preset-$_profileId'),
                  initialValue: _preset,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '模型服务'),
                  items: [
                    ...ProviderCatalog.presets.map(
                      (p) => DropdownMenuItem(
                        value: p.id,
                        child: Text(p.displayName),
                      ),
                    ),
                    const DropdownMenuItem(
                      value: 'custom',
                      child: Text('自定义兼容服务'),
                    ),
                  ],
                  onChanged: busy
                      ? null
                      : (value) {
                          if (value != null) _select(value);
                        },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _model,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: '模型 ID',
                    hintText: '填写服务商提供的可用模型名',
                  ),
                  validator: (value) =>
                      value == null || value.trim().isEmpty ? '请填写模型 ID' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _key,
                  enabled: !busy,
                  obscureText: !_showKey,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText:
                        _saved != null &&
                            (_profileId != controller.profile?.id ||
                                controller.hasKey)
                        ? 'API Key（已保存，留空保留）'
                        : 'API Key',
                    suffixIcon: IconButton(
                      tooltip: _showKey ? '隐藏 Key' : '显示 Key',
                      onPressed: () => setState(() => _showKey = !_showKey),
                      icon: Icon(
                        _showKey
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                    ),
                  ),
                  validator: (value) =>
                      (_saved == null ||
                              (_profileId == controller.profile?.id &&
                                  !controller.hasKey)) &&
                          (value == null || value.trim().isEmpty)
                      ? '请填写 API Key'
                      : null,
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: busy ? null : _listModels,
                  icon: const Icon(Icons.list),
                  label: const Text('从当前服务获取模型列表'),
                ),
                Text(
                  kIsWeb
                      ? '浏览器预览的 Key 仅保留在当前页面内存中，刷新后需重新填写。'
                      : 'Key 保存在系统安全存储中，不进入文档和普通配置数据。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                ExpansionTile(
                  key: ValueKey('advanced-$_profileId'),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 16),
                  title: const Text('接口地址与高级设置'),
                  initiallyExpanded: _preset == 'custom',
                  children: [
                    TextFormField(
                      controller: _url,
                      enabled: !busy,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(labelText: 'Base URL'),
                      validator: (value) {
                        final uri = Uri.tryParse(value?.trim() ?? '');
                        if (uri == null ||
                            !uri.hasAuthority ||
                            uri.userInfo.isNotEmpty ||
                            uri.hasQuery ||
                            uri.hasFragment ||
                            !(uri.scheme == 'https' ||
                                (uri.scheme == 'http' &&
                                    [
                                      'localhost',
                                      '127.0.0.1',
                                      '::1',
                                      '[::1]',
                                    ].contains(uri.host))))
                          return '使用不含凭据、查询参数的 HTTPS 地址';
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<ApiProtocol>(
                      key: ValueKey(_protocol),
                      initialValue: _protocol,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '兼容协议'),
                      items: ApiProtocol.values
                          .map(
                            (p) => DropdownMenuItem(
                              value: p,
                              child: Text(p.label),
                            ),
                          )
                          .toList(),
                      onChanged: busy
                          ? null
                          : (value) {
                              if (value != null)
                                setState(() => _protocol = value);
                            },
                    ),
                    TextFormField(
                      controller: _temperature,
                      enabled: !busy,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Temperature（可选，0–2）',
                      ),
                      validator: (s) {
                        if (s == null || s.trim().isEmpty) return null;
                        final n = double.tryParse(s.trim());
                        return n != null && n.isFinite && n >= 0 && n <= 2
                            ? null
                            : '请输入 0 到 2 的数';
                      },
                    ),
                    TextFormField(
                      controller: _topP,
                      enabled: !busy,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Top P（可选，大于 0 且不超过 1）',
                      ),
                      validator: (s) {
                        if (s == null || s.trim().isEmpty) return null;
                        final n = double.tryParse(s.trim());
                        return n != null && n.isFinite && n > 0 && n <= 1
                            ? null
                            : '请输入大于 0 且不超过 1 的数';
                      },
                    ),
                  ],
                ),
                if (preset != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      preset.configurationNote,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                FilledButton.icon(
                  onPressed: busy ? null : _save,
                  icon: const Icon(Icons.check, size: 18),
                  label: Text(_saving ? '正在保存…' : '保存配置'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed:
                      busy ||
                          !controller.canChat ||
                          controller.profile?.id != _profileId
                      ? null
                      : () => _test(),
                  icon: const Icon(Icons.wifi_tethering, size: 18),
                  label: Text(controller.isTesting ? '正在测试…' : '测试已保存的连接'),
                ),
                OutlinedButton(
                  onPressed:
                      busy ||
                          !controller.canChat ||
                          controller.profile?.id != _profileId
                      ? null
                      : () => _test(tool: true),
                  child: const Text('测试已保存服务的工具往返'),
                ),
                if (controller.connectionMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: SelectableText(controller.connectionMessage!),
                  ),
                const SizedBox(height: 8),
                Text(
                  '连接测试发送固定短文本。工具测试向已保存的服务发送两轮固定内容，可能产生少量 API 费用。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 28),
                const Divider(),
                const SizedBox(height: 16),
                Text('此设备', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                _Detail('资料存储', controller.persistence.description),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('本地中文模型'),
                  subtitle: const Text('离线提问、查资料和创建笔记'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => LocalModelScreen(controller: controller),
                    ),
                  ),
                ),
                _Detail(
                  'Linux 环境',
                  controller.capabilities?.linux.available == true
                      ? '已连接'
                      : '尚未接入',
                ),
                _Detail(
                  '后台执行',
                  controller.capabilities?.backgroundTasks.available == true
                      ? '已连接'
                      : '尚未接入',
                ),
                const _Detail('代码许可', 'GPLv3 · GPL-3.0-only'),
                const SizedBox(height: 16),
                TextButton(
                  onPressed:
                      busy ||
                          !controller.hasKey ||
                          controller.profile?.id != _profileId
                      ? null
                      : () async {
                          final approved = await showDialog<bool>(
                            context: context,
                            builder: (c) => AlertDialog(
                              title: const Text('删除已保存的 API Key？'),
                              content: const Text('文档和任务记录会保留，需要时可重新填写 Key。'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(c, false),
                                  child: const Text('保留'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(c, true),
                                  child: const Text('删除 Key'),
                                ),
                              ],
                            ),
                          );
                          if (approved == true)
                            await controller.removeCredential();
                        },
                  child: const Text('删除已保存的 Key'),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(label, style: const TextStyle(color: PerantColors.muted)),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );
}
