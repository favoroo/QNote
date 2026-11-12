import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/pages/settings/q_memory_page.dart';
import 'package:qnote_flutter/pages/settings/q_personality_page.dart';
import 'package:qnote_flutter/pages/settings/q_skills_page.dart';
import 'package:qnote_flutter/pages/settings/q_voice_page.dart';
import 'package:qnote_flutter/widgets/settings_segment_bar.dart';

/// 小Q设置（管理）一体化页面
///
/// 将原侧边栏分散的「小Q个性」、「小Q技能」与「小Q记忆」三个板块
/// 整合为统一入口，提供顶部平滑切换分段栏：
/// - 个性：人设、语气风格与自定义 Prompt；
/// - 技能：用户技能、使用次数统计、创建/编辑/归档；
/// - 记忆：长期记忆（用户画像与小Q手记）、条目编辑与沉淀管理；
/// - 语音：自动朗读开关、音色与语速（语音回复功能）。
class QSettingsPage extends ConsumerStatefulWidget {
  const QSettingsPage({super.key, this.initialTab = 0});

  /// 初始分区索引：0 个性 / 1 技能 / 2 记忆
  final int initialTab;

  @override
  ConsumerState<QSettingsPage> createState() => _QSettingsPageState();
}

class _QSettingsPageState extends ConsumerState<QSettingsPage> {
  static const _tabs = <SettingsSegmentItem>[
    SettingsSegmentItem(title: '个性', icon: Icons.mood_outlined),
    SettingsSegmentItem(title: '技能', icon: Icons.auto_fix_high_outlined),
    SettingsSegmentItem(title: '记忆', icon: Icons.psychology_outlined),
    SettingsSegmentItem(title: '语音', icon: Icons.graphic_eq_outlined),
  ];

  late int _currentIndex;
  final GlobalKey<QSkillsPageState> _skillsKey = GlobalKey<QSkillsPageState>();

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialTab.clamp(0, _tabs.length - 1);
  }

  void _switchTo(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('小Q设置'),
        centerTitle: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          // 仅在「技能」分区时显示右上角新建技能按钮
          if (_currentIndex == 1)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: '新建技能',
              onPressed: () => _skillsKey.currentState?.openNewSkillEditor(),
            ),
        ],
      ),
      body: Column(
        children: [
          SettingsSegmentBar(items: _tabs, selectedIndex: _currentIndex, onChanged: _switchTo),
          Expanded(
            child: SettingsSegmentContent(
              index: _currentIndex,
              child: IndexedStack(
                index: _currentIndex,
                children: [
                  const QPersonalityPage(embedded: true),
                  QSkillsPage(key: _skillsKey, embedded: true),
                  const QMemoryPage(embedded: true),
                  const QVoicePage(embedded: true),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
