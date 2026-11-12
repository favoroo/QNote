import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qnote_flutter/core/agent/services/q_target_bridge.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/widgets/common/morphing_infinity.dart';
import 'package:qnote_flutter/widgets/ai/q_avatar.dart';
import 'package:qnote_flutter/widgets/side_drawer.dart';
import 'package:qnote_flutter/widgets/debug_console.dart';

class ScaffoldWithNavBar extends StatefulWidget {
  final StatefulNavigationShell navigationShell;

  const ScaffoldWithNavBar({super.key, required this.navigationShell});

  @override
  State<ScaffoldWithNavBar> createState() => _ScaffoldWithNavBarState();
}

class _ScaffoldWithNavBarState extends State<ScaffoldWithNavBar> {
  /// 「记录」合并入口最近停留的分支（笔记 / 待办）。
  ///
  /// 离开记录板块后，底部按钮仍回到用户上次停留的一侧；首次启动默认进笔记。
  int _lastRecordsBranch = ShellBranch.notes;

  @override
  Widget build(BuildContext context) {
    final currentIndex = widget.navigationShell.currentIndex;
    if (currentIndex == ShellBranch.notes || currentIndex == ShellBranch.todo) {
      _lastRecordsBranch = currentIndex;
    }

    return Scaffold(
      key: rootScaffoldKey,
      drawer: const SideDrawer(),
      body: _NavBranchTransition(currentIndex: currentIndex, child: widget.navigationShell),
      bottomNavigationBar: BottomNavBar(
        currentIndex: currentIndex,
        lastRecordsBranch: _lastRecordsBranch,
        onTap: (index) {
          widget.navigationShell.goBranch(index, initialLocation: index == widget.navigationShell.currentIndex);
        },
        onMenuTap: () => rootScaffoldKey.currentState?.openDrawer(),
        onQTap: () {
          // 单击中央按钮：面板打开时收起，否则进入 /ai 全页面
          widget.navigationShell.goBranch(
            ShellBranch.ai,
            initialLocation: widget.navigationShell.currentIndex == ShellBranch.ai,
          );
        },
      ),
    );
  }
}

/// 主导航分支切换平滑过渡组件。
///
/// 保持内部 navigationShell 不被重建，仅在其外层施加一次轻量淡入与微小位移动画，
/// 避免 tab 切换时的生硬瞬切，同时几乎不产生额外渲染负担。
class _NavBranchTransition extends StatefulWidget {
  final int currentIndex;
  final Widget child;

  const _NavBranchTransition({required this.currentIndex, required this.child});

  @override
  State<_NavBranchTransition> createState() => _NavBranchTransitionState();
}

class _NavBranchTransitionState extends State<_NavBranchTransition> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  int _lastIndex = 0;

  @override
  void initState() {
    super.initState();
    _lastIndex = widget.currentIndex;
    _controller = AnimationController(vsync: this, duration: AppDurations.page);
    // 从 0.86 起步而不是全透明：IndexedStack 已在同一帧换掉旧分支，
    // 若从 0 开始会先露出 Scaffold 底色，形成一次可见的「闪白」。
    _fadeAnimation = Tween<double>(
      begin: 0.86,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: AppCurves.emphasized));
    _slideAnimation = Tween<Offset>(begin: Offset.zero, end: Offset.zero).animate(_controller);
    // 首次展示直接到达最终态
    _controller.value = 1.0;
  }

  @override
  void didUpdateWidget(covariant _NavBranchTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      // 判定切换方向：向右切（index变大）新页面由右向左微移，反之由左向右微移
      final direction = widget.currentIndex > _lastIndex ? 0.018 : -0.018;
      _lastIndex = widget.currentIndex;

      if (AppMotion.reduce(context)) {
        _controller.value = 1.0;
        return;
      }

      _slideAnimation = Tween<Offset>(
        begin: Offset(direction, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: _controller, curve: AppCurves.emphasized));

      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 独立重绘边界：切换/抽屉动画期间底层分支内容不再逐帧重绘
    return RepaintBoundary(
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: SlideTransition(position: _slideAnimation, child: widget.child),
      ),
    );
  }
}

/// 自定义底部导航栏：2 个导航项 + 中央小Q导航按钮。
///
/// 「时间线」与「记录（笔记 / 待办）」分列小Q两侧，笔记与待办共用一个入口，
/// 具体落在哪一侧由最近一次停留的分支决定。中央小Q按钮单击进入 /ai 全页面，
/// 长按唤起悬浮快捷面板。
class BottomNavBar extends StatelessWidget {
  final int currentIndex;

  /// 「记录」入口最近停留的分支（[ShellBranch.notes] / [ShellBranch.todo]）
  final int lastRecordsBranch;
  final ValueChanged<int> onTap;
  final VoidCallback? onMenuTap;
  final VoidCallback onQTap;

  const BottomNavBar({
    super.key,
    required this.currentIndex,
    required this.lastRecordsBranch,
    required this.onTap,
    this.onMenuTap,
    required this.onQTap,
  });

  @override
  Widget build(BuildContext context) {
    return _BottomNavContent(
      currentIndex: currentIndex,
      lastRecordsBranch: lastRecordsBranch,
      onTap: onTap,
      onMenuTap: onMenuTap,
      onQTap: onQTap,
    );
  }
}

class _BottomNavContent extends ConsumerWidget {
  /// 底部导航栏内容区域主体高度（不含系统底部安全区/全面屏手势条）。
  /// 设为 66.0，适度提升单手操作触控热区与上下留白呼吸感。
  static const double _navBarContentHeight = 66.0;

  /// 宽屏下底栏内容的最大宽度：只剩 3 个入口时若仍拉满整行，
  /// 图标会被摊到屏幕两端，视觉上过于松散。
  static const double _navBarMaxContentWidth = 480.0;

  /// 「记录」入口连击计数与时间戳，连击 5 次触发日志控制台
  static int _recordsTapCount = 0;
  static DateTime? _lastRecordsTapTime;

  final int currentIndex;

  /// 「记录」入口最近停留的分支（[ShellBranch.notes] / [ShellBranch.todo]）
  final int lastRecordsBranch;
  final ValueChanged<int> onTap;
  final VoidCallback? onMenuTap;
  final VoidCallback onQTap;

  const _BottomNavContent({
    required this.currentIndex,
    required this.lastRecordsBranch,
    required this.onTap,
    this.onMenuTap,
    required this.onQTap,
  });

  /// 长按唤起悬浮快捷面板：有编辑器选区时带引用打开，并按按钮位置设定弹出锚点
  static void _handleQuickQTrigger(WidgetRef ref, {required Alignment anchorAlignment}) {
    final notifier = ref.read(floatingQProvider.notifier);
    final fqState = ref.read(floatingQProvider);

    // 检查编辑器选区
    final signature = fqState.effectiveContext?.signature;
    final quote = QTargetBridge.instance.captureQuote(signature);
    if (quote == null) {
      notifier.openPanel(anchorAlignment: anchorAlignment);
    } else {
      // 收起键盘与选择菜单，把焦点让给面板输入框
      FocusManager.instance.primaryFocus?.unfocus();
      notifier.openWithQuote(quote, anchorAlignment: anchorAlignment);
    }
  }

  /// 记录入口当前归属：在笔记/待办分支时就地取当前分支，否则回落到上次停留的一侧
  int get _recordsBranch =>
      (currentIndex == ShellBranch.notes || currentIndex == ShellBranch.todo) ? currentIndex : lastRecordsBranch;

  bool get _recordsSelected => currentIndex == ShellBranch.notes || currentIndex == ShellBranch.todo;

  /// 记录入口连点 5 次触发日志控制台（间隔小于 800ms 视为连击）
  void _registerRecordsTap(BuildContext context) {
    final now = DateTime.now();
    if (_lastRecordsTapTime != null && now.difference(_lastRecordsTapTime!) > const Duration(milliseconds: 800)) {
      _recordsTapCount = 0;
    }
    _lastRecordsTapTime = now;
    _recordsTapCount++;
    if (_recordsTapCount >= 5) {
      _recordsTapCount = 0;
      _lastRecordsTapTime = null;
      showDebugConsole(context);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final items = navigationItems;

    return SafeArea(
      top: false,
      child: Container(
        height: _navBarContentHeight,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant, width: 0.5)),
        ),
        // 只剩 3 个入口：宽屏下限制内容宽度并居中，避免图标被摊到屏幕两端
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _navBarMaxContentWidth),
            child: Row(
              children: [
                // 时间线
                Expanded(
                  child: _buildNavItem(
                    context,
                    ref,
                    theme,
                    items[ShellBranch.diary],
                    isSelected: currentIndex == ShellBranch.diary,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      onTap(ShellBranch.diary);
                    },
                    // 双击时间线：跳到当前时间
                    onDoubleTap: () {
                      if (currentIndex != ShellBranch.diary) onTap(ShellBranch.diary);
                      ProviderScope.containerOf(
                        context,
                        listen: false,
                      ).read(diaryScrollTriggerProvider.notifier).state = DateTime.now().millisecondsSinceEpoch;
                    },
                    longPressAlignment: const Alignment(-0.55, 1.0),
                  ),
                ),
                // 中央小Q：与其他导航栏图标风格完全统一
                Expanded(
                  child: _QNavButton(currentIndex: currentIndex, onTap: onQTap),
                ),
                // 记录（笔记 / 待办）：图标随最近停留的分段变化，点进去就是上次那一侧
                Expanded(
                  child: _buildNavItem(
                    context,
                    ref,
                    theme,
                    items[_recordsBranch],
                    isSelected: _recordsSelected,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      onTap(_recordsBranch);
                      _registerRecordsTap(context);
                    },
                    longPressAlignment: const Alignment(0.55, 1.0),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context,
    WidgetRef ref,
    ThemeData theme,
    NavigationItem item, {
    required bool isSelected,
    required VoidCallback onTap,
    required Alignment longPressAlignment,
    VoidCallback? onDoubleTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onTap,
      // 长按底栏任意按钮均在当前位置触发小Q悬浮弹窗
      onLongPress: () {
        HapticFeedback.selectionClick();
        _handleQuickQTrigger(ref, anchorAlignment: longPressAlignment);
      },
      onDoubleTap: onDoubleTap,
      child: Center(
        // 选中态 outlined ↔ filled 交叉淡化，避免图标「瞬间换脸」；
        // 颜色随新图标一起过渡，旧图标退场时仍保持原色。
        // key 带上 path：笔记↔待办切换时即使都处于选中态，图标也能交叉淡化。
        child: AppMotion.switcher(
          context: context,
          baseDuration: AppDurations.fast,
          child: Icon(
            isSelected ? item.activeIcon : item.icon,
            key: ValueKey('${item.path}_$isSelected'),
            size: 24,
            // 选中态直接用主题色 primary，与全 App 其他选中态保持同一颜色；
            // 极亮主题色的可读性由主题层统一决策，组件层不再二次压色改观感
            color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 中央小Q导航按钮。
///
/// 风格简洁，无外部圆框，与底部导航其他图标保持一致的尺寸 (24px) 与交互反馈。
/// - 未选中：呈 onSurfaceVariant 浅灰色线条轮廓
/// - 选中（/ai 页面）：呈 primary 主题强调色，并带有灵动的眨眼动效（3~6秒间隔触发单眨/连眨）
/// - 面板展开：呈关闭叉号图标
/// - 工作态：展示简约的动态无限符号
class _QNavButton extends ConsumerStatefulWidget {
  final int currentIndex;
  final VoidCallback onTap;

  const _QNavButton({required this.currentIndex, required this.onTap});

  @override
  ConsumerState<_QNavButton> createState() => _QNavButtonState();
}

class _QNavButtonState extends ConsumerState<_QNavButton> with SingleTickerProviderStateMixin {
  late final AnimationController _blinkController;
  late final Animation<double> _eyeOpennessAnimation;
  Timer? _blinkTimer;
  final math.Random _random = math.Random();
  bool? _reduceMotion;

  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));

    // 0.0 -> 0.45: 快速闭眼 (1.0 -> 0.0)
    // 0.45 -> 0.55: 极短闭合维持
    // 0.55 -> 1.0: 弹润回睁 (0.0 -> 1.0)
    _eyeOpennessAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 0.0).chain(CurveTween(curve: Curves.easeInQuad)),
        weight: 45,
      ),
      TweenSequenceItem(tween: ConstantTween<double>(0.0), weight: 10),
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 45,
      ),
    ]).animate(_blinkController);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery 在 initState 阶段不可用，且系统开关可能在运行时变化，
    // 因此把眨眼循环的启停放到依赖变化里统一处理。
    final reduce = AppMotion.reduce(context);
    if (_reduceMotion == reduce) return;
    _reduceMotion = reduce;

    if (reduce) {
      _stopBlinkingLoop();
    } else if (widget.currentIndex == ShellBranch.ai) {
      _startBlinkingLoop(immediateFirstBlink: true);
    }
  }

  @override
  void didUpdateWidget(covariant _QNavButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasActive = oldWidget.currentIndex == ShellBranch.ai;
    final isNowActive = widget.currentIndex == ShellBranch.ai;

    if (!wasActive && isNowActive) {
      // 刚切到小Q页面：立即眨眼一次并开启周期循环
      _startBlinkingLoop(immediateFirstBlink: true);
    } else if (wasActive && !isNowActive) {
      // 切离小Q页面：停止循环并确保眼睛复位完全睁开
      _stopBlinkingLoop();
    }
  }

  void _startBlinkingLoop({bool immediateFirstBlink = false}) {
    if (AppMotion.reduce(context)) return;
    _blinkTimer?.cancel();
    if (immediateFirstBlink) {
      // 延时 350ms，配合页面切换完成产生轻微延迟交互感
      _blinkTimer = Timer(const Duration(milliseconds: 350), () {
        if (!mounted || widget.currentIndex != 4) return;
        _performBlinkSequence();
      });
    } else {
      _scheduleNextBlink();
    }
  }

  void _stopBlinkingLoop() {
    _blinkTimer?.cancel();
    _blinkTimer = null;
    if (_blinkController.isAnimating) {
      _blinkController.stop();
    }
    _blinkController.value = 0.0;
  }

  void _scheduleNextBlink() {
    _blinkTimer?.cancel();
    if (!mounted || widget.currentIndex != 4) return;

    // 3.0 ~ 5.5 秒随机间隔，节奏自然拟人
    final delayMillis = 3000 + _random.nextInt(2500);
    _blinkTimer = Timer(Duration(milliseconds: delayMillis), () {
      if (!mounted || widget.currentIndex != 4) return;
      _performBlinkSequence();
    });
  }

  void _performBlinkSequence() {
    if (!mounted || widget.currentIndex != 4 || AppMotion.reduce(context)) return;

    _blinkController.forward(from: 0.0).then((_) {
      if (!mounted || widget.currentIndex != 4) return;

      // 约 25% 概率连眨一次，更显生动好奇
      final shouldDoubleBlink = _random.nextDouble() < 0.25;
      if (shouldDoubleBlink) {
        _blinkTimer = Timer(const Duration(milliseconds: 140), () {
          if (!mounted || widget.currentIndex != 4) return;
          _blinkController.forward(from: 0.0).then((_) {
            if (!mounted || widget.currentIndex != 4) return;
            _scheduleNextBlink();
          });
        });
      } else {
        _scheduleNextBlink();
      }
    });
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
    _blinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phase = ref.watch(floatingQProvider.select((s) => s.phase));
    final panelMode = ref.watch(floatingQProvider.select((s) => s.panelMode));
    final panelOpen = panelMode == FloatingQPanelMode.panel;
    final isWorking = phase == FloatingQPhase.working;
    // /ai 分支激活态（ShellBranch.ai）
    final isActive = widget.currentIndex == ShellBranch.ai;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        final notifier = ref.read(floatingQProvider.notifier);
        final mode = ref.read(floatingQProvider).panelMode;
        if (mode == FloatingQPanelMode.panel) {
          // 面板已展开：单击最小化成气泡（会话保留）
          HapticFeedback.selectionClick();
          FocusManager.instance.primaryFocus?.unfocus();
          notifier.minimizePanel();
        } else if (mode == FloatingQPanelMode.bubble) {
          // 当前页面已有气泡：单击重新打开同一段对话，而不是新开
          HapticFeedback.selectionClick();
          FocusManager.instance.primaryFocus?.unfocus();
          notifier.openPanel();
        } else {
          HapticFeedback.selectionClick();
          widget.onTap();
        }
      },
      onLongPress: () {
        HapticFeedback.selectionClick();
        _BottomNavContent._handleQuickQTrigger(ref, anchorAlignment: const Alignment(0.0, 1.0));
      },
      child: Center(
        // 工作态无限符号 / 面板关闭叉 / 小Q头像三种形态差异较大，
        // 直接替换会「跳脸」，用交叉淡化 + 轻微缩放保持连续感。
        child: AppMotion.switcher(
          context: context,
          baseDuration: AppDurations.fast,
          child: KeyedSubtree(
            key: ValueKey(
              isWorking
                  ? 'q_working'
                  : panelOpen
                  ? 'q_close'
                  : 'q_idle_$isActive',
            ),
            child: _buildIcon(theme, isWorking, isActive, panelOpen),
          ),
        ),
      ),
    );
  }

  Widget _buildIcon(ThemeData theme, bool isWorking, bool isActive, bool panelOpen) {
    // 选中/工作态都直接用主题色 primary，与导航项及其他页面的选中态保持一致
    final primary = theme.colorScheme.primary;
    final inactiveColor = theme.colorScheme.onSurfaceVariant;

    // 工作态：简约无限循环动画
    if (isWorking) {
      return MorphingInfinity(size: 22, strokeWidth: 1.8, color: primary);
    }

    // 悬浮面板打开态：显示关闭图标
    if (panelOpen) {
      return Icon(Icons.close_rounded, size: 24, color: primary);
    }

    // 未选中走细线稿轮廓（线条重量与其余 Material 图标一致），选中走实心填充
    final color = isActive ? primary : inactiveColor;
    final screenColor = theme.colorScheme.surface;
    final eyeColor = isActive ? primary : inactiveColor;

    return AnimatedBuilder(
      animation: _eyeOpennessAnimation,
      builder: (context, child) {
        return QIcon(
          size: 24,
          color: color,
          screenColor: screenColor,
          eyeColor: eyeColor,
          // 未选中：细线稿；选中：实心填充，匹配其余图标 outlined/filled 的语义
          filled: isActive,
          eyeOpenness: isActive ? _eyeOpennessAnimation.value : 1.0,
        );
      },
    );
  }
}
