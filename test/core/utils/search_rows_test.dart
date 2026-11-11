import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/search_rows.dart';

void main() {
  group('buildSearchRows', () {
    test('空结果不产生任何行', () {
      expect(buildSearchRows(diaryCount: 0, noteCount: 0), isEmpty);
    });

    test('只有日记：标题 + 结果 + 末尾留白', () {
      final rows = buildSearchRows(diaryCount: 2, noteCount: 0);

      expect(rows.map((r) => r.kind), [
        SearchRowKind.diaryHeader,
        SearchRowKind.diaryResult,
        SearchRowKind.diaryResult,
        SearchRowKind.gap,
      ]);
      expect(rows[1].index, 0);
      expect(rows[2].index, 1);
    });

    test('只有笔记：标题 + 结果', () {
      final rows = buildSearchRows(diaryCount: 0, noteCount: 2);

      expect(rows.map((r) => r.kind), [SearchRowKind.noteHeader, SearchRowKind.noteResult, SearchRowKind.noteResult]);
      expect(rows[1].index, 0);
      expect(rows[2].index, 1);
    });

    test('两组都有：行序与下标都能对上（含留白位置）', () {
      final rows = buildSearchRows(diaryCount: 2, noteCount: 3);

      expect(rows.map((r) => r.kind), [
        SearchRowKind.diaryHeader,
        SearchRowKind.diaryResult,
        SearchRowKind.diaryResult,
        SearchRowKind.gap,
        SearchRowKind.noteHeader,
        SearchRowKind.noteResult,
        SearchRowKind.noteResult,
        SearchRowKind.noteResult,
      ]);

      // 结果行的下标必须落在各自的数组范围内：越界就是运行时崩溃
      for (final row in rows) {
        switch (row.kind) {
          case SearchRowKind.diaryResult:
            expect(row.index, inInclusiveRange(0, 1));
          case SearchRowKind.noteResult:
            expect(row.index, inInclusiveRange(0, 2));
          case SearchRowKind.diaryHeader:
          case SearchRowKind.gap:
          case SearchRowKind.noteHeader:
            expect(row.index, 0);
        }
      }
    });

    test('行数 = 分组标题与留白 + 结果条数', () {
      expect(buildSearchRows(diaryCount: 5, noteCount: 4).length, 5 + 4 + 3);
      expect(buildSearchRows(diaryCount: 1, noteCount: 0).length, 1 + 2);
      expect(buildSearchRows(diaryCount: 0, noteCount: 1).length, 1 + 1);
    });
  });
}
