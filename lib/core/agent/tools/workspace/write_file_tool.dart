import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';

/// 写入或新建虚拟文件工具
class WriteFileTool extends AgentTool {
  final VirtualWorkspaceService _vfs = VirtualWorkspaceService.instance;

  @override
  String get name => 'write_file';

  @override
  String get description =>
      '在虚拟工作区指定路径创建新文件或覆写已有文件。支持全量业务数据写入：\n'
      '1. 待办（如 "/todos/工作/写周报.md"）：Frontmatter 支持 status, priority, repeat_rule (daily/workday/weekly等循环习惯), tags, reminder_time (通知唯一来源)；\n'
      '2. 时间流水（如 "/timeline/2026-09-11.md"）：必须用「## [HH:MM] 标题」或「## [HH:MM - HH:MM] 标题」时间块格式，块内支持「- 分类:」「- 心情:」「- 详情:」及自定义结构化指标（如「- 饮水: 500ml」「- 消费金额: 35」），禁用 YAML Frontmatter；\n'
      '3. 分类管理（如 "/folders/todos.json"、"/folders/notes.json"）：支持新建分类、重命名分类或调整排序；\n'
      '4. 系统与健康偏好（如 "/settings/appearance.json" 切换主题模式与主色调、"/settings/weight.json" 记体重、"/settings/color_marks.json" 日历高光打点、"/settings/ai.json" 调模型温度、"/chats/sessions.json" 会话命名）。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '虚拟文件绝对路径（必须以 "/" 开头，如 "/todos/工作/需求评审.md"、"/timeline/2026-09-11.md"、"/settings/weight.json" 等）',
          },
          'content': {
            'type': 'string',
            'description':
                '写入的完整文件内容。待办支持 YAML Frontmatter (status, priority, repeat_rule, tags, reminder_time 等)；时间流水使用二级时间标题块；设置与分类为 JSON 格式',
          },
        },
        'required': ['path', 'content'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final path = arguments['path'] as String? ?? '';
    final content = arguments['content'] as String? ?? '';

    if (path.trim().isEmpty) {
      return ToolResult.error('文件路径不能为空');
    }

    try {
      final res = await _vfs.writeFile(path, content);
      final status = res['status'] ?? 'saved';
      final title = res['title'] ?? path;
      final buffer = StringBuffer('已成功保存文件 [$path] ($status)\n标题: $title');
      // 回显待办的定时字段，便于模型自检是否真正写入了提醒
      if (res['due_date'] != null) {
        buffer.write('\n截止时间: ${res['due_date']}');
      }
      if (res['reminder_time'] != null) {
        buffer.write('\n提醒时间: ${res['reminder_time']}');
      }
      return ToolResult.success(buffer.toString(), uiDetails: res);
    } catch (e) {
      return ToolResult.error('写入文件失败: $e');
    }
  }
}
