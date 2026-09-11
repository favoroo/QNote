/// 待办提醒时间的统一格式化与解析工具。
///
/// QNote 的提醒时间在数据库中存为 `MM-DD HH:mm` 字符串（解析时补当前年份），
/// 这是 UI 与通知服务共同遵循的约定。集中在此处处理，避免 Agent 写入、
/// 页面设置、通知解析三处各自实现导致格式漂移。
///
/// 为什么需要归一化：Agent 很容易写出 `2026-09-11 19:00` 这种带年份的写法，
/// 而 naïve 解析会把 `2026` 当成月份，DateTime 自动进位成 2194 年，静默失效。
class ReminderUtils {
  ReminderUtils._();

  /// `YYYY-MM-DD HH:mm` / `YYYY/MM/DDTHH:mm:ss` 等带年份写法
  static final RegExp _fullPattern =
      RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})[ T](\d{1,2}):(\d{2})');

  /// `MM-DD HH:mm` / `M/D HH:mm` 等不带年份写法
  static final RegExp _monthDayPattern =
      RegExp(r'^(\d{1,2})[-/.](\d{1,2})[ T](\d{1,2}):(\d{2})');

  /// 裸时间 `HH:mm`，按「今天」处理
  static final RegExp _timeOnlyPattern = RegExp(r'^(\d{1,2}):(\d{2})$');

  /// 把任意常见写法归一化为 `MM-DD HH:mm`；无法识别时返回 null。
  ///
  /// 支持：`2026-09-11 19:00`、`2026-09-11T19:00:00`、`09-11 19:00`、`19:00`。
  static String? normalize(Object? raw) {
    if (raw == null) return null;
    var s = raw.toString().trim();
    if (s.isEmpty) return null;
    // 去掉包裹的引号
    if (s.length >= 2 &&
        ((s.startsWith('"') && s.endsWith('"')) ||
            (s.startsWith("'") && s.endsWith("'")))) {
      s = s.substring(1, s.length - 1).trim();
    }

    var m = _fullPattern.firstMatch(s);
    if (m != null) {
      return _compose(m.group(2)!, m.group(3)!, m.group(4)!, m.group(5)!);
    }

    m = _monthDayPattern.firstMatch(s);
    if (m != null) {
      return _compose(m.group(1)!, m.group(2)!, m.group(3)!, m.group(4)!);
    }

    m = _timeOnlyPattern.firstMatch(s);
    if (m != null) {
      final now = DateTime.now();
      return _compose(
        now.month.toString(),
        now.day.toString(),
        m.group(1)!,
        m.group(2)!,
      );
    }

    return null;
  }

  /// 解析为具体 DateTime（年份取当前年），无法识别时返回 null。
  static DateTime? parse(String? raw) {
    final normalized = normalize(raw);
    if (normalized == null) return null;
    final segments = normalized.split(' ');
    final dateParts = segments[0].split('-');
    final timeParts = segments[1].split(':');
    final now = DateTime.now();
    return DateTime(
      now.year,
      int.parse(dateParts[0]),
      int.parse(dateParts[1]),
      int.parse(timeParts[0]),
      int.parse(timeParts[1]),
    );
  }

  /// 把 DateTime 格式化为存储格式 `MM-DD HH:mm`。
  static String format(DateTime time) {
    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$month-$day $hour:$minute';
  }

  static String _compose(String month, String day, String hour, String minute) {
    final mm = int.parse(month).toString().padLeft(2, '0');
    final dd = int.parse(day).toString().padLeft(2, '0');
    final hh = int.parse(hour).toString().padLeft(2, '0');
    final mi = int.parse(minute).toString().padLeft(2, '0');
    return '$mm-$dd $hh:$mi';
  }
}
