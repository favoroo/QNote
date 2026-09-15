import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qnote_flutter/core/agent/services/q_target_bridge.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
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
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: rootScaffoldKey,
      drawer: const SideDrawer(),
      body: _NavBranchTransition(
        currentIndex: widget.navigationShell.currentIndex,
        child: widget.navigationShell,
      ),
      bottomNavigationBar: BottomNavBar(
        currentIndex: widget.navigationShell.currentIndex,
        onTap: (index) {
          widget.navigationShell.goBranch(
            index,
            initialLocation: index == widget.navigationShell.currentIndex,
          );
        },
        onMenuTap: () => rootScaffoldKey.currentState?.openDrawer(),
        onQTap: () {
          // 单击中央按钮：面板打开时收起，否则进入 /ai 全页面
          widget.navigationShell.goBranch(
            4,
            initialLocation: widget.navigationShell.currentIndex == 4,
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

  const _NavBranchTransition({
    required this.currentIndex,
    required this.child,
  });

  @override
  State<_NavBranchTransition> createState() => _NavBranchTransitionState();
}

class _NavBranchTransitionState extends State<_NavBranchTransition>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  int _lastIndex = 0;

  @override
  void initState() {
    super.initState();
    _lastIndex = widget.currentIndex;
    _controller = AnimationController(
      vsync: this,
      duration: AppDurations.normal,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: AppCurves.emphasized,
    );
    _slideAnimation = Tween<Offset>(
      begin: Offset.zero,
      end: Offset.zero,
    ).animate(_controller);
    // 首次展示直接到达最终态
    _controller.value = 1.0;
  }

  @override
  void didUpdateWidget(covariant _NavBranchTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      // 判定切换方向：向右切（index变大）新页面由右向左微移，反之由左向右微移
      final direction = widget.currentIndex > _lastIndex ? 0.03 : -0.03;
      _lastIndex = widget.currentIndex;

      _slideAnimation = Tween<Offset>(
        begin: Offset(direction, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(
        parent: _controller,
        curve: AppCurves.emphasized,
      ));

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
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: widget.child,
      ),
    );
  }
}

/// 自定义底部导航栏：4 个导航项 + 中央小Q导航按钮。
///
/// 采用简洁无边框图标风格与其他导航项完全统一，无外部圆形边框。
/// 中央小Q按钮单击进入 /ai 全页面，长按唤起悬浮快捷面板。
class BottomNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final VoidCallback? onMenuTap;
  final VoidCallback onQTap;

  const BottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.onMenuTap,
    required this.onQTap,
  });

  @override
  Widget build(BuildContext context) {
    return _BottomNavContent(
      currentIndex: currentIndex,
      onTap: onTap,
      onMenuTap: onMenuTap,
      onQTap: onQTap,
    );
  }
}

class _BottomNavContent extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final VoidCallback? onMenuTap;
  final VoidCallback onQTap;

  const _BottomNavContent({
    required this.currentIndex,
    required this.onTap,
    this.onMenuTap,
    required this.onQTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = navigationItems;

    return SafeArea(
      top: false,
      child: Container(
        height: 60,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(
              color: theme.colorScheme.outlineVariant,
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          children: [
            // 日记
            Expanded(
              child: _buildNavItem(context, theme, items, 0),
            ),
            // 笔记
            Expanded(
              child: _buildNavItem(context, theme, items, 1),
            ),
            // 中央小Q：与其他导航栏图标风格完全统一
            Expanded(
              child: _QNavButton(
                currentIndex: currentIndex,
                onTap: onQTap,
              ),
            ),
            // 待办
            Expanded(
              child: _buildNavItem(context, theme, items, 2),
            ),
            // 统计
            Expanded(
              child: _buildNavItem(context, theme, items, 3),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context,
    ThemeData theme,
    List<NavigationItem> items,
    int index,
  ) {
    final item = items[index];
    final isSelected = index == currentIndex;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap(index);
      },
      // index 0：长按/双击跳转到当前时间
      onLongPress: index == 0
          ? () {
              if (!isSelected) onTap(0);
              ProviderScope.containerOf(context, listen: false)
                  .read(diaryScrollTriggerProvider.notifier)
                  .state = DateTime.now().millisecondsSinceEpoch;
            }
          : (index == 2 ? () => showDebugConsole(context) : null),
      onDoubleTap: index == 0
          ? () {
              if (!isSelected) onTap(0);
              ProviderScope.containerOf(context, listen: false)
                  .read(diaryScrollTriggerProvider.notifier)
                  .state = DateTime.now().millisecondsSinceEpoch;
            }
          : null,
      child: Center(
        child: Icon(
          isSelected ? item.activeIcon : item.icon,
          size: 24,
          color: isSelected
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 中央小Q导航按钮。
///
/// 风格简洁，无外部圆框，与底部导航其他图标保持一致的尺寸 (24px) 与交互反馈。
/// - 未选中：呈 onSurfaceVariant 浅灰色线条轮廓
/// - 选中（/ai 页面）：呈 primary 主题强调色
/// - 面板展开：呈关闭叉号图标
/// - 工作态：展示简约的动态无限符号
class _QNavButton extends ConsumerWidget {
  final int currentIndex;
  final VoidCallback onTap;

  const _QNavButton({
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final phase = ref.watch(floatingQProvider.select((s) => s.phase));
    final panelOpen = ref.watch(floatingQProvider.select((s) => s.panelOpen));
    final isWorking = phase == FloatingQPhase.working;
    // /ai 分支激活态（index 4）
    final isActive = currentIndex == 4;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        final notifier = ref.read(floatingQProvider.notifier);
        if (ref.read(floatingQProvider).panelOpen) {
          // 面板已展开：单击收起
          notifier.closePanel();
        } else {
          HapticFeedback.selectionClick();
          onTap();
        }
      },
      onLongPress: () {
        HapticFeedback.selectionClick();
        _handleLongPress(ref);
      },
      child: Center(
        child: _buildIcon(theme, isWorking, isActive, panelOpen),
      ),
    );
  }

  Widget _buildIcon(
    ThemeData theme,
    bool isWorking,
    bool isActive,
    bool panelOpen,
  ) {
    final primary = theme.colorScheme.primary;
    final inactiveColor = theme.colorScheme.onSurfaceVariant;
    final isDark = theme.brightness == Brightness.dark;

    // 工作态：简约无限循环动画
    if (isWorking) {
      return MorphingInfinity(
        size: 22,
        strokeWidth: 1.8,
        color: primary,
      );
    }

    // 悬浮面板打开态：显示关闭图标
    if (panelOpen) {
      return Icon(
        Icons.close_rounded,
        size: 24,
        color: primary,
      );
    }

    // 选中 / 未选中态：采用单体 QIcon，与其它导航栏图标一致尺寸 24px
    final color = isActive ? primary : inactiveColor;
    final screenColor = isActive
        ? (isDark ? theme.colorScheme.surface : Colors.white)
        : theme.colorScheme.surface;
    final eyeColor = isActive ? primary : inactiveColor;

    return QIcon(
      size: 24,
      color: color,
      screenColor: screenColor,
      eyeColor: eyeColor,
    );
  }

  /// 长按唤起悬浮快捷面板：有编辑器选区时带引用打开
  void _handleLongPress(WidgetRef ref) {
    final notifier = ref.read(floatingQProvider.notifier);
    final fqState = ref.read(floatingQProvider);

    // 检查编辑器选区
    final signature = fqState.effectiveContext?.signature;
    final quote = QTargetBridge.instance.captureQuote(signature);
    if (quote == null) {
      notifier.openPanel();
    } else {
      // 收起键盘与选择菜单，把焦点让给面板输入框
      FocusManager.instance.primaryFocus?.unfocus();
      notifier.openWithQuote(quote);
    }
  }
}

