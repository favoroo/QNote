import 'package:flutter/material.dart';

/// 运动健康日结卡片的内部语义色。
///
/// 这些颜色过去散落在 [DiaryItem] 与批量管理视图里，一张卡片上同时出现紫、蓝、
/// 青、绿、琥珀、橙、红、靛 8 种色相，颜色比数据本身更抢眼。这里收敛成三组语义：
/// **活动 / 睡眠 / 屏幕** 三条主线各占一个色系，生理指标沿用标签语义色（心率红、
/// 血氧蓝、压力琥珀），组内只用明度区分层级。
///
/// 与 [TagColors] 一样给出浅 / 深两支：浅色主题取 600 档（鲜亮不发闷），
/// 深色主题取 400 档。两者都只保证**图形级**对比度（≥3:1），因为这里全部用作
/// 图标、进度条、分段条填充；少量作为文字出现的地方（睡眠时长、屏幕时长、
/// 指标数值）走 `AppContrast.readable` / `inkOnTint` 另行压深。
abstract class HealthColors {
  // —— 等级色（心率 / 血氧 / 压力区间、评分、饮食评价共用）——
  //
  // 这些区间过去在 4 个文件里各写一套 Tailwind 500 档（#10B981/#F59E0B/#EF4444），
  // 既互不一致，压到 11px 文字上又只有 2.1~3.8:1。现在统一成一条四级色阶，
  // 每级一个色相、一个明度，跨页面同义同色。

  /// 正常 / 良好。
  static Color levelGood(Brightness b) => activity(b);

  /// 中性 / 偏低（区间分布里的「静息」「正常偏低」）。
  static Color levelInfo(Brightness b) => distance(b);

  /// 注意 / 中等。
  static Color levelWarn(Brightness b) => activeMinute(b);

  /// 偏高 / 异常。
  static Color levelAlert(Brightness b) => heartRate(b);

  /// 严重 / 需重点关注：比 [levelAlert] 再冷一档的玫红，用在四档评价的最末级。
  static const Color criticalLight = Color(0xFFBE123C);
  static const Color criticalDark = Color(0xFFFDA4AF);

  /// 未归类 / 未知：中性灰。
  static const Color neutralLight = Color(0xFF6B7280);
  static const Color neutralDark = Color(0xFF9CA3AF);

  static Color critical(Brightness b) => _pick(b, criticalLight, criticalDark);

  static Color neutral(Brightness b) => _pick(b, neutralLight, neutralDark);

  // —— 活动主线（步数、消耗、距离、活动分钟、站立）——
  /// 活动主色：步数进度条与达标徽标，与「活动」标签同色系。
  static const Color activityLight = Color(0xFF059669);
  static const Color activityDark = Color(0xFF34D399);

  /// 消耗：暖橙。
  static const Color calorieLight = Color(0xFFEA580C);
  static const Color calorieDark = Color(0xFFFB923C);

  /// 距离：天蓝。
  static const Color distanceLight = Color(0xFF2563EB);
  static const Color distanceDark = Color(0xFF60A5FA);

  /// 活动分钟：琥珀。
  static const Color activeMinuteLight = Color(0xFFB7791F);
  static const Color activeMinuteDark = Color(0xFFFACC15);

  /// 站立次数：紫。
  static const Color standingLight = Color(0xFF7C3AED);
  static const Color standingDark = Color(0xFFA78BFA);

  // —— 睡眠主线（时长、评分、分期）——
  /// 睡眠主色：与「睡眠」标签同色。
  static const Color sleepLight = Color(0xFF7C3AED);
  static const Color sleepDark = Color(0xFFA78BFA);

  /// 深睡：比睡眠主色再深一级。
  static const Color deepSleepLight = Color(0xFF6D28D9);
  static const Color deepSleepDark = Color(0xFFB39DDB);

  /// 浅睡：中紫。
  static const Color lightSleepLight = Color(0xFFA855F7);
  static const Color lightSleepDark = Color(0xFFDDD6FE);

  /// REM：天蓝，与浅睡紫拉开。
  static const Color remSleepLight = Color(0xFF0284C7);
  static const Color remSleepDark = Color(0xFF7DD3FC);

  /// 清醒：中性灰，不做强调。
  ///
  /// 这一段是分段条 / 图例的**填充色**（不是文字），能分辨即可。
  static const Color awakeLight = Color(0xFF7C8AA0);
  static const Color awakeDark = Color(0xFF94A3B8);

  // —— 屏幕主线 ——
  /// 屏幕主色：青，与睡眠紫、活动绿都不撞。
  static const Color screenLight = Color(0xFF0891B2);
  static const Color screenDark = Color(0xFF22D3EE);

  /// Top 应用占比条的前 4 段：同色系内按明度递进，不再跨 4 个色相。
  static const List<Color> screenAppsLight = [
    Color(0xFF0891B2), // 主青
    Color(0xFF06B6D4), // 亮青
    Color(0xFF0284C7), // 天蓝
    Color(0xFF0E7490), // 压深青
  ];
  static const List<Color> screenAppsDark = [
    Color(0xFF22D3EE), // 亮青
    Color(0xFF67E8F9), // 浅青
    Color(0xFF7DD3FC), // 天蓝
    Color(0xFF38BDF8), // 蓝
  ];

  // —— 生理指标（沿用标签语义色）——
  /// 静息心率：红。
  static const Color heartRateLight = Color(0xFFDC2626);
  static const Color heartRateDark = Color(0xFFF87171);

  /// 平均血氧：蓝。
  static const Color spo2Light = Color(0xFF2563EB);
  static const Color spo2Dark = Color(0xFF60A5FA);

  /// 压力指数：琥珀。
  static const Color stressLight = Color(0xFFB7791F);
  static const Color stressDark = Color(0xFFFACC15);

  static Color activity(Brightness b) => _pick(b, activityLight, activityDark);
  static Color calorie(Brightness b) => _pick(b, calorieLight, calorieDark);
  static Color distance(Brightness b) => _pick(b, distanceLight, distanceDark);
  static Color activeMinute(Brightness b) => _pick(b, activeMinuteLight, activeMinuteDark);
  static Color standing(Brightness b) => _pick(b, standingLight, standingDark);
  static Color sleep(Brightness b) => _pick(b, sleepLight, sleepDark);
  static Color deepSleep(Brightness b) => _pick(b, deepSleepLight, deepSleepDark);
  static Color lightSleep(Brightness b) => _pick(b, lightSleepLight, lightSleepDark);
  static Color remSleep(Brightness b) => _pick(b, remSleepLight, remSleepDark);
  static Color awake(Brightness b) => _pick(b, awakeLight, awakeDark);
  static Color screen(Brightness b) => _pick(b, screenLight, screenDark);
  static Color heartRate(Brightness b) => _pick(b, heartRateLight, heartRateDark);
  static Color spo2(Brightness b) => _pick(b, spo2Light, spo2Dark);
  static Color stress(Brightness b) => _pick(b, stressLight, stressDark);

  /// 屏幕 Top 应用占比条的配色序列，按深浅主题取对应一支。
  static List<Color> screenApps(Brightness b) => b == Brightness.dark ? screenAppsDark : screenAppsLight;

  static Color _pick(Brightness brightness, Color light, Color dark) => brightness == Brightness.dark ? dark : light;
}
