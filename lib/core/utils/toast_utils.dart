import 'package:flutter/material.dart';

enum ToastType { success, error, info, warning }

class Toast {
  static OverlayEntry? _currentEntry;
  static const Duration _defaultDuration = Duration(seconds: 2);

  static void show(
    BuildContext context,
    String message, {
    ToastType type = ToastType.info,
    Duration? duration,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    _dismiss();

    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (_) => _ToastWidget(
        message: message,
        type: type,
        duration: duration ?? _defaultDuration,
        onDismiss: _dismiss,
        actionLabel: actionLabel,
        onAction: onAction,
      ),
    );

    _currentEntry = entry;
    overlay.insert(entry);
  }

  static void success(BuildContext context, String message, {Duration? duration}) {
    show(context, message, type: ToastType.success, duration: duration);
  }

  static void error(BuildContext context, String message, {Duration? duration}) {
    show(context, message, type: ToastType.error, duration: duration ?? const Duration(seconds: 3));
  }

  static void info(BuildContext context, String message, {Duration? duration}) {
    show(context, message, type: ToastType.info, duration: duration);
  }

  static void warning(BuildContext context, String message, {Duration? duration}) {
    show(context, message, type: ToastType.warning, duration: duration);
  }

  static void dismiss() {
    _dismiss();
  }

  static void _dismiss() {
    _currentEntry?.remove();
    _currentEntry = null;
  }
}

class _ToastWidget extends StatefulWidget {
  final String message;
  final ToastType type;
  final Duration duration;
  final VoidCallback onDismiss;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _ToastWidget({
    required this.message,
    required this.type,
    required this.duration,
    required this.onDismiss,
    this.actionLabel,
    this.onAction,
  });

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );

    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _controller.forward();

    Future.delayed(widget.duration, _animateOut);
  }

  void _animateOut() {
    if (!mounted) return;
    _controller.reverse().then((_) => widget.onDismiss());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  IconData _iconData() {
    switch (widget.type) {
      case ToastType.success:
        return Icons.check_circle_rounded;
      case ToastType.error:
        return Icons.error_rounded;
      case ToastType.info:
        return Icons.info_rounded;
      case ToastType.warning:
        return Icons.warning_amber_rounded;
    }
  }

  Color _iconColor() {
    switch (widget.type) {
      case ToastType.success:
        return const Color(0xFF4CAF50);
      case ToastType.error:
        return const Color(0xFFEF5350);
      case ToastType.info:
        return const Color(0xFF90A4AE);
      case ToastType.warning:
        return const Color(0xFFFFA726);
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top + 16;
    final hasAction = widget.actionLabel != null && widget.onAction != null;

    return Positioned(
      top: topPadding,
      left: 0,
      right: 0,
      child: Center(
        child: SlideTransition(
          position: _slideAnimation,
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * (hasAction ? 0.8 : 0.7),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_iconData(), color: _iconColor(), size: 18),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      widget.message,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                    ),
                  ),
                  if (hasAction) ...[
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () {
                        widget.onAction?.call();
                        Toast.dismiss();
                      },
                      child: Text(
                        widget.actionLabel!,
                        style: const TextStyle(
                          color: Color(0xFF81D4FA),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
