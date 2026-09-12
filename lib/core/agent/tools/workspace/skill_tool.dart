import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';

/// 技能查阅与加载工具
///
/// 手册采用「按需加载」：不填 name 先看清单，填 name 载入手册，
/// 再配合 section 只取需要的那一章，避免把整篇长手册灌进上下文。
class SkillTool extends AgentTool {
  final SkillRegistry _registry = SkillRegistry.instance;

  @override
  String get name => 'skill';

  @override
  ToolExecutionMode get executionMode => ToolExecutionMode.parallel;

  @override
  String get description =>
      '查看或激活指定的专业技能手册。遇到需要「按规范办事」的复杂任务时先看手册，'
      '例如 GTD 清单整理、长文/卡片排版、日记复盘、数据洞察解读、分类目录维护、系统与 AI 配置、'
      '网页/海报/邀请函/可视化页面设计（frontend-design）。'
      '不填 name 列出全部技能；只关心手册里某一章时传 section（序号或标题关键词），可只取该章、省下上下文。'
      '简单任务（记一条待办、写一条流水）不必查阅手册，直接照 /AGENTS.md 规范执行。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': '技能名称或路径（如 "todo-manager"、"stats-analyst"、'
                '"/skills/todo-manager.md"）；不填则列出所有可用技能。',
          },
          'section': {
            'type': 'string',
            'description': '可选，只加载手册中的某一章：传序号（如 "4"）或标题关键词'
                '（如 "批量操作"）。不填返回整篇手册。',
          },
        },
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final name = arguments['name'] as String?;
    if (name == null || name.trim().isEmpty) {
      final skills = _registry.listSkills();
      final buffer = StringBuffer();
      buffer.writeln('# 可用技能手册清单\n');
      for (final s in skills) {
        buffer.writeln('- **${s['name']}** (`${s['path']}`): ${s['description']}');
      }
      return ToolResult.success(
        buffer.toString().trimRight(),
        uiDetails: {'skills': skills},
      );
    }

    final content = _registry.getSkillContent(name);
    if (content == null) {
      return ToolResult.error(
        '未找到技能 "$name"。可用技能请调用 skill() 查看列表。',
      );
    }

    final section = arguments['section'] as String?;
    if (section == null || section.trim().isEmpty) {
      return ToolResult.success(
        content,
        uiDetails: {'name': name, 'loaded': true},
      );
    }

    final extracted = extractSection(content, section);
    if (extracted == null) {
      // 章节没命中时不整篇回灌：只回章节菜单，让模型换一个序号重试
      final titles = listSectionTitles(content);
      return ToolResult.success(
        '技能「$name」中没有匹配「$section」的章节。\n'
        '可用章节：${titles.isEmpty ? "（无二级章节）" : titles.join(" / ")}\n'
        '可换序号或标题关键词重试；也可以不传 section 获取整篇手册。',
        uiDetails: {'name': name, 'loaded': false, 'sections': titles},
      );
    }

    return ToolResult.success(
      '# 技能手册《$name》· $section\n\n$extracted',
      uiDetails: {'name': name, 'loaded': true, 'section': section},
    );
  }

  /// 提取手册中的某一章（`## ` 级标题，含其下 `###` 子节）
  ///
  /// 支持用序号（"4"）、完整标题（"4. 批量操作"）或标题关键词（"批量操作"）模糊匹配；
  /// 未命中返回 null。抽成静态纯函数便于单测。
  static String? extractSection(String doc, String section) {
    final query = section.trim();
    if (query.isEmpty) return null;

    final lines = doc.split('\n');
    final headingIndexes = <int>[];
    for (var i = 0; i < lines.length; i++) {
      if (RegExp(r'^##\s+\S').hasMatch(lines[i])) headingIndexes.add(i);
    }
    if (headingIndexes.isEmpty) return null;

    int start = -1;
    for (final idx in headingIndexes) {
      if (_headingMatches(lines[idx], query)) {
        start = idx;
        break;
      }
    }
    if (start < 0) return null;

    // 章节范围：本章标题起，到下一个 ## 标题前（含中间的 ### 子节）
    final next = headingIndexes.firstWhere(
      (i) => i > start,
      orElse: () => lines.length,
    );
    return lines.sublist(start, next).join('\n').trimRight();
  }

  /// 列出手册的全部二级章节标题（未命中章节时回给模型做重试依据）
  static List<String> listSectionTitles(String doc) {
    return doc
        .split('\n')
        .where((l) => RegExp(r'^##\s+\S').hasMatch(l))
        .map((l) => l.replaceFirst(RegExp(r'^##\s+'), '').trim())
        .toList();
  }

  /// 章节标题匹配：纯数字按序号匹配，其余按「去序号去空格」后的包含关系匹配
  static bool _headingMatches(String headingLine, String query) {
    final heading = headingLine.replaceFirst(RegExp(r'^##\s+'), '').trim();
    if (heading.isEmpty) return false;

    if (RegExp(r'^\d+$').hasMatch(query)) {
      final number = RegExp(r'^(\d+)').firstMatch(heading)?.group(1);
      return number == query;
    }

    final normalizedHeading = _normalizeHeading(heading);
    final normalizedQuery = _normalizeHeading(query);
    if (normalizedQuery.isEmpty) return false;
    return normalizedHeading == normalizedQuery ||
        normalizedHeading.contains(normalizedQuery);
  }

  /// 归一化标题文本：去掉标记符号、序号与空白，便于宽松比较
  static String _normalizeHeading(String text) {
    return text
        .replaceFirst(RegExp(r'^#+\s*'), '')
        .replaceFirst(RegExp(r'^\d+[.、)]?\s*'), '')
        .replaceAll(RegExp(r'\s+'), '')
        .toLowerCase();
  }
}
