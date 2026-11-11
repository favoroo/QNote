import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';

enum ToastType { success, error, info, warning }

/// 轻量顶部提示。
///
/// 所有 Toast 共用一个常驻 Overlay 宿主，连续调用时由 [AnimatedSwitcher]
/// 交叉淡化替换，而不是「立刻移除旧条 + 插入新条」的硬切；编程式
/// [dismiss] 与自动超时也都走同一条退场动画。
class Toast {
  static OverlayEntry? _hostEntry;
  static OverlayState? _hostOverlay;
  static final _ToastHostController _hostController = _ToastHostController();
  static const Duration _defaultDuration = Duration(seconds: 2);

  static void show(
    BuildContext context,
    String message, {
    ToastType type = ToastType.info,
    Duration? duration,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    showIn(
      Overlay.of(context),
      message,
      type: type,
      duration: duration,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }

  /// 直接指定挂载 Overlay 的入口，供没有 widget context 的层复用同一套样式与
  /// 单槽互斥语义（如 provider 的后台刷新失败提示，经 `rootNavigatorKey` 取 Overlay）。
  static void showIn(
    OverlayState overlay,
    String message, {
    ToastType type = ToastType.info,
    Duration? duration,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    // Overlay 换了（例如测试中重建 MaterialApp）或宿主已卸载就迁移宿主，
    // 避免提示挂在旧树上。
    if (_hostEntry != null && (!_hostEntry!.mounted || _hostOverlay != overlay)) {
      _disposeHost();
    }

    if (_hostEntry == null) {
      final entry = OverlayEntry(
        builder: (_) => _ToastHost(controller: _hostController),
      );
      _hostEntry = entry;
      _hostOverlay = overlay;
      overlay.insert(entry);
    }

    _hostController.show(
      _ToastData(
        message: message,
        type: type,
        duration: duration ?? _defaultDuration,
        actionLabel: actionLabel,
        onAction: onAction,
      ),
    );
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
    _hostController.hide();
  }

  static void _disposeHost() {
    _hostController.clear();
    final entry = _hostEntry;
    if (entry != null && entry.mounted) {
      entry.remove();
    }
    _hostEntry = null;
    _hostOverlay = null;
  }
}

/// Toast 数据快照。`seq` 每次换内容自增，宿主以此判断是否需要重置计时器。
class _ToastData {
  final int seq;
  final String message;
  final ToastType type;
  final Duration duration;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool visible;

  const _ToastData({
    this.seq = 0,
    required this.message,
    required this.type,
    required this.duration,
    this.actionLabel,
    this.onAction,
    this.visible = true,
  });

  _ToastData copyWith({int? seq, bool? visible}) {
    return _ToastData(
      seq: seq ?? this.seq,
      message: message,
      type: type,
      duration: duration,
      actionLabel: actionLabel,
      onAction: onAction,
      visible: visible ?? this.visible,
    );
  }
}

class _ToastHostController extends ChangeNotifier {
  _ToastData? _data;
  int _seq = 0;

  _ToastData? get data => _data;

  void show(_ToastData data) {
    _seq++;
    _data = data.copyWith(seq: _seq);
    notifyListeners();
  }

  void hide() {
    final data = _data;
    if (data == null || !data.visible) return;
    _data = data.copyWith(visible: false);
    notifyListeners();
  }

  void clear() {
    _data = null;
    notifyListeners();
  }
}

class _ToastHost extends StatefulWidget {
  final _ToastHostController controller;

  const _ToastHost({required this.controller});

  @override
  State<_ToastHost> createState() => _ToastHostState();
}

class _ToastHostState extends State<_ToastHost> {
  _ToastData? _data;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleChange);
    _data = widget.controller.data;
    _restartTimer();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.controller.removeListener(_handleChange);
    super.dispose();
  }

  void _handleChange() {
    final next = widget.controller.data;
    final isNewToast = next != null && next.visible && next.seq != _data?.seq;
    final visibilityChanged = (next?.visible ?? false) != (_data?.visible ?? false);
    if (!isNewToast && !visibilityChanged && next?.seq == _data?.seq) {
      return;
    }

    setState(() => _data = next);
    if (isNewToast) {
      _restartTimer();
    } else if (next == null || !next.visible) {
      _hideTimer?.cancel();
      _hideTimer = null;
    }
  }

  void _restartTimer() {
    _hideTimer?.cancel();
    final data = _data;
    if (data == null || !data.visible) return;
    _hideTimer = Timer(data.duration, widget.controller.hide);
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final visible = data != null && data.visible;

    return Positioned(
      top: MediaQuery.paddingOf(context).top + 16,
      left: 12,
      right: 12,
      child: IgnorePointer(
        ignoring: !visible,
        child: Center(
          child: AnimatedSwitcher(
            duration: AppMotion.duration(context, AppDurations.normal),
            reverseDuration: AppMotion.duration(context, AppDurations.fast),
            switchInCurve: AppCurves.emphasized,
            switchOutCurve: AppCurves.exit,
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, -0.35),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              );
            },
            child: visible
                ? _ToastCard(key: ValueKey<int>(data.seq), data: data)
                : const SizedBox.shrink(key: ValueKey<String>('toast_empty')),
          ),
        ),
      ),
    );
  }
}

class _ToastCard extends StatelessWidget {
  final _ToastData data;

  const _ToastCard({super.key, required this.data});

  IconData _iconData() {
    switch (data.type) {
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
    switch (data.type) {
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
    final hasAction = data.actionLabel != null && data.onAction != null;

    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * (hasAction ? 0.8 : 0.7),
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
                data.message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ),
            if (hasAction) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  data.onAction?.call();
                  Toast.dismiss();
                },
                child: Text(
                  data.actionLabel!,
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
    );
  }
}
