import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:qnote_flutter/core/health/screen_usage_service.dart';
import 'package:qnote_flutter/core/theme/tag_colors.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/screen_usage_info.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:qnote_flutter/widgets/action_menu.dart';
import 'package:qnote_flutter/widgets/ai/q_avatar.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';
import 'package:qnote_flutter/widgets/animated_gradient_border.dart';

class DiaryItem extends StatefulWidget {
  final DiaryRecord record;
  final VoidCallback? onTap;
  final void Function(DiaryRecord)? onEdit;
  final void Function(DiaryRecord)? onDelete;
  final VoidCallback? onAiExtract;
  final VoidCallback? onAiExtractLongPress;
  /// 「给小Q」引用该条记录（非 null 时操作菜单与卡片长按展示该入口）
  final void Function(DiaryRecord)? onQuoteToQ;
  final bool isExtracting;
  final VoidCallback? onUndo;
  final bool isUndoable;
  final Animation<double>? undoAnimation;

  const DiaryItem({
    super.key,
    required this.record,
    this.onTap,
    this.onEdit,
    this.onDelete,
    this.onAiExtract,
    this.onAiExtractLongPress,
    this.onQuoteToQ,
    this.isExtracting = false,
    this.onUndo,
    this.isUndoable = false,
    this.undoAnimation,
  });

  @override
  State<DiaryItem> createState() => _DiaryItemState();
}

class _DiaryItemState extends State<DiaryItem> {
  final _cardKey = GlobalKey();

  DiaryRecord get record => widget.record;
  VoidCallback? get onTap => widget.onTap;
  void Function(DiaryRecord)? get onEdit => widget.onEdit;
  void Function(DiaryRecord)? get onDelete => widget.onDelete;
  VoidCallback? get onAiExtract => widget.onAiExtract;
  VoidCallback? get onAiExtractLongPress => widget.onAiExtractLongPress;
  void Function(DiaryRecord)? get onQuoteToQ => widget.onQuoteToQ;
  bool get isExtracting => widget.isExtracting;
  VoidCallback? get onUndo => widget.onUndo;
  bool get isUndoable => widget.isUndoable;
  Animation<double>? get undoAnimation => widget.undoAnimation;

  /// 当日屏幕使用时间（仅在日结卡片无持久化屏幕时长时异步获取并补全展示）
  TodayScreenUsage? _liveScreenUsage;
  bool _hasFetchedLiveScreenUsage = false;

  @override
  void initState() {
    super.initState();
    _checkAndFetchLiveScreenUsage();
  }

  @override
  void didUpdateWidget(covariant DiaryItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.record.id != widget.record.id ||
        oldWidget.record.bodyState?['screen_time_ms'] != widget.record.bodyState?['screen_time_ms']) {
      _hasFetchedLiveScreenUsage = false;
      _checkAndFetchLiveScreenUsage();
    }
  }

  void _checkAndFetchLiveScreenUsage() {
    if (!_isHealthDailySummary) return;
    final bs = record.bodyState;
    if (bs != null && bs['screen_time_ms'] != null) {
      return; // 已持久化屏幕使用时间，无需现查
    }
    if (_hasFetchedLiveScreenUsage) return;
    _hasFetchedLiveScreenUsage = true;

    final service = ScreenUsageService();
    if (!service.isSupported) return;

    final dateStr = bs?['date'] as String?;
    final cardDate = dateStr != null ? DateTime.tryParse(dateStr) : record.time;
    final targetDate = cardDate ?? record.time;

    service.hasPermission().then((authed) {
      if (!authed || !mounted) return;
      service.getUsageForDate(targetDate, limit: 5).then((usage) {
        if (!mounted || usage == null || usage.totalTimeMs <= 0) return;
        setState(() {
          _liveScreenUsage = usage;
        });
      }).catchError((_) {});
    }).catchError((_) {});
  }

  /// 卡片操作菜单：通过长按卡片触发；
  /// 配置了 onQuoteToQ 时追加「给小Q」引用入口
  void _showActionMenu() {
    HapticFeedback.lightImpact();
    ActionMenu.show(
      context: context,
      key: _cardKey,
      items: [
        if (onQuoteToQ != null)
          ActionMenuItem(
            iconWidget: QIcon(
              size: 20,
              color: Theme.of(context).colorScheme.primary,
            ),
            label: '给小Q',
            onTap: () => onQuoteToQ?.call(record),
          ),
        if (!_isHealthDailySummary) ...[
          ActionMenuItem(
            icon: Icons.edit,
            label: '编辑',
            onTap: () => onEdit?.call(record),
          ),
          ActionMenuItem(
            icon: Icons.delete_outline,
            label: '删除',
            isDestructive: true,
            onTap: () => onDelete?.call(record),
          ),
        ],
      ],
    );
  }

  static const _tagIcons = <String, IconData>{
    '睡眠': Icons.nightlight_round,
    '饮食': Icons.restaurant,
    '活动': Icons.directions_run,
    '记账': Icons.account_balance_wallet,
    '运动健康': Icons.favorite_rounded,
    '健康': Icons.favorite_rounded,
  };

  static const _defaultIcon = Icons.description_outlined;

  static const _tagColors = TagColors.map;

  static const _defaultColor = TagColors.defaultTag;

  /// 正文与图片相对标签 pill 的左侧缩进，避免视觉上“凸出”在标签外
  static const _contentIndent = 4.0;

  IconData _tagIcon(String displayTag) => _tagIcons[displayTag] ?? _defaultIcon;

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
      if (typeVal != null && typeVal.toString().isNotEmpty) {
        tags.add(typeVal.toString());
      }
      final ratingVal = _getVal(bs, ['rating', 'health', '评价']);
      if (ratingVal != null && ratingVal.toString().isNotEmpty) {
        tags.add(ratingVal.toString());
      }
      handledKeys.addAll([
        'type',
        'item',
        '种类',
        '类别',
        'rating',
        'health',
        '评价',
      ]);
    } else if (entry.name == '活动') {
      final typeVal = _getVal(bs, ['type', 'item', '项目', '类型']);
      final subTypeVal = _getVal(bs, ['sub_type', 'subtype', '子类型', 'sport_type', '运动项目']);

      // 优先展示具体运动项目（如 户外跑步、户外骑行），避免出现原始的 sub_type: 英文键
      if (subTypeVal != null && subTypeVal.toString().isNotEmpty) {
        tags.add(subTypeVal.toString());
      } else if (typeVal != null && typeVal.toString().isNotEmpty) {
        tags.add(typeVal.toString());
      }

      final durationVal = _getVal(bs, ['duration', '时长']);
      if (durationVal != null) {
        final formatted = _formatDouble(durationVal);
        if (formatted.isNotEmpty) tags.add('$formatted小时');
      }

      final distVal = _getVal(bs, ['distance_km', 'distance', '距离']);
      if (distVal != null && distVal.toString().isNotEmpty) {
        final formatted = _formatDouble(distVal);
        if (formatted.isNotEmpty) tags.add('${formatted}km');
      }

      final calVal = _getVal(bs, ['calories', 'cal', '卡路里', '消耗']);
      if (calVal != null && calVal.toString().isNotEmpty) {
        final formatted = _formatDouble(calVal);
        if (formatted.isNotEmpty) tags.add('${formatted}kcal');
      }

      final hrVal = _getVal(bs, ['avg_hr', 'heart_rate', '心率', '平均心率']);
      if (hrVal != null && hrVal.toString().isNotEmpty) {
        final formatted = _formatDouble(hrVal);
        if (formatted.isNotEmpty) tags.add('${formatted}bpm');
      }

      final paceVal = _getVal(bs, ['avg_pace', 'pace', '配速', '平均配速']);
      if (paceVal != null && paceVal.toString().isNotEmpty) {
        tags.add(paceVal.toString());
      }

      handledKeys.addAll([
        'type',
        'item',
        '项目',
        '类型',
        'sub_type',
        'subtype',
        '子类型',
        'sport_type',
        '运动项目',
        'duration',
        '时长',
        'distance_km',
        'distance',
        '距离',
        'calories',
        'cal',
        '卡路里',
        '消耗',
        'avg_hr',
        'heart_rate',
        '心率',
        '平均心率',
        'avg_pace',
        'pace',
        '配速',
        '平均配速',
      ]);
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
      handledKeys.addAll([
        'symptom',
        '症状',
        'severity',
        '严重程度',
        'medication',
        '用药',
      ]);
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
      final typeVal = _getVal(bs, [
        'type',
        'incomeType',
        '支出类型',
        '收入类型',
        '分类',
        '类型',
      ]);
      if (typeVal != null && typeVal.toString().isNotEmpty) {
        tags.add(typeVal.toString());
      }
      final amountVal = _getVal(bs, ['amount', '金额', '钱数']);
      if (amountVal != null) {
        final formatted = _formatDouble(amountVal);
        if (formatted.isNotEmpty) tags.add('$formatted元');
      }
      handledKeys.addAll([
        '_category',
        'category',
        '收支类型',
        '收支',
        'type',
        'incomeType',
        '支出类型',
        '收入类型',
        '分类',
        '类型',
        'amount',
        '金额',
        '钱数',
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

  String _getFieldLabel(
    String tagName,
    String key,
    Map<String, dynamic> fields,
  ) {
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
          final isIncome =
              fields['_category'] == 'income' ||
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
          'sub_type': '项目',
          'subtype': '项目',
          'distance_km': '距离',
          'distance': '距离',
          'calories': '消耗',
          'cal': '消耗',
          'avg_hr': '心率',
          'heart_rate': '心率',
          'avg_pace': '配速',
          'pace': '配速',
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
      if (!valStr.contains('元') &&
          !valStr.contains('￥') &&
          !valStr.contains(r'$')) {
        return '$valStr元';
      }
    }
    if (lowerKey == 'distance_km' || lowerKey == 'distance') {
      if (!valStr.toLowerCase().contains('km') && !valStr.contains('公里') && !valStr.contains('米')) {
        return '${valStr}km';
      }
    }
    if (lowerKey == 'calories' || lowerKey == 'cal') {
      if (!valStr.toLowerCase().contains('kcal') && !valStr.contains('卡')) {
        return '${valStr}kcal';
      }
    }
    if (lowerKey == 'avg_hr' || lowerKey == 'heart_rate') {
      if (!valStr.toLowerCase().contains('bpm') && !valStr.contains('次')) {
        return '${valStr}bpm';
      }
    }
    return valStr;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tagColor = _tagColor(record.displayTag);
    final hasMultipleTags = record.tagEntries.length > 1;

    return IntrinsicHeight(
      child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 48,
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              Positioned(
                top: 0,
                bottom: 0,
                child: Container(
                  width: 2,
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
              Positioned(
                top: 12,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: tagColor.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _tagIcon(record.displayTag),
                        size: 14,
                        color: tagColor,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16, right: 12),
            child: GestureDetector(
              onTap: onTap,
              // 长按卡片弹出操作菜单（日结卡片仅保留「给小Q」，普通卡片含「给小Q/编辑/删除」）
              onLongPress: _showActionMenu,
              behavior: HitTestBehavior.opaque,
              child: AnimatedGradientBorder(
                isAnimating: isExtracting,
                borderRadius: 16,
                strokeWidth: 2,
                child: Container(
                  key: _cardKey,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isExtracting
                          ? Colors.transparent
                          : tagColor.withValues(alpha: 0.15),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: tagColor.withValues(alpha: 0.03),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.01),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      SingleChildScrollView(
                        physics: const NeverScrollableScrollPhysics(),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildHeader(
                              theme,
                              tagColor,
                              categoryTag: !hasMultipleTags && record.displayTag.isNotEmpty
                                  ? record.displayTag
                                  : null,
                            ),
                            if (_isHealthDailySummary)
                              _buildHealthDailySummaryCard(theme, tagColor)
                            else if (hasMultipleTags)
                              _buildMultiTagSections(theme)
                            else ...[
                              _buildTagAndFieldsRow(theme, tagColor),
                              _buildSingleTagContent(theme, tagColor),
                            ],
                            if (record.photos.isNotEmpty)
                              Builder(
                                builder: (context) {
                                  final screenWidth = MediaQuery.of(
                                    context,
                                  ).size.width;
                                  final maxWidth =
                                      screenWidth - 132 - _contentIndent;
                                  const spacing = 6.0;
                                  final itemWidth =
                                      ((maxWidth - spacing * 2 - 2.0) / 3)
                                          .clamp(50.0, 70.0);
                                  return Padding(
                                    padding: const EdgeInsets.only(
                                      left: _contentIndent,
                                      top: 4,
                                    ),
                                    child: Wrap(
                                      spacing: spacing,
                                      runSpacing: spacing,
                                      children: record.photos.asMap().entries.map((entry) {
                                        final index = entry.key;
                                        final photo = entry.value;
                                        return GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () {
                                            Navigator.of(context).push(
                                              MaterialPageRoute(
                                                builder: (_) => FullScreenImageGallery(
                                                  images: record.photos,
                                                  initialIndex: index,
                                                ),
                                              ),
                                            );
                                          },
                                          child: UnifiedImage(
                                            imagePath: photo,
                                            width: itemWidth,
                                            height: itemWidth,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                      if (onAiExtract != null && !_isHealthDailySummary)
                        Positioned(
                          bottom: -22,
                          right: -24,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: isUndoable ? onUndo : onAiExtract,
                            onLongPress: isUndoable
                                ? null
                                : (isExtracting
                                      ? null
                                      : onAiExtractLongPress),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surface,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: (isUndoable
                                              ? theme.colorScheme.error
                                              : tagColor)
                                          .withValues(alpha: 0.2),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: isUndoable
                                    ? (undoAnimation != null
                                          ? AnimatedBuilder(
                                              animation: undoAnimation!,
                                              builder: (context, child) {
                                                return Stack(
                                                  alignment: Alignment.center,
                                                  children: [
                                                    SizedBox(
                                                      width: 28,
                                                      height: 28,
                                                      child: CustomPaint(
                                                        painter:
                                                            _UndoCountdownPainter(
                                                          progress:
                                                              undoAnimation!
                                                                  .value,
                                                          color: theme
                                                              .colorScheme
                                                              .error,
                                                        ),
                                                      ),
                                                    ),
                                                    child!,
                                                  ],
                                                );
                                              },
                                              child: Icon(
                                                Icons.undo,
                                                size: 14,
                                                color:
                                                    theme.colorScheme.error,
                                              ),
                                            )
                                          : Icon(
                                              Icons.undo,
                                              size: 14,
                                              color: theme.colorScheme.error,
                                            ))
                                    : isExtracting
                                    ? Center(
                                        child: SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.0,
                                            color: tagColor,
                                          ),
                                        ),
                                      )
                                    : Icon(
                                        Icons.auto_awesome,
                                        size: 16,
                                        color: tagColor,
                                      ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, Color primaryTagColor, {String? categoryTag}) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 时间胶囊
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
              decoration: BoxDecoration(
                color: primaryTagColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.access_time_filled,
                    size: 13,
                    color: primaryTagColor,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _formatTimeRangeWithDate(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: primaryTagColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            // 种类标签（并列在时间右侧，单行不换行）
            if (categoryTag != null && categoryTag.isNotEmpty) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                decoration: BoxDecoration(
                  color: primaryTagColor,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: primaryTagColor.withValues(alpha: 0.22),
                      blurRadius: 4,
                      offset: const Offset(0, 1.5),
                    ),
                  ],
                ),
                child: Text(
                  categoryTag,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
      );
  }

  Widget _buildTagAndFieldsRow(ThemeData theme, Color primaryTagColor) {
    final rowItems = <Widget>[];

    if (record.tagEntries.isNotEmpty) {
      for (final entry in record.tagEntries) {
        final color = _tagColor(entry.name);

        // 仅添加属性字段胶囊（种类标签已在卡片头部第一行并列展示，单标签模式下无需在此重复显示）
        final additionalTags = _buildAdditionalTags(entry);
        for (final tagText in additionalTags) {
          rowItems.add(
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                tagText,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color.withValues(alpha: 0.9),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          );
        }

        final showTime = entry.displayTime ?? entry.time;
        if (showTime != null &&
            showTime.isNotEmpty &&
            !_isTagTimeDuplicate(entry)) {
          rowItems.add(
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                showTime,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.7,
                  ),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          );
        }
      }
    }

    // 若没有额外的属性标签与独立时间，整行直接收起，避免占用纵向空间
    if (rowItems.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 6),
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

  Widget _buildTagEntryPills(
    ThemeData theme,
    TagEntry entry, {
    bool showIcon = false,
    String? showTime,
  }) {
    final color = _tagColor(entry.name);
    final icon = _tagIcon(entry.name);

    final rowItems = <Widget>[];

    // 1. Tag name pill (filled)
    rowItems.add(
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.25),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showIcon) ...[
              Icon(icon, size: 12, color: Colors.white),
              const SizedBox(width: 4),
            ],
            Text(
              entry.name,
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );

    // 2. Field pills (outlined)
    final additionalTags = _buildAdditionalTags(entry);
    for (final tagText in additionalTags) {
      rowItems.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            tagText,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color.withValues(alpha: 0.9),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    // 3. Optional time display
    if (showTime != null &&
        showTime.isNotEmpty &&
        !_isTagTimeDuplicate(entry)) {
      rowItems.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            showTime,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      );
    }

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: rowItems,
    );
  }

  Widget _buildMultiTagSections(ThemeData theme) {
    final sections = <Widget>[];

    for (int i = 0; i < record.tagEntries.length; i++) {
      final entry = record.tagEntries[i];

      if (i > 0) {
        sections.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Divider(
              height: 1,
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
        );
      }

      sections.add(
        _buildTagEntryPills(
          theme,
          entry,
          showIcon: true,
          showTime: entry.displayTime ?? entry.time,
        ),
      );
    }

    final richContent = _buildRichContent(
      context: theme,
      text: record.content,
      bodyState: record.bodyState,
      tag: record.displayTag,
      leftPadding: _contentIndent,
      isMultiTag: true,
    );
    if (richContent != null) {
      sections.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Divider(
            height: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
      );
      sections.add(richContent);
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: sections,
      ),
    );
  }

  Widget _buildSingleTagContent(ThemeData theme, Color tagColor) {
    final richContent = _buildRichContent(
      context: theme,
      text: record.content,
      bodyState: record.bodyState,
      tag: record.displayTag,
      leftPadding: _contentIndent,
    );
    if (richContent == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        richContent,
      ],
    );
  }

  Widget? _buildRichContent({
    required ThemeData context,
    String? text,
    Map<String, dynamic>? bodyState,
    String? tag,
    double leftPadding = 0,
    bool isMultiTag = false,
  }) {
    String cleanText = text ?? '';
    if (cleanText.isEmpty) return null;

    final theme = context;
    if (tag != null && tag.isNotEmpty && cleanText.startsWith('【$tag】')) {
      cleanText = cleanText.substring(tag.length + 2).trim();
    }

    if (cleanText.isEmpty) return null;

    final rawLines = cleanText.split('\n');
    final displayLines = <String>[];
    final remarkLines = <String>[];
    bool inRemarkSection = false;

    final keysToSkip = {
      'duration',
      'quality',
      'fallasleeptime',
      'type',
      'rating',
      'item',
      'amount',
      'incometype',
      'symptom',
      'severity',
      'notes',
      'note',
      'remark',
      'remarks',
      'health',
      'medication',
      '时长',
      '质量',
      '入睡时间',
      '类型',
      '评价',
      '项目',
      '金额',
      '收入类型',
      '症状',
      '严重程度',
      '备注',
      '种类',
      '睡眠质量',
      '类别',
      '用药',
    };

    String normalizeKey(String key) {
      return key.trim().toLowerCase().replaceAll(
        RegExp(r'[\s\(_\)（）\-:]+'),
        '',
      );
    }

    for (final entry in record.tagEntries) {
      for (final f in entry.fields.entries) {
        keysToSkip.add(normalizeKey(f.key));
        final label = _getFieldLabel(entry.name, f.key, entry.fields);
        keysToSkip.add(normalizeKey(label));
      }
    }

    for (final line in rawLines) {
      final trimmedLine = line.trim();
      if (trimmedLine.isEmpty) continue;

      if (inRemarkSection) {
        remarkLines.add(trimmedLine);
        continue;
      }

      if (trimmedLine.startsWith('备注：')) {
        inRemarkSection = true;
        final rem = trimmedLine.substring(3).trim();
        if (rem.isNotEmpty) remarkLines.add(rem);
        continue;
      } else if (trimmedLine.startsWith('备注:')) {
        inRemarkSection = true;
        final rem = trimmedLine.substring(3).trim();
        if (rem.isNotEmpty) remarkLines.add(rem);
        continue;
      }

      if (!trimmedLine.contains(':') && !trimmedLine.contains('：')) {
        displayLines.add(trimmedLine);
        continue;
      }

      // 支持逗号、分号及竖线(| / ｜)拆分多项属性与详细指标
      final regExp = RegExp(r'([^:：,，;；|｜]+)([:：])\s*([^,，;；|｜]+)([,，;；|｜]?)');
      final matches = regExp.allMatches(trimmedLine);

      if (matches.isEmpty) {
        displayLines.add(trimmedLine);
        continue;
      }

      final remainingSegments = <String>[];
      int lastIndex = 0;

      for (final match in matches) {
        final key = match.group(1)?.trim() ?? '';
        final normKey = normalizeKey(key);
        String lastPartNorm = '';
        if (key.contains('-')) {
          lastPartNorm = normalizeKey(key.split('-').last);
        }
        final val = match.group(3)?.trim() ?? '';

        bool shouldSkip = false;
        for (final skipKey in keysToSkip) {
          if (normKey == skipKey ||
              (normKey.length <= 4 && normKey.contains(skipKey))) {
            shouldSkip = true;
            break;
          }
          if (lastPartNorm.isNotEmpty && lastPartNorm == skipKey) {
            shouldSkip = true;
            break;
          }
        }

        if (shouldSkip) {
          lastIndex = match.end;
          continue;
        }

        final colon = match.group(2) ?? '：';
        remainingSegments.add('$key$colon$val');
        lastIndex = match.end;
      }

      if (lastIndex < trimmedLine.length) {
        final suffix = trimmedLine
            .substring(lastIndex)
            .trim()
            .replaceAll(RegExp(r'^[，,;；|｜\s]+|[，,;；|｜\s]+$'), '');
        if (suffix.isNotEmpty) {
          final normSuffix = normalizeKey(suffix);
          bool suffixShouldSkip = false;
          for (final skipKey in keysToSkip) {
            if (normSuffix == skipKey) {
              suffixShouldSkip = true;
              break;
            }
          }
          if (!suffixShouldSkip) {
            remainingSegments.add(suffix);
          }
        }
      }

      if (remainingSegments.isNotEmpty) {
        displayLines.add(remainingSegments.join(' · '));
      }
    }

    final elements = <Widget>[];

    for (final line in displayLines) {
      elements.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            line,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 13,
              height: 1.6,
            ),
          ),
        ),
      );
    }

    for (final line in remarkLines) {
      elements.add(
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 2),
          child: Text(
            line,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
              fontSize: 13,
              height: 1.6,
            ),
          ),
        ),
      );
    }

    if (elements.isEmpty) return null;

    return Padding(
      padding: EdgeInsets.only(left: leftPadding, top: 4, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: elements,
      ),
    );
  }

  String _formatTimeRangeWithDate() {
    final start = record.startTime ?? record.time;
    // 小米运动健康日结汇总卡片固定在每天 23:00，仅展示时间刻度，不重复展开冗长起止
    if (_isHealthDailySummary) {
      return DateFormat.Hm().format(start);
    }
    final startDateStr = DateFormat('MM-dd').format(start);
    final startStr = DateFormat.Hm().format(start);

    if (record.endTime != null) {
      final end = record.endTime!;
      final endStr = DateFormat.Hm().format(end);

      final isCrossDate =
          start.year != end.year ||
          start.month != end.month ||
          start.day != end.day;

      if (isCrossDate) {
        final endDateStr = DateFormat('MM-dd').format(end);
        return '$startDateStr $startStr → $endDateStr $endStr';
      }
      return '$startDateStr $startStr → $endStr';
    }
    return '$startDateStr $startStr';
  }

  bool _isTagTimeDuplicate(TagEntry entry) {
    // 1. 如果该记录只有一个标签（单标签模式），顶部的 Header 已经完整展示了整条记录的时间范围，
    // 此时标签旁的局部时间纯属多余，直接判定为重复以隐藏
    if (record.tagEntries.length <= 1) {
      return true;
    }

    final recordStart = record.startTime ?? record.time;
    final recordStartHour = recordStart.hour;
    final recordStartMinute = recordStart.minute;

    if (entry.startHour == null || entry.startMinute == null) {
      // 容错：如果 startHour 没解析出来但 entry.time 与起始时间字符串相同，也判定为重复
      final startHm = DateFormat.Hm().format(recordStart);
      if (entry.time != null &&
          (entry.time == startHm || entry.time!.startsWith(startHm))) {
        return true;
      }
      return false;
    }

    final isStartSame =
        entry.startHour == recordStartHour &&
        entry.startMinute == recordStartMinute;
    if (!isStartSame) return false;

    // 当起始时分与记录起始时分一致时：
    if (record.endTime == null) {
      return entry.endHour == null;
    } else {
      // 记录具有结束时间（时段如 08:30 → 08:44）：
      // 若标签本身未设置结束时间（entry.endHour == null），说明它仅代表记录起始时刻，
      // 在卡片顶部已显示完整起止时间的情况下属于起点冗余，直接返回 true 进行隐藏
      if (entry.endHour == null) {
        return true;
      }

      final recordEndHour = record.endTime!.hour;
      final recordEndMinute = record.endTime!.minute;
      return entry.endHour == recordEndHour &&
          entry.endMinute == recordEndMinute;
    }
  }

  bool get _isHealthDailySummary {
    final bs = record.bodyState;
    if (bs == null) return false;
    return bs['source'] == 'mi_fitness' && bs['type'] == 'daily_summary';
  }

  /// 专属「运动健康」高颜值日结卡片渲染
  Widget _buildHealthDailySummaryCard(ThemeData theme, Color primaryColor) {
    final colorScheme = theme.colorScheme;
    final bs = record.bodyState ?? {};

    final steps = (bs['steps'] as num?)?.toInt() ?? 0;
    final stepTarget = (bs['step_target'] as num?)?.toInt() ?? 8000;
    final calories = (bs['calories'] as num?)?.toDouble() ?? 0.0;
    final distanceMeters = (bs['distance_meters'] as num?)?.toDouble() ?? 0.0;
    final activeMinutes = (bs['active_minutes'] as num?)?.toInt() ?? 0;
    final standingCount = (bs['standing_count'] as num?)?.toInt() ?? 0;

    final sleepMinutes = (bs['sleep_duration_minutes'] as num?)?.toInt() ?? 0;
    final sleepScore = (bs['sleep_score'] as num?)?.toInt();
    final deepSleep = (bs['deep_sleep_minutes'] as num?)?.toInt() ?? 0;
    final lightSleep = (bs['light_sleep_minutes'] as num?)?.toInt() ?? 0;
    final remSleep = (bs['rem_sleep_minutes'] as num?)?.toInt() ?? 0;
    final awakeMinutes = (bs['awake_minutes'] as num?)?.toInt() ?? 0;
    final sleepStartRaw = bs['sleep_start_time'] as String?;
    final sleepEndRaw = bs['sleep_end_time'] as String?;
    // 解析完整 ISO8601 时间戳，兼容旧数据 HH:mm 格式
    final sleepStartDt = sleepStartRaw != null ? DateTime.tryParse(sleepStartRaw) : null;
    final sleepEndDt = sleepEndRaw != null ? DateTime.tryParse(sleepEndRaw) : null;
    String? fmtHm(DateTime dt) =>
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    // 跨午夜睡眠展示「昨晚 HH:mm ~ 今早 HH:mm」，同天/旧数据展示「HH:mm ~ HH:mm」
    final String? sleepTimeDisplay;
    if (sleepStartDt != null && sleepEndDt != null) {
      final crossMidnight = sleepStartDt.day != sleepEndDt.day ||
          sleepStartDt.month != sleepEndDt.month ||
          sleepStartDt.year != sleepEndDt.year;
      sleepTimeDisplay = crossMidnight
          ? '昨晚 ${fmtHm(sleepStartDt)} ~ 今早 ${fmtHm(sleepEndDt)}'
          : '${fmtHm(sleepStartDt)} ~ ${fmtHm(sleepEndDt)}';
    } else {
      sleepTimeDisplay = (sleepStartRaw != null && sleepEndRaw != null)
          ? '$sleepStartRaw ~ $sleepEndRaw'
          : null;
    }

    final restingHr = (bs['resting_heart_rate'] as num?)?.toInt();
    final avgSpo2 = (bs['avg_spo2'] as num?)?.toInt();
    final avgStress = (bs['avg_stress'] as num?)?.toInt();

    final sportsRaw = bs['sports'] as List<dynamic>? ?? [];

    final progress = stepTarget > 0 ? (steps / stepTarget).clamp(0.0, 1.0) : 0.0;
    final isTargetReached = steps >= stepTarget;

    const brandGreen = Color(0xFF10B981);
    const sleepPurple = Color(0xFF6366F1);
    const screenBlue = Color(0xFF0284C7);

    // 屏幕使用时长（优先使用持久化数据，若无则使用当日异步检测补全数据）
    final screenMs = (bs['screen_time_ms'] as num?)?.toInt() ?? _liveScreenUsage?.totalTimeMs ?? 0;
    final screenYesterdayMs = (bs['screen_yesterday_time_ms'] as num?)?.toInt() ?? _liveScreenUsage?.yesterdayTotalTimeMs;
    final screenTopAppsRaw = bs['screen_top_apps'] as List<dynamic>?;
    final List<Map<String, dynamic>> topApps = [];
    if (screenTopAppsRaw != null && screenTopAppsRaw.isNotEmpty) {
      for (final a in screenTopAppsRaw) {
        if (a is Map) {
          topApps.add(Map<String, dynamic>.from(a));
        }
      }
    } else if (_liveScreenUsage != null && _liveScreenUsage!.appList.isNotEmpty) {
      for (final a in _liveScreenUsage!.appList.take(4)) {
        topApps.add({
          'name': a.appName,
          'package': a.packageName,
          'formatted': a.formattedDuration,
        });
      }
    }

    final screenMins = screenMs ~/ 60000;
    final screenHours = screenMins ~/ 60;
    final screenRemMins = screenMins % 60;
    final String screenTimeDisplay;
    if (screenMins < 1) {
      screenTimeDisplay = '${(screenMs / 1000).round()}秒';
    } else if (screenHours > 0) {
      screenTimeDisplay = screenRemMins > 0 ? '$screenHours小时$screenRemMins分' : '$screenHours小时';
    } else {
      screenTimeDisplay = '$screenMins分钟';
    }

    String? screenDiffDesc;
    if (screenYesterdayMs != null && screenYesterdayMs > 0 && screenMs > 0) {
      final diffMs = screenMs - screenYesterdayMs;
      final diffMins = (diffMs.abs()) ~/ 60000;
      if (diffMins == 0) {
        screenDiffDesc = '与昨日持平';
      } else {
        final dH = diffMins ~/ 60;
        final dM = diffMins % 60;
        final tStr = dH > 0 ? '$dH小时$dM分' : '$dM分';
        screenDiffDesc = diffMs > 0 ? '较昨日+$tStr' : '较昨日-$tStr';
      }
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. 步数与核心活动卡片
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: brandGreen.withValues(alpha: 0.18),
                width: 0.8,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      NumberFormat('#,###').format(steps),
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '步',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
                      decoration: BoxDecoration(
                        color: (isTargetReached ? brandGreen : colorScheme.primary)
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isTargetReached ? Icons.check_circle_rounded : Icons.flag_rounded,
                            size: 13,
                            color: isTargetReached ? brandGreen : colorScheme.primary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isTargetReached
                                ? '达标 ${(steps / stepTarget * 100).toInt()}%'
                                : '${(steps / stepTarget * 100).toInt()}% / 目标$stepTarget',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: isTargetReached ? brandGreen : colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 5,
                    backgroundColor: colorScheme.outlineVariant.withValues(alpha: 0.25),
                    valueColor: const AlwaysStoppedAnimation(brandGreen),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildMetricItem(
                      theme,
                      icon: Icons.local_fire_department_rounded,
                      iconColor: const Color(0xFFF97316),
                      value: '${calories.toStringAsFixed(0)} kcal',
                      label: '消耗',
                    ),
                    _buildMetricItem(
                      theme,
                      icon: Icons.place_rounded,
                      iconColor: const Color(0xFF3B82F6),
                      value: '${(distanceMeters / 1000).toStringAsFixed(2)} km',
                      label: '距离',
                    ),
                    _buildMetricItem(
                      theme,
                      icon: Icons.timer_outlined,
                      iconColor: const Color(0xFFEAB308),
                      value: '$activeMinutes 分钟',
                      label: '活动',
                    ),
                    if (standingCount > 0)
                      _buildMetricItem(
                        theme,
                        icon: Icons.accessibility_new_rounded,
                        iconColor: const Color(0xFF8B5CF6),
                        value: '$standingCount 次',
                        label: '站立',
                      ),
                  ],
                ),
              ],
            ),
          ),

          // 2. 作息睡眠卡片（若有）
          if (sleepMinutes > 0) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: sleepPurple.withValues(alpha: 0.18),
                  width: 0.8,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.nightlight_round, size: 16, color: sleepPurple),
                      const SizedBox(width: 6),
                      Text(
                        '作息睡眠',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Flexible(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                '${sleepMinutes ~/ 60}小时${sleepMinutes % 60}分',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: sleepPurple,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (sleepScore != null) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: sleepPurple.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '$sleepScore分',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: sleepPurple,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _buildSleepStagesBar(
                    deepMinutes: deepSleep,
                    lightMinutes: lightSleep,
                    remMinutes: remSleep,
                    awakeMinutes: awakeMinutes,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (deepSleep > 0)
                        _buildSleepLegend('深睡', '$deepSleep分', const Color(0xFF6366F1)),
                      if (deepSleep > 0) const SizedBox(width: 10),
                      if (lightSleep > 0)
                        _buildSleepLegend('浅睡', '$lightSleep分', const Color(0xFFA855F7)),
                      if (lightSleep > 0) const SizedBox(width: 10),
                      if (remSleep > 0)
                        _buildSleepLegend('REM', '$remSleep分', const Color(0xFF38BDF8)),
                      const Spacer(),
                      if (sleepTimeDisplay != null)
                        Flexible(
                          child: Text(
                            sleepTimeDisplay,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 10,
                              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],

          // 3. 屏幕使用时间卡片（若有数据或当日已获取）
          if (screenMs > 0) ...[
            const SizedBox(height: 10),
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  // 点击直接跳转至统计页的屏幕时长完整看板
                  context.push('/statistics');
                },
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.28),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: screenBlue.withValues(alpha: 0.18),
                      width: 0.8,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.phone_android_rounded, size: 16, color: screenBlue),
                          const SizedBox(width: 6),
                          Text(
                            '屏幕使用',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (screenDiffDesc != null) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: screenBlue.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                screenDiffDesc,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: screenBlue,
                                ),
                              ),
                            ),
                          ],
                          const Spacer(),
                          Text(
                            screenTimeDisplay,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: screenBlue,
                            ),
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 16,
                            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                          ),
                        ],
                      ),
                      if (topApps.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final app in topApps)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        app['name'] as String? ?? '应用',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w500,
                                          color: colorScheme.onSurface,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      app['formatted'] as String? ?? '',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: screenBlue.withValues(alpha: 0.9),
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
                ),
              ),
            ),
          ],

          // 4. 生理指标横排（若有心率、血氧或压力）
          if ((restingHr != null && restingHr > 0) ||
              (avgSpo2 != null && avgSpo2 > 0) ||
              (avgStress != null && avgStress > 0)) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                if (restingHr != null && restingHr > 0)
                  Expanded(
                    child: _buildVitalsChip(
                      theme,
                      icon: Icons.favorite_rounded,
                      iconColor: const Color(0xFFEF4444),
                      label: '静息心率',
                      value: '$restingHr bpm',
                    ),
                  ),
                if (avgSpo2 != null && avgSpo2 > 0) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildVitalsChip(
                      theme,
                      icon: Icons.water_drop_rounded,
                      iconColor: const Color(0xFF0EA5E9),
                      label: '平均血氧',
                      value: '$avgSpo2%',
                    ),
                  ),
                ],
                if (avgStress != null && avgStress > 0) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildVitalsChip(
                      theme,
                      icon: Icons.speed_rounded,
                      iconColor: const Color(0xFFF97316),
                      label: '压力指数',
                      value: '$avgStress',
                    ),
                  ),
                ],
              ],
            ),
          ],

          // 5. 今日运动记录列表（若有单次运动）
          if (sportsRaw.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.directions_run_rounded, size: 16, color: brandGreen),
                const SizedBox(width: 4),
                Text(
                  '今日运动 (${sportsRaw.length}项)',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final s in sportsRaw) ...[
              _buildSportItemCard(theme, s as Map<String, dynamic>),
              const SizedBox(height: 6),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildSleepStagesBar({
    required int deepMinutes,
    required int lightMinutes,
    required int remMinutes,
    required int awakeMinutes,
  }) {
    final sum = (deepMinutes + lightMinutes + remMinutes + awakeMinutes).clamp(1, 99999);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 6,
        child: Row(
          children: [
            if (deepMinutes > 0)
              Expanded(
                flex: (deepMinutes * 100 ~/ sum).clamp(1, 100),
                child: Container(color: const Color(0xFF6366F1)),
              ),
            if (lightMinutes > 0)
              Expanded(
                flex: (lightMinutes * 100 ~/ sum).clamp(1, 100),
                child: Container(color: const Color(0xFFA855F7)),
              ),
            if (remMinutes > 0)
              Expanded(
                flex: (remMinutes * 100 ~/ sum).clamp(1, 100),
                child: Container(color: const Color(0xFF38BDF8)),
              ),
            if (awakeMinutes > 0)
              Expanded(
                flex: (awakeMinutes * 100 ~/ sum).clamp(1, 100),
                child: Container(color: const Color(0xFFCBD5E1)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSleepLegend(String label, String value, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          '$label $value',
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  Widget _buildMetricItem(
    ThemeData theme, {
    required IconData icon,
    required Color iconColor,
    required String value,
    required String label,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: iconColor),
        const SizedBox(width: 5),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildVitalsChip(
    ThemeData theme, {
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
  }) {
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: iconColor),
          const SizedBox(width: 5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 9,
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSportItemCard(ThemeData theme, Map<String, dynamic> sport) {
    final colorScheme = theme.colorScheme;
    final title = sport['title'] as String? ?? '运动';
    final distMeters = (sport['distance_meters'] as num?)?.toDouble() ?? 0.0;
    final durSec = (sport['duration_seconds'] as num?)?.toInt() ?? 0;
    final cal = (sport['calories'] as num?)?.toDouble() ?? 0.0;
    final pace = sport['avg_pace'] as String?;
    final hr = (sport['avg_heart_rate'] ?? sport['avg_hr'] as num?)?.toInt();

    IconData sportIcon = Icons.fitness_center_rounded;
    if (title.contains('跑')) {
      sportIcon = Icons.directions_run_rounded;
    } else if (title.contains('骑')) {
      sportIcon = Icons.directions_bike_rounded;
    } else if (title.contains('游')) {
      sportIcon = Icons.pool_rounded;
    } else if (title.contains('走') || title.contains('徒步')) {
      sportIcon = Icons.hiking_rounded;
    }

    final distStr = distMeters > 0 ? '${(distMeters / 1000).toStringAsFixed(2)} km' : '';
    final durMin = durSec ~/ 60;
    final durStr = '$durMin分钟';

    final items = <String>[
      if (distStr.isNotEmpty) distStr,
      durStr,
      if (cal > 0) '${cal.toStringAsFixed(0)} kcal',
      if (pace != null && pace.isNotEmpty) '配速 $pace',
      if (hr != null && hr > 0) '$hr bpm',
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: const Color(0xFF10B981).withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(sportIcon, size: 15, color: const Color(0xFF10B981)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  items.join(' · '),
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UndoCountdownPainter extends CustomPainter {
  final double progress;
  final Color color;

  _UndoCountdownPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - 4) / 2;

    final bgPaint = Paint()
      ..color = color.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, bgPaint);

    final fgPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    final sweepAngle = (1.0 - progress) * 2 * 3.141592653589793;
    if (sweepAngle > 0.01) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -3.141592653589793 / 2,
        sweepAngle,
        false,
        fgPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _UndoCountdownPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
