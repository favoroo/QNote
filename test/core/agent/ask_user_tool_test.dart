import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/tools/general/ask_user_tool.dart';
import 'package:qnote_flutter/core/agent/services/agent_interaction_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AskUserTool 与 AgentInteractionService 测试', () {
    test('AskUserTool 参数 Schema 验证', () {
      final tool = AskUserTool();
      expect(tool.name, 'ask_user');
      expect(tool.parametersSchema['type'], 'object');
      expect(tool.parametersSchema['required'], contains('question'));
      final props = tool.parametersSchema['properties'] as Map<String, dynamic>;
      expect(props.containsKey('question'), true);
      expect(props.containsKey('options'), true);
    });

    test('AgentInteractionService 无 context 时优雅回退为 null', () async {
      final answer = await AgentInteractionService.instance.askUser(
        question: '测试确认？',
        options: ['确认', '取消'],
        timeout: const Duration(milliseconds: 200),
      );
      // 在没有 Flutter Navigator 挂载的纯单元测试环境中，应当安全返回 null（取消）而不崩溃
      expect(answer, isNull);
    });

    test('AskUserTool 注入模拟用户确认选择', () async {
      final tool = AskUserTool(
        onAskUser: ({required question, options}) async {
          return '确认删除';
        },
      );

      final result = await tool.execute({
        'question': '确认删除 2026-09-11 的日记吗？',
        'options': ['确认删除', '取消'],
      });

      expect(result.isError, false);
      expect(result.uiDetails?['status'], 'confirmed');
      expect(result.uiDetails?['choice'], '确认删除');
      expect(result.modelOutput.contains('用户已确认并回复：\"确认删除\"'), true);
    });

    test('AskUserTool 注入模拟用户选择取消', () async {
      final tool = AskUserTool(
        onAskUser: ({required question, options}) async {
          return '取消';
        },
      );

      final result = await tool.execute({
        'question': '确认删除 2026-09-11 的日记吗？',
        'options': ['确认删除', '取消'],
      });

      expect(result.isError, false);
      expect(result.uiDetails?['status'], 'cancelled');
      expect(result.modelOutput.contains('用户明确选择了【取消】'), true);
    });

    test('AskUserTool 注入模拟用户关闭弹窗(返回 null)', () async {
      final tool = AskUserTool(
        onAskUser: ({required question, options}) async {
          return null;
        },
      );

      final result = await tool.execute({
        'question': '确认删除 2026-09-11 的日记吗？',
        'options': ['确认删除', '取消'],
      });

      expect(result.isError, false);
      expect(result.uiDetails?['status'], 'cancelled');
      expect(result.modelOutput.contains('用户取消了该操作'), true);
    });
  });
}
