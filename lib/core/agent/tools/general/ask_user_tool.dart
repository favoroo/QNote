import 'package:qnote_flutter/core/agent/models/agent_tool.dart';

/// 向用户提问或请求确认的工具
class AskUserTool extends AgentTool {
  @override
  String get name => 'ask_user';

  @override
  String get description =>
      '当用户指令不明确、缺少关键信息、或者即将执行不可逆操作（如批量删除）时，调用此工具向用户提出明确的问题或列出可选项。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'question': {
            'type': 'string',
            'description': '向用户提出的问题或确认提示内容',
          },
          'options': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': '可选的建议快捷选项列表，方便用户快速点击选择',
          },
        },
        'required': ['question'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final question = arguments['question'] as String? ?? '';
    final options = (arguments['options'] as List?)?.map((e) => e.toString()).toList();

    return ToolResult.success(
      '已向用户呈现提问/确认：$question',
      uiDetails: {
        'type': 'ask_user',
        'question': question,
        'options': options,
      },
    );
  }
}
