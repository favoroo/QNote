import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:qnote_flutter/core/knowledge/kg_config.dart';
import 'package:qnote_flutter/core/knowledge/kg_indexer.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/providers/knowledge_graph_provider.dart';

/// 知识图谱设置页。
///
/// 只放在「小Q设置 → 图谱」分段里，不进入一级导航。图谱不会在后台自动运行：
/// 用户点「更新图谱」才做本地规则整理，点「深度分析笔记」才在确认额度后调用模型。
/// 这里同时展示索引状态、待整理数量与实时进度，面向想控制模型消耗或排查问题的用户。
class QKnowledgePage extends ConsumerStatefulWidget {
  const QKnowledgePage({super.key, this.embedded = false});

  /// 嵌入模式：由小Q设置综合页承载时不重复生成 Scaffold/AppBar
  final bool embedded;

  @override
  ConsumerState<QKnowledgePage> createState() => _QKnowledgePageState();
}

class _QKnowledgePageState extends ConsumerState<QKnowledgePage> {
  bool _loading = true;
  bool _busy = false;
  bool _enabled = true;
  bool _semantic = true;
  bool _running = false;
  int _limit = KgConfig.defaultDailyDocLimit;

  static const _limitOptions = [10, 30, 60, 100];

  @override
  void initState() {
    super.initState();
    _running = KnowledgeGraphIndexer.instance.isRunning;
    KnowledgeGraphIndexer.instance.progress.addListener(_onProgressChanged);
    _load();
  }

  @override
  void dispose() {
    KnowledgeGraphIndexer.instance.progress.removeListener(_onProgressChanged);
    super.dispose();
  }

  void _onProgressChanged() {
    final running = KnowledgeGraphIndexer.instance.progress.value != null;
    if (!mounted || running == _running) return;
    setState(() => _running = running);
    if (!running) {
      ref.invalidate(kgStatusProvider);
      ref.invalidate(kgInsightsProvider);
    }
  }

  Future<void> _load() async {
    final enabled = await KgConfig.isEnabled();
    final semantic = await KgConfig.isSemanticEnabled();
    final limit = await KgConfig.dailyDocLimit();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _semantic = semantic;
      _limit = limit;
      _loading = false;
    });
  }

  Future<void> _setEnabled(bool value) async {
    setState(() => _enabled = value);
    await KgConfig.setEnabled(value);
    if (mounted) ref.invalidate(kgStatusProvider);
  }

  Future<void> _setSemantic(bool value) async {
    setState(() => _semantic = value);
    await KgConfig.setSemanticEnabled(value);
  }

  Future<void> _setLimit(int? value) async {
    if (value == null) return;
    setState(() => _limit = value);
    await KgConfig.setDailyDocLimit(value);
  }

  Future<bool> _confirmSemantic(KgSemanticPlan plan) async {
    if (!mounted) return false;
    final chars = plan.characters >= 10000
        ? '${(plan.characters / 10000).toStringAsFixed(1)} 万字'
        : '${plan.characters} 字';
    final confirmed = await AppMotion.showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('深度分析笔记'),
        content: Text(
          '将分析 ${plan.documents} 篇笔记/日记（约 $chars），使用「时间线提取模型」，'
          '只保留有原文证据的实体和关系。\n\n'
          '今日已用 ${plan.dailyUsed}/${plan.dailyLimit} 篇。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('跳过')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('开始分析')),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _startUpdate({required bool semantic, bool forceFull = false}) async {
    if (!_enabled) {
      Toast.warning(context, '请先启用知识图谱');
      return;
    }
    if (_running) return;

    try {
      final report = await KnowledgeGraphIndexer.instance.run(
        semantic: semantic && _semantic,
        forceFull: forceFull,
        confirmSemantic: _confirmSemantic,
      );
      if (!mounted) return;
      final summary = _summarize(report);
      final pendingHint = _semantic && report.semanticPending > 0 ? '；${report.semanticPending} 篇笔记可深度分析' : '';
      if (report.error != null) {
        Toast.error(context, '更新失败：${report.error}');
      } else if (report.cancelled) {
        Toast.info(context, summary.isEmpty ? '已停止更新' : '已停止更新（$summary）');
      } else if (report.semanticUnavailable) {
        Toast.warning(context, summary.isEmpty ? '未配置「时间线提取模型」，无法深度分析' : '$summary；未配置「时间线提取模型」，已跳过深度分析');
      } else if (report.semanticDeclined) {
        Toast.info(context, summary.isEmpty ? '已跳过深度分析' : '$summary，已跳过深度分析');
      } else if (report.semanticQuotaExhausted) {
        Toast.warning(context, summary.isEmpty ? '今日深度分析额度已用完' : '$summary；今日深度分析额度已用完');
      } else if (report.failed > 0) {
        Toast.warning(context, summary.isEmpty ? '更新失败 ${report.failed} 条' : '$summary，失败 ${report.failed} 条');
      } else if (!report.hasChanges) {
        Toast.success(context, '图谱已是最新$pendingHint');
      } else {
        Toast.success(context, '$summary$pendingHint');
      }
    } catch (e) {
      if (mounted) Toast.error(context, '更新失败：$e');
    } finally {
      if (mounted) {
        ref.invalidate(kgStatusProvider);
        ref.invalidate(kgInsightsProvider);
      }
    }
  }

  String _summarize(KgIndexReport report) {
    final parts = <String>[
      if (report.updated > 0) '更新 ${report.updated} 条',
      if (report.removed > 0) '清理 ${report.removed} 条',
      if (report.semanticUpdated > 0) '深度分析 ${report.semanticUpdated} 篇',
    ];
    return parts.join('，');
  }

  Future<void> _rebuild() async {
    if (!_enabled) {
      Toast.warning(context, '请先启用知识图谱');
      return;
    }
    final confirmed = await AppMotion.showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('全部重建'),
        content: const Text(
          '将清空现有实体与关联，并按全部记录重新建图。'
          '只做本地规则整理，不调用模型；需要语义分析可之后再点「深度分析笔记」。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('开始重建')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final report = await KnowledgeGraphIndexer.instance.rebuildAll();
      if (!mounted) return;
      if (report.error != null) {
        Toast.error(context, '重建失败：${report.error}');
      } else {
        final summary = _summarize(report);
        Toast.success(context, summary.isEmpty ? '重建完成' : '重建完成：$summary');
      }
    } catch (e) {
      if (mounted) Toast.error(context, '重建失败：$e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        ref.invalidate(kgStatusProvider);
        ref.invalidate(kgInsightsProvider);
      }
    }
  }

  Future<void> _clear() async {
    final confirmed = await AppMotion.showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空图谱数据'),
        content: const Text(
          '只清空派生出的实体、关系与关联发现，不影响时间线、笔记、待办等源数据。'
          '下次手动更新时会重新建图。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await KnowledgeGraphIndexer.instance.clear();
      if (mounted) Toast.success(context, '已清空图谱数据');
    } catch (e) {
      if (mounted) Toast.error(context, '清空失败：$e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        ref.invalidate(kgStatusProvider);
        ref.invalidate(kgInsightsProvider);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _buildConfigCard(theme),
              const SizedBox(height: 16),
              _buildStatusCard(theme),
              const SizedBox(height: 16),
              _buildAdvancedCard(theme),
            ],
          );

    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('知识图谱'), centerTitle: false),
      body: body,
    );
  }

  Widget _buildConfigCard(ThemeData theme) {
    final locked = _busy || _running;
    return _card(
      theme,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.touch_app_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '图谱只在手动更新时运行，不会在后台自动扫描或调用模型',
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(Icons.hub_outlined, color: theme.colorScheme.primary),
          title: const Text('启用知识图谱'),
          subtitle: const Text('把时间线、笔记、日记、待办与健康数据整理成关联网络，供小Q查询'),
          value: _enabled,
          onChanged: locked ? null : _setEnabled,
        ),
        const Divider(height: 1),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(Icons.auto_awesome_outlined, color: theme.colorScheme.primary),
          title: const Text('允许深度分析'),
          subtitle: const Text(
            '在「深度分析笔记」时用「时间线提取模型」补充人物、地点、项目等实体；'
            '关闭后仍保留结构化图谱',
          ),
          value: _semantic && _enabled,
          onChanged: locked || !_enabled ? null : _setSemantic,
        ),
        if (_semantic && _enabled)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.speed_outlined),
            title: const Text('每日语义分析上限'),
            subtitle: const Text('超过上限的笔记会在后续深度分析中继续处理'),
            trailing: DropdownButton<int>(
              value: _limitOptions.contains(_limit) ? _limit : _limitOptions.first,
              underline: const SizedBox.shrink(),
              items: [for (final option in _limitOptions) DropdownMenuItem(value: option, child: Text('$option 篇/天'))],
              onChanged: locked ? null : _setLimit,
            ),
          ),
      ],
    );
  }

  Widget _buildStatusCard(ThemeData theme) {
    final statusAsync = ref.watch(kgStatusProvider);
    return _card(
      theme,
      children: [
        Row(
          children: [
            Icon(Icons.insights_outlined, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text('图谱状态', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 12),
        statusAsync.when(
          loading: () => const LinearProgressIndicator(minHeight: 2),
          error: (e, _) => Text('读取失败：$e', style: theme.textTheme.bodySmall),
          data: (status) => _buildStatusRows(theme, status),
        ),
        const SizedBox(height: 14),
        ValueListenableBuilder<KgRunProgress?>(
          valueListenable: KnowledgeGraphIndexer.instance.progress,
          builder: (context, progress, _) {
            if (progress != null) return _buildProgress(theme, progress);
            return _buildActions(theme);
          },
        ),
      ],
    );
  }

  Widget _buildStatusRows(ThemeData theme, Map<String, dynamic> status) {
    final lastScan = DateTime.tryParse(status['last_scan_at']?.toString() ?? '');
    final pending = (status['pending_rule_count'] as num?)?.toInt() ?? 0;
    final hasSource = status['has_source_data'] == true;
    final pendingText = pending < 0 ? (hasSource ? '尚未建立' : '暂无记录') : (pending == 0 ? '暂无新记录' : '约 $pending 条');
    return Column(
      children: [
        _statusRow(theme, '已索引记录', '${status['document_count'] ?? 0} 条'),
        _statusRow(theme, '待整理', pendingText, valueColor: pending > 0 ? theme.colorScheme.primary : null),
        _statusRow(theme, '实体 / 状态', '${status['entity_count'] ?? 0} / ${status['state_count'] ?? 0}'),
        _statusRow(theme, '关系 / 提及', '${status['edge_count'] ?? 0} / ${status['mention_count'] ?? 0}'),
        if (_semantic && _enabled)
          _statusRow(theme, '今日语义分析', '${status['semantic_docs_today'] ?? 0}/${status['semantic_limit'] ?? _limit} 篇'),
        _statusRow(theme, '最近更新', lastScan == null ? '尚未更新' : DateFormat('MM-dd HH:mm').format(lastScan)),
      ],
    );
  }

  Widget _buildActions(ThemeData theme) {
    final canRun = _enabled && !_busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: canRun ? () => _startUpdate(semantic: false) : null,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('更新图谱'),
        ),
        if (_semantic) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: canRun ? () => _startUpdate(semantic: true, forceFull: true) : null,
            icon: const Icon(Icons.manage_search_rounded),
            label: const Text('深度分析笔记'),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          _semantic ? '更新只处理新增和修改的记录；深度分析会扫描全部笔记/日记，并在调用模型前确认篇数与今日额度。' : '更新只做本地规则整理，不调用模型。',
          style: theme.textTheme.bodySmall?.copyWith(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _buildProgress(ThemeData theme, KgRunProgress progress) {
    final phase = switch (progress.phase) {
      KgRunPhase.collecting => '收集记录',
      KgRunPhase.rules => '整理记录',
      KgRunPhase.semantic => '深度分析',
      KgRunPhase.topics => '计算主题',
      KgRunPhase.insights => '更新关联发现',
    };
    final count = progress.total == null ? '${progress.done}' : '${progress.done}/${progress.total}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '$phase · ${progress.message}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            if (progress.total != null && progress.total! > 0) ...[
              const SizedBox(width: 8),
              Text(count, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
            ],
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: progress.fraction, minHeight: 4),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: KnowledgeGraphIndexer.instance.cancel,
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: const Text('停止'),
          ),
        ),
      ],
    );
  }

  Widget _buildAdvancedCard(ThemeData theme) {
    final locked = _busy || _running;
    return _card(
      theme,
      children: [
        Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            leading: const Icon(Icons.build_outlined),
            title: const Text('高级操作'),
            subtitle: const Text('重建或清空派生数据'),
            shape: const Border(),
            collapsedShape: const Border(),
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.restart_alt_rounded),
                title: const Text('全部重建'),
                subtitle: const Text('清空派生图后按全部记录重跑；不调用模型'),
                trailing: locked
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.chevron_right_rounded),
                onTap: locked ? null : _rebuild,
              ),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.delete_outline_rounded, color: theme.colorScheme.error),
                title: Text('清空图谱数据', style: TextStyle(color: theme.colorScheme.error)),
                subtitle: const Text('不影响源记录；下次手动更新时会重新建图'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: locked ? null : _clear,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _statusRow(ThemeData theme, String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500, color: valueColor),
          ),
        ],
      ),
    );
  }

  Widget _card(ThemeData theme, {required List<Widget> children}) {
    // 用 Material 而不是 Container 承载背景：ListTile 的水波纹画在最近的
    // Material 上，中间隔一层带背景色的 DecoratedBox 会把点击反馈遮掉
    return Material(
      color: theme.colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      ),
    );
  }
}
