import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/health/health_sync_service.dart';
import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/app_typography.dart';
import 'package:qnote_flutter/core/theme/tag_colors.dart';
import 'package:qnote_flutter/core/utils/diary_timeline_layout.dart';
import 'package:qnote_flutter/core/utils/health_timeline.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/providers/health_timeline_provider.dart';

/// 时间线 23:00 槽位的「运动健康日结」空位卡。
///
/// 真实日结卡只有同步成功且当天有数据时才会落库；未同步、同步失败或当天无数据
/// 的日子里，时间线原本没有任何入口，用户只能去设置页手动同步。本组件补一张
/// 不落库的虚拟卡：点击即按日同步，有数据时由服务层生成真实日结卡并替换本卡。
///
/// 不写入数据库是有意为之：空位卡一旦被当成记录，会污染日期计数、生活完整度、
/// 统计与批量管理；它只存在于渲染层，状态全部来自健康数据仓库。
class HealthDailyPlaceholderCard extends ConsumerStatefulWidget {
  const HealthDailyPlaceholderCard({super.key, required this.date, required this.isToday});

  /// 卡片所属日期（零点）。
  final DateTime date;

  /// 是否为今天，只影响文案里的「今日 / 当天」。
  final bool isToday;

  @override
  ConsumerState<HealthDailyPlaceholderCard> createState() => _HealthDailyPlaceholderCardState();
}

class _HealthDailyPlaceholderCardState extends ConsumerState<HealthDailyPlaceholderCard> {
  bool _syncing = false;

  /// 最近一次同步失败原因；成功后清空。
  String? _errorMessage;

  Future<void> _handleSync() async {
    if (_syncing) return;
    HapticFeedback.selectionClick();
    setState(() {
      _syncing = true;
      _errorMessage = null;
    });

    HealthSyncResult result;
    try {
      result = await ref.read(healthSyncServiceProvider).syncDate(widget.date);
    } catch (e) {
      result = HealthSyncResult(success: false, errorMessage: '同步异常：$e');
    }
    if (!mounted) return;
    setState(() => _syncing = false);

    final label = widget.isToday ? '今日' : '${widget.date.month}月${widget.date.day}日';
    if (!result.success) {
      setState(() => _errorMessage = result.errorMessage ?? '同步失败');
      Toast.error(context, result.errorMessage ?? '同步失败');
      // 只在确认本地凭证已被清空时才收起空位卡：网络/接口故障不应让整条时间线闪一下。
      // 服务端拒绝 passToken 时 auth service 会清空凭证，此时空位卡继续显示只会误导。
      final stillAuthorized = await ref.read(healthSyncServiceProvider).isAuthorized();
      if (!stillAuthorized && mounted) {
        ref.invalidate(healthBindingStatusProvider);
      }
      return;
    }

    if (result.newTimelineCards == 0) {
      // 无数据时不会生成卡片，靠版本号让本卡切到「已同步 · 当天无数据」；
      // 有数据时服务层已写入真实卡片，本卡随之被替换，无需再刷状态造成闪烁。
      ref.read(healthSyncVersionProvider.notifier).state++;
      Toast.info(context, '$label暂无健康数据');
    } else {
      Toast.success(context, '$label健康数据已更新');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    const healthColor = TagColors.health;
    final healthInk = AppContrast.inkOnTint(healthColor, colorScheme.surface, 0.1);

    final availability = ref.watch(healthDayAvailabilityProvider(diaryDateKey(widget.date)));
    final mode = availability.when(
      data: (value) => resolveHealthPlaceholderMode(hasSynced: value.hasSynced, hasData: value.hasData),
      // 查询期间先保持可点击：即便本地状态未知，按日同步本身是安全的。
      loading: () => null,
      // 本地查询失败按「未同步」处理，仍允许用户主动拉取一次。
      error: (_, _) => HealthPlaceholderMode.unsynced,
    );

    final subtitle = _buildSubtitle(mode);
    final subtitleColor = _errorMessage != null ? colorScheme.error : colorScheme.onSurfaceVariant;

    return Stack(
      children: [
        // 与 DiaryItem 相同的竖轴线与左栏宽度，保证空位卡和真实卡片在同一条时间线上
        Positioned(
          left: 23,
          top: 0,
          bottom: 0,
          child: Container(width: 2, color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 48,
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: colorScheme.surface,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Container(
                      margin: const EdgeInsets.all(4),
                      decoration: BoxDecoration(color: healthColor.withValues(alpha: 0.1), shape: BoxShape.circle),
                      child: Icon(Icons.monitor_heart_outlined, size: 14, color: healthInk),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16, right: 12),
                child: Semantics(
                  button: true,
                  label: _syncing ? '正在同步健康数据' : '同步${widget.isToday ? '今日' : '当天'}运动健康数据',
                  child: GestureDetector(
                    onTap: _syncing ? null : _handleSync,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Color.alphaBlend(healthColor.withValues(alpha: 0.02), colorScheme.surface),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: healthColor.withValues(alpha: 0.18), width: 0.8),
                        boxShadow: [
                          BoxShadow(
                            color: healthColor.withValues(alpha: 0.03),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.01),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              _buildTimePill(theme, healthColor, healthInk),
                              const Spacer(),
                              _buildStatusChip(theme, mode),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: healthColor.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  mode == HealthPlaceholderMode.syncedEmpty
                                      ? Icons.monitor_heart_outlined
                                      : Icons.sync_rounded,
                                  size: 18,
                                  color: healthInk,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '运动健康日结',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      subtitle,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: subtitleColor,
                                        fontSize: AppTypography.caption,
                                        height: 1.35,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              _buildAction(theme, healthColor, healthInk, mode),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _buildSubtitle(HealthPlaceholderMode? mode) {
    final error = _errorMessage;
    if (error != null) {
      return error.startsWith('同步') ? error : '同步失败：$error';
    }
    final dayLabel = widget.isToday ? '今日' : '当天';
    switch (mode) {
      case HealthPlaceholderMode.unsynced:
        return '点击同步小米运动健康，获取$dayLabel步数、睡眠与体征';
      case HealthPlaceholderMode.syncedEmpty:
        return '已同步，$dayLabel没有步数、睡眠或运动记录';
      case HealthPlaceholderMode.syncedWithoutCard:
        return '健康数据已就绪，点击生成日结卡片';
      case null:
        return '正在读取$dayLabel同步状态…';
    }
  }

  Widget _buildTimePill(ThemeData theme, Color healthColor, Color healthInk) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
      decoration: BoxDecoration(color: healthColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.access_time_filled, size: 13, color: healthInk),
          const SizedBox(width: 4),
          Text(
            '23:00',
            style: theme.textTheme.labelSmall?.copyWith(color: healthInk, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusChip(ThemeData theme, HealthPlaceholderMode? mode) {
    final colorScheme = theme.colorScheme;
    final String text;
    final Color foreground;
    final Color background;
    if (_errorMessage != null) {
      text = '同步失败';
      foreground = colorScheme.error;
      background = colorScheme.error.withValues(alpha: 0.1);
    } else if (mode == HealthPlaceholderMode.syncedEmpty) {
      text = '无数据';
      foreground = colorScheme.onSurfaceVariant;
      background = colorScheme.onSurfaceVariant.withValues(alpha: 0.1);
    } else if (mode == HealthPlaceholderMode.syncedWithoutCard) {
      text = '待生成';
      foreground = colorScheme.primary;
      background = colorScheme.primary.withValues(alpha: 0.1);
    } else if (mode == null) {
      text = '读取中';
      foreground = colorScheme.onSurfaceVariant;
      background = colorScheme.onSurfaceVariant.withValues(alpha: 0.1);
    } else {
      text = '未同步';
      foreground = colorScheme.onSurfaceVariant;
      background = colorScheme.onSurfaceVariant.withValues(alpha: 0.1);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: foreground.withValues(alpha: 0.24)),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: foreground, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildAction(ThemeData theme, Color healthColor, Color healthInk, HealthPlaceholderMode? mode) {
    if (_syncing) {
      return SizedBox(
        width: 54,
        height: 30,
        child: Center(
          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: healthInk)),
        ),
      );
    }

    final String label;
    if (_errorMessage != null) {
      label = '重试';
    } else if (mode == HealthPlaceholderMode.syncedWithoutCard) {
      label = '生成';
    } else if (mode == HealthPlaceholderMode.syncedEmpty) {
      label = '重新同步';
    } else {
      label = '同步';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: healthColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: healthColor.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.sync_rounded, size: 14, color: healthInk),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: healthInk, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
