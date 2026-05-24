import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';

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
  String _formatTimeRange(DiaryRecord record) {
    final start = record.startTime ?? record.time;
    final dateStr = DateFormat('MM-dd HH:mm').format(start);
    if (record.endTime != null) {
      final endStr = DateFormat('HH:mm').format(record.endTime!);
      return '$dateStr - $endStr';
    }
    return dateStr;
  }

  void _openRecordDetails(DiaryRecord record) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return _RecordDetailSheet(
          records: _filteredRecords,
          initialIndex: _filteredRecords.indexOf(record),
          selectedIds: _selectedIds,
          onToggleSelect: (id) {
            _toggleSelect(id);
          },
          onRefresh: _applyFilters,
        );
      },
    );
  }

  void _openGallery(DiaryRecord record, int index) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _FullScreenImageGallery(
          photos: record.photos,
          initialIndex: index,
        ),
      ),
    );
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
                                _formatTimeRange(record),
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
                        const SizedBox(height: 6),
                        Text(
                          record.content.isNotEmpty ? record.content : '无备注内容',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: record.content.isNotEmpty
                                ? colorScheme.onSurface
                                : colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                          ),
                        ),
                        if (record.photos.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {}, // Prevent card tap selection
                            child: Row(
                              children: record.photos.asMap().entries.map((entry) {
                                final idx = entry.key;
                                final photo = entry.value;
                                return GestureDetector(
                                  onTap: () => _openGallery(record, idx),
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: UnifiedImage(
                                        imagePath: photo,
                                        width: 48,
                                        height: 48,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openRecordDetails(record), // Prevent card tap selection and open detail view
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                      child: Icon(
                        Icons.visibility_outlined,
                        color: colorScheme.primary,
                        size: 20,
                      ),
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

class _FullScreenImageGallery extends StatefulWidget {
  final List<String> photos;
  final int initialIndex;

  const _FullScreenImageGallery({
    required this.photos,
    required this.initialIndex,
  });

  @override
  State<_FullScreenImageGallery> createState() => _FullScreenImageGalleryState();
}

class _FullScreenImageGalleryState extends State<_FullScreenImageGallery> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          '${_currentIndex + 1} / ${widget.photos.length}',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.photos.length,
        onPageChanged: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        itemBuilder: (context, index) {
          return Center(
            child: InteractiveViewer(
              minScale: 1.0,
              maxScale: 4.0,
              child: UnifiedImage(
                imagePath: widget.photos[index],
                fit: BoxFit.contain,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RecordDetailSheet extends StatefulWidget {
  final List<DiaryRecord> records;
  final int initialIndex;
  final Set<String> selectedIds;
  final void Function(String) onToggleSelect;
  final VoidCallback? onRefresh;

  const _RecordDetailSheet({
    required this.records,
    required this.initialIndex,
    required this.selectedIds,
    required this.onToggleSelect,
    this.onRefresh,
  });

  @override
  State<_RecordDetailSheet> createState() => _RecordDetailSheetState();
}

class _RecordDetailSheetState extends State<_RecordDetailSheet> {
  late PageController _pageController;
  late int _currentIndex;
  late Set<String> _localSelectedIds;
  late List<DiaryRecord> _localRecords;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    _localSelectedIds = Set.from(widget.selectedIds);
    _localRecords = List.from(widget.records);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _toggleLocalSelect(String id) {
    setState(() {
      if (_localSelectedIds.contains(id)) {
        _localSelectedIds.remove(id);
      } else {
        _localSelectedIds.add(id);
      }
    });
    widget.onToggleSelect(id);
  }

  Future<void> _editRecord(DiaryRecord record) async {
    // Navigate to editor screen
    await GoRouter.of(context).push('/diary/editor', extra: record);
    
    // Fetch updated record from database
    final repo = DiaryRepository();
    final updatedRecord = await repo.getById(record.id);
    
    if (mounted) {
      if (updatedRecord == null || updatedRecord.isDeleted) {
        // Record was deleted
        setState(() {
          _localRecords.removeWhere((r) => r.id == record.id);
          if (_localRecords.isEmpty) {
            Navigator.of(context).pop();
          } else {
            if (_currentIndex >= _localRecords.length) {
              _currentIndex = _localRecords.length - 1;
            }
          }
        });
        widget.onRefresh?.call();
      } else {
        // Record was updated
        setState(() {
          final idx = _localRecords.indexWhere((r) => r.id == record.id);
          if (idx != -1) {
            _localRecords[idx] = updatedRecord;
          }
        });
        widget.onRefresh?.call();
      }
    }
  }

  String _formatTimeRange(DiaryRecord record) {
    final start = record.startTime ?? record.time;
    final dateStr = DateFormat('yyyy-MM-dd HH:mm').format(start);
    if (record.endTime != null) {
      final endStr = DateFormat('HH:mm').format(record.endTime!);
      return '$dateStr - $endStr';
    }
    return dateStr;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (_localRecords.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // Top Drag Handle
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Top Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Text(
                    '记录详情 (${_currentIndex + 1} / ${_localRecords.length})',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  // Actions Row: Edit and Select
                  Builder(
                    builder: (context) {
                      final currentRecord = _localRecords[_currentIndex];
                      final isSelected = _localSelectedIds.contains(currentRecord.id);
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(Icons.edit_outlined, color: colorScheme.primary),
                            onPressed: () => _editRecord(currentRecord),
                          ),
                          const SizedBox(width: 4),
                          FilterChip(
                            selected: isSelected,
                            label: Text(isSelected ? '已选择' : '选择此项'),
                            onSelected: (_) => _toggleLocalSelect(currentRecord.id),
                            selectedColor: colorScheme.primary.withValues(alpha: 0.15),
                            checkmarkColor: colorScheme.primary,
                            labelStyle: TextStyle(
                              color: isSelected ? colorScheme.primary : colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // PageView
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _localRecords.length,
                onPageChanged: (index) {
                  setState(() {
                    _currentIndex = index;
                  });
                },
                itemBuilder: (context, index) {
                  final record = _localRecords[index];
                  return _buildRecordDetail(context, record, theme, colorScheme);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordDetail(
    BuildContext context,
    DiaryRecord record,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final tagColor = _tagColor(record.displayTag);
    final tagIcon = _tagIcon(record.displayTag);
    final fields = record.bodyState ?? {};

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Time and Tag Badge Row
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.access_time, size: 14, color: colorScheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      _formatTimeRange(record),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              if (record.displayTag.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: tagColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(tagIcon, size: 14, color: tagColor),
                      const SizedBox(width: 6),
                      Text(
                        record.displayTag,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: tagColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 20),

          // Body State fields (if any)
          if (fields.isNotEmpty) ...[
            Text(
              '记录数据',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
              child: Wrap(
                spacing: 16,
                runSpacing: 12,
                children: fields.entries.map((entry) {
                  if (entry.value == null || entry.value.toString().isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${entry.key}：',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      Text(
                        entry.value.toString(),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 20),
          ],

          // Content Box
          Text(
            '详细内容',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: colorScheme.outlineVariant.withValues(alpha: 0.3),
              ),
            ),
            child: Text(
              record.content.isNotEmpty ? record.content : '（无备注内容）',
              style: theme.textTheme.bodyMedium?.copyWith(
                height: 1.6,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Photos
          if (record.photos.isNotEmpty) ...[
            Text(
              '照片附件',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: record.photos.asMap().entries.map((entry) {
                final idx = entry.key;
                final photo = entry.value;
                return GestureDetector(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _FullScreenImageGallery(
                          photos: record.photos,
                          initialIndex: idx,
                        ),
                      ),
                    );
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: UnifiedImage(
                        imagePath: photo,
                        width: 100,
                        height: 100,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  // Mappings copied from DiaryItem
  static const _tagIcons = <String, IconData>{
    '睡眠': Icons.nightlight_round,
    '饮食': Icons.restaurant,
    '活动': Icons.directions_run,
    '记账': Icons.account_balance_wallet,
  };

  static const _defaultIcon = Icons.description_outlined;

  static const _tagColors = <String, Color>{
    '睡眠': Color(0xFF6366F1),
    '饮食': Color(0xFFF59E0B),
    '活动': Color(0xFF10B981),
    '记账': Color(0xFFEF4444),
  };

  static const _defaultColor = Color(0xFF6B7280);

  IconData _tagIcon(String displayTag) => _tagIcons[displayTag] ?? _defaultIcon;
  Color _tagColor(String displayTag) => _tagColors[displayTag] ?? _defaultColor;
}
