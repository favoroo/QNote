import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/widgets/statistics/screen_usage_stats_view.dart';

/// 屏幕使用时间独立页面
///
/// 展示今日屏幕总时长、各应用使用排行榜及近7天趋势，支持点击顶栏更新按钮与下拉刷新。
class ScreenUsagePage extends ConsumerStatefulWidget {
  const ScreenUsagePage({super.key});

  @override
  ConsumerState<ScreenUsagePage> createState() => _ScreenUsagePageState();
}

class _ScreenUsagePageState extends ConsumerState<ScreenUsagePage> {
  final GlobalKey<ScreenUsageStatsViewState> _viewKey = GlobalKey<ScreenUsageStatsViewState>();
  bool _isRefreshing = false;

  /// 手动触发数据更新
  Future<void> _handleRefresh() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    HapticFeedback.lightImpact();

    try {
      await _viewKey.currentState?.refresh();
      if (mounted) {
        Toast.success(context, '屏幕使用时间已更新');
      }
    } catch (e) {
      if (mounted) {
        Toast.error(context, '更新失败: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isRefreshing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
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
              tooltip: '更新屏幕使用时间',
              onPressed: _handleRefresh,
            ),
        ],
      ),
      body: ScreenUsageStatsView(key: _viewKey),
    );
  }
}
