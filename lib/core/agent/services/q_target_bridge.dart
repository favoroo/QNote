import 'package:flutter/foundation.dart';

/// 悬浮小Q任务与打开中的编辑页之间的联动桥。
///
/// 背景：笔记/日记/手账编辑页持有本地编辑状态（控制器 + 防抖自动保存），
/// 小Q通过 VFS 直接修改底层数据不会自动反映到打开中的编辑器；若不联动，
/// 编辑器随后的自动保存会用旧内容覆盖小Q的修改。
///
/// 工作流：
/// 1. 编辑页 initState 按 [QPageContext.signature] 注册 [QTargetHooks]，dispose 注销；
/// 2. 任务开始时 [notifyTaskStart] 通知编辑页（如暂停自动保存）并记录编辑器指纹；
/// 3. 任务结束时 [notifyTaskEnd] 比对指纹：未变（用户未手动编辑）→ 调用
///    [QTargetHooks.reload] 从仓库重读刷新 UI；已变 → 保留用户版本，由编辑页自行提示。
class QTargetBridge {
  static final QTargetBridge instance = QTargetBridge._();
  QTargetBridge._();

  /// 仅供测试创建独立实例（业务代码统一使用 [instance] 单例）
  @visibleForTesting
  QTargetBridge.test();

  final Map<String, QTargetHooks> _hooks = {};

  /// 任务开始时记录的编辑器指纹，供任务结束时比对
  final Map<String, String> _fingerprints = {};

  /// 注册编辑页钩子；同签名重复注册以后者为准
  void register(String signature, QTargetHooks hooks) {
    _hooks[signature] = hooks;
  }

  /// 注销编辑页钩子
  void unregister(String signature) {
    _hooks.remove(signature);
    _fingerprints.remove(signature);
  }

  /// 任务开始：记录编辑器指纹并通知目标编辑页（如暂停自动保存）
  void notifyTaskStart(String? signature) {
    final hooks = signature == null ? null : _hooks[signature];
    if (hooks == null) return;
    final fp = hooks.fingerprint;
    if (fp != null) {
      try {
        _fingerprints[signature!] = fp();
      } catch (_) {
        _fingerprints.remove(signature);
      }
    }
    try {
      hooks.onTaskStart?.call();
    } catch (_) {}
  }

  /// 任务结束：目标编辑页指纹未变则重载，否则保留用户编辑版本。
  /// 返回是否触发了重载
  Future<bool> notifyTaskEnd(String? signature) async {
    final hooks = signature == null ? null : _hooks[signature];
    if (hooks == null) return false;
    try {
      hooks.onTaskEnd?.call();
    } catch (_) {}

    if (hooks.fingerprint == null || hooks.reload == null) return false;
    final baseline = _fingerprints.remove(signature);
    try {
      if (baseline == null || hooks.fingerprint!() != baseline) {
        // 任务期间用户手动编辑过（或未记录到基线）：保留用户版本，不重载
        return false;
      }
      await hooks.reload!();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 直接触发重载（撤回恢复后使用，跳过指纹比对）
  Future<void> reload(String? signature) async {
    final hooks = signature == null ? null : _hooks[signature];
    if (hooks?.reload == null) return;
    try {
      await hooks!.reload!();
    } catch (_) {}
  }

  /// 重载所有已注册的编辑页（撤回恢复后使用：受影响目标可能跨页面）
  Future<void> reloadAll() async {
    for (final hooks in List.of(_hooks.values)) {
      if (hooks.reload == null) continue;
      try {
        await hooks.reload!();
      } catch (_) {}
    }
  }
}

/// 编辑页向桥接注册的钩子集合
class QTargetHooks {
  /// 当前编辑器内容的指纹（如序列化后的正文+标题），判断任务期间用户是否手动编辑
  final String Function()? fingerprint;

  /// 从仓库重读最新数据并刷新编辑器 UI（需自行抑制监听器/自动保存误触发）
  final Future<void> Function()? reload;

  /// 任务开始回调（如暂停自动保存）
  final void Function()? onTaskStart;

  /// 任务结束回调（如恢复自动保存）
  final void Function()? onTaskEnd;

  const QTargetHooks({
    this.fingerprint,
    this.reload,
    this.onTaskStart,
    this.onTaskEnd,
  });
}
