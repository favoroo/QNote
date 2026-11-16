import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/csv_parser.dart';

void main() {
  group('parseDelimited', () {
    test('基础：逗号分隔与行列', () {
      expect(parseDelimited('a,b,c\n1,2,3'), [
        ['a', 'b', 'c'],
        ['1', '2', '3'],
      ]);
    });

    test('引号包裹的逗号、转义引号与内嵌换行', () {
      final rows = parseDelimited('name,note\n"张三","他说""你好"", 然后走了"\n"李四","第一行\n第二行"');
      expect(rows[1], ['张三', '他说"你好", 然后走了']);
      expect(rows[2][1], '第一行\n第二行');
    });

    test('CRLF 视为行分隔', () {
      expect(parseDelimited('a,b\r\n1,2\r\n'), [
        ['a', 'b'],
        ['1', '2'],
      ]);
    });

    test('空字段保留，末尾换行不多出空行', () {
      expect(parseDelimited('a,,\n'), [
        ['a', '', ''],
      ]);
      expect(parseDelimited(''), isEmpty);
    });

    test('制表符分隔（TSV）', () {
      expect(parseDelimited('a\tb\n1\t2', delimiter: '\t'), [
        ['a', 'b'],
        ['1', '2'],
      ]);
    });
  });

  group('dropBlankRows / delimiterForExtension', () {
    test('去掉全空白行，保留含空字段的有效行', () {
      expect(
        dropBlankRows([
          ['a', ''],
          ['', ''],
          ['b', 'c'],
        ]),
        [
          ['a', ''],
          ['b', 'c'],
        ],
      );
    });

    test('按扩展名选分隔符', () {
      expect(delimiterForExtension('tsv'), '\t');
      expect(delimiterForExtension('TSV'), '\t');
      expect(delimiterForExtension('csv'), ',');
      expect(delimiterForExtension(null), ',');
    });
  });

  group('serializeDelimited', () {
    test('纯文本字段不加引号原样输出', () {
      expect(
        serializeDelimited([
          ['a', 'b'],
          ['1', '2'],
        ]),
        'a,b\n1,2',
      );
    });

    test('含分隔符/引号/换行的字段自动加引号并转义', () {
      expect(
        serializeDelimited([
          ['米饭,两荤', '他说"你好"', '多\n行'],
        ]),
        '"米饭,两荤","他说""你好""","多\n行"',
      );
    });

    test('与 parseDelimited 互为逆操作', () {
      const source = '日期,项目,金额\n2026-11-10,"午餐, 食堂",22.5\n"多行\n备注",,';
      final rows = parseDelimited(source);
      final roundTrip = parseDelimited(serializeDelimited(rows));
      expect(roundTrip, rows);
    });

    test('可保持 CRLF 换行风格，编辑写回不污染源码', () {
      expect(
        serializeDelimited([
          ['a', 'b'],
          ['1', '2'],
        ], lineEnding: '\r\n'),
        'a,b\r\n1,2',
      );
    });
  });
}
