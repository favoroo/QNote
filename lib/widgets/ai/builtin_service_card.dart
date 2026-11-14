import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_contrast.dart';

import 'package:qnote_flutter/core/ai/builtin_provider.dart';
import 'package:qnote_flutter/core/ai/builtin_request_signer.dart';
import 'package:qnote_flutter/core/ai/builtin_service_config_service.dart';
import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/models/builtin_service_config.dart';
import 'package:qnote_flutter/widgets/common/app_icon_badge.dart';

/// 模型服务列表顶部的「小Q 内置服务」只读卡片。
///
/// 卡片不可点击、没有 chevron、没有二级页面，也不能选模型；唯一可交互的是
/// 「测试」按钮。生图模型不在这里出现，等 `image.enabled` 翻真后由虚拟厂商
/// 自动进入「模型分配 → 生图模型」选择栏。
class BuiltinServiceCard extends StatefulWidget {
  const BuiltinServiceCard({super.key});

  @override
  State<BuiltinServiceCard> createState() => _BuiltinServiceCardState();
}

class _BuiltinServiceCardState extends State<BuiltinServiceCard> {
  final BuiltinServiceConfigService _service = BuiltinServiceConfigService.instance;

  bool _testing = false;
  bool? _testOk;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    _service.configNotifier.addListener(_onServiceChanged);
    _service.refreshing.addListener(_onServiceChanged);
    _service.lastError.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    _service.configNotifier.removeListener(_onServiceChanged);
    _service.refreshing.removeListener(_onServiceChanged);
    _service.lastError.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final config = _service.config;
    final status = _status(theme, config);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const AppIconBadge(
                    icon: Icons.auto_awesome_rounded,
                    size: 30,
                    iconSize: 16,
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            BuiltinProvider.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 6),
                        _badge(theme, '免费', theme.accentInk),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _statusIndicator(theme, status),
                  const SizedBox(width: 8),
                  _testButton(theme),
                ],
              ),
              if (_detailText(config) != null) ...[
                const SizedBox(height: 5),
                Padding(
                  padding: const EdgeInsets.only(left: 40),
                  child: Text(
                    _detailText(config)!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
              if (_testResult != null) ...[
                const SizedBox(height: 5),
                Row(
                  children: [
                    Icon(
                      _testOk == true ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                      size: 13,
                      color: _testOk == true ? _successColor(theme) : colorScheme.error,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        _testResult!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _testOk == true ? _successColor(theme) : colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusIndicator(ThemeData theme, ({String label, Color color}) status) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: status.color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          status.label,
          style: theme.textTheme.labelSmall?.copyWith(color: status.color, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _testButton(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final label = _service.config == null ? '重试' : '测试';
    return OutlinedButton.icon(
      onPressed: _testing ? null : _runTest,
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.8)),
        foregroundColor: colorScheme.onSurface,
      ),
      icon: _testing
          ? const SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.bolt_rounded, size: 14),
      label: Text(label, style: theme.textTheme.labelSmall),
    );
  }

  ({String label, Color color}) _status(ThemeData theme, BuiltinServiceConfig? config) {
    final colorScheme = theme.colorScheme;
    if (config == null) {
      if (_service.lastError.value != null) {
        return (label: '连接失败', color: colorScheme.error);
      }
      return (label: '获取中', color: colorScheme.outline);
    }
    if (!_service.isAppSupported) {
      return (label: '需升级 App', color: _warningColor(theme));
    }
    if (config.maintenance) {
      return (label: '维护中', color: _warningColor(theme));
    }
    if (!config.enabled || !config.isUsable) {
      return (label: '已停用', color: colorScheme.outline);
    }
    return (label: '可用', color: _successColor(theme));
  }

  /// 只在「维护中 / 连接失败 / 版本过低」时补一行短提示；可用状态不占高度
  String? _detailText(BuiltinServiceConfig? config) {
    if (config == null) return _service.lastError.value;
    if (!_service.isAppSupported) return '请升级 App 后使用';
    if (config.maintenance || !config.isUsable) {
      return config.maintenanceMessage.trim().isEmpty ? null : config.maintenanceMessage;
    }
    return null;
  }

  Widget _badge(ThemeData theme, String label, Color color) {
    // 同色系背景下淡底与文字会一起融进卡片，文字按淡底上的可读前景压深
    final ink = AppContrast.inkOnTint(color, theme.cardColor, 0.1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: ink, fontWeight: FontWeight.w600),
      ),
    );
  }

  Color _successColor(ThemeData theme) =>
      theme.brightness == Brightness.dark ? Colors.green.shade400 : Colors.green.shade700;

  Color _warningColor(ThemeData theme) =>
      theme.brightness == Brightness.dark ? Colors.orange.shade300 : Colors.orange.shade800;

  /// 只测连通性：`max_tokens: 8` 的非流式请求，成本极低
  Future<void> _runTest() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _testOk = null;
      _testResult = null;
    });
    try {
      if (!_service.hasConfig) {
        final ok = await _service.refreshIfStale(force: true);
        if (!ok) {
          _finish(false, '配置获取失败，请检查网络后重试');
          return;
        }
      }
      final config = _service.config;
      if (config == null || !config.hasChat) {
        _finish(false, '内置服务配置不可用');
        return;
      }
      if (config.maintenance || !config.isUsable) {
        _finish(false, config.maintenanceMessage.trim().isEmpty ? '内置服务维护中' : config.maintenanceMessage);
        return;
      }

      final stopwatch = Stopwatch()..start();
      final headers = await BuiltinRequestSigner.headersForPath('/v1/chat/completions');
      final dio = Dio(
        BaseOptions(connectTimeout: const Duration(seconds: 8), receiveTimeout: const Duration(seconds: 20)),
      );
      final response = await dio.post<Map<String, dynamic>>(
        '${config.baseUrl}/chat/completions',
        data: <String, dynamic>{
          'model': BuiltinProvider.chatModelId,
          'stream': false,
          'max_tokens': 8,
          'messages': <Map<String, String>>[
            <String, String>{'role': 'user', 'content': 'ping'},
          ],
        },
        options: Options(headers: <String, String>{...headers, 'Content-Type': 'application/json'}),
      );
      stopwatch.stop();
      if (response.statusCode == 200) {
        _finish(true, '连接正常 · ${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
      } else {
        _finish(false, '连接失败（HTTP ${response.statusCode}）');
      }
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 429) {
        _finish(false, '今日免费额度已用完，明天再来');
      } else if (status == 503) {
        _finish(false, '内置服务维护中，请稍后再试');
      } else if (e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout) {
        _finish(false, '连接超时，请检查网络');
      } else if (status != null) {
        _finish(false, '连接失败（HTTP $status）');
      } else {
        _finish(false, '连接失败：${e.message ?? '网络错误'}');
      }
    } catch (e) {
      _finish(false, '连接失败：$e');
    }
  }

  void _finish(bool ok, String message) {
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = ok;
      _testResult = message;
    });
  }
}
