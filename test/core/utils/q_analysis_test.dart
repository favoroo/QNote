import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/q_analysis.dart';

void main() {
  group('extractLegacyQAnalysisLine', () {
    test('识别旧版图片解读并保留「图：」前缀', () {
      expect(extractLegacyQAnalysisLine('图：米饭约250kcal'), '图：米饭约250kcal');
      expect(extractLegacyQAnalysisLine('  图:薯片约375kcal  '), '图:薯片约375kcal');
    });

    test('剥离模型自带的「小Q分析：」标题', () {
      expect(extractLegacyQAnalysisLine('小Q分析：整餐热量约520kcal'), '整餐热量约520kcal');
      expect(extractLegacyQAnalysisLine('小Q分析: 荤素搭配均衡'), '荤素搭配均衡');
    });

    test('普通正文与备注行不误判', () {
      expect(extractLegacyQAnalysisLine('午饭吃了米饭和青菜'), isNull);
      expect(extractLegacyQAnalysisLine('备注：今天状态不错'), isNull);
      expect(extractLegacyQAnalysisLine(''), isNull);
    });
  });

  group('splitQAnalysisLines', () {
    test('按行拆分、去空行并去重', () {
      expect(splitQAnalysisLines('图：米饭约250kcal\n\n图：米饭约250kcal\n整体热量偏高'), ['图：米饭约250kcal', '整体热量偏高']);
    });

    test('空文本返回空列表', () {
      expect(splitQAnalysisLines(null), isEmpty);
      expect(splitQAnalysisLines('  \n '), isEmpty);
    });

    test('标点不同的同一句只保留一条', () {
      expect(splitQAnalysisLines('图：米饭约250kcal，合计约620kcal\n图：米饭约250kcal,合计约620kcal'), ['图：米饭约250kcal，合计约620kcal']);
    });
  });

  group('mergeQAnalysisLines', () {
    test('显式分析优先于旧版正文行，并按内容去重', () {
      final lines = mergeQAnalysisLines(
        analysis: '图：米饭约250kcal\n整体热量偏高',
        legacyLines: const ['图：米饭约250kcal', '建议晚餐清淡'],
      );
      expect(lines, ['图：米饭约250kcal', '整体热量偏高', '建议晚餐清淡']);
    });
  });

  group('normalizeQAnalysisText', () {
    test('统一为去标题后的换行文本', () {
      expect(normalizeQAnalysisText('小Q分析：图：米饭约250kcal\n\n整体热量偏高'), '图：米饭约250kcal\n整体热量偏高');
    });
  });
}
