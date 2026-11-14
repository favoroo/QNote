import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_surface.dart';

/// 虚拟工作区（VFS）中与实例状态、Repository 无关的纯计算逻辑
///
/// 这里的函数从 [VirtualWorkspaceService] 中原样抽出，用于路径规范化、日期/值转换、
/// 占位文案判定与检索片段截取等场景；规则与调用方保持逐字一致，便于单测覆盖。

/// 规范化虚拟路径：去首尾空白、反斜杠转正斜杠、补前导 `/`、合并连续斜杠
///
/// 注意：本函数**不做** `..` 解析，路径中的 `..` 会原样保留（与历史行为一致）。
String normalizeWorkspacePath(String path) {
  var p = path.trim().replaceAll(r'\', '/');
  if (!p.startsWith('/')) {
    p = '/$p';
  }
  // 移除多余的连续斜杠
  p = p.replaceAll(RegExp(r'/+'), '/');
  return p;
}

/// 统一日期格式化（YYYY-MM-DD），供时间线/日记路径拼接使用
String formatWorkspaceDate(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// 评分端点里的日期归一化为 `YYYY-MM-DD`
String workspaceStatsDateKey(DateTime date) => date.toIso8601String().split('T').first;

/// 每日日记的固定虚拟路径（月份/日期补零，年份按原值输出）
String journalWorkspacePath(DateTime date) {
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '/journal/${date.year}-$m-$d.md';
}

/// 按天归档的日期序列目录根：read_files 可配合日期区间自动展开为逐日文件
const List<String> kWorkspaceDateSeriesRoots = ['/timeline', '/journal', '/health', '/stats/scores'];

/// 去掉路径结尾斜杠，便于识别目录根（保留根路径 `/`）
String normalizeWorkspaceDirPath(String path) {
  final normalized = normalizeWorkspacePath(path);
  if (normalized == '/') return normalized;
  return normalized.replaceAll(RegExp(r'/+$'), '');
}

/// 是否为支持日期区间展开的按天归档目录根（兼容结尾斜杠）
bool isWorkspaceDateSeriesRoot(String path) => kWorkspaceDateSeriesRoots.contains(normalizeWorkspaceDirPath(path));

/// 严格解析 `YYYY-MM-DD`：拒绝带时间、非补零月份/日期或非法日历日，失败返回 null
DateTime? tryParseWorkspaceDate(String raw) {
  final text = raw.trim();
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) return null;
  final parsed = DateTime.tryParse(text);
  if (parsed == null) return null;
  final normalized = DateTime(parsed.year, parsed.month, parsed.day);
  // DateTime 会把 2026-02-30 顺延到 3 月，用格式化结果回比拦截越界日期
  return formatWorkspaceDate(normalized) == text ? normalized : null;
}

/// 生成日期序列目录在指定区间内的逐日虚拟路径（含首尾，按日期升序）
///
/// 未知目录返回空列表；区间长度与展开数量由调用方负责限制。
List<String> expandWorkspaceDateSeriesPaths(String root, DateTime start, DateTime end) {
  final normalized = normalizeWorkspaceDirPath(root);
  final startDay = DateTime(start.year, start.month, start.day);
  final endDay = DateTime(end.year, end.month, end.day);
  if (endDay.isBefore(startDay)) return const [];

  final paths = <String>[];
  // 逐日构造而非累加 Duration，避免夏令时切换导致日期漂移/重复
  for (var offset = 0; ; offset++) {
    final day = DateTime(startDay.year, startDay.month, startDay.day + offset);
    if (day.isAfter(endDay)) break;
    final date = formatWorkspaceDate(day);
    final path = switch (normalized) {
      '/timeline' => '/timeline/$date.md',
      '/journal' => '/journal/$date.md',
      '/health' => '/health/$date.json',
      '/stats/scores' => '/stats/scores/$date.json',
      _ => null,
    };
    if (path == null) return const [];
    paths.add(path);
  }
  return paths;
}

/// 解析评分端点里的日期参数，非法时抛出带字段名的异常
DateTime parseWorkspaceStatsDate(dynamic raw, String label) {
  final text = (raw ?? '').toString().trim();
  if (text.isEmpty) {
    throw Exception('缺少 $label（格式 YYYY-MM-DD）');
  }
  try {
    final parsed = DateTime.parse(text);
    return DateTime(parsed.year, parsed.month, parsed.day);
  } catch (_) {
    throw Exception('$label 日期格式无效: $text（应为 YYYY-MM-DD）');
  }
}

/// 剥离 [readFile] 添加的「行号 + 制表符」前缀，还原文件真实文本
///
/// 与读取端共用同一条锚定规则（仅匹配行首数字+制表符），避免误伤正文里
/// 本身含制表符的内容。
String stripWorkspaceLineNumbers(String text) {
  return text.split('\n').map((l) => l.replaceFirst(RegExp(r'^\d+\t'), '')).join('\n');
}

/// 空态占位文案特征串：由读取端在「无数据/未编写」时生成，并非用户真实内容，
/// 追加写入时必须整段丢弃，否则占位提示会被固化成正文
const List<String> kWorkspacePlaceholderMarkers = ['暂无流水事件打卡', '尚未开始编写这天的深度反思日记', '暂无记忆条目', '当天暂无生活评分记录', '暂无常用提示词'];

/// 判断读取结果是否为空态占位文案（无真实内容的端点）
bool isWorkspacePlaceholderText(String content) => kWorkspacePlaceholderMarkers.any(content.contains);

final RegExp _uuidPathSegmentPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// 路径末段是否为实体 id（UUID 形态）：用于识别 canonical 路径
/// （`/todos/<分类>/<id>.md`、`/notes/<id>.md`）并做 id 路径命中与脏数据防护
bool isUuidPathSegment(String segment) => _uuidPathSegmentPattern.hasMatch(segment);

/// 移除文件名/路径片段里的 `.md` 文本（沿用既有 `replaceAll` 语义，非仅去后缀）
String removeMarkdownExtension(String value) => value.replaceAll('.md', '');

/// 去掉待办标题的勾选前缀（`[ ] ` / `[x] `）
String stripTodoTitlePrefix(String title) => title.replaceAll(RegExp(r'^\[[ x]\]\s*'), '').trim();

/// 从 `/todos/<分类>/<标题>.md` 路径解析标题（分类段之后的全部内容）
///
/// 只做路径文本解析，不访问待办实体；兼容单段路径（`/todos/<标题>.md`）。
String todoTitleFromPath(String path) {
  final segments = path.substring('/todos/'.length).split('/');
  final titleWithExt = segments.length >= 2 ? segments.sublist(1).join('/') : segments[0];
  return stripTodoTitlePrefix(removeMarkdownExtension(titleWithExt));
}

/// 从 `/notes/<笔记本>/<标题>.md` 路径解析末段标题（不做前缀清洗）
String noteTitleFromPath(String path) {
  final segments = path.substring('/notes/'.length).split('/');
  return removeMarkdownExtension(segments.last).trim();
}

/// 取分类/笔记本目录名：去掉前缀后的全部路径文本，再移除斜杠与空白
String workspaceFolderNameFromPath(String path, String prefix) =>
    path.substring(prefix.length).replaceAll('/', '').trim();

/// 取路径末段的实体标识（标题或 id），去掉 .md 后缀与待办勾选前缀
String workspaceEntityKeyFromPath(String path, String prefix) {
  final rest = path.substring(prefix.length);
  return stripTodoTitlePrefix(removeMarkdownExtension(rest.split('/').last));
}

/// 取「字段名: 值」中第一个冒号之后的全部内容（值本身可含冒号，不能用 split 取固定下标）
String workspaceFieldValue(String line) {
  final idx = line.indexOf(':');
  if (idx == -1 || idx == line.length - 1) return '';
  return line.substring(idx + 1).trim();
}

/// 从 Markdown 正文提取图片链接路径（`![...](路径)`），保持出现顺序并去重
///
/// 仅匹配独立成行的图片语法；data URI（Web 端内嵌图）体积过大且无需同步，跳过不入索引。
List<String> extractWorkspaceMarkdownImages(String content) {
  final pattern = RegExp(r'^!\[.*?\]\((.*?)\)\s*$', multiLine: true);
  final paths = <String>[];
  for (final match in pattern.allMatches(content)) {
    final path = match.group(1)?.trim() ?? '';
    if (path.isEmpty || path.startsWith('data:')) continue;
    if (!paths.contains(path)) paths.add(path);
  }
  return paths;
}

/// 供工具返回结果展示的截止时间文本（应用内提醒实际依赖 reminder_time）
String? formatWorkspaceDueTime(DateTime? due) {
  if (due == null) return null;
  final y = due.year.toString().padLeft(4, '0');
  final m = due.month.toString().padLeft(2, '0');
  final d = due.day.toString().padLeft(2, '0');
  final hh = due.hour.toString().padLeft(2, '0');
  final mi = due.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $hh:$mi';
}

/// 将 Color 转为标准 #RRGGBB 十六进制字符串
String workspaceColorToHex(Color color) {
  final rgb = color.toARGB32() & 0x00FFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

/// 颜色解析（支持 hex #RRGGBB、#AARRGGBB 与常见颜色别名）
Color? parseWorkspaceColor(dynamic raw) {
  if (raw == null) return null;
  if (raw is int) return Color(raw);
  if (raw is String) {
    final s = raw.trim().toLowerCase();
    if (s == 'classic_blue' || s == 'blue' || s == '经典蓝') {
      return const Color(0xFF005BCB);
    }
    if (s == 'yellow_green' || s == '荧光黄绿') return const Color(0xFFC5E803);
    if (s == 'pink' || s == 'rose' || s == '玫瑰粉红') {
      return const Color(0xFFE91E8C);
    }
    if (s == 'green' || s == '春天亮绿') return const Color(0xFF00E676);
    if (s == 'red' || s == '红色' || s == '活力红' || s == '赤焰红') return const Color(0xFFF80004);
    if (s == 'orange' || s == '橙色' || s == '活力橙') {
      return const Color(0xFFFF9500);
    }
    if (s == 'cyan' || s == '青色' || s == '湖水青') return const Color(0xFF00BCD4);
    if (s == 'purple' || s == '紫色' || s == '典雅紫') {
      return const Color(0xFF7C4DFF);
    }
    var hex = s.replaceAll('#', '').replaceAll('0x', '');
    if (hex.length == 6) hex = 'ff$hex';
    if (hex.length == 8) {
      final val = int.tryParse(hex, radix: 16);
      if (val != null) return Color(val);
    }
  }
  return null;
}

/// 解析 ThemeMode（支持 system, light, dark 及其中文别名）
ThemeMode parseWorkspaceThemeMode(dynamic raw) {
  if (raw == null) return ThemeMode.system;
  final s = raw.toString().trim().toLowerCase();
  if (s == 'dark' || s == '深色' || s == '暗色' || s == '夜间' || s == '黑') {
    return ThemeMode.dark;
  }
  if (s == 'light' || s == '浅色' || s == '明亮' || s == '日间' || s == '白') {
    return ThemeMode.light;
  }
  return ThemeMode.system;
}

/// 将 ThemeMode 转为字符串
String workspaceThemeModeToString(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.dark:
      return 'dark';
    case ThemeMode.light:
      return 'light';
    case ThemeMode.system:
      return 'system';
  }
}

/// 解析背景预设（支持 system/light/dark/oled/accent/custom/paper/mist/pine 及其中文别名）
AppBackgroundPreset parseWorkspaceBackgroundPreset(dynamic raw) {
  if (raw == null) return AppBackgroundPreset.system;
  final s = raw.toString().trim().toLowerCase();
  if (s == 'light' || s == '浅色' || s == '明亮' || s == '日间' || s == '白') {
    return AppBackgroundPreset.light;
  }
  if (s == 'dark' || s == '深色' || s == '暗色' || s == '夜间' || s == '黑') {
    return AppBackgroundPreset.dark;
  }
  if (s == 'oled' || s == 'oled黑' || s == 'oled纯黑' || s == '纯黑' || s == '极黑') {
    return AppBackgroundPreset.oled;
  }
  if (s == 'accent' || s == '主题色' || s == '强调色') {
    return AppBackgroundPreset.accent;
  }
  if (s == 'custom' || s == '自定义' || s == '自定义颜色' || s == '自定义背景色') {
    return AppBackgroundPreset.custom;
  }
  if (s == 'paper' || s == '暖纸' || s == '纸色' || s == '米色') {
    return AppBackgroundPreset.paper;
  }
  if (s == 'mist' || s == '雾蓝' || s == '雾霾蓝') {
    return AppBackgroundPreset.mist;
  }
  if (s == 'pine' || s == '松林' || s == '松林绿' || s == '森林绿') {
    return AppBackgroundPreset.pine;
  }
  return AppBackgroundPreset.system;
}

/// 将背景预设转为字符串
String workspaceBackgroundPresetToString(AppBackgroundPreset preset) => preset.name;

/// 单条 grep 命中文本（match）的最大长度，控制回传给模型的体积
const int kWorkspaceGrepMatchMaxLength = 200;

/// 构造检索正则：非法正则自动降级为按字面量匹配，避免模型传入的表达式直接抛错
RegExp buildWorkspaceGrepRegExp(String query) {
  try {
    return RegExp(query, caseSensitive: false);
  } catch (_) {
    return RegExp(RegExp.escape(query), caseSensitive: false);
  }
}

/// 为整篇内容类命中生成上下文摘要（命中点前后各取一段）
String buildWorkspaceGrepSnippet(String content, RegExp reg) {
  final text = content.trim();
  if (text.isEmpty) return '';
  final match = reg.firstMatch(text);
  if (match == null) {
    return text.length > kWorkspaceGrepMatchMaxLength ? '${text.substring(0, kWorkspaceGrepMatchMaxLength)}…' : text;
  }
  final start = (match.start - 30).clamp(0, text.length);
  final end = (match.end + 50).clamp(0, text.length);
  var snippet = text.substring(start, end).replaceAll('\n', ' ').trim();
  if (start > 0) snippet = '…$snippet';
  if (end < text.length) snippet = '$snippet…';
  return snippet.length > kWorkspaceGrepMatchMaxLength
      ? '${snippet.substring(0, kWorkspaceGrepMatchMaxLength)}…'
      : snippet;
}

/// Frontmatter 解析结果：`meta` 为头部键值，`body` 为去掉头部后的正文
class WorkspaceParsedContent {
  final Map<String, dynamic> meta;
  final String body;

  WorkspaceParsedContent({required this.meta, required this.body});
}

/// 解析 Markdown Frontmatter（`---` 包裹的键值头部）
WorkspaceParsedContent parseWorkspaceFrontmatter(String content) {
  if (!content.startsWith('---')) {
    return WorkspaceParsedContent(meta: {}, body: content);
  }
  final secondDash = content.indexOf('---', 3);
  if (secondDash == -1) {
    return WorkspaceParsedContent(meta: {}, body: content);
  }

  final header = content.substring(3, secondDash).trim();
  final body = content.substring(secondDash + 3).trim();

  final meta = <String, dynamic>{};
  for (final line in header.split('\n')) {
    final colon = line.indexOf(':');
    if (colon != -1) {
      final key = line.substring(0, colon).trim();
      var val = line.substring(colon + 1).trim();
      if (val.startsWith('"') && val.endsWith('"') && val.length >= 2) {
        val = val.substring(1, val.length - 1);
      }
      if (val == 'true') {
        meta[key] = true;
      } else if (val == 'false') {
        meta[key] = false;
      } else {
        meta[key] = val;
      }
    }
  }
  return WorkspaceParsedContent(meta: meta, body: body);
}
