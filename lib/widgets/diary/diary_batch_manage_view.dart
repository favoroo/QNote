import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';

class DiaryBatchManageView extends ConsumerStatefulWidget {
  const DiaryBatchManageView({super.key});

  @override
  ConsumerState<DiaryBatchManageView> createState() => _DiaryBatchManageViewState();
}

class _DiaryBatchManageViewState extends ConsumerState<DiaryBatchManageView> {
  Set<String> _selectedIds = {};
  DateTimeRange? _dateRange;
  final List<String> _selectedTags = [];
  List<DiaryRecord> _filteredRecords = [];
  List<String> _allTags = [];
  bool _isConfirming = false;
  Timer? _confirmTimer;

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  @override
  void dispose() {
    _confirmTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadRecords() async {
    final repo = DiaryRepository();
    final allRecords = await repo.getAll();
    final tags = <String>{};
    for (final r in allRecords) {
      tags.addAll(r.tags);
    }
    setState(() {
      _allTags = tags.toList()..sort();
      _filteredRecords = allRecords;
    });
  }

  void _applyFilters() async {
    final repo = DiaryRepository();
    List<DiaryRecord> records;

    if (_dateRange != null) {
      final start = DateTime(
        _dateRange!.start.year,
        _dateRange!.start.month,
        _dateRange!.start.day,
      );
      final end = DateTime(
        _dateRange!.end.year,
        _dateRange!.end.month,
        _dateRange!.end.day,
        23,
        59,
        59,
      );
      records = await repo.getByDateRange(start, end);
    } else {
      records = await repo.getAll();
    }

    if (_selectedTags.isNotEmpty) {
      records = records.where((r) {
        return _selectedTags.any((tag) => r.tags.contains(tag));
      }).toList();
    }

    records.sort((a, b) => b.time.compareTo(a.time));

    setState(() {
      _filteredRecords = records;
      _selectedIds = _selectedIds.intersection(records.map((r) => r.id).toSet());
    });
  }

  void _toggleTag(String tag) {
    setState(() {
      if (_selectedTags.contains(tag)) {
        _selectedTags.remove(tag);
      } else {
        _selectedTags.add(tag);
      }
    });
    _applyFilters();
  }

  void _pickDateRange() async {
    final result = await showDatePicker(
      context: context,
      initialDate: _dateRange?.start ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: const Locale('zh', 'CN'),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            splashFactory: NoSplash.splashFactory,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            colorScheme: ColorScheme.light(
              primary: Theme.of(context).colorScheme.primary,
              onPrimary: Colors.white,
              onSurface: Colors.black,
            ),
            dialogTheme: DialogThemeData(
              barrierColor: Colors.black.withValues(alpha: 0.2),
            ),
          ),
          child: child!,
        );
      },
    );
    if (result != null) {
      setState(() {
        _dateRange = DateTimeRange(start: result, end: result);
      });
      _applyFilters();
    }
  }

  void _clearDateRange() {
    setState(() {
      _dateRange = null;
    });
    _applyFilters();
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds = _selectedIds.difference({id});
      } else {
        _selectedIds = {..._selectedIds, id};
      }
    });
  }

  void _toggleSelectAll() {
    if (_selectedIds.length == _filteredRecords.length && _filteredRecords.isNotEmpty) {
      setState(() {
        _selectedIds = {};
      });
    } else {
      setState(() {
        _selectedIds = _filteredRecords.map((r) => r.id).toSet();
      });
    }
  }

  void _handleBatchDelete() {
    if (_selectedIds.isEmpty) return;

    if (!_isConfirming) {
      setState(() {
        _isConfirming = true;
      });
      _confirmTimer?.cancel();
      _confirmTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _isConfirming = false;
          });
        }
      });
      return;
    }

    for (final id in _selectedIds) {
      ref.read(diaryListProvider.notifier).deleteDiary(id);
    }
    setState(() {
      _selectedIds = {};
      _isConfirming = false;
    });
    _confirmTimer?.cancel();
    _loadRecords();
  }

  String _formatTime(DateTime dt) {
    return DateFormat('MM-dd HH:mm').format(dt);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('批量管理'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 160),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildFilterCard(theme, colorScheme),
                  const SizedBox(height: 16),
                  _buildListHeader(theme, colorScheme),
                  const SizedBox(height: 12),
                  _buildRecordList(theme, colorScheme),
                ],
              ),
            ),
          ),
          _buildBottomBar(theme, colorScheme),
        ],
      ),
    );
  }

  Widget _buildFilterCard(ThemeData theme, ColorScheme colorScheme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.filter_list, size: 16, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  '筛选条件',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildDateFilter(theme, colorScheme),
            const SizedBox(height: 16),
            _buildTagFilter(theme, colorScheme),
          ],
        ),
      ),
    );
  }

  Widget _buildDateFilter(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '日期区间范围',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        InkWell(
          onTap: _pickDateRange,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _dateRange != null
                      ? DateFormat('yyyy-MM-dd').format(_dateRange!.start) !=
                              DateFormat('yyyy-MM-dd').format(_dateRange!.end)
                          ? '${DateFormat('yyyy-MM-dd').format(_dateRange!.start)} 至 ${DateFormat('yyyy-MM-dd').format(_dateRange!.end)}'
                          : DateFormat('yyyy-MM-dd').format(_dateRange!.start)
                      : '未选择日期',
                  style: theme.textTheme.bodyMedium,
                ),
                Icon(Icons.calendar_today, size: 16, color: colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
        if (_dateRange != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: GestureDetector(
              onTap: _clearDateRange,
              child: Text(
                '清除日期',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTagFilter(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '标签来源选择 (多选)',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _allTags.map((tag) {
              final isSelected = _selectedTags.contains(tag);
              return GestureDetector(
                onTap: () => _toggleTag(tag),
                child: Chip(
                  label: Text(tag),
                  labelStyle: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isSelected ? colorScheme.onPrimary : colorScheme.onSurface,
                  ),
                  backgroundColor: isSelected ? colorScheme.primary : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  side: isSelected ? BorderSide.none : BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              );
            }).toList(),
          ),
        ),
        if (_allTags.isEmpty)
          Text(
            '暂无标签',
            style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
      ],
    );
  }

  Widget _buildListHeader(ThemeData theme, ColorScheme colorScheme) {
    final isAllSelected = _selectedIds.length == _filteredRecords.length && _filteredRecords.isNotEmpty;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          '共找到 ${_filteredRecords.length} 条记录',
          style: theme.textTheme.labelSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.bold,
          ),
        ),
        GestureDetector(
          onTap: _toggleSelectAll,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isAllSelected ? Icons.check_box : Icons.check_box_outline_blank,
                size: 14,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 4),
              Text(
                isAllSelected ? '取消全选' : '全选',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRecordList(ThemeData theme, ColorScheme colorScheme) {
    if (_filteredRecords.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text(
            '无符合条件的记录',
            style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    return Column(
      children: _filteredRecords.map((record) {
        final isSelected = _selectedIds.contains(record.id);
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: GestureDetector(
            onTap: () => _toggleSelect(record.id),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isSelected
                    ? colorScheme.primary.withValues(alpha: 0.05)
                    : colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isSelected
                      ? colorScheme.primary
                      : colorScheme.outlineVariant.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                    color: isSelected ? colorScheme.primary : colorScheme.onSurfaceVariant,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                _formatTime(record.time),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            if (record.displayTag.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: colorScheme.primary.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  record.displayTag,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: colorScheme.primary,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          record.content,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildBottomBar(ThemeData theme, ColorScheme colorScheme) {
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.1))),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            offset: const Offset(0, -4),
            blurRadius: 20,
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '已选 ${_selectedIds.length} 项',
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              FilledButton(
                onPressed: _selectedIds.isEmpty ? null : _handleBatchDelete,
                style: FilledButton.styleFrom(
                  backgroundColor: _isConfirming ? Colors.amber.shade700 : colorScheme.error,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.delete_outline, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      _isConfirming ? '再次点击确认' : '删除',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
