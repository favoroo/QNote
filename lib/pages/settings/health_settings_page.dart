import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/health/screen_usage_service.dart';
import 'package:qnote_flutter/pages/settings/mi_fitness_settings_page.dart';
import 'package:qnote_flutter/pages/settings/screen_usage_page.dart';
import 'package:qnote_flutter/widgets/settings_segment_bar.dart';

/// 健康数据设置（运动健康 + 屏幕使用时间一体化页面）
///
/// 两段都是「这一天身体/注意力状态」的来源：运动健康看体征（步数、睡眠、心率、
/// 血氧、压力），屏幕使用看注意力去向（总时长、应用排行）。原先在侧边栏分列两个
/// 入口，实际使用中是同一次「看看我今天怎么样」的动作，这里合并为一个入口。
///
/// 顶栏动作按分段切换：运动健康显示「同步当天」（未绑定时不显示），屏幕使用显示
/// 「刷新」。两段各自持有自己的日期状态，切换分段不会互相覆盖。
class HealthSettingsPage extends ConsumerStatefulWidget {
  const HealthSettingsPage({super.key, this.initialTab = 0, this.initialDate});

  /// 初始分段索引：0 运动健康 / 1 屏幕使用
  final int initialTab;

  /// 进入时对齐到的日期（日记日结卡片、统计页跳转时带入）
  final DateTime? initialDate;

  @override
  ConsumerState<HealthSettingsPage> createState() => _HealthSettingsPageState();
}

class _HealthSettingsPageState extends ConsumerState<HealthSettingsPage> {
  static const _tabs = <SettingsSegmentItem>[
    SettingsSegmentItem(title: '运动健康', icon: Icons.favorite_border_rounded),
    SettingsSegmentItem(title: '屏幕使用', icon: Icons.hourglass_bottom_rounded),
  ];

  late int _currentIndex;
  final GlobalKey<MiFitnessSettingsPageState> _fitnessKey = GlobalKey<MiFitnessSettingsPageState>();
  final GlobalKey<ScreenUsagePageState> _screenKey = GlobalKey<ScreenUsagePageState>();

  /// 运动健康子页的顶栏状态：未绑定时顶栏不显示同步按钮
  final ValueNotifier<MiFitnessTopBarStatus> _fitnessStatus = ValueNotifier<MiFitnessTopBarStatus>((
    authed: false,
    syncing: false,
  ));

  /// 屏幕使用子页的刷新态：由子页在开始/结束刷新时写入
  final ValueNotifier<bool> _screenRefreshing = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialTab.clamp(0, _tabs.length - 1);
  }

  @override
  void dispose() {
    _fitnessStatus.dispose();
    _screenRefreshing.dispose();
    super.dispose();
  }

  void _switchTo(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text('健康数据'),
        centerTitle: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [_buildTopBarAction()],
      ),
      body: Column(
        children: [
          SettingsSegmentBar(items: _tabs, selectedIndex: _currentIndex, onChanged: _switchTo),
          Expanded(
            // IndexedStack 让两段各自保留日期选择与滚动位置；两段数据源互不相干，
            // 重建成本也不低（都要查库 + 平台通道），不适合按需重建
            child: SettingsSegmentContent(
              index: _currentIndex,
              child: IndexedStack(
                index: _currentIndex,
                children: [
                  MiFitnessSettingsPage(
                    key: _fitnessKey,
                    initialDate: widget.initialDate,
                    embedded: true,
                    statusNotifier: _fitnessStatus,
                  ),
                  ScreenUsagePage(
                    key: _screenKey,
                    initialDate: widget.initialDate,
                    embedded: true,
                    refreshingNotifier: _screenRefreshing,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶栏动作随分段切换：同一位置承载「同步当天」或「刷新」
  Widget _buildTopBarAction() {
    if (_currentIndex == 0) {
      return ValueListenableBuilder<MiFitnessTopBarStatus>(
        valueListenable: _fitnessStatus,
        builder: (context, status, _) {
          // 未绑定账号时同步按钮点了只会弹「请先授权登录」，不如不显示
          if (!status.authed) return const SizedBox.shrink();
          if (status.syncing) {
            return const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          return IconButton(
            icon: const Icon(Icons.sync_rounded),
            tooltip: '同步当天数据',
            onPressed: () => _fitnessKey.currentState?.syncSelectedDate(),
          );
        },
      );
    }

    // 屏幕使用分段：刷新态由子页写入通知器，顶栏与子页按钮状态同源
    return ValueListenableBuilder<bool>(
      valueListenable: _screenRefreshing,
      builder: (context, refreshing, _) {
        // 非 Android 平台采集不到屏幕时长，子页会显示「仅支持 Android」，
        // 这里再挂一个点了没反应的刷新按钮只会误导
        if (!ref.read(screenUsageServiceProvider).isSupported) {
          return const SizedBox.shrink();
        }
        if (refreshing) {
          return const Padding(
            padding: EdgeInsets.all(14),
            child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        return IconButton(
          icon: const Icon(Icons.refresh_rounded),
          tooltip: '更新数据',
          onPressed: () => _screenKey.currentState?.refresh(),
        );
      },
    );
  }
}
