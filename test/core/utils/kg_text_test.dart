import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/kg_text.dart';

void main() {
  group('normalizeKgName', () {
    test('去空白与标点，保留中文', () {
      expect(normalizeKgName('  珍珠奶茶！ '), '珍珠奶茶');
    });

    test('全角转半角并小写 Latin', () {
      expect(normalizeKgName('ＡＢＣ　１２３'), 'abc123');
    });

    test('同名不同写法归一后一致', () {
      expect(normalizeKgName('拿铁'), normalizeKgName('拿 铁'));
    });

    test('空串返回空', () {
      expect(normalizeKgName('   '), '');
    });
  });

  group('kgTokenize', () {
    test('中文整段 + 二元组 + 三元组', () {
      final tokens = kgTokenize('睡眠不足');
      expect(tokens, contains('睡眠不足'));
      expect(tokens, contains('睡眠'));
      expect(tokens, contains('不足'));
    });

    test('英文按单词切分并过滤停用词', () {
      final tokens = kgTokenize('the Flutter app');
      expect(tokens, contains('flutter'));
      expect(tokens, contains('app'));
      expect(tokens, isNot(contains('the')));
    });

    test('长词优先排序', () {
      final tokens = kgTokenize('睡眠不足');
      expect(tokens.first.length, greaterThanOrEqualTo(tokens.last.length));
    });
  });

  group('kgSnippet', () {
    test('围绕关键词截取', () {
      const text = '今天下午开完会之后头痛得厉害，吃了布洛芬。';
      final snippet = kgSnippet(text, maxLength: 12, query: '头痛');
      expect(snippet, contains('头痛'));
      expect(snippet.length, lessThanOrEqualTo(14));
    });

    test('压成单行', () {
      expect(kgSnippet('第一行\n第二行'), '第一行 第二行');
    });
  });

  group('kgContentHash', () {
    test('同一内容稳定，不同内容不同', () {
      final a = kgContentHash({'title': 'A', 'body': 'B'});
      final b = kgContentHash({'title': 'A', 'body': 'B'});
      final c = kgContentHash({'title': 'A', 'body': 'C'});
      expect(a, b);
      expect(a, isNot(c));
    });
  });

  group('编辑距离与相似度', () {
    test('头痛 / 头晕 距离为 1', () {
      expect(kgEditDistance('头痛', '头晕'), 1);
      expect(kgSimilarity('头痛', '头晕'), closeTo(0.5, 0.0001));
    });

    test('数字串去前导零', () {
      expect(kgNumberTokens('ADR 0011 vs ADR 0012'), ['11', '12']);
    });
  });

  test('kgDateKey 使用本地日期', () {
    expect(kgDateKey(DateTime(2026, 11, 9, 23, 59)), '2026-11-09');
  });
}
