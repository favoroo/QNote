/// Agent 动态取消与中止控制器（对齐 AbortController 设计）
class AgentCancellationToken {
  bool _isCancelled = false;
  String? _reason;
  final List<void Function()> _listeners = [];

  /// 是否已被取消
  bool get isCancelled => _isCancelled;

  /// 取消原因
  String? get reason => _reason;

  /// 发起取消操作
  void cancel([String? reason]) {
    if (_isCancelled) return;
    _isCancelled = true;
    _reason = reason ?? '用户主动取消操作';
    for (final listener in List.of(_listeners)) {
      try {
        listener();
      } catch (_) {}
    }
  }

  /// 添加取消监听器
  void addListener(void Function() listener) {
    if (_isCancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  /// 移除取消监听器
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }
}
