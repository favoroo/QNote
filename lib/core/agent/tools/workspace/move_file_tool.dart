import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';

/// 移动/改名工具：待办改分类、笔记换笔记本或重命名
///
/// 取代「read_file → write_file → delete_file」三步法：三步法既消耗三轮工具调用，
/// 又在中途失败时留下重复条目（新文件已建、旧文件还在）。
class MoveFileTool extends AgentTool {
  final VirtualWorkspaceService _vfs = VirtualWorkspaceService.instance;

  @override
  String get name => 'move_file';

  @override
  String get description =>
      '把待办或笔记移动到新路径，一步完成「换分类/换笔记本」与「改名」：'
      '待办改分类（/todos/今日/X.md → /todos/工作/X.md）、笔记换笔记本或重命名同理。'
      '目标路径的目录段决定新归属：写成 /notes/<标题>.md（无笔记本段）表示移出笔记本到根目录。'
      '这是唯一正确的移动方式——不要再「新建一个再删掉旧的」，那样中途失败会留下重复条目。'
      '每日日记按日期归档、不支持移动；时间线与配置类文件也不支持。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'from': {
            'type': 'string',
            'description': '源路径（如 "/todos/今日/拿快递.md"、"/notes/临时/会议纪要.md"）',
          },
          'to': {
            'type': 'string',
            'description': '目标路径（如 "/todos/工作/拿快递.md"、"/notes/会议/周会纪要.md"）；'
                '待办只能移到待办、笔记只能移到笔记',
          },
        },
        'required': ['from', 'to'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final from = (arguments['from'] as String? ?? '').trim();
    final to = (arguments['to'] as String? ?? '').trim();
    if (from.isEmpty || to.isEmpty) {
      return ToolResult.error('from 与 to 路径都不能为空');
    }

    onProgress?.call('正在移动：$from → $to');
    try {
      final res = await _vfs.moveFile(from, to);
      return ToolResult.success(
        '已移动 [$from] → [${res['path'] ?? to}]'
        '${res['title'] == null ? '' : '（新标题：${res['title']}）'}',
        uiDetails: res,
      );
    } catch (e) {
      return ToolResult.error('移动失败: $e');
    }
  }
}
