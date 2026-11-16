import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/agent/skills/frontend_design/frontend_design_doc.dart';
import 'package:qnote_flutter/core/agent/skills/frontend_design/q_style_theme.dart';

void main() {
  group('QStyle 主题数据', () {
    test('主题 id 唯一，两个家族都有主题', () {
      final ids = qStyleThemes.map((theme) => theme.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(qStyleThemes.length, greaterThanOrEqualTo(9));
      expect(qStyleThemes.where((theme) => theme.family == QStyleFamily.magazine), isNotEmpty);
      expect(qStyleThemes.where((theme) => theme.family == QStyleFamily.swiss), isNotEmpty);
    });

    test('所有主题对比度达标', () {
      expect(qStyleThemeErrors(), isEmpty);
    });

    test('每套主题都能生成完整语义 token 块', () {
      for (final theme in qStyleThemes) {
        final block = theme.cssBlock;
        expect(block, startsWith('[data-theme="${theme.id}"]{'));
        for (final variable in [
          '--paper:',
          '--paper-2:',
          '--ink:',
          '--text-2:',
          '--text-3:',
          '--line:',
          '--line-strong:',
          '--accent:',
          '--accent-ink:',
          '--accent-on:',
        ]) {
          expect(block.contains(variable), isTrue, reason: '${theme.id} 缺少 $variable');
        }
        if (theme.family == QStyleFamily.swiss) {
          expect(block.contains('--accent-soft'), isFalse, reason: '瑞士风禁止荧光底色');
        }
        if (theme.isDark) {
          expect(block.contains('color-scheme:dark'), isTrue, reason: '${theme.id} 缺少暗色声明');
        }
      }
    });
  });

  group('frontend-design 提示词', () {
    final doc = buildFrontendDesignDoc();

    test('包含全部主题色块与主题决策表', () {
      for (final theme in qStyleThemes) {
        expect(doc.contains('[data-theme="${theme.id}"]'), isTrue, reason: '缺少 ${theme.id} 色块');
      }
      expect(doc.contains('| 内容类型 | 家族 | 主题 |'), isTrue);
    });

    test('包含 12 个登记版式', () {
      for (var index = 1; index <= 12; index++) {
        final id = 'L${index.toString().padLeft(2, '0')}';
        expect(doc.contains('| $id |'), isTrue, reason: '缺少登记版式 $id');
      }
    });

    test('包含两族公共 token 与关键硬规则', () {
      expect(doc.contains('[data-family="swiss"]'), isTrue);
      expect(doc.contains('--font-display'), isTrue);
      expect(doc.contains('--fs-body:16px'), isTrue);
      expect(doc.contains('localStorage'), isTrue);
      expect(doc.contains('反模式清单'), isTrue);
      expect(doc.contains('自检清单'), isTrue);
    });
  });
}
