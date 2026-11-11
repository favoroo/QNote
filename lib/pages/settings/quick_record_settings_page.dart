import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/pages/settings/fixed_events_page.dart';
import 'package:qnote_flutter/pages/settings/shortcuts_page.dart';
import 'package:qnote_flutter/widgets/settings_segment_bar.dart';

/// 快捷记录设置（快捷按钮 + 固定事件一体化页面）
///
/// 两者是同一件事的两面：快捷按钮定义「记录成什么样」（名称、字段、分类），
/// 固定事件定义「什么时候自动带出这些按钮」（时间段 + 关联标签）。原先在侧边栏
/// 分列两个入口，用户改一处常要来回跳，这里合并为一个入口、两个分段。
///
/// 顶栏的「+」按当前分段决定新建对象，避免两个分段各挂一个入口。
class QuickRecordSettingsPage extends ConsumerStatefulWidget {
  const QuickRecordSettingsPage({super.key, this.initialTab = 0});

  /// 初始分段索引：0 快捷按钮 / 1 固定事件
  final int initialTab;

  @override
  ConsumerState<QuickRecordSettingsPage> createState() => _QuickRecordSettingsPageState();
}

class _QuickRecordSettingsPageState extends ConsumerState<QuickRecordSettingsPage> {
  static const _tabs = <SettingsSegmentItem>[
    SettingsSegmentItem(title: '快捷按钮', icon: Icons.hexagon_outlined),
    SettingsSegmentItem(title: '固定事件', icon: Icons.event_repeat),
  ];

  late int _currentIndex;
  final GlobalKey<ShortcutsPageState> _shortcutsKey = GlobalKey<ShortcutsPageState>();
  final GlobalKey<FixedEventsPageState> _fixedEventsKey = GlobalKey<FixedEventsPageState>();

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialTab.clamp(0, _tabs.length - 1);
  }

  void _switchTo(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
  }

  /// 顶栏「+」按当前分段新建：快捷按钮与固定事件共用同一个按钮位
  void _createCurrent() {
    if (_currentIndex == 0) {
      _shortcutsKey.currentState?.openNewShortcutEditor();
    } else {
      _fixedEventsKey.currentState?.openNewTemplateEditor();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text('快捷记录'),
        centerTitle: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: _currentIndex == 0 ? '新建快捷按钮' : '新建固定事件',
            onPressed: _createCurrent,
          ),
        ],
      ),
      body: Column(
        children: [
          SettingsSegmentBar(
            items: _tabs,
            selectedIndex: _currentIndex,
            onChanged: _switchTo,
          ),
          Expanded(
            // IndexedStack 保留两个分段的滚动位置与编辑态，来回切换不会重建列表
            child: SettingsSegmentContent(
              index: _currentIndex,
              child: IndexedStack(
                index: _currentIndex,
                children: [
                  ShortcutsPage(key: _shortcutsKey, embedded: true),
                  FixedEventsPage(key: _fixedEventsKey, embedded: true),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
