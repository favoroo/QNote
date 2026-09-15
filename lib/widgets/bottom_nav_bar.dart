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
import 'package:qnote_flutter/widgets/animated_gradient_border.dart';
import 'package:qnote_flutter/widgets/common/morphing_infinity.dart';
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

/// 自定义底部导航栏：4 个导航项 + 中央小Q停靠按钮。
///
/// 替代原 M3 NavigationBar（5 项含小Q tab）。小Q全页面改为中央按钮单击进入，
/// 长按唤起悬浮快捷面板（替代原全局悬浮球）。
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
    return _BottomNavWithDock(
      currentIndex: currentIndex,
      onTap: onTap,
      onMenuTap: onMenuTap,
      onQTap: onQTap,
    );
  }
}

class _BottomNavWithDock extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final VoidCallback? onMenuTap;
  final VoidCallback onQTap;

  const _BottomNavWithDock({
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
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topCenter,
        children: [
          // 导航栏背景 + 4 个导航项
          Container(
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
                Expanded(
                  child: _buildNavItem(context, theme, items, 0),
                ),
                Expanded(
                  child: _buildNavItem(context, theme, items, 1),
                ),
                // 中央停靠按钮占位间隙
                const SizedBox(width: 56),
                Expanded(
                  child: _buildNavItem(context, theme, items, 2),
                ),
                Expanded(
                  child: _buildNavItem(context, theme, items, 3),
                ),
              ],
            ),
          ),
          // 中央小Q停靠按钮：内嵌导航栏居中，不凸出
          Positioned(
            top: 8,
            child: _QDockButton(
              currentIndex: currentIndex,
              onTap: onQTap,
            ),
          ),
        ],
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

/// 中央小Q停靠按钮。
///
/// 单击：面板打开时收起面板，否则进入 /ai 全页面。
/// 长按：唤起悬浮快捷面板（有编辑器选区时带引用打开）。
/// 工作态：极光流光边框 + 脉冲光晕（复用原悬浮球视觉）。
class _QDockButton extends ConsumerWidget {
  final int currentIndex;
  final VoidCallback onTap;

  const _QDockButton({
    required this.currentIndex,
    required this.onTap,
  });

  static const double _size = 44;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final phase = ref.watch(floatingQProvider.select((s) => s.phase));
    final panelOpen = ref.watch(floatingQProvider.select((s) => s.panelOpen));
    final isWorking = phase == FloatingQPhase.working;
    // /ai 分支激活态（index 4）
    final isActive = currentIndex == 4;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
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
      child: _buildVisual(theme, isWorking, isActive, panelOpen),
    );
  }

  Widget _buildVisual(
    ThemeData theme,
    bool isWorking,
    bool isActive,
    bool panelOpen,
  ) {
    final primary = theme.colorScheme.primary;

    // 工作态：极光流光边框 + 脉冲光晕
    if (isWorking) {
      return _WorkingDock(size: _size);
    }

    final icon = panelOpen ? Icons.close_rounded : Icons.smart_toy_rounded;

    // /ai 激活态：primary 填充
    if (isActive) {
      return Container(
        width: _size,
        height: _size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: primary,
          boxShadow: [
            BoxShadow(
              color: primary.withValues(alpha: 0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Center(
          child: Icon(icon, color: theme.colorScheme.onPrimary, size: 22),
        ),
      );
    }

    // 待机态：surface 背景 + primary 图标
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.colorScheme.surface,
        border: Border.all(
          color: primary.withValues(alpha: isDark ? 0.5 : 0.6),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: primary.withValues(alpha: isDark ? 0.25 : 0.15),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Center(
        child: Icon(icon, color: primary, size: 22),
      ),
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

/// 工作态停靠按钮：AI 极光流光边框 + 中心脉冲。
///
/// 视觉逻辑从原 `_WorkingBall` 提取，尺寸适配停靠按钮。
class _WorkingDock extends StatefulWidget {
  final double size;

  const _WorkingDock({required this.size});

  @override
  State<_WorkingDock> createState() => _WorkingDockState();
}

class _WorkingDockState extends State<_WorkingDock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final isDark = theme.brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        // 外圈轻度脉冲光晕，表达能量汇聚
        final ringScale = 1.0 + _pulse.value * 0.22;
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            Transform.scale(
              scale: ringScale,
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: primary.withValues(
                      alpha: (isDark ? 0.30 : 0.20) * (1 - _pulse.value)),
                ),
              ),
            ),
            child!,
          ],
        );
      },
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: theme.colorScheme.surface,
          boxShadow: [
            BoxShadow(
              color: primary.withValues(alpha: isDark ? 0.40 : 0.30),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: AnimatedGradientBorder(
          isAnimating: true,
          borderRadius: widget.size / 2,
          strokeWidth: 2.2,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: primary.withValues(alpha: isDark ? 0.22 : 0.12),
            ),
            child: Center(
              child: MorphingInfinity(
                size: 22,
                strokeWidth: 1.5,
                color: primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
