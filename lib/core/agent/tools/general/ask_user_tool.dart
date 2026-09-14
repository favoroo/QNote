import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/services/agent_interaction_service.dart';

/// 向用户提问或请求确认的工具
class AskUserTool extends AgentTool {
  final Future<String?> Function({
    required String question,
    List<String>? options,
  })? onAskUser;

  AskUserTool({this.onAskUser});

  @override
  String get name => 'ask_user';

  @override
  String get description =>
      '当用户指令有歧义、缺少关键参数、或者即将执行删除/清空等敏感或不可逆操作时，必须调用此工具向用户提出明确的问题并列出选项供用户选择。系统会挂起并弹出交互弹窗等待用户做出选择后，再继续执行后续操作。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'question': {
            'type': 'string',
            'description': '向用户提出的问题或操作确认提示内容',
          },
          'options': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': '建议的快捷选项列表供用户点击选择，例如 ["确认删除", "取消"]',
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

    onProgress?.call('正在等待用户选择/确认...');

    // 挂起等待用户在 UI 弹窗中完成交互
    final userChoice = onAskUser != null
        ? await onAskUser!(question: question, options: options)
        : await AgentInteractionService.instance.askUser(
            question: question,
            options: options,
          );

    if (userChoice == null) {
      return ToolResult.success(
        '用户取消了该操作（或关闭了确认弹窗）。请停止继续执行此操作，并向用户简要反馈已取消。',
        uiDetails: {
          'type': 'ask_user',
          'question': question,
          'options': options,
          'status': 'cancelled',
        },
      );
    }

    final lower = userChoice.toLowerCase();
    final isCancel = lower == '取消' || lower == 'cancel';

    if (isCancel) {
      return ToolResult.success(
        '用户明确选择了【取消】。请不要执行该操作，并向用户回复确认已取消。',
        uiDetails: {
          'type': 'ask_user',
          'question': question,
          'options': options,
          'status': 'cancelled',
          'choice': userChoice,
        },
      );
    }

    return ToolResult.success(
      '用户已确认并回复："$userChoice"。请根据用户的决定继续执行后续动作。',
      uiDetails: {
        'type': 'ask_user',
        'question': question,
        'options': options,
        'status': 'confirmed',
        'choice': userChoice,
      },
    );
  }
}

