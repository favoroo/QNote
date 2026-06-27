import 'package:flutter/material.dart';

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

  static void show({
    required BuildContext context,
    required GlobalKey key,
    required List<ActionMenuItem> items,
  }) {
    dismiss();

    final renderBox = key.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final overlay = Overlay.of(context);
    final size = renderBox.size;
    final offset = renderBox.localToGlobal(Offset.zero);
    final screenSize = MediaQuery.of(context).size;

    final menuWidth = 220.0;
    final itemHeight = 52.0;
    final menuHeight = items.length * itemHeight + 16;

    bool showAbove = offset.dy + size.height + menuHeight > screenSize.height - 16;
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

    _overlayEntry = OverlayEntry(
      builder: (context) => _ActionMenuOverlay(
        top: top,
        left: left,
        menuWidth: menuWidth,
        items: items,
        onDismiss: dismiss,
      ),
    );

    overlay.insert(_overlayEntry!);
  }

  static void dismiss() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }
}

class _ActionMenuOverlay extends StatefulWidget {
  final double top;
  final double left;
  final double menuWidth;
  final List<ActionMenuItem> items;
  final VoidCallback onDismiss;

  const _ActionMenuOverlay({
    required this.top,
    required this.left,
    required this.menuWidth,
    required this.items,
    required this.onDismiss,
  });

  @override
  State<_ActionMenuOverlay> createState() => _ActionMenuOverlayState();
}

class _ActionMenuOverlayState extends State<_ActionMenuOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _scaleAnimation = Tween<double>(begin: 0.9, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleItemTap(ActionMenuItem item) {
    widget.onDismiss();
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
