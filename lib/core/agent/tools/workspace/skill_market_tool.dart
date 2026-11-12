import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/skills/skill_market_service.dart';

/// skills.sh 技能市场工具：搜索第三方技能并安装为本地用户技能
///
/// 对齐 find-skills 的「发现 → 评估 → 安装」链路，但受 App 能力边界约束：
/// 不执行 `npx skills`、不下载脚本与附件；安装即把详情页里的 SKILL.md 正文
/// 转存为 `/skills/<name>.md`，供之后用 `skill(name)` 按需载入。
/// 因安装会写用户技能库，本工具声明为串行执行，避免与其他写操作并发。
class SkillMarketTool extends AgentTool {
  SkillMarketTool({SkillMarketService? service}) : _service = service ?? SkillMarketService.instance;

  final SkillMarketService _service;

  @override
  String get name => 'skill_market';

  @override
  ToolExecutionMode get executionMode => ToolExecutionMode.sequential;

  @override
  String get description =>
      '搜索并安装 skills.sh 开放技能市场的第三方技能。'
      '用户问「有没有做 X 的技能」、想扩展小Q能力、或本地 /skills/ 索引里没有合适手册时先用 search；'
      '搜索建议用英文关键词，返回技能名、来源仓库与安装量。'
      '向用户展示候选并确认后，用 install 传完整 id（如 "anthropics/skills/pdf"）安装；'
      '安装会把该技能的 SKILL.md 手册转存为用户技能 /skills/<name>.md，之后用 skill(name) 载入。'
      'App 内没有命令行，不执行 npx、不下载脚本与附件，只转存手册文本；'
      '网页版通过公共只读代理访问，代理限流或不可用时会返回明确提示。';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'search': {'type': 'string', 'description': '市场搜索关键词，建议英文（如 "pdf"、"poster"、"react performance"）。'},
      'install': {'type': 'string', 'description': '要安装的完整技能 id，取自 search 结果，如 "anthropics/skills/pdf"；也支持详情页 URL。'},
      'as': {'type': 'string', 'description': '可选，自定义本地技能名（默认使用市场技能名 slug 化）；名称冲突或太长时使用。'},
      'overwrite': {'type': 'boolean', 'description': '可选，同名用户技能已存在时是否覆盖，默认 false；覆盖前必须先向用户确认。'},
      'limit': {'type': 'integer', 'description': 'search 返回条数，默认 8，最大 20。'},
    },
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments, {void Function(String progress)? onProgress}) async {
    final search = (arguments['search'] as String? ?? '').trim();
    final install = (arguments['install'] as String? ?? '').trim();
    final alias = (arguments['as'] as String? ?? '').trim();
    final overwrite = arguments['overwrite'] == true;

    if (search.isNotEmpty && install.isNotEmpty) {
      return ToolResult.error('search 与 install 不能同时使用；请先搜索，确认候选后再单独安装。');
    }
    if (search.isEmpty && install.isEmpty) {
      return ToolResult.error('请传 search（搜索关键词）或 install（完整技能 id）。');
    }
    if (install.isEmpty && (alias.isNotEmpty || overwrite)) {
      return ToolResult.error('as / overwrite 只能与 install 一起使用。');
    }
    if (alias.isNotEmpty && !RegExp(r'^[^\s/\\]+$').hasMatch(alias)) {
      return ToolResult.error('as 指定的技能名不能包含空白或路径分隔符。');
    }

    if (search.isNotEmpty) {
      return _search(search, arguments['limit']);
    }
    return _install(install, alias, overwrite, onProgress);
  }

  Future<ToolResult> _search(String query, Object? rawLimit) async {
    final limit = rawLimit is int ? rawLimit : int.tryParse('${rawLimit ?? ''}') ?? 8;
    try {
      final results = await _service.search(query, limit: limit);
      final details = <String, dynamic>{
        'type': 'skill_market',
        'action': 'search',
        'query': query,
        'results': results
            .map((r) => {'id': r.id, 'name': r.name, 'source': r.source, 'installs': r.installs})
            .toList(),
      };
      if (results.isEmpty) {
        return ToolResult.success(
          'skills.sh 没有搜到与「$query」相关的技能。建议换英文关键词（如把"海报"换成 "poster"、把"周报"换成 "report"）后重试；'
          '仍找不到就如实告诉用户市场里没有，不要编造技能名。',
          uiDetails: details,
        );
      }

      final buffer = StringBuffer()
        ..writeln('在 skills.sh 搜索「$query」，找到 ${results.length} 个技能：')
        ..writeln();
      for (var i = 0; i < results.length; i++) {
        final item = results[i];
        buffer.writeln('${i + 1}. **${item.name}** — ${item.source}（安装量 ${item.installs}）');
        buffer.writeln('   id: `${item.id}`');
      }
      buffer
        ..writeln()
        ..writeln(
          '安装前先向用户展示候选（名称、来源、安装量）并让用户确认；确认后调用 skill_market(install: "<id>")。'
          '优先选择安装量高、来源可信的技能；安装量低或来源不明的技能要提示用户风险。',
        );
      return ToolResult.success(buffer.toString().trimRight(), uiDetails: details);
    } on SkillMarketException catch (e) {
      return ToolResult.error(e.message, uiDetails: {'type': 'skill_market', 'action': 'search', 'query': query});
    } catch (e) {
      return ToolResult.error('技能市场搜索失败：$e', uiDetails: {'type': 'skill_market', 'action': 'search', 'query': query});
    }
  }

  Future<ToolResult> _install(
    String id,
    String alias,
    bool overwrite,
    void Function(String progress)? onProgress,
  ) async {
    final parsed = SkillMarketService.parseMarketId(id);
    if (parsed == null) {
      return ToolResult.error('安装标识 "$id" 格式不正确，应为完整 id（如 "anthropics/skills/pdf"），可先用 search 查找。');
    }

    onProgress?.call('正在安装技能：${parsed.skillId}');
    try {
      final result = await _service.install(id: id, as: alias.isEmpty ? null : alias, overwrite: overwrite);
      final details = <String, dynamic>{
        'type': 'skill_market',
        'action': 'install',
        'name': result.name,
        'path': result.path,
        'source': result.source,
        'overwritten': result.overwritten,
      };
      final overwriteHint = result.overwritten ? '（已覆盖原同名技能）' : '';
      return ToolResult.success(
        '已安装技能「${result.name}」$overwriteHint\n'
        '路径：${result.path}\n'
        '来源：skills.sh · ${result.source}\n'
        '说明：${result.description}\n'
        '手册长度：${result.contentLength} 字符\n\n'
        '后续用 skill(name: "${result.name}") 载入手册再执行。'
        '原技能依赖的脚本、附件与命令行步骤无法在 App 内执行，需要改写为 QNote 工具或如实告知用户。',
        uiDetails: details,
      );
    } on SkillMarketException catch (e) {
      return ToolResult.error(e.message, uiDetails: {'type': 'skill_market', 'action': 'install', 'name': alias});
    } catch (e) {
      return ToolResult.error('技能安装失败：$e', uiDetails: {'type': 'skill_market', 'action': 'install', 'name': alias});
    }
  }
}
