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

  void _clearAllFilters() {
    setState(() {
      _dateRange = null;
      _selectedTags.clear();
    });
    _applyFilters();
  }

  void _showTagFilterBottomSheet() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tempSelectedTags = List<String>.from(_selectedTags);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              decoration: BoxDecoration(
                color: colorScheme.surface,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: colorScheme.outlineVariant.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '按标签筛选',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (tempSelectedTags.isNotEmpty)
                          GestureDetector(
                            onTap: () {
                              setSheetState(() {
                                tempSelectedTags.clear();
                              });
                            },
                            child: Text(
                              '清空已选',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (_allTags.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            '暂无可选标签',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                    else
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.45,
                        ),
                        child: SingleChildScrollView(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 10,
                            children: _allTags.map((tag) {
                              final isSelected = tempSelectedTags.contains(tag);
                              final tagColor = _tagColor(tag);
                              return FilterChip(
                                label: Text(tag),
                                selected: isSelected,
                                onSelected: (selected) {
                                  setSheetState(() {
                                    if (selected) {
                                      tempSelectedTags.add(tag);
                                    } else {
                                      tempSelectedTags.remove(tag);
                                    }
                                  });
                                },
                                selectedColor: tagColor.withValues(alpha: 0.18),
                                checkmarkColor: tagColor,
                                labelStyle: TextStyle(
                                  fontSize: 13,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                  color: isSelected ? tagColor : colorScheme.onSurface,
                                ),
                                side: BorderSide(
                                  color: isSelected
                                      ? tagColor.withValues(alpha: 0.6)
                                      : colorScheme.outlineVariant.withValues(alpha: 0.4),
                                  width: 1,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            child: const Text('取消'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: () {
                              setState(() {
                                _selectedTags.clear();
                                _selectedTags.addAll(tempSelectedTags);
                              });
                              _applyFilters();
                              Navigator.of(ctx).pop();
                            },
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            child: Text(
                              tempSelectedTags.isEmpty
                                  ? '全部展示'
                                  : '确定 (${tempSelectedTags.length})',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
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

      // 不在卡片底部标签显示，已在顶部时间段中体现
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

  /// 运动健康日结紧凑看板
  Widget _buildHealthSummaryContent(ThemeData theme, DiaryRecord record, ColorScheme colorScheme) {
    final bs = record.bodyState ?? {};
    final steps = (bs['steps'] as num?)?.toInt() ?? 0;
    final stepTarget = (bs['step_target'] as num?)?.toInt() ?? 8000;
    final calories = (bs['calories'] as num?)?.toDouble() ?? 0.0;
    final distanceMeters = (bs['distance_meters'] as num?)?.toDouble() ?? 0.0;
    final activeMinutes = (bs['active_minutes'] as num?)?.toInt() ?? 0;
    final sleepMinutes = (bs['sleep_duration_minutes'] as num?)?.toInt() ?? 0;
    final sleepScore = (bs['sleep_score'] as num?)?.toInt();
    final avgSpo2 = (bs['avg_spo2'] as num?)?.toInt();
    final avgStress = (bs['avg_stress'] as num?)?.toInt();
    final screenMs = (bs['screen_time_ms'] as num?)?.toInt() ?? 0;

    final progress = stepTarget > 0 ? (steps / stepTarget).clamp(0.0, 1.0) : 0.0;
    final isTargetReached = steps >= stepTarget;
    const brandGreen = Color(0xFF10B981);
    const sleepPurple = Color(0xFF6366F1);
    const activityOrange = Color(0xFFF97316);

    // 格式化屏幕时长
    String? screenStr;
    if (screenMs > 0) {
      final sMins = screenMs ~/ 60000;
      final sH = sMins ~/ 60;
      final sRem = sMins % 60;
      screenStr = sH > 0 ? (sRem > 0 ? '$sH小时$sRem分' : '$sH小时') : '$sMins分';
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 步数与消耗行
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: brandGreen.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: brandGreen.withValues(alpha: 0.15),
                width: 0.8,
              ),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.directions_walk_rounded, size: 16, color: brandGreen),
                    const SizedBox(width: 4),
                    Text(
                      NumberFormat('#,###').format(steps),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                        letterSpacing: -0.3,
                      ),
                    ),
                    Text(
                      ' 步',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: (isTargetReached ? brandGreen : colorScheme.primary).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        isTargetReached ? '已达标' : '目标 $stepTarget',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isTargetReached ? brandGreen : colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 3.5,
                    backgroundColor: colorScheme.outlineVariant.withValues(alpha: 0.2),
                    valueColor: const AlwaysStoppedAnimation(brandGreen),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '🔥 ${calories.toStringAsFixed(0)} kcal',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: activityOrange,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '⏱ $activeMinutes 分钟',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: const Color(0xFFD97706),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '📍 ${(distanceMeters / 1000).toStringAsFixed(2)} km',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: const Color(0xFF2563EB),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 睡眠与生理体征次级标签行
          if (sleepMinutes > 0 || avgSpo2 != null || screenStr != null) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (sleepMinutes > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: sleepPurple.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.nightlight_round, size: 10, color: sleepPurple),
                        const SizedBox(width: 3),
                        Text(
                          '${sleepMinutes ~/ 60}h${sleepMinutes % 60}m${sleepScore != null ? ' · $sleepScore分' : ''}',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: sleepPurple,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (avgSpo2 != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDC2626).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '血氧 $avgSpo2%',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFDC2626),
                      ),
                    ),
                  ),
                if (avgStress != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF8B5CF6).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '压力 $avgStress',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8B5CF6),
                      ),
                    ),
                  ),
                if (screenStr != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0284C7).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.phone_android_rounded, size: 10, color: Color(0xFF0284C7)),
                        const SizedBox(width: 3),
                        Text(
                          '屏幕 $screenStr',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF0284C7),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ],
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

  bool _isHealthDailySummary(DiaryRecord record) {
    final bs = record.bodyState ?? {};
    return (bs['source'] == 'mi_fitness' && bs['type'] == 'daily_summary') ||
        (record.tags.contains('运动健康') && bs.containsKey('steps'));
  }

  Widget _buildFilterCard(ThemeData theme, ColorScheme colorScheme) {
    final hasActiveFilter = _dateRange != null || _selectedTags.isNotEmpty;

    String dateLabel = '全部日期';
    if (_dateRange != null) {
      final start = _dateRange!.start;
      final end = _dateRange!.end;
      final isSameDay = start.year == end.year && start.month == end.month && start.day == end.day;
      if (isSameDay) {
        final now = DateTime.now();
        if (start.year == now.year && start.month == now.month && start.day == now.day) {
          dateLabel = '今天';
        } else {
          dateLabel = DateFormat('MM-dd').format(start);
        }
      } else {
        dateLabel = '${DateFormat('MM-dd').format(start)} ~ ${DateFormat('MM-dd').format(end)}';
      }
    }

    final String tagLabel;
    if (_selectedTags.isEmpty) {
      tagLabel = '全部标签';
    } else if (_selectedTags.length == 1) {
      tagLabel = _selectedTags.first;
    } else {
      tagLabel = '已选${_selectedTags.length}类';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          // 1. 日期筛选胶囊
          Expanded(
            child: InkWell(
              onTap: _pickDateRange,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: _dateRange != null
                      ? colorScheme.primary.withValues(alpha: 0.1)
                      : colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _dateRange != null
                        ? colorScheme.primary.withValues(alpha: 0.4)
                        : colorScheme.outlineVariant.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.calendar_today_rounded,
                      size: 14,
                      color: _dateRange != null ? colorScheme.primary : colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        dateLabel,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: _dateRange != null ? FontWeight.bold : FontWeight.w500,
                          color: _dateRange != null ? colorScheme.primary : colorScheme.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_dateRange != null)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _clearDateRange,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Icon(
                            Icons.close_rounded,
                            size: 14,
                            color: colorScheme.primary,
                          ),
                        ),
                      )
                    else
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 16,
                        color: colorScheme.onSurfaceVariant,
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),

          // 2. 标签多选胶囊（点击呼出二级抽屉）
          Expanded(
            child: InkWell(
              onTap: _showTagFilterBottomSheet,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: _selectedTags.isNotEmpty
                      ? colorScheme.primary.withValues(alpha: 0.1)
                      : colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _selectedTags.isNotEmpty
                        ? colorScheme.primary.withValues(alpha: 0.4)
                        : colorScheme.outlineVariant.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.filter_alt_outlined,
                      size: 14,
                      color: _selectedTags.isNotEmpty ? colorScheme.primary : colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        tagLabel,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: _selectedTags.isNotEmpty ? FontWeight.bold : FontWeight.w500,
                          color: _selectedTags.isNotEmpty ? colorScheme.primary : colorScheme.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_selectedTags.isNotEmpty)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          setState(() {
                            _selectedTags.clear();
                          });
                          _applyFilters();
                        },
                        child: Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Icon(
                            Icons.close_rounded,
                            size: 14,
                            color: colorScheme.primary,
                          ),
                        ),
                      )
                    else
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 16,
                        color: colorScheme.onSurfaceVariant,
                      ),
                  ],
                ),
              ),
            ),
          ),

          // 3. 一键重置（当有任意过滤条件激活时显示）
          if (hasActiveFilter) ...[
            const SizedBox(width: 6),
            InkWell(
              onTap: _clearAllFilters,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(
                  Icons.refresh_rounded,
                  size: 18,
                  color: colorScheme.primary,
                ),
              ),
            ),
          ],
        ],
      ),
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
        final tagColor = _tagColor(record.displayTag);
        // P1-25: 隔离每条记录的重绘，选中态变化时不影响其他记录
        return RepaintBoundary(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GestureDetector(
              onTap: () => _toggleSelect(record.id),
              onLongPress: () => _openRecordDetails(record),
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
                                  color: tagColor.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _isHealthDailySummary(record)
                                          ? Icons.favorite_rounded
                                          : Icons.access_time,
                                      size: 12,
                                      color: _isHealthDailySummary(record)
                                          ? const Color(0xFF10B981)
                                          : tagColor,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      _formatTimeRange(record),
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: _isHealthDailySummary(record)
                                            ? const Color(0xFF10B981)
                                            : tagColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (_isHealthDailySummary(record)) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF10B981).withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Text(
                                    '系统同步',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF10B981),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (_isHealthDailySummary(record))
                            _buildHealthSummaryContent(theme, record, colorScheme)
                          else ...[
                            _buildTagAndFieldsRow(theme, record, colorScheme),
                            const SizedBox(height: 6),
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Text(
                                record.content.isNotEmpty ? record.content : '无备注内容',
                                maxLines: 8,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: record.content.isNotEmpty
                                      ? colorScheme.onSurface
                                      : colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                                ),
                              ),
                            ),
                          ],
                          if (record.photos.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: GestureDetector(
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
                  color: tagColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.access_time, size: 14, color: tagColor),
                    const SizedBox(width: 6),
                    Text(
                      _formatTimeRange(record),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: tagColor,
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
              _isHealthDailySummary(record) ? '健康看板数据' : '记录数据',
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
                  final key = entry.key;
                  if (key.startsWith('_') || key == 'source' || key == 'type') {
                    return const SizedBox.shrink();
                  }
                  String label = key;
                  String val = entry.value.toString();
                  if (key == 'steps') label = '步数';
                  if (key == 'step_target') label = '目标步数';
                  if (key == 'calories') label = '卡路里';
                  if (key == 'distance_meters') label = '距离(米)';
                  if (key == 'active_minutes') label = '有效活动';
                  if (key == 'sleep_duration_minutes') label = '睡眠时长(分)';
                  if (key == 'sleep_score') label = '睡眠得分';
                  if (key == 'avg_spo2') label = '平均血氧';
                  if (key == 'avg_stress') label = '平均压力';
                  if (key == 'screen_time_ms') {
                    label = '屏幕时长';
                    final sMins = (entry.value as num).toInt() ~/ 60000;
                    val = '${sMins ~/ 60}小时${sMins % 60}分';
                  }

                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$label：',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      Text(
                        val,
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

  bool _isHealthDailySummary(DiaryRecord record) {
    final bs = record.bodyState ?? {};
    return (bs['source'] == 'mi_fitness' && bs['type'] == 'daily_summary') ||
        (record.tags.contains('运动健康') && bs.containsKey('steps'));
  }
}
