import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/core/utils/delta_markdown.dart';
import 'package:qnote_flutter/core/utils/search_rows.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/note_provider.dart';
import 'package:qnote_flutter/widgets/search_highlight.dart';

class SearchView extends ConsumerStatefulWidget {
  final void Function(dynamic result)? onResultSelected;

  const SearchView({super.key, this.onResultSelected});

  @override
  ConsumerState<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends ConsumerState<SearchView> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  List<DiaryRecord> _diaryResults = [];
  List<Note> _noteResults = [];
  bool _isSearching = false;
  String _query = '';
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _performSearch(value);
    });
  }

  Future<void> _performSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _diaryResults = [];
        _noteResults = [];
        _query = '';
        _isSearching = false;
      });
      return;
    }

    setState(() {
      _isSearching = true;
      _query = query.trim();
    });

    final diaryRepo = ref.read(diaryRepositoryProvider);
    final noteRepo = ref.read(noteRepositoryProvider);
    final diaries = await diaryRepo.search(query.trim());
    final notes = await noteRepo.search(query.trim());

    if (!mounted) return;

    setState(() {
      _diaryResults = diaries;
      _noteResults = notes;
      _isSearching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasResults = _diaryResults.isNotEmpty || _noteResults.isNotEmpty;
    final showEmpty = _query.isNotEmpty && !_isSearching && !hasResults;
    final rows = buildSearchRows(diaryCount: _diaryResults.length, noteCount: _noteResults.length);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
        title: TextField(
          controller: _searchController,
          focusNode: _focusNode,
          onChanged: _onSearchChanged,
          style: theme.textTheme.bodyLarge,
          decoration: InputDecoration(
            hintText: '搜索日记或笔记',
            border: InputBorder.none,
            hintStyle: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        actions: [
          if (_searchController.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _searchController.clear();
                setState(() {
                  _diaryResults = [];
                  _noteResults = [];
                  _query = '';
                  _isSearching = false;
                });
              },
            ),
        ],
      ),
      body: AnimatedSwitcher(
        duration: AppDurations.fast,
        switchInCurve: AppCurves.emphasized,
        switchOutCurve: AppCurves.exit,
        layoutBuilder: (currentChild, previousChildren) {
          return Stack(alignment: Alignment.topCenter, children: <Widget>[...previousChildren, ?currentChild]);
        },
        child: _isSearching
            ? const Center(key: ValueKey('search_loading'), child: CircularProgressIndicator())
            : showEmpty
            ? KeyedSubtree(key: const ValueKey('search_empty'), child: _buildEmptyState(theme))
            : KeyedSubtree(
                key: const ValueKey('search_results'),
                // 搜索结果条数没有上限（repo.search 不带 limit），列表必须懒加载：
                // 这里过去是 `ListView(children: [...全部结果])`，每次搜索（300ms
                // 防抖后的 setState）都要把所有结果连同关键词高亮重建一遍。
                // 行号 → 分组下标的换算在 buildSearchRows 里（有单测覆盖）。
                child: ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    switch (row.kind) {
                      case SearchRowKind.diaryHeader:
                        return _buildSectionHeader(theme, '日记', Icons.book);
                      case SearchRowKind.diaryResult:
                        final d = _diaryResults[row.index];
                        return _DiaryResultTile(
                          diary: d,
                          query: _query,
                          onTap: () {
                            widget.onResultSelected?.call(d);
                            Navigator.of(context).pop(d);
                          },
                        );
                      case SearchRowKind.gap:
                        return const SizedBox(height: 8);
                      case SearchRowKind.noteHeader:
                        return _buildSectionHeader(theme, '笔记', Icons.note);
                      case SearchRowKind.noteResult:
                        final n = _noteResults[row.index];
                        return _NoteResultTile(
                          note: n,
                          query: _query,
                          onTap: () {
                            widget.onResultSelected?.call(n);
                            Navigator.of(context).pop(n);
                          },
                        );
                    }
                  },
                ),
              ),
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search, size: 72, color: theme.colorScheme.outlineVariant),
          const SizedBox(height: 16),
          Text('未找到相关内容', style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _DiaryResultTile extends StatelessWidget {
  final DiaryRecord diary;
  final String query;
  final VoidCallback onTap;

  const _DiaryResultTile({required this.diary, required this.query, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contentPreview = diary.content.length > 80 ? '${diary.content.substring(0, 80)}...' : diary.content;

    return ListTile(
      leading: Icon(Icons.book_outlined, color: theme.colorScheme.primary),
      title: diary.displayTag.isNotEmpty
          ? highlightSearchMatch(diary.displayTag, query, theme)
          : highlightSearchMatch(diary.title, query, theme),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          highlightSearchMatch(contentPreview, query, theme, isSubtitle: true),
          const SizedBox(height: 2),
          Text(
            diary.time.toIso8601String().substring(0, 10),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _NoteResultTile extends StatelessWidget {
  final Note note;
  final String query;
  final VoidCallback onTap;

  const _NoteResultTile({required this.note, required this.query, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contentPreview = extractPlainTextFromDelta(note.content, maxLength: 80);

    return ListTile(
      leading: Icon(Icons.note_outlined, color: theme.colorScheme.tertiary),
      title: highlightSearchMatch(note.title, query, theme),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          highlightSearchMatch(contentPreview, query, theme, isSubtitle: true),
          const SizedBox(height: 2),
          Text(
            note.updatedAt.toIso8601String().substring(0, 10),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}
