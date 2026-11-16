import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/csv_table_layout.dart';

void main() {
  group('estimatedTextWidth', () {
    test('中文/全角字符比英文宽', () {
      expect(estimatedTextWidth('表格'), closeTo(26, 0.001));
      expect(estimatedTextWidth('ab'), closeTo(14.4, 0.001));
      expect(estimatedTextWidth('表格'), greaterThan(estimatedTextWidth('ab')));
      // 全角标点按 CJK 宽度计算
      expect(estimatedTextWidth('，'), closeTo(13, 0.001));
    });

    test('中英混排按字符累加', () {
      expect(estimatedTextWidth('中a'), closeTo(13 + 7.2, 0.001));
    });

    test('多行文本取最宽一行，空串返回 0', () {
      expect(estimatedTextWidth('abc\n中'), closeTo(21.6, 0.001));
      expect(estimatedTextWidth('中\nab'), closeTo(14.4, 0.001));
      expect(estimatedTextWidth(''), 0);
      expect(estimatedTextWidth('\n'), 0);
    });

    test('可自定义中英字符宽度', () {
      expect(estimatedTextWidth('ab', latinWidth: 10), closeTo(20, 0.001));
      expect(estimatedTextWidth('中', cjkWidth: 20), closeTo(20, 0.001));
    });
  });

  group('computeCsvColumnWidths', () {
    test('按内容给出不同列宽，空列回落到 minWidth', () {
      final widths = computeCsvColumnWidths(
        rows: [
          ['名称', '数量', '备注', '空'],
          ['苹果', '12', '这是比较长的一段备注文本', ''],
          ['香蕉', '3', '', ''],
        ],
        columnCount: 4,
      );
      expect(widths.length, 4);
      expect(widths[0], greaterThanOrEqualTo(72));
      expect(widths[1], lessThan(widths[2]));
      expect(widths[3], 72);
      // 不能所有列都被挤成同一个最小值
      expect(widths.toSet().length, greaterThan(1));
    });

    test('宽度夹在 minWidth / maxWidth 之间', () {
      final longText = '这是一段很长的备注内容' * 6;
      final widths = computeCsvColumnWidths(
        rows: [
          ['h'],
          [longText],
          ['$longText。'],
          ['$longText！'],
        ],
        columnCount: 1,
        minWidth: 80,
        maxWidth: 240,
      );
      expect(widths.single, 240);
    });

    test('单个超长单元格不会把整列撑到上限', () {
      final widths = computeCsvColumnWidths(
        rows: [
          ['备注'],
          for (var i = 0; i < 5; i++) ['普通文本'],
          ['超长内容' * 200],
        ],
        columnCount: 1,
      );
      expect(widths.single, lessThan(320));
      expect(widths.single, greaterThan(72));
    });

    test('sampleRows 只采样表头与前 N 行，不被采样范围外的长内容带偏', () {
      final rows = <List<String>>[
        ['备注'],
        for (var i = 0; i < 3; i++) ['短'],
        for (var i = 0; i < 4; i++) ['这是一段明显更长但仍然合理的备注内容'],
        ['超长尾部单元格' * 200],
      ];
      final sampled = computeCsvColumnWidths(rows: rows, columnCount: 1, sampleRows: 3);
      final withLongerRows = computeCsvColumnWidths(rows: rows, columnCount: 1, sampleRows: 7);
      final full = computeCsvColumnWidths(rows: rows, columnCount: 1, sampleRows: 80);

      expect(sampled.single, lessThan(withLongerRows.single));
      expect(sampled.single, lessThan(120));
      // 采样范围外的单个超长单元格不会把宽度直接推到 320
      expect(full.single, lessThan(320));
    });

    test('行缺列/多列不会越界，长度始终等于 columnCount', () {
      final widths = computeCsvColumnWidths(
        rows: [
          ['a', 'b', 'c', 'd'],
          ['1'],
          ['2', '3', '4', '5', '6'],
        ],
        columnCount: 4,
      );
      expect(widths.length, 4);
      expect(widths.every((width) => width >= 72 && width <= 320), isTrue);
    });

    test('空表与 0 列', () {
      expect(computeCsvColumnWidths(rows: const [], columnCount: 3), [72, 72, 72]);
      expect(computeCsvColumnWidths(rows: const [], columnCount: 0), isEmpty);
    });
  });

  group('isNumericCsvColumn', () {
    test('忽略空值/空白值，全部可解析才算数值列', () {
      expect(
        isNumericCsvColumn([
          ['1'],
          [' 2.5 '],
          [''],
          ['   '],
          ['-3e2'],
        ], 0),
        isTrue,
      );
    });

    test('含非数值返回 false', () {
      expect(
        isNumericCsvColumn([
          ['1'],
          ['abc'],
        ], 0),
        isFalse,
      );
      expect(
        isNumericCsvColumn([
          ['12%'],
        ], 0),
        isFalse,
      );
    });

    test('全空列、越界列返回 false', () {
      expect(
        isNumericCsvColumn([
          [''],
          ['   '],
        ], 0),
        isFalse,
      );
      expect(
        isNumericCsvColumn([
          ['1', '2'],
        ], 5),
        isFalse,
      );
      expect(isNumericCsvColumn(const [], 0), isFalse);
    });
  });

  group('encodeTsvRow', () {
    test('普通单元格用制表符连接', () {
      expect(encodeTsvRow(['张三', '研发', '128']), '张三\t研发\t128');
    });

    test('含制表符/换行/引号的单元格按 RFC 4180 转义', () {
      expect(encodeTsvRow(['a\tb', 'c\nd', 'e"f']), '"a\tb"\t"c\nd"\t"e""f"');
    });
  });
}
