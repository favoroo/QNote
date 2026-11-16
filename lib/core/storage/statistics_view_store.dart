import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/utils/stats_utils.dart';

/// 数据统计页的本地浏览偏好。
///
/// 只存本机 SharedPreferences，**不进备份、不参与云同步**：上次看的是哪个分类
/// 属于设备上的临时浏览状态，换设备后没有意义。
///
/// 读写失败一律静默降级：记不住分类只是回到默认分类，不能让进入统计页失败。
abstract final class StatisticsViewStore {
  /// SharedPreferences 键名
  static const String lastTabKey = 'statistics_last_tab';

  /// 读取上次停留的分类；无记录、值非法或存储不可用时返回 null。
  static Future<StatTab?> loadLastTab() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final name = prefs.getString(lastTabKey);
      if (name == null) return null;
      for (final tab in StatTab.values) {
        if (tab.name == name) return tab;
      }
    } catch (_) {
      // 读偏好失败只是回到默认分类，不影响统计页本身
    }
    return null;
  }

  /// 记录当前分类；写入失败静默忽略。
  static Future<void> saveLastTab(StatTab tab) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(lastTabKey, tab.name);
    } catch (_) {
      // 记不住上次分类只是少一个便利，不影响本次切换
    }
  }
}
