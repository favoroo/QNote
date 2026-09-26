import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:qnote_flutter/core/storage/daily_score_service.dart';
import 'package:qnote_flutter/core/utils/daily_score_adjust.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';

/// 执行一次区间调整（[dryRun] 为 true 时只算不写）。
typedef ScoreAdjustRunner =
    Future<ScoreAdjustRangeResult> Function({
      required DateTime from,
      required DateTime to,
      required ScoreAdjustSpec spec,
      required bool dryRun,
    });

enum _AdjustMode { delta, absolute }

/// 统计页评分 tab 的批量调整抽屉。
///
/// 只依赖 [adjust] 回调，不直接读 Provider 与数据库，因此可脱离 sqflite 单测。
class BatchScoreAdjustSheet extends StatefulWidget {
  const BatchScoreAdjustSheet({super.key, required this.adjust});

  final ScoreAdjustRunner adjust;

  /// 打开抽屉；落库成功后由 service 广播 `/stats/` 事件驱动统计页刷新，调用方无需再 invalidate
  static Future<void> show(BuildContext context, {required ScoreAdjustRunner adjust}) {
    final colorScheme = Theme.of(context).colorScheme;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.86),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: BatchScoreAdjustSheet(adjust: adjust),
        ),
      ),
    );
  }

  @override
  State<BatchScoreAdjustSheet> createState() => _BatchScoreAdjustSheetState();
}

class _BatchScoreAdjustSheetState extends State<BatchScoreAdjustSheet> {
  static final DateFormat _labelFormat = DateFormat('M月d日');

  late DateTime _from;
  late DateTime _to;
  _AdjustMode _mode = _AdjustMode.delta;
  Set<ScoreField> _fields = Set<ScoreField>.from(kAllScoreFields);
  final TextEditingController _deltaController = TextEditingController(text: '-5');
  int _absoluteValue = 80;

  ScoreAdjustRangeResult? _preview;
  bool _loadingPreview = false;
  String? _error;
  bool _applying = false;
  int _requestSeq = 0;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    _to = DateTime(today.year, today.month, today.day);
    _from = _to.subtract(const Duration(days: 6));
    _refreshPreview();
  }

  @override
  void dispose() {
    _deltaController.dispose();
    super.dispose();
  }

  ScoreAdjustSpec? _buildSpec() {
    if (_fields.isEmpty) return null;
    if (_mode == _AdjustMode.delta) {
      final delta = int.tryParse(_deltaController.text.trim());
      if (delta == null || delta == 0) return null;
      return ScoreAdjustSpec(delta: delta, fields: _fields);
    }
    return ScoreAdjustSpec(setValue: _absoluteValue, fields: _fields);
  }

  Future<void> _refreshPreview() async {
    final spec = _buildSpec();
    final seq = ++_requestSeq;
    if (spec == null) {
      setState(() {
        _preview = null;
        _loadingPreview = false;
      });
      return;
    }
    setState(() => _loadingPreview = true);
    try {
      final result = await widget.adjust(
        from: _from,
        to: _to,
        spec: spec,
        dryRun: true,
      );
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _preview = result;
        _loadingPreview = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _preview = null;
        _loadingPreview = false;
        _error = '$e';
      });
    }
  }

  Future<void> _apply(ScoreAdjustSpec spec) async {
    setState(() => _applying = true);
    try {
      final result = await widget.adjust(
        from: _from,
        to: _to,
        spec: spec,
        dryRun: false,
      );
      if (!mounted) return;
      setState(() => _applying = false);
      Toast.success(context, '已调整 ${result.applied} 天评分${_clampedSuffix(result)}');
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _applying = false;
        _error = '$e';
      });
      Toast.error(context, '调整失败，请重试');
    }
  }

  String _clampedSuffix(ScoreAdjustRangeResult result) {
    final parts = <String>[];
    if (result.clamped > 0) parts.add('${result.clamped} 天已到上下限');
    if (result.missingDays > 0) parts.add('${result.missingDays} 天无评分已跳过');
    parts.add('评语文字未变');
    return '（${parts.join('，')}）';
  }

  void _setRange(DateTime from, DateTime to) {
    setState(() {
      _from = DateTime(from.year, from.month, from.day);
      _to = DateTime(to.year, to.month, to.day);
    });
    _refreshPreview();
  }

  Future<void> _pickDate({required bool isStart}) async {
    final today = DateTime.now();
    final initial = isStart ? _from : _to;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(today.year, today.month, today.day),
      locale: const Locale('zh', 'CN'),
    );
    if (picked == null) return;
    if (isStart) {
      _setRange(picked, _to.isBefore(picked) ? picked : _to);
    } else {
      _setRange(_from.isAfter(picked) ? picked : _from, picked);
    }
  }

  void _applyQuickRange(int days) {
    final today = DateTime.now();
    final end = DateTime(today.year, today.month, today.day);
    _setRange(end.subtract(Duration(days: days - 1)), end);
  }

  void _applyThisMonth() {
    final today = DateTime.now();
    _setRange(DateTime(today.year, today.month, 1), today);
  }

  void _toggleField(ScoreField field) {
    setState(() {
      if (_fields.contains(field)) {
        _fields = _fields.difference({field});
      } else {
        _fields = _fields.union({field});
      }
    });
    _refreshPreview();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final spec = _buildSpec();
    final applied = _preview?.applied ?? 0;
    final canApply = spec != null && applied > 0 && !_applying;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: colorScheme.outlineVariant.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text(
            '批量调整历史评分',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '对已有评分按同一规则改分；区间内没有评分的日期会被跳过，不会新建记录。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ActionChip(
                        label: const Text('近7天'),
                        onPressed: _applying ? null : () => _applyQuickRange(7),
                      ),
                      ActionChip(
                        label: const Text('近30天'),
                        onPressed: _applying ? null : () => _applyQuickRange(30),
                      ),
                      ActionChip(
                        label: const Text('本月'),
                        onPressed: _applying ? null : _applyThisMonth,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _applying ? null : () => _pickDate(isStart: true),
                          icon: const Icon(Icons.calendar_today_outlined, size: 16),
                          label: Text('起 ${_labelFormat.format(_from)}'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _applying ? null : () => _pickDate(isStart: false),
                          icon: const Icon(Icons.calendar_today_outlined, size: 16),
                          label: Text('止 ${_labelFormat.format(_to)}'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SegmentedButton<_AdjustMode>(
                    segments: const [
                      ButtonSegment(value: _AdjustMode.delta, label: Text('加减分')),
                      ButtonSegment(value: _AdjustMode.absolute, label: Text('设为固定值')),
                    ],
                    selected: {_mode},
                    onSelectionChanged: _applying
                        ? null
                        : (selection) {
                            setState(() => _mode = selection.first);
                            _refreshPreview();
                          },
                  ),
                  const SizedBox(height: 12),
                  if (_mode == _AdjustMode.delta)
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _deltaController,
                            enabled: !_applying,
                            keyboardType: const TextInputType.numberWithOptions(
                              signed: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: '加减分值',
                              helperText: '负数表示降分',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (_) => _refreshPreview(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        for (final preset in const [-20, -10, -5, 5, 10, 20])
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: ActionChip(
                              label: Text(preset > 0 ? '+$preset' : '$preset'),
                              onPressed: _applying
                                  ? null
                                  : () {
                                      _deltaController.text = '$preset';
                                      _refreshPreview();
                                    },
                            ),
                          ),
                      ],
                    )
                  else
                    Slider(
                      value: _absoluteValue.toDouble(),
                      min: 0,
                      max: 100,
                      divisions: 20,
                      label: '$_absoluteValue 分',
                      onChanged: _applying
                          ? null
                          : (value) {
                              setState(() => _absoluteValue = value.round());
                              _refreshPreview();
                            },
                    ),
                  const SizedBox(height: 12),
                  Text('作用字段', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final field in ScoreField.values)
                        FilterChip(
                          label: Text(field.label),
                          selected: _fields.contains(field),
                          onSelected: _applying ? null : (_) => _toggleField(field),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildPreviewCard(context, applied: applied),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: canApply ? () => _apply(spec) : null,
              icon: _applying
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
              label: Text(applied > 0 ? '应用到 $applied 天' : _noTargetLabel()),
            ),
          ),
        ],
      ),
    );
  }

  String _noTargetLabel() {
    if (_fields.isEmpty) return '请至少选择一个字段';
    if (_buildSpec() == null) return '请填写调整数值';
    return '该区间没有需要改动的评分';
  }

  Widget _buildPreviewCard(BuildContext context, {required int applied}) {
    final colorScheme = Theme.of(context).colorScheme;
    final result = _preview;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: _loadingPreview
          ? Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text('正在计算影响范围…', style: Theme.of(context).textTheme.bodySmall),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  result == null
                      ? '填写调整规则后这里会列出将被改动的日期与前后分值'
                      : result.preview,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (result != null && result.outcomes.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (final outcome in result.outcomes.take(6))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 56,
                            child: Text(
                              _labelFormat.format(outcome.before.date),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              outcome.changes
                                  .map((c) => '${c.field.label} ${c.before ?? '—'}→${c.after}')
                                  .join('　'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: colorScheme.primary,
                              ),
                            ),
                          ),
                          if (outcome.clamped)
                            Tooltip(
                              message: '已到上下限，实际幅度不足所请求的加减分',
                              child: Icon(
                                Icons.warning_amber_rounded,
                                size: 16,
                                color: colorScheme.error,
                              ),
                            ),
                        ],
                      ),
                    ),
                  if (result.outcomes.length > 6)
                    Text(
                      '…另有 ${result.outcomes.length - 6} 天同类改动',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
                const SizedBox(height: 8),
                Text(
                  '总分不随维度重算，评语与建议文字保持不变；超出近 3 个月的日期不会出现在热力图上。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
    );
  }
}
