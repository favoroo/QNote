import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:dio/dio.dart';
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
  List<String> _openRouterFreeModels = [];
  bool _isFetchingFreeModels = false;
  String? _fetchMessage;
  bool _fetchMessageIsError = false;

  @override
  void initState() {
    super.initState();
    _loadRoles();
    _loadLatencies();
    _loadOpenRouterFreeModels();
  }

  Future<void> _loadOpenRouterFreeModels() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedModels = prefs.getStringList('openrouter_free_models');
    if (cachedModels != null && cachedModels.isNotEmpty) {
      if (mounted) {
        setState(() {
          _openRouterFreeModels = cachedModels;
        });
      }
    }
  }

  Future<void> _fetchOpenRouterFreeModels(StateSetter setDialogState) async {
    if (_isFetchingFreeModels) return;
    setDialogState(() {
      _isFetchingFreeModels = true;
      _fetchMessage = null;
    });
    setState(() {
      _isFetchingFreeModels = true;
      _fetchMessage = null;
    });

    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
      ));
      
      final response = await dio.get(
        'https://openrouter.ai/api/frontend/models/find?active=true&fmt=cards&q=free',
        options: Options(
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Accept': 'application/json',
            'Referer': 'https://openrouter.ai/',
          },
        ),
      );

      if (response.statusCode == 200) {
        final data = response.data;
        if (data is Map && data['data'] != null) {
          final nestedData = data['data'];
          final modelsList = nestedData['models'];
          final Map<String, dynamic> analytics = nestedData['analytics'] is Map ? nestedData['analytics'] : {};

          if (modelsList is List) {
            final List<Map<String, dynamic>> parsedModels = [];
            for (final item in modelsList) {
              if (item is Map) {
                final endpoint = item['endpoint'];
                if (endpoint is Map && endpoint['is_free'] == true) {
                  final slug = endpoint['model_variant_slug'];
                  final permaslug = endpoint['model_variant_permaslug'];
                  if (slug is String && slug.isNotEmpty) {
                    int usage = 0;
                    
                    int getUsage(String key) {
                      final cleanKey = key.replaceAll(':free', '');
                      if (analytics[cleanKey] != null) {
                        final a = analytics[cleanKey];
                        if (a is Map) {
                          return ((a['total_prompt_tokens'] ?? 0) as num).toInt() + ((a['total_completion_tokens'] ?? 0) as num).toInt();
                        }
                      }
                      if (analytics[key] != null) {
                        final a = analytics[key];
                        if (a is Map) {
                          return ((a['total_prompt_tokens'] ?? 0) as num).toInt() + ((a['total_completion_tokens'] ?? 0) as num).toInt();
                        }
                      }
                      return 0;
                    }

                    usage = getUsage(permaslug ?? slug);
                    if (usage == 0) usage = getUsage(slug);

                    parsedModels.add({
                      'slug': slug,
                      'usage': usage,
                    });
                  }
                }
              }
            }

            parsedModels.sort((a, b) => (b['usage'] as int).compareTo(a['usage'] as int));
            final List<String> freeModelsList = parsedModels.map((m) => m['slug'] as String).toList();

            if (freeModelsList.isNotEmpty) {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setStringList('openrouter_free_models', freeModelsList);

              if (mounted) {
                setDialogState(() {
                  _openRouterFreeModels = freeModelsList;
                  _fetchMessage = '成功获取并更新了 ${freeModelsList.length} 个免费模型！';
                  _fetchMessageIsError = false;
                });
                setState(() {
                  _openRouterFreeModels = freeModelsList;
                  _fetchMessage = '成功获取并更新了 ${freeModelsList.length} 个免费模型！';
                  _fetchMessageIsError = false;
                });
                }
// Success dialog removed; using in-dialog banner
            } else {
              throw Exception('未找到任何免费模型');
            }
          } else {
            throw Exception('模型数据列表格式无效');
          }
        } else {
          throw Exception('返回数据结构无效');
        }
      } else {
        throw Exception('HTTP 错误: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        String errorMsg = e.toString();
        if (e is DioException) {
          if (kIsWeb && (errorMsg.contains('XMLHttpRequest') || errorMsg.contains('CORS'))) {
            errorMsg = 'Web端存在CORS跨域限制，请在模拟器或真机中点击获取。';
          } else {
            errorMsg = '网络连接失败，请检查网络设置。';
          }
        }
        setDialogState(() {
          _fetchMessage = '获取失败: $errorMsg';
          _fetchMessageIsError = true;
        });
        setState(() {
          _fetchMessage = '获取失败: $errorMsg';
          _fetchMessageIsError = true;
        });
// Snackbar removed; using in-dialog banner for error feedback
      }
    } finally {
      if (mounted) {
        setDialogState(() {
          _isFetchingFreeModels = false;
        });
        setState(() {
          _isFetchingFreeModels = false;
        });
      }
    }
  }

  void _showModelPickerBottomSheet({
    required BuildContext context,
    required List<String> models,
    required String currentSelected,
    required ValueChanged<String> onSelected,
  }) {
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return _ModelPickerBottomSheet(
          models: models,
          currentSelected: currentSelected,
          onSelected: onSelected,
        );
      },
    );
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
    if (e is DioException) {
      final responseData = e.response?.data;
      if (responseData != null) {
        if (responseData is Map) {
          final errorObj = responseData['error'];
          if (errorObj != null) {
            if (errorObj is Map && errorObj['message'] != null) {
              return '错误: ${errorObj['message']}';
            } else if (errorObj is String) {
              return '错误: $errorObj';
            }
          }
          if (responseData['message'] != null) {
            return '错误: ${responseData['message']}';
          }
        } else if (responseData is String && responseData.isNotEmpty) {
          return '错误: $responseData';
        }
      }
      final msg = e.toString();
      if (kIsWeb && (msg.contains('XMLHttpRequest') || msg.contains('connection error') || msg.contains('CORS') || msg.contains('onError'))) {
        return '浏览器限制：Web端无法直接调用外部API（CORS），请在真机上测试';
      }
      if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.receiveTimeout) {
        return '请求超时';
      }
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
        return '认证失败，请检查API Key';
      }
      if (e.response?.statusCode != null) {
        return 'HTTP ${e.response!.statusCode} 错误';
      }
    }

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
    ref.invalidate(aiTemperaturesProvider);
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
            if (roleKey == 'timelineOptimization') ...[
              const SizedBox(height: 4),
              Divider(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '是否提取图片',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '提取时包含图片信息（需要模型支持）',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: settings.extractImages,
                    onChanged: (value) {
                      _updateRoleSettings(roleKey, settings.copyWith(extractImages: value));
                    },
                  ),
                ],
              ),
            ],
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

    // Reset fetch status message when dialog opens
    _fetchMessage = null;
    _fetchMessageIsError = false;

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
                            _fetchMessage = null;
                            _fetchMessageIsError = false;
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
                      Row(
                        children: [
                          Text('模型名称', style: Theme.of(context).textTheme.labelSmall),
                          const Spacer(),
                          if (selectedVendorId == 'openrouter')
                            TextButton.icon(
                              onPressed: _isFetchingFreeModels
                                  ? null
                                  : () => _fetchOpenRouterFreeModels(setDialogState),
                              icon: _isFetchingFreeModels
                                  ? const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.refresh, size: 14),
                              label: Text(
                                _isFetchingFreeModels ? '更新中...' : '一键获取免费模型',
                                style: const TextStyle(fontSize: 11),
                              ),
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                        ],
                      ),
                      if (selectedVendorId == 'openrouter' && _fetchMessage != null) ...[
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: _fetchMessageIsError 
                                ? Colors.red.shade50.withValues(alpha: 0.8) 
                                : Colors.green.shade50.withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: _fetchMessageIsError 
                                  ? Colors.red.shade200.withValues(alpha: 0.5) 
                                  : Colors.green.shade200.withValues(alpha: 0.5),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _fetchMessageIsError ? Icons.error_outline : Icons.check_circle_outline,
                                size: 14,
                                color: _fetchMessageIsError ? Colors.red.shade700 : Colors.green.shade700,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  _fetchMessage!,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: _fetchMessageIsError ? Colors.red.shade800 : Colors.green.shade800,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      _buildModelSelector(ctx, selectedVendorId, modelCtl, setDialogState),
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

  Widget _buildModelSelector(BuildContext dialogContext, String vendorId, TextEditingController modelCtl, StateSetter setDialogState) {
    final providerConfig = getProviderById(vendorId);
    
    List<String> modelsList = [];
    if (vendorId == 'openrouter') {
      modelsList = _openRouterFreeModels.isNotEmpty ? _openRouterFreeModels : (providerConfig?.models ?? []);
    } else {
      modelsList = providerConfig?.models ?? [];
    }

    final hasPredefinedModels = modelsList.isNotEmpty;
    final isModelInList = modelsList.contains(modelCtl.text);

    if (hasPredefinedModels) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          InkWell(
            onTap: () {
              _showModelPickerBottomSheet(
                context: dialogContext,
                models: modelsList,
                currentSelected: modelCtl.text,
                onSelected: (selectedVal) {
                  if (selectedVal == '__custom__') {
                    setDialogState(() => modelCtl.text = '');
                  } else {
                    setDialogState(() => modelCtl.text = selectedVal);
                  }
                },
              );
            },
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(dialogContext).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(dialogContext).colorScheme.outlineVariant.withValues(alpha: 0.5),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      modelCtl.text.isEmpty
                          ? '点击选择模型...'
                          : (modelCtl.text.contains('/')
                              ? modelCtl.text.split('/').last.replaceAll(':free', '')
                              : modelCtl.text),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: modelCtl.text.isEmpty ? FontWeight.normal : FontWeight.bold,
                        color: modelCtl.text.isEmpty
                            ? Theme.of(dialogContext).colorScheme.onSurfaceVariant
                            : Theme.of(dialogContext).colorScheme.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    Icons.arrow_drop_down,
                    color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (modelCtl.text.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '完整 ID: ${modelCtl.text}',
              style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(fontSize: 10, color: Theme.of(dialogContext).colorScheme.onSurfaceVariant),
            ),
          ],
          if (!isModelInList) ...[
            const SizedBox(height: 8),
            TextField(
              controller: modelCtl,
              decoration: InputDecoration(
                hintText: providerConfig?.placeholder ?? '请输入自定义模型名称',
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ],
      );
    }

    return TextField(
      controller: modelCtl,
      decoration: InputDecoration(
        hintText: providerConfig?.placeholder ?? '请输入模型名称',
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      style: const TextStyle(fontSize: 13),
    );
  }
}

class _ModelPickerBottomSheet extends StatefulWidget {
  final List<String> models;
  final String currentSelected;
  final ValueChanged<String> onSelected;

  const _ModelPickerBottomSheet({
    required this.models,
    required this.currentSelected,
    required this.onSelected,
  });

  @override
  State<_ModelPickerBottomSheet> createState() => _ModelPickerBottomSheetState();
}

class _ModelPickerBottomSheetState extends State<_ModelPickerBottomSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _parseProvider(String model) {
    if (!model.contains('/')) return '';
    return model.split('/').first.toLowerCase();
  }

  Widget _buildProviderChip(String provider, ThemeData theme) {
    if (provider.isEmpty) return const SizedBox.shrink();

    Color bgColor;
    Color textColor;

    switch (provider) {
      case 'google':
        bgColor = Colors.blue.shade50;
        textColor = Colors.blue.shade700;
        break;
      case 'openai':
        bgColor = Colors.teal.shade50;
        textColor = Colors.teal.shade700;
        break;
      case 'meta':
      case 'meta-llama':
        bgColor = Colors.purple.shade50;
        textColor = Colors.purple.shade700;
        break;
      case 'mistral':
      case 'mistralai':
        bgColor = Colors.orange.shade50;
        textColor = Colors.orange.shade700;
        break;
      case 'deepseek':
        bgColor = Colors.indigo.shade50;
        textColor = Colors.indigo.shade700;
        break;
      case 'qwen':
        bgColor = Colors.cyan.shade50;
        textColor = Colors.cyan.shade700;
        break;
      case 'nvidia':
        bgColor = Colors.green.shade50;
        textColor = Colors.green.shade700;
        break;
      case 'microsoft':
        bgColor = Colors.blueGrey.shade50;
        textColor = Colors.blueGrey.shade700;
        break;
      case 'cohere':
        bgColor = Colors.amber.shade50;
        textColor = Colors.amber.shade900;
        break;
      default:
        bgColor = Colors.grey.shade100;
        textColor = Colors.grey.shade700;
    }

    final displayName = provider.toUpperCase() == 'OPENAI' || provider.toUpperCase() == 'GLM'
        ? provider.toUpperCase()
        : provider[0].toUpperCase() + provider.substring(1);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        displayName,
        style: TextStyle(
          color: textColor,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filteredModels = widget.models
        .where((m) => m.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      padding: EdgeInsets.only(
        top: 16,
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: FractionallySizedBox(
        heightFactor: 0.7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '选择模型',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '共 ${widget.models.length} 个模型',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索模型名称...',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          setState(() {
                            _searchController.clear();
                            _searchQuery = '';
                          });
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: theme.colorScheme.primary.withValues(alpha: 0.5),
                    width: 1.5,
                  ),
                ),
              ),
              onChanged: (val) {
                setState(() {
                  _searchQuery = val;
                });
              },
            ),
            const SizedBox(height: 16),
            Expanded(
              child: filteredModels.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.search_off_outlined,
                            size: 48,
                            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '未找到匹配的模型',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: filteredModels.length + 1,
                      itemBuilder: (context, index) {
                        if (index == filteredModels.length) {
                          final isSelected = widget.currentSelected == '__custom__' || 
                              (!widget.models.contains(widget.currentSelected) && widget.currentSelected.isNotEmpty);
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            leading: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.edit_note_outlined,
                                size: 18,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            title: const Text(
                              '自定义模型标识符...',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            subtitle: const Text(
                              '手动输入其他模型 ID',
                              style: TextStyle(fontSize: 11),
                            ),
                            trailing: isSelected
                                ? Icon(Icons.check_circle, color: theme.colorScheme.primary, size: 20)
                                : null,
                            selected: isSelected,
                            onTap: () {
                              Navigator.pop(context);
                              widget.onSelected('__custom__');
                            },
                          );
                        }

                        final model = filteredModels[index];
                        final isSelected = model == widget.currentSelected;
                        final provider = _parseProvider(model);
                        
                        String displayName = model;
                        if (model.contains('/')) {
                          displayName = model.split('/').last;
                        }
                        displayName = displayName.replaceAll(':free', '');

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: InkWell(
                            onTap: () {
                              Navigator.pop(context);
                              widget.onSelected(model);
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? theme.colorScheme.primaryContainer.withValues(alpha: 0.15)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isSelected
                                      ? theme.colorScheme.primary.withValues(alpha: 0.3)
                                      : Colors.transparent,
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 12,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: isSelected
                                            ? theme.colorScheme.primary
                                            : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                                        width: isSelected ? 3.5 : 1.5,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          displayName,
                                          style: theme.textTheme.bodyMedium?.copyWith(
                                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                            color: isSelected
                                                ? theme.colorScheme.primary
                                                : theme.colorScheme.onSurface,
                                            fontSize: 13,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          model,
                                          style: theme.textTheme.bodySmall?.copyWith(
                                            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                                            fontSize: 10.5,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (provider.isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    _buildProviderChip(provider, theme),
                                  ],
                                  if (model.endsWith(':free')) ...[
                                    const SizedBox(width: 4),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                      decoration: BoxDecoration(
                                        color: Colors.green.shade50,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: const Text(
                                        'FREE',
                                        style: TextStyle(
                                          color: Colors.green,
                                          fontSize: 8,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
