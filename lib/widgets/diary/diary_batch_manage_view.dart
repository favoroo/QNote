import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';
import 'package:qnote_flutter/widgets/diary/custom_date_range_picker.dart';

class DiaryBatchManageView extends ConsumerStatefulWidget {
  final List<String>? initialTags;
  final DateTimeRange? initialDateRange;

  const DiaryBatchManageView({
    super.key,
    this.initialTags,
    this.initialDateRange,
  });

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
    if (widget.initialTags != null) {
      _selectedTags.addAll(widget.initialTags!);
    }
    if (widget.initialDateRange != null) {
      _dateRange = widget.initialDateRange;
    }
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
    });
    _applyFilters();
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
    final result = await showDialog<DateTimeRange>(
      context: context,
      builder: (context) => CustomDateRangePickerDialog(
        initialDateRange: _dateRange,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
      ),
    );
    if (result != null) {
      setState(() {
        _dateRange = result;
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

  /// 快捷选择今天
  void _selectToday() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    setState(() {
      _dateRange = DateTimeRange(
        start: today,
        end: today,
      );
    });
    _applyFilters();
  }

  /// 快捷选择本周（周一到今天）
  void _selectThisWeek() {
    final now = DateTime.now();
    // weekday: 1=周一 ... 7=周日
    final monday = now.subtract(Duration(days: now.weekday - 1));
    setState(() {
      _dateRange = DateTimeRange(
        start: DateTime(monday.year, monday.month, monday.day),
        end: DateTime(now.year, now.month, now.day),
      );
    });
    _applyFilters();
  }

  /// 快捷选择本月（本月1号到今天）
  void _selectThisMonth() {
    final now = DateTime.now();
    setState(() {
      _dateRange = DateTimeRange(
        start: DateTime(now.year, now.month, 1),
        end: DateTime(now.year, now.month, now.day),
      );
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

  // 标签颜色配置，与 DiaryItem 保持一致
  static const _tagColors = <String, Color>{
    '睡眠': Color(0xFF6366F1),
    '饮食': Color(0xFFF59E0B),
    '活动': Color(0xFF10B981),
    '记账': Color(0xFFEF4444),
  };

  static const _defaultColor = Color(0xFF6B7280);

  Color _tagColor(String displayTag) => _tagColors[displayTag] ?? _defaultColor;

  String _formatDouble(dynamic val) {
    if (val == null) return '';
    final d = double.tryParse(val.toString());
    if (d == null) return val.toString();
    if (d == d.toInt()) return d.toInt().toString();
    return d.toString();
  }

  List<String> _buildAdditionalTags(TagEntry entry) {
    final tags = <String>[];
    final bs = entry.fields;
    final handledKeys = <String>{};

    if (entry.name == '睡眠') {
      final durationVal = _getVal(bs, ['duration', '时长', '睡眠时长']);
      if (durationVal != null) {
        final formatted = _formatDouble(durationVal);
        if (formatted.isNotEmpty) tags.add('$formatted小时');
      }
      handledKeys.addAll(['duration', '时长', '睡眠时长']);

      final qualityVal = _getVal(bs, ['quality', '质量', '睡眠质量']);
      if (qualityVal != null && qualityVal.toString().isNotEmpty) {
        tags.add(qualityVal.toString());
      }
      handledKeys.addAll(['quality', '质量', '睡眠质量']);

      final fallAsleepVal = _getVal(bs, ['fallAsleepTime', '入睡时间']);
      if (fallAsleepVal != null && fallAsleepVal.toString().isNotEmpty) {
        tags.add('入睡: ${fallAsleepVal.toString()}');
      }
      handledKeys.addAll(['fallAsleepTime', '入睡时间']);
    } else if (entry.name == '饮食') {
      final typeVal = _getVal(bs, ['type', 'item', '种类', '类别']);
      if (typeVal != null && typeVal.toString().isNotEmpty) tags.add(typeVal.toString());
      final ratingVal = _getVal(bs, ['rating', 'health', '评价']);
      if (ratingVal != null && ratingVal.toString().isNotEmpty) tags.add(ratingVal.toString());
      handledKeys.addAll(['type', 'item', '种类', '类别', 'rating', 'health', '评价']);
    } else if (entry.name == '活动') {
      final typeVal = _getVal(bs, ['type', 'item', '项目', '类型']);
      if (typeVal != null && typeVal.toString().isNotEmpty) tags.add(typeVal.toString());
      final durationVal = _getVal(bs, ['duration', '时长']);
      if (durationVal != null) {
        final formatted = _formatDouble(durationVal);
        if (formatted.isNotEmpty) tags.add('$formatted小时');
      }
      handledKeys.addAll(['type', 'item', '项目', '类型', 'duration', '时长']);
    } else if (entry.name == '健康') {
      final symptomVal = _getVal(bs, ['symptom', '症状']);
      if (symptomVal != null) {
        if (symptomVal is List) {
          for (final s in symptomVal) {
            if (s.toString().isNotEmpty) tags.add(s.toString());
          }
        } else if (symptomVal.toString().isNotEmpty) {
          tags.add(symptomVal.toString());
        }
      }
      final severityVal = _getVal(bs, ['severity', '严重程度']);
      if (severityVal != null && severityVal.toString().isNotEmpty) {
        tags.add(severityVal.toString());
      }
      final medicationVal = _getVal(bs, ['medication', '用药']);
      if (medicationVal != null && medicationVal.toString().isNotEmpty) {
        tags.add('💊 ${medicationVal.toString()}');
      }
      handledKeys.addAll(['symptom', '症状', 'severity', '严重程度', 'medication', '用药']);
    } else if (entry.name == '记账') {
      final categoryVal = _getVal(bs, ['_category', 'category', '收支类型', '收支']);
      String? direction;
      if (categoryVal != null) {
        final catStr = categoryVal.toString().toLowerCase();
        if (catStr == 'expense' || catStr == '支出') {
          direction = '支出';
        } else if (catStr == 'income' || catStr == '收入') {
          direction = '收入';
        }
      }
      if (direction == null) {
        if (bs.containsKey('type') || bs.containsKey('支出类型')) {
          direction = '支出';
        } else if (bs.containsKey('incomeType') || bs.containsKey('收入类型')) {
          direction = '收入';
        }
      }
      if (direction != null) tags.add(direction);
      final typeVal = _getVal(bs, ['type', 'incomeType', '支出类型', '收入类型', '分类', '类型']);
      if (typeVal != null && typeVal.toString().isNotEmpty) tags.add(typeVal.toString());
      final amountVal = _getVal(bs, ['amount', '金额', '钱数']);
      if (amountVal != null) {
        final formatted = _formatDouble(amountVal);
        if (formatted.isNotEmpty) tags.add('$formatted元');
      }
      handledKeys.addAll([
        '_category', 'category', '收支类型', '收支',
        'type', 'incomeType', '支出类型', '收入类型', '分类', '类型',
        'amount', '金额', '钱数'
      ]);
    }

    for (final f in bs.entries) {
      if (f.key.startsWith('_')) continue;
      final normKey = f.key.trim().toLowerCase();
      if (handledKeys.contains(normKey)) continue;

      final label = _getFieldLabel(entry.name, f.key, bs);
      final normLabel = label.trim().toLowerCase();
      if (handledKeys.contains(normLabel)) continue;

      final val = _formatFieldValue(entry.name, f.key, f.value);
      if (val.isNotEmpty) {
        tags.add('$label: $val');
      }
    }

    return tags;
  }

  dynamic _getVal(Map<String, dynamic> bs, List<String> keys) {
    for (final k in keys) {
      if (bs.containsKey(k)) return bs[k];
      final lowerK = k.toLowerCase();
      for (final entry in bs.entries) {
        if (entry.key.toLowerCase() == lowerK) return entry.value;
      }
    }
    return null;
  }

  String _getFieldLabel(String tagName, String key, Map<String, dynamic> fields) {
    final lowerKey = key.trim().toLowerCase();
    switch (lowerKey) {
      case 'duration':
        return '时长';
      case 'quality':
        return '睡眠质量';
      case 'fallasleeptime':
        return '入睡时间';
      case 'item':
        if (tagName == '饮食') return '种类';
        if (tagName == '活动') return '类型';
        return '项目';
      case 'type':
        if (tagName == '饮食') return '种类';
        if (tagName == '活动') return '类型';
        if (tagName == '记账') {
          final isIncome = fields['_category'] == 'income' || 
                           fields.containsKey('incomeType') || 
                           fields.containsKey('收入类型');
          return isIncome ? '收入类型' : '支出类型';
        }
        return '类型';
      case 'rating':
        return '评价';
      case 'health':
        return '评价';
      case 'amount':
        if (tagName == '记账') return '金额';
        return '数量';
      case 'incometype':
        if (tagName == '记账') return '收入类型';
        return '类型';
      default:
        final translations = {
          'duration': '时长',
          'quality': '质量',
          'item': '项目',
          'type': '类型',
          'rating': '评价',
          'health': '评价',
          'amount': '数量',
          'price': '价格',
          'cost': '费用',
          'location': '地点',
          'note': '备注',
          'remark': '备注',
        };
        return translations[lowerKey] ?? key;
    }
  }

  String _formatFieldValue(String tagName, String key, dynamic value) {
    final valStr = _formatDouble(value);
    if (valStr.isEmpty) return '';
    final lowerKey = key.trim().toLowerCase();
    if (tagName == '睡眠' && lowerKey == 'duration') {
      if (!valStr.contains('小时') && !valStr.contains('h')) {
        return '$valStr小时';
      }
    }
    if (tagName == '记账' && lowerKey == 'amount') {
      if (!valStr.contains('元') && !valStr.contains('￥') && !valStr.contains(r'$')) {
        return '$valStr元';
      }
    }
    return valStr;
  }

  Widget _buildTagAndFieldsRow(ThemeData theme, DiaryRecord record, ColorScheme colorScheme) {
    final rowItems = <Widget>[];

    if (record.tagEntries.isNotEmpty) {
      for (final entry in record.tagEntries) {
        final color = _tagColor(entry.name);
        
        // Add the primary tag pill (filled)
        rowItems.add(Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            entry.name,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
        ));

        // Add the additional fields (outlined)
        final additionalTags = _buildAdditionalTags(entry);
        for (final tagText in additionalTags) {
          rowItems.add(Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.02),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: color.withValues(alpha: 0.35),
                width: 1,
              ),
            ),
            child: Text(
              tagText,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color.withValues(alpha: 0.9),
                fontWeight: FontWeight.w500,
              ),
            ),
          ));
        }

        final showTime = entry.displayTime ?? entry.time;
        // 时间与记录主时间相同则不重复显示
        final recordTimeStr = DateFormat('HH:mm').format(record.startTime ?? record.time);
        if (showTime != null && showTime.isNotEmpty && showTime != recordTimeStr) {
          rowItems.add(Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              showTime,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                fontWeight: FontWeight.w500,
              ),
            ),
          ));
        }
      }
    } else if (record.displayTag.isNotEmpty) {
      // Just display tag if no tagEntries
      final color = _tagColor(record.displayTag);
      rowItems.add(Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          record.displayTag,
          style: theme.textTheme.labelSmall?.copyWith(
            color: color,
            fontWeight: FontWeight.bold,
          ),
        ),
      ));
    }

    if (rowItems.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          children: rowItems.map((item) {
            final isLast = rowItems.last == item;
            return Padding(
              padding: EdgeInsets.only(right: isLast ? 0 : 6),
              child: item,
            );
          }).toList(),
        ),
      ),
    );
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

  // 跳转编辑页
  Future<void> _editRecord(DiaryRecord record) async {
    await GoRouter.of(context).push('/diary/editor', extra: record);
    _applyFilters(); // 编辑返回后刷新列表
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
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.filter_list, size: 16, color: colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  '筛选条件',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _buildDateFilter(theme, colorScheme),
            const SizedBox(height: 10),
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
        // 快捷选择按钮
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 8,
            children: [
              ActionChip(
                label: const Text('今天'),
                onPressed: _selectToday,
                avatar: Icon(Icons.today, size: 16, color: colorScheme.primary),
              ),
              ActionChip(
                label: const Text('本周'),
                onPressed: _selectThisWeek,
                avatar: Icon(Icons.date_range, size: 16, color: colorScheme.primary),
              ),
              ActionChip(
                label: const Text('本月'),
                onPressed: _selectThisMonth,
                avatar: Icon(Icons.calendar_month, size: 16, color: colorScheme.primary),
              ),
            ],
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
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: colorScheme.primary.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.access_time, size: 12, color: colorScheme.primary),
                                  const SizedBox(width: 4),
                                  Text(
                                    _formatTimeRange(record),
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        _buildTagAndFieldsRow(theme, record, colorScheme),
                        const SizedBox(height: 6),
                        Text(
                          record.content.isNotEmpty ? record.content : '无备注内容',
                          maxLines: 8,
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
                    onTap: () => _editRecord(record),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                      child: Icon(
                        Icons.edit_outlined,
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
