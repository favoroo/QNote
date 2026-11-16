import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/mermaid_er_repair.dart';

void main() {
  group('repairMermaidErSource', () {
    test('中文字段名换成英文标识并把中文保留在注释列，中文关系标签补引号', () {
      final result = repairMermaidErSource('''
erDiagram
    USER ||--o{ ORDER : 下单
    USER {
        string 昵称 "谦"
        float 体重
    }
''');
      expect(result.changed, isTrue);
      expect(result.renamedFields, 2);
      expect(result.quotedLabels, 1);
      expect(result.source, contains('USER ||--o{ ORDER : "下单"'));
      expect(result.source, contains('string field_1 "昵称 · 谦"'));
      expect(result.source, contains('float field_2 "体重"'));
      expect(result.notice, contains('中文字段名'));
      expect(result.notice, contains('关系标签'));
      expect(result.notice, contains('源码本身未修改'));
    });

    test('中文字段类型换成 string，原类型也保留进注释', () {
      final result = repairMermaidErSource('''
erDiagram
    USER {
        字符串 昵称 "谦"
    }
''');
      expect(result.changed, isTrue);
      expect(result.source, contains('string field_1 "原类型：字符串 · 昵称 · 谦"'));
    });

    test('纯 ASCII 的合法 ER 源码完全不变', () {
      const source = '''erDiagram
    USER ||--o{ ORDER : "下单"
    USER {
        string nickname "昵称"
        int age PK "年龄"
    }
''';
      final result = repairMermaidErSource(source);
      expect(result.changed, isFalse);
      expect(result.source, source);
      expect(result.notice, isNull);
    });

    test('字段约束 PK/FK/UK 保留', () {
      final result = repairMermaidErSource('''
erDiagram
    USER {
        string 昵称 PK "谦"
        int 年龄 FK
    }
''');
      expect(result.source, contains('string field_1 PK "昵称 · 谦"'));
      expect(result.source, contains('int field_2 FK "年龄"'));
    });

    test('非 ER 源码不做任何处理', () {
      const source = 'flowchart TD\n  A[开始] --> B[结束]';
      final result = repairMermaidErSource(source);
      expect(result.changed, isFalse);
      expect(result.source, source);
    });

    test('中文实体名不替换，避免图里只剩 ENTITY_1 看不懂；交给错误态诊断', () {
      final result = repairMermaidErSource('''
erDiagram
    用户 ||--o{ 订单 : "下单"
    用户 {
        string name "姓名"
    }
''');
      expect(result.changed, isFalse);
      expect(result.source, contains('用户 ||--o{ 订单'));
    });

    test('CRLF 行尾保持不变', () {
      final result = repairMermaidErSource('erDiagram\r\n    USER {\r\n        string 昵称\r\n    }\r\n');
      expect(result.changed, isTrue);
      expect(result.source, contains('\r\n'));
      expect(result.source.contains('\n\n'), isFalse);
    });
  });
}
