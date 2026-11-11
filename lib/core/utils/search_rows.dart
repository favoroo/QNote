/// 搜索结果列表的行模型。
///
/// 搜索页把「日记 / 笔记」两个分组铺成一条懒加载列表 —— 搜索结果条数没有上限
/// （`repo.search` 不带 limit），沿用 `Column(children: [...全部结果])` 会在每次
/// 防抖后的 setState 里把全部结果连同关键词高亮重建一遍。改成 builder 后，行号到
/// 分组内下标的换算最容易写错（错一格就是越界崩溃），所以单独抽成纯函数并配单测。
library;

/// 一行的类型。
enum SearchRowKind { diaryHeader, diaryResult, gap, noteHeader, noteResult }

/// 一行：类型 + （结果行才有）在对应结果数组里的下标。
class SearchRow {
  const SearchRow(this.kind, [this.index = 0]);

  final SearchRowKind kind;

  /// 结果行（[SearchRowKind.diaryResult] / [SearchRowKind.noteResult]）在其结果
  /// 数组中的下标；标题行与留白行为 0。
  final int index;
}

/// 按结果条数展开行列表。
///
/// 行序保持与改动前一致：日记分组（标题 + 结果 + 分组间留白）、笔记分组（标题 +
/// 结果）。留白只在日记分组存在时插入（即使没有笔记分组，末尾也保留这段间距，
/// 与原 `children` 列表的写法一致）。
List<SearchRow> buildSearchRows({required int diaryCount, required int noteCount}) {
  final rows = <SearchRow>[];
  if (diaryCount > 0) {
    rows.add(const SearchRow(SearchRowKind.diaryHeader));
    for (var i = 0; i < diaryCount; i++) {
      rows.add(SearchRow(SearchRowKind.diaryResult, i));
    }
    rows.add(const SearchRow(SearchRowKind.gap));
  }
  if (noteCount > 0) {
    rows.add(const SearchRow(SearchRowKind.noteHeader));
    for (var i = 0; i < noteCount; i++) {
      rows.add(SearchRow(SearchRowKind.noteResult, i));
    }
  }
  return rows;
}
