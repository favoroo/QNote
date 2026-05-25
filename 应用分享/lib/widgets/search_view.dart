import 'dart:async';
import 'package:flutter/material.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/core/utils/delta_markdown.dart';

class SearchView extends StatefulWidget {
  final void Function(dynamic result)? onResultSelected;

  const SearchView({super.key, this.onResultSelected});

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final DiaryRepository _diaryRepo = DiaryRepository();
  final NoteRepository _noteRepo = NoteRepository();

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

    final diaries = await _diaryRepo.search(query.trim());
    final notes = await _noteRepo.search(query.trim());

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

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: TextField(
          controller: _searchController,
          focusNode: _focusNode,
          onChanged: _onSearchChanged,
          style: theme.textTheme.bodyLarge,
          decoration: InputDecoration(
            hintText: '搜索日记或笔记...',
            border: InputBorder.none,
            hintStyle: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
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
      body: _isSearching
          ? const Center(child: CircularProgressIndicator())
          : showEmpty
              ? _buildEmptyState(theme)
              : ListView(
                  children: [
                    if (_diaryResults.isNotEmpty) ...[
                      _buildSectionHeader(theme, '日记记录', Icons.book),
                      ..._diaryResults.map(
                        (d) => _DiaryResultTile(
                          diary: d,
                          query: _query,
                          onTap: () {
                            widget.onResultSelected?.call(d);
                            Navigator.of(context).pop(d);
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (_noteResults.isNotEmpty) ...[
                      _buildSectionHeader(theme, '笔记', Icons.note),
                      ..._noteResults.map(
                        (n) => _NoteResultTile(
                          note: n,
                          query: _query,
                          onTap: () {
                            widget.onResultSelected?.call(n);
                            Navigator.of(context).pop(n);
                          },
                        ),
                      ),
                    ],
                  ],
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
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
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
          Icon(
            Icons.search,
            size: 72,
            color: theme.colorScheme.outlineVariant,
          ),
          const SizedBox(height: 16),
          Text(
            '未找到相关内容',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _DiaryResultTile extends StatelessWidget {
  final DiaryRecord diary;
  final String query;
  final VoidCallback onTap;

  const _DiaryResultTile({
    required this.diary,
    required this.query,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contentPreview = diary.content.length > 80
        ? '${diary.content.substring(0, 80)}...'
        : diary.content;

    return ListTile(
      leading: Icon(Icons.book_outlined, color: theme.colorScheme.primary),
      title: diary.displayTag.isNotEmpty
          ? _highlightText(diary.displayTag, query, theme)
          : _highlightText(diary.title, query, theme),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          _highlightText(contentPreview, query, theme, isSubtitle: true),
          const SizedBox(height: 2),
          Text(
            diary.time.toIso8601String().substring(0, 10),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
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

  const _NoteResultTile({
    required this.note,
    required this.query,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contentPreview = extractPlainTextFromDelta(note.content, maxLength: 80);

    return ListTile(
      leading: Icon(Icons.note_outlined, color: theme.colorScheme.tertiary),
      title: _highlightText(note.title, query, theme),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          _highlightText(contentPreview, query, theme, isSubtitle: true),
          const SizedBox(height: 2),
          Text(
            note.updatedAt.toIso8601String().substring(0, 10),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

Widget _highlightText(String text, String query, ThemeData theme,
    {bool isSubtitle = false}) {
  if (query.isEmpty) {
    return Text(
      text,
      maxLines: isSubtitle ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      style: isSubtitle ? theme.textTheme.bodySmall : null,
    );
  }

  final lowerText = text.toLowerCase();
  final lowerQuery = query.toLowerCase();
  final index = lowerText.indexOf(lowerQuery);

  if (index == -1) {
    return Text(
      text,
      maxLines: isSubtitle ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      style: isSubtitle ? theme.textTheme.bodySmall : null,
    );
  }

  final before = text.substring(0, index);
  final match = text.substring(index, index + query.length);
  final after = text.substring(index + query.length);

  return RichText(
    maxLines: isSubtitle ? 2 : 1,
    overflow: TextOverflow.ellipsis,
    text: TextSpan(
      style: isSubtitle
          ? theme.textTheme.bodySmall
          : theme.textTheme.bodyLarge,
      children: [
        TextSpan(text: before),
        TextSpan(
          text: match,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.primary,
            backgroundColor: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
          ),
        ),
        TextSpan(text: after),
      ],
    ),
  );
}
