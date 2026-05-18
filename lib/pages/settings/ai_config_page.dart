import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_roles.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/config/models.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

class AiConfigPage extends ConsumerStatefulWidget {
  const AiConfigPage({super.key});

  @override
  ConsumerState<AiConfigPage> createState() => _AiConfigPageState();
}

class _AiConfigPageState extends ConsumerState<AiConfigPage> {
  AiRoles _roles = const AiRoles();
  AiTemperatures _roleSettings = const AiTemperatures();
  bool _rolesLoaded = false;
  final Map<String, bool> _testingMap = {};
  final Map<String, String> _latencyMap = {};
  bool _batchTesting = false;

  @override
  void initState() {
    super.initState();
    _loadRoles();
    _loadLatencies();
  }

  Future<void> _loadRoles() async {
    final roles = await AiRoleService.instance.getRoles();
    final settings = await AiRoleService.instance.getTemperatures();
    if (mounted) {
      setState(() {
        _roles = roles;
        _roleSettings = settings;
        _rolesLoaded = true;
      });
    }
  }

  Future<void> _loadLatencies() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('ai_latency_'));
    final map = <String, String>{};
    for (final key in keys) {
      final val = prefs.getString(key);
      if (val != null) map[key] = val;
    }
    if (mounted) setState(() => _latencyMap..addAll(map));
  }

  Future<void> _saveLatency(String configId, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ai_latency_$configId', value);
    if (mounted) setState(() => _latencyMap[configId] = value);
  }

  String _formatTestError(Object e) {
    final msg = e.toString();
    if (kIsWeb && (msg.contains('XMLHttpRequest') || msg.contains('connection error') || msg.contains('CORS') || msg.contains('onError'))) {
      return '浏览器限制：Web端无法直接调用外部API（CORS），请在真机上测试';
    }
    if (msg.contains('SocketException') || msg.contains('NetworkException') || msg.contains('connection')) {
      return '网络连接失败，请检查网络或Base URL';
    }
    if (msg.contains('401') || msg.contains('403')) {
      return '认证失败，请检查API Key';
    }
    if (msg.contains('timeout')) {
      return '请求超时';
    }
    return msg.length > 60 ? '${msg.substring(0, 60)}...' : msg;
  }

  Future<void> _testSingleConfig(AiConfig config) async {
    if (_testingMap[config.id] == true) return;
    setState(() => _testingMap[config.id] = true);
    try {
      final service = AiService();
      service.updateConfig(config);
      final sw = Stopwatch()..start();
      await service.chat([
        ChatMessage(role: 'user', content: 'Hi', timestamp: DateTime.now()),
      ]);
      sw.stop();
      await _saveLatency(config.id, '${sw.elapsedMilliseconds}ms');
    } catch (e) {
      await _saveLatency(config.id, _formatTestError(e));
    } finally {
      if (mounted) setState(() => _testingMap[config.id] = false);
    }
  }

  Future<void> _testAllConfigs(List<AiConfig> configs) async {
    if (_batchTesting || configs.isEmpty) return;
    setState(() => _batchTesting = true);
    for (final config in configs) {
      if (!mounted) break;
      await _testSingleConfig(config);
    }
    if (mounted) setState(() => _batchTesting = false);
  }

  Widget _buildLatencyText(String configId, ThemeData theme) {
    final latency = _latencyMap[configId];
    if (latency == null) return const SizedBox.shrink();
    final isError = latency.contains('失败') || latency.contains('限制') || latency.contains('无法');
    final isLong = latency.length > 10;
    return Text(
      latency,
      style: theme.textTheme.bodySmall?.copyWith(
        color: isError ? Colors.red : Colors.orange,
        fontWeight: FontWeight.w500,
        fontSize: isLong ? 10 : null,
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  @override
  Widget build(BuildContext context) {
    final configsAsync = ref.watch(aiConfigListProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 配置'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showEditDialog(context, null),
          ),
        ],
      ),
      body: configsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (configs) => SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '模型列表',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  if (configs.isNotEmpty)
                    TextButton.icon(
                      onPressed: _batchTesting ? null : () => _testAllConfigs(configs),
                      icon: _batchTesting
                          ? SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.primary),
                            )
                          : const Icon(Icons.bolt, size: 16),
                      label: Text(_batchTesting ? '测试中...' : '批量测试', style: const TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(foregroundColor: theme.colorScheme.primary),
                    ),
                  const SizedBox(width: 4),
                  TextButton.icon(
                    onPressed: () => _showEditDialog(context, null),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('添加模型', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(foregroundColor: theme.colorScheme.primary),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ...configs.map((config) => _buildConfigCard(context, config, configs)),
              if (configs.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      '暂无配置，点击右上角 + 添加',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.disabledColor),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              if (_rolesLoaded && configs.isNotEmpty) ...[
                Text(
                  '角色绑定',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                _buildRoleAssignment(context, '提问助手', 'assistant', configs),
                const SizedBox(height: 8),
                _buildRoleAssignment(context, '时间轴智能提取', 'timelineOptimization', configs),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConfigCard(BuildContext context, AiConfig config, List<AiConfig> allConfigs) {
    final theme = Theme.of(context);
    final providerConfig = config.vendorId != null ? getProviderById(config.vendorId!) : null;
    final displayName = providerConfig?.name ?? config.name;
    final isTesting = _testingMap[config.id] == true;

    return Dismissible(
      key: ValueKey(config.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        if (allConfigs.length <= 1) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('至少保留一个配置')),
          );
          return false;
        }
        return showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('确认删除'),
            content: Text('确定要删除 "$displayName" 吗？'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
            ],
          ),
        );
      },
      onDismissed: (_) {
        ref.read(aiConfigListProvider.notifier).deleteConfig(config.id);
        setState(() => _latencyMap.remove(config.id));
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: Colors.red.shade100,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.delete, color: Colors.red),
      ),
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            displayName,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        _buildLatencyText(config.id, theme),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      config.modelName,
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                icon: isTesting
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5))
                    : Icon(Icons.bolt_outlined, size: 18, color: theme.colorScheme.primary),
                tooltip: '测试延迟',
                onPressed: isTesting ? null : () => _testSingleConfig(config),
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                icon: Icon(Icons.edit_outlined, size: 16, color: theme.colorScheme.outline),
                tooltip: '编辑',
                onPressed: () => _showEditDialog(context, config),
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                icon: Icon(Icons.delete_outline, size: 16, color: Colors.red.shade300),
                tooltip: '删除',
                onPressed: () async {
                  if (allConfigs.length <= 1) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('至少保留一个配置')));
                    return;
                  }
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('确认删除'),
                      content: Text('确定要删除 "$displayName" 吗？'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    ref.read(aiConfigListProvider.notifier).deleteConfig(config.id);
                    setState(() => _latencyMap.remove(config.id));
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  AiRoleSettings _getSettingsForRole(String roleKey) {
    switch (roleKey) {
      case 'assistant':
        return _roleSettings.assistant;
      case 'timelineOptimization':
        return _roleSettings.timelineOptimization;
      default:
        return const AiRoleSettings();
    }
  }

  Future<void> _updateRoleSettings(String roleKey, AiRoleSettings newSettings) async {
    AiTemperatures newTemps;
    switch (roleKey) {
      case 'assistant':
        newTemps = _roleSettings.copyWith(assistant: newSettings);
        break;
      case 'timelineOptimization':
        newTemps = _roleSettings.copyWith(timelineOptimization: newSettings);
        break;
      default:
        newTemps = _roleSettings;
    }
    await AiRoleService.instance.saveTemperatures(newTemps);
    if (mounted) setState(() => _roleSettings = newTemps);
  }

  Widget _buildRoleAssignment(BuildContext context, String label, String roleKey, List<AiConfig> configs) {
    final theme = Theme.of(context);
    final settings = _getSettingsForRole(roleKey);
    String? currentId;
    switch (roleKey) {
      case 'assistant':
        currentId = _roles.assistant;
      case 'timelineOptimization':
        currentId = _roles.timelineOptimization;
    }

    double tempValue = settings.temperature;
    int tokenValue = settings.maxTokens;
    final tokenCtl = TextEditingController(text: tokenValue.toString());

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 130,
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      isExpanded: true,
                      value: currentId,
                      hint: const Text(
                        '未设置',
                        style: TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                      style: theme.textTheme.bodyMedium?.copyWith(fontSize: 12),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('未设置', style: TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                        ),
                        ...configs.map((c) => DropdownMenuItem<String?>(
                          value: c.id,
                          child: Text(c.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                        )),
                      ],
                      onChanged: (value) async {
                        AiRoles newRoles;
                        switch (roleKey) {
                          case 'assistant':
                            newRoles = _roles.copyWith(assistant: value);
                          case 'timelineOptimization':
                            newRoles = _roles.copyWith(timelineOptimization: value);
                          default:
                            newRoles = _roles;
                        }
                        await AiRoleService.instance.saveRoles(newRoles);
                        if (mounted) setState(() => _roles = newRoles);
                      },
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  'Temp: ${tempValue.toStringAsFixed(1)}',
                  style: theme.textTheme.labelSmall?.copyWith(fontSize: 11),
                ),
                const Spacer(),
                Text(
                  'Max Tokens: ',
                  style: theme.textTheme.labelSmall?.copyWith(fontSize: 11),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: 70,
                  child: TextField(
                    controller: tokenCtl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 11),
                    decoration: InputDecoration(
                      hintText: '2048',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onChanged: (v) {
                      final parsed = int.tryParse(v);
                      if (parsed != null && parsed > 0) {
                        tokenValue = parsed;
                      }
                    },
                    onSubmitted: (v) {
                      final parsed = int.tryParse(v);
                      if (parsed != null && parsed > 0) {
                        _updateRoleSettings(roleKey, settings.copyWith(maxTokens: parsed));
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 32,
              child: Slider(
                value: tempValue,
                min: 0.0,
                max: 2.0,
                divisions: 20,
                onChanged: (v) {
                  setState(() => tempValue = v);
                  _updateRoleSettings(roleKey, settings.copyWith(temperature: v));
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditDialog(BuildContext context, AiConfig? existingConfig) {
    final isEditing = existingConfig != null;
    final nameCtl = TextEditingController(text: existingConfig?.name ?? '');
    final modelCtl = TextEditingController(text: existingConfig?.modelName ?? '');
    final apiKeyCtl = TextEditingController(text: existingConfig?.apiKey ?? '');
    final baseUrlCtl = TextEditingController(text: existingConfig?.baseUrl ?? '');
    String selectedVendorId = existingConfig?.vendorId ?? 'deepseek';
    String selectedProvider = existingConfig?.provider ?? 'openai';
    bool showApiKey = false;
    String? testResult;
    bool isTesting = false;

    if (!isEditing) {
      final defaultProvider = getProviderById(selectedVendorId);
      if (defaultProvider != null) {
        nameCtl.text = defaultProvider.name;
        baseUrlCtl.text = defaultProvider.defaultBaseUrl;
        if (defaultProvider.models.isNotEmpty) {
          modelCtl.text = defaultProvider.models.first;
        }
        selectedProvider = defaultProvider.provider;
      }
    }

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: Text(isEditing ? '编辑配置' : '添加配置'),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: MediaQuery.of(context).size.width * 0.85,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('供应商选择', style: Theme.of(context).textTheme.labelSmall),
                      DropdownButton<String>(
                        value: selectedVendorId,
                        isExpanded: true,
                        items: aiProviders.map((p) => DropdownMenuItem(
                          value: p.id,
                          child: Text(p.name, overflow: TextOverflow.ellipsis),
                        )).toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          final provider = getProviderById(value);
                          setDialogState(() {
                            selectedVendorId = value;
                            if (provider != null) {
                              selectedProvider = provider.provider;
                              nameCtl.text = provider.name;
                              baseUrlCtl.text = provider.defaultBaseUrl;
                              if (provider.models.isNotEmpty) {
                                modelCtl.text = provider.models.first;
                              } else {
                                modelCtl.text = '';
                              }
                            }
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      if (selectedVendorId == 'custom') ...[
                        Text('接口类型', style: Theme.of(context).textTheme.labelSmall),
                        DropdownButton<String>(
                          value: selectedProvider,
                          isExpanded: true,
                          items: const [
                            DropdownMenuItem(value: 'openai', child: Text('OpenAI 兼容')),
                            DropdownMenuItem(value: 'gemini', child: Text('Google Gemini')),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setDialogState(() => selectedProvider = value);
                          },
                        ),
                        const SizedBox(height: 12),
                      ],
                      Text('显示名称', style: Theme.of(context).textTheme.labelSmall),
                      TextField(controller: nameCtl, decoration: const InputDecoration(hintText: '例如：我的模型')),
                      const SizedBox(height: 12),
                      Text('模型名称', style: Theme.of(context).textTheme.labelSmall),
                      _buildModelSelector(selectedVendorId, modelCtl, setDialogState),
                      const SizedBox(height: 12),
                      Text('API Key', style: Theme.of(context).textTheme.labelSmall),
                      TextField(
                        controller: apiKeyCtl,
                        obscureText: !showApiKey,
                        decoration: InputDecoration(
                          hintText: 'sk-...',
                          suffixIcon: IconButton(
                            icon: Icon(showApiKey ? Icons.visibility_off : Icons.visibility),
                            onPressed: () => setDialogState(() => showApiKey = !showApiKey),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (selectedProvider != 'gemini') ...[
                        Text('Base URL', style: Theme.of(context).textTheme.labelSmall),
                        TextField(controller: baseUrlCtl, decoration: const InputDecoration(hintText: 'https://api.openai.com')),
                        const SizedBox(height: 12),
                      ],
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: isTesting
                              ? null
                              : () async {
                                  setDialogState(() {
                                    isTesting = true;
                                    testResult = null;
                                  });
                                  try {
                                    final testConfig = AiConfig(
                                      id: existingConfig?.id ?? 'test',
                                      name: nameCtl.text,
                                      provider: selectedProvider,
                                      modelName: modelCtl.text,
                                      apiKey: apiKeyCtl.text,
                                      baseUrl: baseUrlCtl.text,
                                      vendorId: selectedVendorId,
                                      createdAt: DateTime.now(),
                                      updatedAt: DateTime.now(),
                                    );
                                    final service = AiService();
                                    service.updateConfig(testConfig);
                                    final sw = Stopwatch()..start();
                                    await service.chat([
                                      ChatMessage(role: 'user', content: 'Hi', timestamp: DateTime.now()),
                                    ]);
                                    sw.stop();
                                    final latencyStr = '${sw.elapsedMilliseconds}ms';
                                    if (existingConfig != null) await _saveLatency(existingConfig.id, latencyStr);
                                    setDialogState(() {
                                      isTesting = false;
                                      testResult = '连接成功！延迟: $latencyStr';
                                    });
                                  } catch (e) {
                                    final errMsg = _formatTestError(e);
                                    if (existingConfig != null) await _saveLatency(existingConfig.id, errMsg);
                                    setDialogState(() {
                                      isTesting = false;
                                      testResult = '连接失败: $errMsg';
                                    });
                                  }
                                },
                          child: isTesting
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('连接测试'),
                        ),
                      ),
                      if (testResult != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            testResult!,
                            style: TextStyle(
                              color: testResult!.startsWith('连接成功') ? Colors.green : Colors.red,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () async {
                    final config = AiConfig(
                      id: existingConfig?.id ?? const Uuid().v4(),
                      name: nameCtl.text.isEmpty ? '未命名' : nameCtl.text,
                      provider: selectedProvider,
                      modelName: modelCtl.text,
                      apiKey: apiKeyCtl.text,
                      baseUrl: baseUrlCtl.text,
                      isDefault: existingConfig?.isDefault ?? false,
                      vendorId: selectedVendorId,
                      createdAt: existingConfig?.createdAt ?? DateTime.now(),
                      updatedAt: DateTime.now(),
                    );
                    if (isEditing) {
                      await ref.read(aiConfigListProvider.notifier).updateConfig(config);
                    } else {
                      await ref.read(aiConfigListProvider.notifier).addConfig(config);
                    }
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildModelSelector(String vendorId, TextEditingController modelCtl, StateSetter setDialogState) {
    final providerConfig = getProviderById(vendorId);
    if (providerConfig != null && providerConfig.models.isNotEmpty) {
      final isModelInList = providerConfig.models.contains(modelCtl.text);
      return Column(
        children: [
          DropdownButton<String>(
            value: isModelInList ? modelCtl.text : null,
            isExpanded: true,
            hint: Text(modelCtl.text.isEmpty ? '选择模型' : modelCtl.text),
            items: [
              ...providerConfig.models.map((m) => DropdownMenuItem(
                value: m,
                child: Text(m, overflow: TextOverflow.ellipsis),
              )),
              const DropdownMenuItem(value: '__custom__', child: Text('自定义...')),
            ],
            onChanged: (value) {
              if (value == '__custom__') {
                setDialogState(() => modelCtl.text = '');
              } else if (value != null) {
                setDialogState(() => modelCtl.text = value);
              }
            },
          ),
          if (!isModelInList)
            TextField(
              controller: modelCtl,
              decoration: InputDecoration(hintText: providerConfig.placeholder),
            ),
        ],
      );
    }
    return TextField(
      controller: modelCtl,
      decoration: InputDecoration(hintText: providerConfig?.placeholder ?? '请输入模型名称'),
    );
  }
}
