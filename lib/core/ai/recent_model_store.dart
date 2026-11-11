import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/models/ai_model_ref.dart';

/// 最近使用的小Q 模型引用
///
/// 只存本机 SharedPreferences，**不进备份、不参与云同步**：换设备后「最近用过」
/// 没有意义，多端合并还会互相覆盖顺序（口径与 token 用量统计一致）。
///
/// 所有方法都吞掉存储异常：记不住最近使用只是少一个快捷入口，不能让切换模型
/// 这个主动作失败。
class RecentModelStore {
  static final RecentModelStore instance = RecentModelStore._internal();

  RecentModelStore._internal();

  /// SharedPreferences 键名
  static const String prefsKey = 'ai_recent_model_refs';

  /// 最多保留几条；再多就不是「快捷切换」而是第二个模型列表了
  static const int maxEntries = 5;

  /// 读取最近使用（最新在前）；解析失败或存储不可用时返回空列表
  Future<List<AiModelRef>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(prefsKey) ?? const <String>[];
      final refs = <AiModelRef>[];
      for (final text in raw) {
        final ref = AiModelRef.tryParse(text);
        // 同一引用重复出现时只留第一条（越靠前越新）
        if (ref != null && !refs.contains(ref)) refs.add(ref);
      }
      return refs;
    } catch (_) {
      return const [];
    }
  }

  /// 记录一次使用：提到最前、去重、截断；返回更新后的列表
  Future<List<AiModelRef>> record(AiModelRef ref) async {
    final current = await load();
    final next = [ref, ...current.where((item) => item != ref)]
        .take(maxEntries)
        .toList();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        prefsKey,
        [for (final item in next) item.encode()],
      );
    } catch (_) {
      // 写偏好失败不影响本次切换，界面用返回值先更新
    }
    return next;
  }

  /// 清空最近使用（退出登录、清空本地数据等场景使用）
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsKey);
    } catch (_) {
      // 清不掉也不影响其它功能
    }
  }
}
