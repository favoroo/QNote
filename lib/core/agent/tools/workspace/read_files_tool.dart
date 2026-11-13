import 'dart:math' as math;

import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_path_utils.dart';

/// 批量读取工具：一次调用读取多个文件，支持按天归档目录展开日期区间
///
/// 与 [ReadFileTool] 共用 VFS 读取链路，区别在于「一次多条」：查看最近一周的
/// 时间线/日记/健康/评分时，逐天调用 read_file 会产生 7 次工具调用与 7 张结果卡；
/// 批量入口把路径列表与日期区间收敛到一次调用，并由工具层统一控制输出预算。
class ReadFilesTool extends AgentTool {
  final VirtualWorkspaceService _vfs = VirtualWorkspaceService.instance;

  /// 单次显式路径上限，防止一次调用灌爆上下文与执行时长
  static const int maxBatchSize = 20;

  /// 日期区间展开后的文件总数上限（4 个目录 × 一周约 28 个）
  static const int maxExpandedTargets = 60;

  /// 日期区间最长天数，更长区间请用 /stats/score_index.json 或拆批
  static const int maxRangeDays = 31;

  /// 返回给模型的总字符预算与单文件预算
  static const int defaultMaxChars = 16000;
  static const int hardMaxChars = 40000;
  static const int defaultMaxCharsPerFile = 6000;
  static const int hardMaxCharsPerFile = 12000;

  /// 单文件截断提示，需计入预算，避免提示本身把总预算顶穿
  static const String _truncatedNote = '\n...（本文件超出预算已截断；可用 read_file 的 offset 续读）';

  @override
  String get name => 'read_files';

  @override
  ToolExecutionMode get executionMode => ToolExecutionMode.parallel;

  @override
  String get description =>
      '一次调用读取多个文件的批量版本。paths 可传任意虚拟文件路径；也可传按天归档的目录 '
      '"/timeline"、"/journal"、"/health"、"/stats/scores"，配合 start_date/end_date（YYYY-MM-DD，含首尾）'
      '自动展开为区间内逐日文件。看「最近一周/某段日期」的流水、日记、健康、评分时优先用它，'
      '不要逐天调用 read_file。无数据的日期会自动跳过并在结果里列出。'
      '单次最多 $maxBatchSize 个显式路径、区间展开最多 $maxExpandedTargets 个文件；'
      '总输出默认 $defaultMaxChars 字符，超出预算的后续文件会提示改用 read_file 续读。';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'paths': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': '虚拟路径列表（1~$maxBatchSize 个）。可直接写具体文件，也可写日期序列目录根',
      },
      'start_date': {'type': 'string', 'description': '日期区间起点 YYYY-MM-DD；仅对日期序列目录生效。提供后 end_date 默认今天'},
      'end_date': {'type': 'string', 'description': '日期区间终点 YYYY-MM-DD（含当天）；仅对日期序列目录生效'},
      'max_chars': {'type': 'integer', 'description': '本次返回的总字符预算，默认 $defaultMaxChars，最大 $hardMaxChars'},
      'max_chars_per_file': {
        'type': 'integer',
        'description': '单个文件的字符上限，默认 $defaultMaxCharsPerFile，最大 $hardMaxCharsPerFile',
      },
    },
    'required': ['paths'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments, {void Function(String progress)? onProgress}) async {
    final rawPaths = arguments['paths'];
    // 兼容模型误把单个路径当字符串传入，避免一次可用调用直接失败
    final pathList = rawPaths is String ? <String>[rawPaths] : rawPaths;
    if (pathList is! List || pathList.isEmpty) {
      return ToolResult.error('paths 不能为空，请提供要读取的文件路径列表');
    }
    if (pathList.length > maxBatchSize) {
      return ToolResult.error('单次批量读取最多 $maxBatchSize 个路径，当前 ${pathList.length} 个，请拆分调用');
    }

    final requestedPaths = <String>[];
    for (final raw in pathList) {
      final path = (raw as String? ?? '').trim();
      if (path.isNotEmpty) requestedPaths.add(_vfs.normalizePath(path));
    }
    if (requestedPaths.isEmpty) return ToolResult.error('paths 中没有有效路径');

    // 目录根不是文件：提前拦截，避免 VFS 返回「文件不存在」这类误导性错误
    const nonReadableDirRoots = {
      '/skills',
      '/memory',
      '/todos',
      '/notes',
      '/folders',
      '/stats',
      '/chats',
      '/settings',
      '/quick_prompts',
    };
    for (final path in requestedPaths) {
      if (nonReadableDirRoots.contains(normalizeWorkspaceDirPath(path))) {
        return ToolResult.error('$path 是目录，不能直接读取；请传具体文件路径，或先用 list_dir 查看条目');
      }
    }

    // 先解析并校验日期区间；参数错误在读取前直接拒绝，避免产生半截结果
    final startRaw = (arguments['start_date'] as String? ?? '').trim();
    final endRaw = (arguments['end_date'] as String? ?? '').trim();
    final dateSeriesPaths = requestedPaths.where(isWorkspaceDateSeriesRoot).toList();
    DateTime? startDate;
    DateTime? endDate;
    if (startRaw.isNotEmpty || endRaw.isNotEmpty) {
      if (startRaw.isEmpty) {
        return ToolResult.error('提供了 end_date 但缺少 start_date（格式 YYYY-MM-DD）');
      }
      startDate = tryParseWorkspaceDate(startRaw);
      if (startDate == null) {
        return ToolResult.error('start_date 日期格式无效: $startRaw（应为 YYYY-MM-DD）');
      }
      final today = _today();
      endDate = endRaw.isEmpty ? today : tryParseWorkspaceDate(endRaw);
      if (endDate == null) {
        return ToolResult.error('end_date 日期格式无效: $endRaw（应为 YYYY-MM-DD）');
      }
      if (endRaw.isEmpty && startDate.isAfter(today)) {
        return ToolResult.error('start_date 不能晚于今天（未提供 end_date 时默认统计到今天）');
      }
      if (endDate.isBefore(startDate)) return ToolResult.error('end_date 不能早于 start_date');
      final days = endDate.difference(startDate).inDays + 1;
      if (days > maxRangeDays) {
        return ToolResult.error('日期区间最长 $maxRangeDays 天，当前 $days 天，请缩短范围或分批读取');
      }
    }
    if (dateSeriesPaths.isNotEmpty && startDate == null) {
      return ToolResult.error('${dateSeriesPaths.join('、')} 是按天归档的目录，需要同时提供 start_date 与 end_date（YYYY-MM-DD）才能批量读取');
    }

    // 展开日期序列目录并去重，保留调用方给出的顺序；显式文件路径原样保留
    final targets = <String>[];
    final expandedTargets = <String>{};
    final seen = <String>{};
    void addTarget(String path, {bool fromExpansion = false}) {
      if (!seen.add(path)) return;
      targets.add(path);
      if (fromExpansion) expandedTargets.add(path);
    }

    for (final path in requestedPaths) {
      if (!isWorkspaceDateSeriesRoot(path)) {
        addTarget(path);
        continue;
      }
      for (final expanded in expandWorkspaceDateSeriesPaths(path, startDate!, endDate!)) {
        addTarget(expanded, fromExpansion: true);
      }
    }
    if (targets.length > maxExpandedTargets) {
      return ToolResult.error('展开后共 ${targets.length} 个文件，超过单次上限 $maxExpandedTargets，请缩短日期范围或拆分目录读取');
    }

    final maxChars = _clampBudget(
      arguments['max_chars'],
      fallback: defaultMaxChars,
      minChars: 2000,
      maxCharsLimit: hardMaxChars,
    );
    final maxCharsPerFile = _clampBudget(
      arguments['max_chars_per_file'],
      fallback: defaultMaxCharsPerFile,
      minChars: 1000,
      maxCharsLimit: hardMaxCharsPerFile,
    );

    final fileDetails = <Map<String, dynamic>>[];
    final body = StringBuffer();
    final skipped = <String>[];
    final failures = <String>[];
    final unread = <String>[];
    var used = 0;
    var readCount = 0;

    for (final path in targets) {
      final remaining = maxChars - used;
      // 预留头部与最小正文空间；空间不足时不再发起读取，避免读了也放不下
      if (remaining <= 240) {
        unread.add(path);
        fileDetails.add({'path': path, 'status': 'unread', 'reason': '总输出预算已用尽'});
        continue;
      }

      onProgress?.call('正在批量读取：$path');
      String content;
      try {
        content = await _vfs.readFile(path);
      } catch (e) {
        // 按天归档的文件在无数据时返回占位文案而非抛错，抛错说明是真实读取异常
        failures.add('$path（$e）');
        fileDetails.add({'path': path, 'status': 'failed', 'error': e.toString()});
        continue;
      }

      final trimmed = content.trimRight();
      if (expandedTargets.contains(path) && _isEmptyDateFile(path, trimmed)) {
        skipped.add(path);
        fileDetails.add({'path': path, 'status': 'skipped', 'reason': '无数据'});
        continue;
      }

      final header = '===== $path =====\n';
      // 预留头部与文件间空行，保证 used 不超过 maxChars
      final available = remaining - header.length - 2;
      // 除头部外还要给截断提示与最小正文留空间，否则会小幅顶穿总预算
      if (available <= 260) {
        unread.add(path);
        fileDetails.add({'path': path, 'status': 'unread', 'reason': '剩余预算不足以容纳头部'});
        continue;
      }

      final fileCap = math.min(maxCharsPerFile, available);
      final willTruncate = trimmed.length > fileCap;
      final note = willTruncate ? _truncatedNote : '';
      final contentCap = willTruncate ? math.max(200, fileCap - note.length) : fileCap;
      final shown = willTruncate ? _truncateAtLineBoundary(trimmed, contentCap) : trimmed;

      body.write(header);
      body.write(shown);
      body.write(note);
      body.write('\n\n');
      used += header.length + shown.length + note.length + 2;
      readCount++;
      fileDetails.add({'path': path, 'status': 'read', 'chars': shown.length, 'truncated': willTruncate});
    }

    final summary = StringBuffer();
    summary.write('批量读取完成：共 ${targets.length} 个文件，成功读取 $readCount 个');
    if (skipped.isNotEmpty) summary.write('，跳过 ${skipped.length} 个无数据日期');
    if (failures.isNotEmpty) summary.write('，失败 ${failures.length} 个');
    if (unread.isNotEmpty) summary.write('，因输出预算未读 ${unread.length} 个');
    summary.writeln('。');
    if (startDate != null && endDate != null) {
      summary.writeln('日期范围：${formatWorkspaceDate(startDate)} ~ ${formatWorkspaceDate(endDate)}');
    }
    if (skipped.isNotEmpty) summary.writeln('跳过：${skipped.join('、')}');
    if (failures.isNotEmpty) summary.writeln('失败：${failures.join('、')}');
    if (unread.isNotEmpty) {
      summary.writeln('未读：${unread.join('、')}（可拆分后再次调用 read_files，或调大 max_chars，也可用 read_file 单读并配 offset）');
    }
    if (readCount == 0 && failures.isEmpty) summary.writeln('区间内没有可读内容。');
    if (readCount > 0) {
      summary.writeln();
      summary.write(body.toString().trimRight());
    }

    final details = {
      'type': 'read_files',
      'requested': requestedPaths,
      'dateRange': startDate == null || endDate == null
          ? null
          : '${formatWorkspaceDate(startDate)}~${formatWorkspaceDate(endDate)}',
      'total': targets.length,
      'read': readCount,
      'skipped': skipped.length,
      'failed': failures.length,
      'unread': unread.length,
      'files': fileDetails,
    };

    // 全部路径都读取失败时按错误上报；仅跳过（无数据）视为正常空结果
    if (readCount == 0 && failures.isNotEmpty) {
      return ToolResult(modelOutput: summary.toString(), uiDetails: details, isError: true);
    }
    return ToolResult.success(summary.toString(), uiDetails: details);
  }

  /// 取当天零点，作为未传 end_date 时的默认终点
  static DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// 预算参数归一化：兼容 int / num / string，缺省取 fallback 并收敛到允许区间
  static int _clampBudget(dynamic raw, {required int fallback, required int minChars, required int maxCharsLimit}) {
    int? value;
    if (raw is int) {
      value = raw;
    } else if (raw is num) {
      value = raw.round();
    } else if (raw is String) {
      value = int.tryParse(raw);
    }
    if (value == null) return fallback;
    return value.clamp(minChars, maxCharsLimit);
  }

  /// 按行边界截断，避免把一行行号前缀切成半截导致后续 edit_file 难以对照
  static String _truncateAtLineBoundary(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    final cut = text.substring(0, maxLength);
    final lastNewline = cut.lastIndexOf('\n');
    // 找不到接近尾部的换行时直接硬截，避免只剩一两行
    return lastNewline > maxLength ~/ 2 ? cut.substring(0, lastNewline) : cut;
  }

  /// 判断区间展开出的某天文件是否没有真实内容
  ///
  /// 时间线/日记/评分读取空数据时返回占位文案，健康数据则返回 `has_data: false`
  /// 的 JSON；这些都不应占用批量读取的预算。
  static bool _isEmptyDateFile(String path, String content) {
    if (content.trim().isEmpty) return true;
    if (isWorkspacePlaceholderText(content)) return true;
    if (path.startsWith('/health/') && content.contains('"has_data": false')) return true;
    return false;
  }
}
