import 'package:flutter/material.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';

class ActionMenuItem {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDestructive;

  const ActionMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
  });
}

class ActionMenu {
  static OverlayEntry? _overlayEntry;
  static GlobalKey<_ActionMenuOverlayState>? _currentOverlayKey;

  static void show({
    required BuildContext context,
    required GlobalKey key,
    required List<ActionMenuItem> items,
  }) {
    dismiss(immediate: true);

    final renderBox = key.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final overlay = Overlay.of(context);
    final size = renderBox.size;
    final offset = renderBox.localToGlobal(Offset.zero);
    final screenSize = MediaQuery.of(context).size;

    const menuWidth = 220.0;
    const itemHeight = 52.0;
    final menuHeight = items.length * itemHeight + 16;

    final showAbove = offset.dy + size.height + menuHeight > screenSize.height - 16;
    double top;
    if (showAbove) {
      top = offset.dy - menuHeight;
      if (top < 16) top = 16;
    } else {
      top = offset.dy + size.height + 4;
    }

    double left = offset.dx;
    if (left + menuWidth > screenSize.width - 16) {
      left = screenSize.width - menuWidth - 16;
    }
    if (left < 16) left = 16;

    final overlayKey = GlobalKey<_ActionMenuOverlayState>();
    _currentOverlayKey = overlayKey;

    _overlayEntry = OverlayEntry(
      builder: (context) => _ActionMenuOverlay(
        key: overlayKey,
        top: top,
        left: left,
        menuWidth: menuWidth,
        items: items,
        onDismiss: () => dismiss(immediate: false),
        onRemoveEntry: () {
          _overlayEntry?.remove();
          _overlayEntry = null;
          _currentOverlayKey = null;
        },
      ),
    );

    overlay.insert(_overlayEntry!);
  }

  /// 关闭菜单。
  ///
  /// [immediate] 为 true 时立即从 Overlay 移除，用于重新弹出新菜单时的快速清理；
  /// 为 false 时播放平滑的反向淡出缩放动画后再移除。
  static void dismiss({bool immediate = false}) {
    if (immediate) {
      _overlayEntry?.remove();
      _overlayEntry = null;
      _currentOverlayKey = null;
      return;
    }

    final state = _currentOverlayKey?.currentState;
    if (state != null) {
      state.dismissWithAnimation();
    } else {
      _overlayEntry?.remove();
      _overlayEntry = null;
      _currentOverlayKey = null;
    }
  }
}

class _ActionMenuOverlay extends StatefulWidget {
  final double top;
  final double left;
  final double menuWidth;
  final List<ActionMenuItem> items;
  final VoidCallback onDismiss;
  final VoidCallback onRemoveEntry;

  const _ActionMenuOverlay({
    super.key,
    required this.top,
    required this.left,
    required this.menuWidth,
    required this.items,
    required this.onDismiss,
    required this.onRemoveEntry,
  });

  @override
  State<_ActionMenuOverlay> createState() => _ActionMenuOverlayState();
}

class _ActionMenuOverlayState extends State<_ActionMenuOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  bool _isDismissing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AppDurations.fast,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: AppCurves.emphasized,
      reverseCurve: AppCurves.exit,
    );
    _scaleAnimation = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: AppCurves.emphasized,
        reverseCurve: AppCurves.exit,
      ),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 播放反向动画平滑退出后从 Overlay 移除
  void dismissWithAnimation() {
    if (_isDismissing || !mounted) return;
    _isDismissing = true;
    _controller.reverse().then((_) {
      if (mounted) {
        widget.onRemoveEntry();
      }
    });
  }

  void _handleItemTap(ActionMenuItem item) {
    dismissWithAnimation();
    item.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Stack(
      children: [
        GestureDetector(
          onTap: widget.onDismiss,
          behavior: HitTestBehavior.opaque,
          child: const SizedBox.expand(),
        ),
        Positioned(
          top: widget.top,
          left: widget.left,
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: ScaleTransition(
              scale: _scaleAnimation,
              alignment: Alignment.topRight,
              child: Material(
                elevation: 12,
                shadowColor: Colors.black.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(24),
                color: colorScheme.surface,
                child: Container(
                  width: widget.menuWidth,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: widget.items.map((item) {
                      final color = item.isDestructive
                          ? colorScheme.error
                          : colorScheme.onSurface;
                      return InkWell(
                        onTap: () => _handleItemTap(item),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                          child: Row(
                            children: [
                              Icon(item.icon, size: 22, color: color),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  item.label,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: color,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
