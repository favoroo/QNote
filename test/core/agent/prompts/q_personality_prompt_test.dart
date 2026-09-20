import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/agent/agent_tool_registry.dart';
import 'package:qnote_flutter/core/agent/prompts/q_personalities.dart';
import 'package:qnote_flutter/core/agent/prompts/q_system_prompt.dart';
import 'package:qnote_flutter/core/agent/services/q_personality_service.dart';

/// 小Q人格注入的结构护栏
///
/// 人格段只有一两句话，而 AGENTS.md 规范正文有数千字，历史上人格经常被淹成
/// 统一的「公文腔」。这里锁住三件事：人格必须成节且在最前、必须带优先级声明、
/// 回复风格条款必须显式为人格让路——避免后续改提示词时把权重结构改回去。
void main() {
  group('QSystemPrompt 人格段结构', () {
    test('人格段独立成节并位于 AGENTS.md 规范之前', () {
      final prompt = QSystemPrompt.buildSystemPrompt(
        personalityPrompt: '你是元气小Q。',
        personalityName: '活泼元气',
      );

      expect(prompt, startsWith('# 人格与身份'));
      final personalityAt = prompt.indexOf('你是元气小Q。');
      final agentsAt = prompt.indexOf('# QNote Agent Operating System');
      expect(personalityAt, greaterThanOrEqualTo(0));
      expect(agentsAt, greaterThan(personalityAt));
    });

    test('输出个性名标记，让模型知道自己是哪一种人格', () {
      final prompt = QSystemPrompt.buildSystemPrompt(
        personalityPrompt: '你是温柔陪伴者小Q。',
        personalityName: '温柔陪伴',
      );
      expect(prompt, contains('（当前个性：**温柔陪伴**）'));
    });

    test('personalityName 留空时不输出空标记行', () {
      final prompt = QSystemPrompt.buildSystemPrompt(
        personalityPrompt: '你是效率助理小Q。',
      );
      expect(prompt, contains('你是效率助理小Q。'));
      expect(prompt, isNot(contains('当前个性：')));
    });

    test('带优先级声明且明确不豁免执行铁律', () {
      final prompt = QSystemPrompt.buildSystemPrompt();
      expect(prompt, contains('人格管什么'));
      expect(prompt, contains('人格不管什么'));
      expect(prompt, contains('最高优先级，贯穿整场对话'));
      // 语气可以变，铁律不能松动
      expect(prompt, contains('完成门禁'));
      expect(prompt, contains('ask_user'));
    });

    test('回复风格条款服从人格小节，且不再使用绝对句数上限', () {
      final prompt = QSystemPrompt.buildSystemPrompt();
      final styleRuleAt = prompt.indexOf('8. **回复风格**');
      expect(styleRuleAt, greaterThan(0));
      final styleSection = prompt.substring(styleRuleAt);
      expect(styleSection, contains('服从开头的「人格与身份」小节'));
      expect(styleSection, contains('五种个性不该读出同一种腔调'));
      // 「3 句以内」这类硬上限会把活泼/温柔型的情绪表达直接砍掉
      expect(styleSection, isNot(contains('3 句以内')));
    });

    test('禁用的可选工具对应准则段不注入（回归保护）', () {
      final all = QSystemPrompt.buildSystemPrompt();
      final withoutImage = QSystemPrompt.buildSystemPrompt(
        enabledOptionalTools: AgentToolRegistry.optionalToolNames
            .difference({'generate_image'}),
      );
      expect(all, contains('图片生成（generate_image）'));
      expect(withoutImage, isNot(contains('图片生成（generate_image）')));
      expect(withoutImage, contains('网页阅读（fetch_url）'));
    });
  });

  group('QPersonalities 语气摘要', () {
    test('预设人格都带尾部复述用的 digest', () {
      for (final preset in QPersonalities.presets) {
        if (preset.id == QPersonalities.customId) continue;
        expect(preset.digest, isNotEmpty, reason: preset.id);
        expect(preset.digest, isNot(contains('\n')), reason: preset.id);
      }
    });

    test('未知 id 回退经典管家', () {
      expect(QPersonalities.byId('not-exist').id, QPersonalities.defaultId);
      expect(QPersonalities.byId('').id, QPersonalities.defaultId);
    });
  });

  group('QPersonalityService.digestOf 尾部摘要提炼', () {
    test('取首个整句作为摘要', () {
      const text = '你是一位说话带点幽默感的极简助手。喜欢用短句，偶尔打个比方。';
      expect(
        QPersonalityService.digestOf(text),
        '你是一位说话带点幽默感的极简助手。',
      );
    });

    test('多行与多余空白折叠成一行', () {
      const text = '  说话像老朋友。\n\n  先接情绪，再给建议。  ';
      expect(QPersonalityService.digestOf(text), '说话像老朋友。');
    });

    test('无句末标点时整段作为摘要，超长再截断', () {
      expect(QPersonalityService.digestOf('说话简洁'), '说话简洁');
      final long = '啊' * 120;
      final digest = QPersonalityService.digestOf(long);
      expect(digest.length, 81); // 80 字 + 省略号
      expect(digest, endsWith('…'));
    });

    test('英文句末标点同样断句', () {
      expect(
        QPersonalityService.digestOf('Be witty and terse. Never ramble.'),
        'Be witty and terse.',
      );
    });
  });
}
