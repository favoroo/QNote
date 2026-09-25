import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/agent/agent_tool_registry.dart';
import 'package:qnote_flutter/core/agent/prompts/q_system_prompt.dart';

/// 提示词里的「模型能不能看图」分支
///
/// 锁的是安全事故：模型其实看不见画面时，提示词绝不能出现「你已能直接看到画面」这类
/// 授意它照着问题编造图片内容的措辞（实测 glm-5.2 收图返回 200 并瞎答颜色）。
void main() {
  String build({required bool supportsVisionInput, bool toolEnabled = true}) {
    final enabled = AgentToolRegistry.optionalToolNames.toSet();
    if (!toolEnabled) enabled.remove('describe_image');
    return QSystemPrompt.buildSystemPrompt(
      enabledOptionalTools: enabled,
      supportsVisionInput: supportsVisionInput,
    );
  }

  group('当前模型看不了图', () {
    test('附件条款明确告知看不到画面并指向 describe_image', () {
      final prompt = build(supportsVisionInput: false);

      expect(prompt, contains('当前对话模型不支持图片输入'));
      expect(prompt, contains('你看不到任何画面'));
      expect(prompt, contains('describe_image'));
    });

    test('不得残留「已能直接看到画面」的旧措辞', () {
      final prompt = build(supportsVisionInput: false);

      expect(prompt, isNot(contains('你已能直接看到画面')));
    });

    test('识图准则要求未调用工具前严禁描述图片', () {
      final prompt = build(supportsVisionInput: false);

      expect(prompt, contains('图片识别（describe_image）'));
      expect(prompt, contains('严禁'));
      expect(prompt, contains('文字'));
    });
  });

  group('当前模型能看图', () {
    test('附件条款保持「已注入上下文、直接作答」，不诱导多余工具调用', () {
      final prompt = build(supportsVisionInput: true);

      expect(prompt, contains('你已能直接看到画面'));
      expect(prompt, isNot(contains('你看不到任何画面')));
    });

    test('识图准则降为「按需精确抄录」，不与 view_image 抢活', () {
      final prompt = build(supportsVisionInput: true);

      expect(prompt, contains('图片识别（describe_image）'));
      expect(prompt, contains('一般无需调用本工具'));
    });
  });

  test('用户禁用 describe_image 时，准则段与工具引导一起消失', () {
    final prompt = build(supportsVisionInput: false, toolEnabled: false);

    expect(prompt, isNot(contains('图片识别（describe_image）')));
  });
}
