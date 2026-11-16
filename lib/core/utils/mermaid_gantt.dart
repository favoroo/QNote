/// Mermaid `gantt` 源码的轻量解析器。
///
/// Mermaid 自带的甘特 SVG 在手机上任务名会跟着时间轴一起滚走，日期轴也很容易被
/// 压到看不清。App 对 `.mmd` 甘特改用原生视图：固定左侧任务列、时间轴横向滚动、
/// 日/周/月三档缩放，视觉跟随全局主题。
///
/// 这里只解析原生视图需要的常用子集；遇到 `excludes`、`inclusiveEndDates`、
/// 自定义 dateFormat、循环 `after` 等无法保证语义正确的写法时返回 null，
/// 由调用方回退到通用 Mermaid 预览。宁可回退，也不能画出一张日期错误的图。
library;

/// 任务状态（与 Mermaid gantt 的标签对应）
enum GanttTaskStatus { normal, done, active, crit }

/// 状态中文名
String ganttTaskStatusLabel(GanttTaskStatus status) => switch (status) {
  GanttTaskStatus.normal => '未开始',
  GanttTaskStatus.done => '已完成',
  GanttTaskStatus.active => '进行中',
  GanttTaskStatus.crit => '关键任务',
};

/// 单个甘特任务
class GanttTask {
  /// Mermaid 任务 id（源码未写 id 时由解析器生成，不可被 `after` 引用）
  final String id;
  final String name;
  final String section;
  final DateTime start;

  /// 排他终点：`start == end` 表示里程碑
  final DateTime end;
  final GanttTaskStatus status;
  final bool milestone;

  const GanttTask({
    required this.id,
    required this.name,
    required this.section,
    required this.start,
    required this.end,
    required this.status,
    required this.milestone,
  });

  Duration get duration => end.difference(start);

  /// 任务在日期轴上的天数（里程碑为 0）
  int get durationDays => duration.inDays;

  @override
  String toString() => 'GanttTask($id, $name, $start → $end, $status, milestone=$milestone)';
}

/// 一个 `section` 分组
class GanttSection {
  final String name;
  final List<GanttTask> tasks;

  const GanttSection({required this.name, required this.tasks});
}

/// 解析后的甘特计划
class GanttPlan {
  final String? title;

  /// 图表范围（已向两侧各留 1 天，且至少 3 天）
  final DateTime rangeStart;
  final DateTime rangeEnd;

  final List<GanttSection> sections;
  final Map<String, GanttTask> taskById;

  const GanttPlan({
    required this.title,
    required this.rangeStart,
    required this.rangeEnd,
    required this.sections,
    required this.taskById,
  });

  /// 按源码顺序展开的全部任务
  List<GanttTask> get tasks => [for (final section in sections) ...section.tasks];

  int get taskCount => tasks.length;

  /// 图表覆盖的自然日数
  int get daySpan {
    final start = DateTime.utc(rangeStart.year, rangeStart.month, rangeStart.day);
    final end = DateTime.utc(rangeEnd.year, rangeEnd.month, rangeEnd.day);
    return end.difference(start).inDays;
  }

  /// 日期是否落在图表范围内（按自然日比较；[rangeEnd] 为排他终点）
  bool containsDate(DateTime date) {
    final d = DateTime.utc(date.year, date.month, date.day);
    final start = DateTime.utc(rangeStart.year, rangeStart.month, rangeStart.day);
    final end = DateTime.utc(rangeEnd.year, rangeEnd.month, rangeEnd.day);
    return !d.isBefore(start) && d.isBefore(end);
  }
}

/// 解析 `.mmd` 源码中的 gantt 图；不是 gantt 或使用了不支持的写法时返回 null。
GanttPlan? parseMermaidGantt(String source) {
  final lines = source.split(RegExp(r'\r?\n'));
  var headerFound = false;
  var inFrontMatter = false;
  String? title;
  String dateFormat = 'YYYY-MM-DD';
  final rawTasks = <_RawTask>[];
  var currentSection = '';
  var autoId = 0;

  for (final rawLine in lines) {
    final line = rawLine.trim();
    if (!headerFound) {
      if (line.isEmpty) continue;
      if (line == '---') {
        inFrontMatter = !inFrontMatter;
        continue;
      }
      if (inFrontMatter) continue;
      if (line.startsWith('%%')) continue;
      if (line.toLowerCase() == 'gantt') {
        headerFound = true;
        continue;
      }
      return null;
    }

    if (line.isEmpty) continue;
    if (line.startsWith('%%{')) {
      // init 指令可能改变日期/排期语义，原生视图不猜，交给 Mermaid 通用渲染
      return null;
    }
    if (line.startsWith('%%')) continue;

    final lower = line.toLowerCase();
    if (lower == 'gantt') continue;
    if (lower.startsWith('title ')) {
      title = _unquote(line.substring(6).trim());
      if (title.isEmpty) title = null;
      continue;
    }
    if (lower.startsWith('dateformat ')) {
      dateFormat = _unquote(line.substring('dateformat '.length).trim());
      if (!_supportedDateFormat(dateFormat)) return null;
      continue;
    }
    if (lower.startsWith('axisformat ')) {
      // 原生视图使用自己的日期刻度，axisFormat 不影响数据语义
      continue;
    }
    if (lower.startsWith('tickinterval ')) continue;
    if (lower.startsWith('displaymode ')) continue;
    if (lower.startsWith('weekday ')) continue;
    if (lower.startsWith('topaxis')) continue;
    if (lower.startsWith('inclusiveenddates')) {
      // 终点是否包含当天会改变工期，原生视图不猜
      return null;
    }
    if (lower.startsWith('excludes ')) {
      // 排除周末/节假日会让「5d」变成自然日之外的含义，原生视图不猜
      return null;
    }
    if (lower.startsWith('todaymarker')) {
      // 仅影响今天标记的显示，可以安全忽略
      continue;
    }
    if (lower.startsWith('section ')) {
      currentSection = _unquote(line.substring('section '.length).trim());
      continue;
    }
    if (line.contains(':')) {
      final task = _parseTaskLine(
        line,
        section: currentSection,
        autoId: autoId++,
        statusTags: const {'done', 'active', 'crit', 'milestone'},
      );
      if (task == null) return null;
      rawTasks.add(task);
      continue;
    }

    // 未识别的配置行/语法：不猜
    return null;
  }

  if (!headerFound || rawTasks.isEmpty) return null;
  if (rawTasks.length > 200) return null; // 原生视图一次性构建行，避免超长文档卡顿

  // id 必须唯一，否则 after 引用会有歧义
  final rawById = <String, _RawTask>{};
  for (final task in rawTasks) {
    if (rawById.containsKey(task.id)) return null;
    rawById[task.id] = task;
  }

  final resolved = <String, GanttTask>{};
  final resolving = <String>{};

  GanttTask? resolve(_RawTask raw) {
    final cached = resolved[raw.id];
    if (cached != null) return cached;
    if (!resolving.add(raw.id)) return null; // 循环 after

    DateTime start;
    if (raw.startAfter != null) {
      final dependency = rawById[raw.startAfter];
      if (dependency == null) return null;
      final dependencyTask = resolve(dependency);
      if (dependencyTask == null) return null;
      start = dependencyTask.end;
    } else {
      final parsed = _parseDate(raw.start);
      if (parsed == null) return null;
      start = parsed;
    }

    DateTime end;
    if (raw.milestone) {
      end = start;
    } else if (raw.end == null) {
      end = _addDays(start, 1);
    } else {
      final duration = _parseDuration(raw.end!);
      if (duration != null) {
        end = start.add(duration);
        if (!end.isAfter(start)) {
          // 0d 任务等价于里程碑
          end = start;
          raw.milestone = true;
        }
      } else {
        final parsedEnd = _parseDate(raw.end!);
        if (parsedEnd == null) return null;
        // Mermaid 的结束日期是包含当天的；这里转成排他终点
        end = _addDays(parsedEnd, 1);
        if (!end.isAfter(start)) {
          if (_sameDate(start, parsedEnd)) {
            end = _addDays(start, 1);
          } else {
            return null;
          }
        }
      }
    }

    final task = GanttTask(
      id: raw.id,
      name: raw.name,
      section: raw.section,
      start: start,
      end: end,
      status: raw.status,
      milestone: raw.milestone,
    );
    resolved[raw.id] = task;
    resolving.remove(raw.id);
    return task;
  }

  final orderedTasks = <GanttTask>[];
  for (final raw in rawTasks) {
    final task = resolve(raw);
    if (task == null) return null;
    orderedTasks.add(task);
  }

  // 分组保持源码中 section 首次出现的顺序
  final sectionTasks = <String, List<GanttTask>>{};
  for (final task in orderedTasks) {
    final name = task.section.trim().isEmpty ? '任务' : task.section;
    sectionTasks.putIfAbsent(name, () => <GanttTask>[]).add(task);
  }
  final sections = [
    for (final entry in sectionTasks.entries) GanttSection(name: entry.key, tasks: List.unmodifiable(entry.value)),
  ];

  var minStart = orderedTasks.first.start;
  var maxEnd = orderedTasks.first.end;
  for (final task in orderedTasks.skip(1)) {
    if (task.start.isBefore(minStart)) minStart = task.start;
    if (task.end.isAfter(maxEnd)) maxEnd = task.end;
  }
  final rangeStart = _addDays(minStart, -1);
  var rangeEnd = _addDays(maxEnd, 1);
  if (!rangeEnd.isAfter(rangeStart)) rangeEnd = _addDays(rangeStart, 3);
  if (_daysBetween(rangeStart, rangeEnd) < 3) rangeEnd = _addDays(rangeStart, 3);

  return GanttPlan(
    title: title,
    rangeStart: _dateOnly(rangeStart),
    rangeEnd: _dateOnly(rangeEnd),
    sections: List.unmodifiable(sections),
    taskById: Map.unmodifiable(resolved),
  );
}

class _RawTask {
  final String id;
  final String name;
  final String section;
  final GanttTaskStatus status;
  final String start;
  final String? end;
  final String? startAfter;
  bool milestone;

  _RawTask({
    required this.id,
    required this.name,
    required this.section,
    required this.status,
    required this.start,
    required this.end,
    required this.startAfter,
    required this.milestone,
  });
}

_RawTask? _parseTaskLine(String line, {required String section, required int autoId, required Set<String> statusTags}) {
  final colon = line.indexOf(':');
  if (colon <= 0) return null;
  final name = _unquote(line.substring(0, colon).trim());
  if (name.isEmpty) return null;

  final tokens = [
    for (final token in line.substring(colon + 1).split(','))
      if (token.trim().isNotEmpty) _unquote(token.trim()),
  ];
  if (tokens.isEmpty) return null;

  var status = GanttTaskStatus.normal;
  var milestone = false;
  var cursor = 0;
  while (cursor < tokens.length) {
    final tag = tokens[cursor].toLowerCase();
    if (!statusTags.contains(tag)) break;
    switch (tag) {
      case 'done':
        status = GanttTaskStatus.done;
      case 'active':
        status = GanttTaskStatus.active;
      case 'crit':
        status = GanttTaskStatus.crit;
      case 'milestone':
        milestone = true;
    }
    cursor++;
  }
  if (cursor >= tokens.length) return null;

  String id;
  if (_looksLikeId(tokens[cursor])) {
    id = tokens[cursor];
    cursor++;
  } else {
    id = '__auto_$autoId';
  }
  if (cursor >= tokens.length) return null;

  final startToken = tokens[cursor++];
  String? startAfter;
  if (startToken.toLowerCase().startsWith('after ')) {
    startAfter = startToken.substring(6).trim();
    if (startAfter.isEmpty) return null;
  } else if (_parseDate(startToken) == null) {
    return null;
  }

  final endToken = cursor < tokens.length ? tokens[cursor] : null;
  if (endToken != null && _parseDuration(endToken) == null && _parseDate(endToken) == null) {
    // 未识别的第四个字段（如 until/自定义标记）不猜
    return null;
  }

  return _RawTask(
    id: id,
    name: name,
    section: section,
    status: status,
    start: startToken,
    end: endToken,
    startAfter: startAfter,
    milestone: milestone,
  );
}

bool _looksLikeId(String token) {
  if (token.isEmpty) return false;
  if (_parseDate(token) != null) return false;
  if (_parseDuration(token) != null) return false;
  if (token.toLowerCase().startsWith('after ')) return false;
  return true;
}

bool _supportedDateFormat(String value) {
  final compact = value.replaceAll(RegExp(r'\s'), '').toUpperCase();
  return compact == 'YYYY-MM-DD' ||
      compact == 'YYYY/MM/DD' ||
      compact == 'YYYY.MM.DD' ||
      compact == 'YYYY-MM-DD HH:MM' ||
      compact == 'YYYY/MM/DD HH:MM';
}

final RegExp _datePattern = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?:[ T](\d{1,2}):(\d{2}))?$');

DateTime? _parseDate(String raw) {
  final match = _datePattern.firstMatch(raw.trim());
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = match.group(4) == null ? 0 : int.parse(match.group(4)!);
  final minute = match.group(5) == null ? 0 : int.parse(match.group(5)!);
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59) return null;
  final value = DateTime(year, month, day, hour, minute);
  // DateTime 会把 2 月 30 日滚到 3 月，这里按非法日期拒绝
  if (value.year != year || value.month != month || value.day != day) return null;
  return value;
}

final RegExp _durationPattern = RegExp(r'^(\d+(?:\.\d+)?)\s*([dwDhHmMsS])$');

Duration? _parseDuration(String raw) {
  final match = _durationPattern.firstMatch(raw.trim());
  if (match == null) return null;
  final amount = double.parse(match.group(1)!);
  if (amount < 0) return null;
  final unit = match.group(2)!.toLowerCase();
  final seconds = switch (unit) {
    'd' => amount * 86400,
    'w' => amount * 7 * 86400,
    'h' => amount * 3600,
    'm' => amount * 60,
    's' => amount,
    _ => 0.0,
  };
  return Duration(milliseconds: (seconds * 1000).round());
}

String _unquote(String value) {
  if (value.length >= 2) {
    final first = value[0];
    final last = value[value.length - 1];
    if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
      return value.substring(1, value.length - 1);
    }
  }
  return value;
}

DateTime _dateOnly(DateTime value) => DateTime(value.year, value.month, value.day);

DateTime _addDays(DateTime value, int days) => DateTime(value.year, value.month, value.day + days);

bool _sameDate(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

int _daysBetween(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
