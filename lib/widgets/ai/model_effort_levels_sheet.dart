import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/ai/model_reasoning_capability.dart';
import 'package:qnote_flutter/models/reasoning_effort.dart';

/// 档位配置结果
///
/// [customLevels] 为 null 表示「自动识别」，与「用户取消」区分开——两者都
/// 可能返回 null，但语义完全不同。
class ModelEffortLevelsSelection {
  final List<ReasoningEffort>? customLevels;

  const ModelEffortLevelsSelection(this.customLevels);
}

/// 弹出某模型的「可选思考档位」配置面板
///
/// 这里只决定对话界面出现哪些档位，不设置当前使用哪一档；当前档位统一在
/// 对话的模型面板里调整，避免同一个设置在两个地方打架。
Future<ModelEffortLevelsSelection?> showModelEffortLevelsSheet(
  BuildContext context, {
  required String modelName,
  required String providerType,
  String? vendorId,
  List<ReasoningEffort>? customLevels,
}) {
  return showModalBottomSheet<ModelEffortLevelsSelection>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ModelEffortLevelsSheet(
      modelName: modelName,
      providerType: providerType,
      vendorId: vendorId,
      customLevels: customLevels,
    ),
  );
}

/// 模型可选档位配置：勾选对话里能选的档位
class ModelEffortLevelsSheet extends StatefulWidget {
  final String modelName;
  final String providerType;
  final String? vendorId;

  /// 当前自定义集合；null 表示按模型族自动识别
  final List<ReasoningEffort>? customLevels;

  const ModelEffortLevelsSheet({
    super.key,
    required this.modelName,
    required this.providerType,
    this.vendorId,
    this.customLevels,
  });

  @override
  State<ModelEffortLevelsSheet> createState() => _ModelEffortLevelsSheetState();
}

class _ModelEffortLevelsSheetState extends State<ModelEffortLevelsSheet> {
  /// 自动识别的能力（决定参数形态、候选档位与「恢复」的目标）
  late final ModelReasoningCapability _autoCapability = ModelReasoningCapability.forUi(
    modelName: widget.modelName,
    providerType: widget.providerType,
    vendorId: widget.vendorId,
  );

  late final Set<ReasoningEffort> _selected = {..._autoCapability.withLevels(widget.customLevels).levels};

  bool get _isAuto =>
      _selected.length == _autoCapability.levels.length && _selected.containsAll(_autoCapability.levels);

  /// 当前配置来源：自动识别 / 通用兜底 / 自定义
  String get _sourceLabel {
    if (!_isAuto) return '自定义';
    return _autoCapability.isGeneric ? '通用兜底' : '自动识别';
  }

  void _toggle(ReasoningEffort effort, bool selected) {
    setState(() {
      if (selected) {
        _selected.add(effort);
      } else {
        _selected.remove(effort);
      }
    });
  }

  void _resetToAuto() {
    setState(() {
      _selected
        ..clear()
        ..addAll(_autoCapability.levels);
    });
  }

  /// 一键勾满全部档位；用户不必为了加一档逐行点
  void _selectAll() {
    setState(() {
      _selected
        ..clear()
        ..addAll(ReasoningEffort.values);
    });
  }

  void _clearAll() {
    setState(_selected.clear);
  }

  void _save() {
    if (_selected.isEmpty) return;
    final levels = [
      for (final effort in ReasoningEffort.values)
        if (_selected.contains(effort)) effort,
    ];
    // 勾选结果与自动识别一致时存 null，扫描/升级后仍能跟着能力表走
    final isAuto = levels.length == _autoCapability.levels.length && levels.toSet().containsAll(_autoCapability.levels);
    final selection = ModelEffortLevelsSelection(isAuto ? null : levels);
    Navigator.of(context).pop(selection);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      minChildSize: 0.45,
      maxChildSize: 0.92,
      builder: (context, controller) => Column(
        children: [
          _buildHeader(theme),
          Expanded(
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.only(bottom: 12),
              children: [
                _buildIntro(theme),
                _buildQuickActions(theme),
                for (final effort in _autoCapability.configurableLevels) _buildLevelTile(theme, effort),
              ],
            ),
          ),
          _buildFooter(theme),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    // 自动识别用中性底，自定义用主色底，扫一眼就能分清是不是动过
    final badgeColor = _isAuto ? colorScheme.surfaceContainerHighest : colorScheme.primaryContainer;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('思考档位', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _sourceLabel,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: _isAuto ? colorScheme.onSurfaceVariant : colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  widget.modelName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildIntro(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final autoLabels = _autoCapability.levels.map(_autoCapability.labelFor).join(' / ');
    final autoLine = _autoCapability.isGeneric ? '通用兜底档位：$autoLabels' : '自动识别为 $autoLabels';
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '勾选对话界面能选的档位；当前使用哪一档，在对话的模型面板里设置。',
            style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Text(
            '所有档位都能勾选，协议不能单独表达的档位会按下方「实际发送」折叠。',
            style: theme.textTheme.labelSmall?.copyWith(color: colorScheme.outline),
          ),
          const SizedBox(height: 2),
          Text(
            '$_autoCapability.paramStyleLabel；$autoLine',
            style: theme.textTheme.labelSmall?.copyWith(color: colorScheme.outline),
          ),
          if (_autoCapability.isGeneric) ...[
            const SizedBox(height: 4),
            Text(
              '未收录该模型，参数按通用字段发送，不支持的档位会被端点忽略。',
              style: theme.textTheme.labelSmall?.copyWith(color: colorScheme.outline),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            '取消当前正在使用的档位会先回到「自动」，不会继续发失效参数。',
            style: theme.textTheme.labelSmall?.copyWith(color: colorScheme.outline),
          ),
        ],
      ),
    );
  }

  /// 「全选 / 清空」快捷操作：放开全部档位后不必逐行点
  Widget _buildQuickActions(ThemeData theme) {
    final allSelected = _selected.length == ReasoningEffort.values.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 12, 0),
      child: Row(
        children: [
          Text(
            '可选档位',
            style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline, fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          TextButton(
            onPressed: allSelected ? null : _selectAll,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('全选'),
          ),
          TextButton(
            onPressed: _selected.isEmpty ? null : _clearAll,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }

  Widget _buildLevelTile(ThemeData theme, ReasoningEffort effort) {
    final colorScheme = theme.colorScheme;
    final selected = _selected.contains(effort);
    final label = _autoCapability.labelFor(effort);
    final description = effort.description;
    return CheckboxListTile(
      value: selected,
      onChanged: (value) => _toggle(effort, value ?? false),
      dense: true,
      isThreeLine: true,
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      title: Text(label),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(description),
          Text(
            _autoCapability.wireValueFor(effort),
            style: theme.textTheme.labelSmall?.copyWith(color: colorScheme.outline),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        border: Border(top: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.6))),
      ),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_selected.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('至少保留一个档位，或恢复自动识别', style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.error)),
              ),
            Row(
              children: [
                TextButton(onPressed: _isAuto ? null : _resetToAuto, child: const Text('恢复自动识别')),
                const Spacer(),
                FilledButton(onPressed: _selected.isEmpty ? null : _save, child: const Text('完成')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
