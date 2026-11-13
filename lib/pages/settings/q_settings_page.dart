import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/pages/settings/ai_config_page.dart';
import 'package:qnote_flutter/pages/settings/q_memory_page.dart';
import 'package:qnote_flutter/pages/settings/q_personality_page.dart';
import 'package:qnote_flutter/pages/settings/q_skills_page.dart';
import 'package:qnote_flutter/pages/settings/q_voice_page.dart';
import 'package:qnote_flutter/widgets/settings_segment_bar.dart';

/// 小Q设置（管理）一体化页面
///
/// 将原侧边栏分散的「小Q个性」「小Q技能」「小Q记忆」「AI 模型配置」等入口
/// 整合为统一入口，提供顶部平滑切换分段栏：
/// - 模型：模型服务、路由组与角色模型分配（原独立的「AI 模型配置」页）；
/// - 个性：人设、语气风格与自定义 Prompt；
/// - 技能：用户技能、使用次数统计、创建/编辑/归档；
/// - 记忆：长期记忆（用户画像与小Q手记）、条目编辑与沉淀管理；
/// - 语音：自动朗读开关、音色与语速（语音回复功能）。
///
/// 模型放在第一位：它是小Q能否工作的前置状态——没有可用模型时，人设、技能、
/// 记忆都跑不起来。进页面第一眼就能看到「有没有可用的 AI 模型」，比翻到最后
/// 一个分段才发现没配置更符合直觉。顶部胶囊与内容分段按同一顺序排布。
class QSettingsPage extends ConsumerStatefulWidget {
  const QSettingsPage({super.key, this.initialTab = 0, this.autoOpenAddModelService = false});

  /// 初始分区索引：0 模型 / 1 个性 / 2 技能 / 3 记忆 / 4 语音
  final int initialTab;

  /// 直达「模型」分段并立即拉起添加模型服务弹窗（供「去配置模型」引导链接使用）
  final bool autoOpenAddModelService;

  @override
  ConsumerState<QSettingsPage> createState() => _QSettingsPageState();
}

class _QSettingsPageState extends ConsumerState<QSettingsPage> {
  static const _tabs = <SettingsSegmentItem>[
    SettingsSegmentItem(title: '模型', icon: Icons.memory_outlined),
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
          // 顶栏动作跟随当前分段：模型段的添加入口已下放到「模型服务」区块标题右侧，
          // 顶栏只保留技能段的「新建技能」
          if (_currentIndex == 2)
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
                // IndexedStack 只隐藏画面不暂停子树动画；用 TickerMode 静音非当前分段，
                // 否则 LoadingRing / EmptyState 的 repeat() 仍会持续唤醒 vsync
                children: [
                  TickerMode(
                    enabled: _currentIndex == 0,
                    child: AiConfigPage(embedded: true, autoOpenAdd: widget.autoOpenAddModelService),
                  ),
                  TickerMode(enabled: _currentIndex == 1, child: const QPersonalityPage(embedded: true)),
                  TickerMode(
                    enabled: _currentIndex == 2,
                    child: QSkillsPage(key: _skillsKey, embedded: true),
                  ),
                  TickerMode(enabled: _currentIndex == 3, child: const QMemoryPage(embedded: true)),
                  TickerMode(enabled: _currentIndex == 4, child: const QVoicePage(embedded: true)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
