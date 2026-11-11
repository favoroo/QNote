import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/providers/selected_date_provider.dart';
import 'package:qnote_flutter/widgets/statistics/screen_usage_stats_view.dart';

/// 屏幕使用时间页面
///
/// 展示今日屏幕总时长、各应用使用排行榜及近7天趋势，支持点击顶栏更新按钮与下拉刷新。
/// 既可作为独立路由打开，也可嵌入「健康数据」综合页的「屏幕使用」分段。
class ScreenUsagePage extends ConsumerStatefulWidget {
  final DateTime? initialDate;

  /// 嵌入模式：由「健康数据」综合页承载时为 true，不重复生成外层 Scaffold 与 AppBar，
  /// 顶栏刷新动作改由外层页通过 GlobalKey 触发。
  final bool embedded;

  /// 嵌入模式下向外层顶栏同步「是否正在刷新」；独立打开时为 null。
  final ValueNotifier<bool>? refreshingNotifier;

  const ScreenUsagePage({
    super.key,
    this.initialDate,
    this.embedded = false,
    this.refreshingNotifier,
  });

  @override
  ConsumerState<ScreenUsagePage> createState() => ScreenUsagePageState();
}

class ScreenUsagePageState extends ConsumerState<ScreenUsagePage> {
  final GlobalKey<ScreenUsageStatsViewState> _viewKey = GlobalKey<ScreenUsageStatsViewState>();
  bool _isRefreshing = false;

  /// 是否正在刷新（外层「健康数据」页据此把顶栏按钮换成转圈）
  bool get isRefreshing => _isRefreshing;

  @override
  void initState() {
    super.initState();
    final initDate = widget.initialDate;
    if (initDate != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        ref.read(selectedDateProvider.notifier).state = DateTime(
          initDate.year,
          initDate.month,
          initDate.day,
        );
      });
    }
  }

  /// 外部调用：手动触发数据更新（独立页顶栏与综合页顶栏共用）
  Future<void> refresh() => _handleRefresh();

  /// 刷新标志同时写入本页 state 与外层顶栏通知器，两处显示永远同源
  void _setRefreshing(bool value) {
    _isRefreshing = value;
    widget.refreshingNotifier?.value = value;
  }

  /// 手动触发数据更新
  Future<void> _handleRefresh() async {
    if (_isRefreshing) return;
    setState(() => _setRefreshing(true));
    HapticFeedback.lightImpact();

    try {
      await _viewKey.currentState?.refresh();
      if (mounted) {
        Toast.success(context, '已更新');
      }
    } catch (e) {
      if (mounted) {
        Toast.error(context, '更新失败：$e');
      }
    } finally {
      if (mounted) {
        setState(() => _setRefreshing(false));
      } else {
        _setRefreshing(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = ScreenUsageStatsView(key: _viewKey);

    // 嵌入「健康数据」综合页时不重复生成 Scaffold/AppBar
    if (widget.embedded) {
      return body;
    }

    return Scaffold(
      appBar: AppBar(
        // 独立打开时用完整名称；嵌入综合页时顶栏由外层承载，分段标签是「屏幕使用」
        title: const Text('屏幕使用时间'),
        actions: [
          if (_isRefreshing)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: '更新数据',
              onPressed: _handleRefresh,
            ),
        ],
      ),
      body: body,
    );
  }
}
