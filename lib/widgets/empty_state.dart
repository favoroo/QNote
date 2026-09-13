import 'dart:math' as math;
import 'package:flutter/material.dart';

class EmptyStateWidget extends StatefulWidget {
  final IconData icon;
  final String message;
  final String? description;
  final double iconSize;

  const EmptyStateWidget({
    super.key,
    required this.icon,
    required this.message,
    this.description,
    this.iconSize = 48,
  });

  @override
  State<EmptyStateWidget> createState() => _EmptyStateWidgetState();
}

class _EmptyStateWidgetState extends State<EmptyStateWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // 2.6s 优雅低频呼吸浮动周期，节能且不喧宾夺主
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final disableAnimations = MediaQuery.of(context).disableAnimations;

    Widget iconBox = Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.04),
        shape: BoxShape.circle,
        border: Border.all(
          color: colorScheme.primary.withValues(alpha: 0.06),
          width: 2,
        ),
      ),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colorScheme.primary.withValues(alpha: 0.08),
          shape: BoxShape.circle,
        ),
        child: Icon(
          widget.icon,
          size: widget.iconSize,
          color: colorScheme.primary,
        ),
      ),
    );

    if (!disableAnimations) {
      iconBox = AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          // 正弦波动：上下浮动 ±3px，微量缩放 0.98 ~ 1.02
          final progress = _controller.value * 2 * math.pi;
          final offsetY = math.sin(progress) * 3.0;
          final scale = 1.0 + math.sin(progress) * 0.02;
          return Transform.translate(
            offset: Offset(0, offsetY),
            child: Transform.scale(
              scale: scale,
              child: child,
            ),
          );
        },
        child: iconBox,
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            iconBox,
            const SizedBox(height: 24),
            Text(
              widget.message,
              style: textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            if (widget.description != null) ...[
              const SizedBox(height: 8),
              Text(
                widget.description!,
                style: textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
