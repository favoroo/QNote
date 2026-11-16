import 'package:qnote_flutter/models/diary_record.dart';

/// 统计页 tab 类型，提到此处避免 stats_provider ↔ statistics_page 循环依赖
enum StatTab { score, healthDevice, screenTime, sleep, diet, finance, mood, activity }

class SleepDailyData {
  final String date;
  final double duration;
  final String? quality;
  SleepDailyData({required this.date, required this.duration, this.quality});
}

class SleepStatistics {
  final int totalRecords;
  final double averageDuration;
  final Map<String, int> qualityDistribution;
  final List<SleepDailyData> dailyData;
  SleepStatistics({
    required this.totalRecords,
    required this.averageDuration,
    required this.qualityDistribution,
    required this.dailyData,
  });
}

class FinanceDailyData {
  final String date;
  final double income;
  final double expense;
  FinanceDailyData({required this.date, required this.income, required this.expense});
}

/// 一笔记账明细，供统计页与二级页「逐笔」展示。
class FinanceLedgerEntry {
  /// 关联的日记记录 id，点击时据此定位并打开详情弹层。
  final String recordId;

  /// 记账时间。
  final DateTime time;

  /// 是否为收入（false 为支出）。
  final bool isIncome;

  /// 金额。
  final double amount;

  /// 分类（支出类型 / 收入类型），缺省「其他」。
  final String category;

  /// 备注预览，取自记录正文，可能为空。
  final String? note;

  FinanceLedgerEntry({
    required this.recordId,
    required this.time,
    required this.isIncome,
    required this.amount,
    required this.category,
    this.note,
  });
}

class FinanceStatistics {
  final double totalIncome;
  final double totalExpense;
  final double balance;
  final int totalRecords;
  final Map<String, double> incomeByType;
  final Map<String, double> expenseByType;
  final List<FinanceDailyData> dailyData;

  /// 逐笔明细，按时间倒序（最新在前）。
  final List<FinanceLedgerEntry> ledger;

  FinanceStatistics({
    required this.totalIncome,
    required this.totalExpense,
    required this.balance,
    required this.totalRecords,
    required this.incomeByType,
    required this.expenseByType,
    required this.dailyData,
    required this.ledger,
  });
}

/// 一条饮食明细，供统计页与二级页「吃过什么」逐条展示。
class DietMealEntry {
  /// 关联的日记记录 id。
  final String recordId;

  /// 用餐时间。
  final DateTime time;

  /// 吃了什么（经 [_resolveDietItem] 归类后），可能为空。
  final String? item;

  /// 健康评价：健康 / 一般 / 不健康 / 过于放纵。
  final String health;

  /// 估算热量（千卡），AI 或用户填写后才有值。
  final double? calories;

  /// 备注预览，取自记录正文，可能为空。
  final String? note;

  DietMealEntry({
    required this.recordId,
    required this.time,
    this.item,
    required this.health,
    this.calories,
    this.note,
  });
}

class DietStatistics {
  final int totalMeals;
  final Map<String, int> typeDistribution;
  final Map<String, int> healthDistribution;

  /// 区间内累计估算热量（千卡），仅统计填了热量的餐次。
  final double totalCalories;

  /// 填了热量的餐次数量，用于展示均值与「已估算 X 餐」。
  final int calorieMealCount;

  /// 逐条明细，按时间倒序（最新在前）。
  final List<DietMealEntry> meals;

  DietStatistics({
    required this.totalMeals,
    required this.typeDistribution,
    required this.healthDistribution,
    required this.meals,
    this.totalCalories = 0,
    this.calorieMealCount = 0,
  });
}

class MoodStatistics {
  final double averageSeverity;
  final int totalRecords;
  final Map<String, int> symptomDistribution;
  final Map<String, int> durationDistribution;
  final List<({String date, double severity, String? symptom})> dailyData;
  MoodStatistics({
    required this.averageSeverity,
    required this.totalRecords,
    required this.symptomDistribution,
    required this.durationDistribution,
    required this.dailyData,
  });
}

class ActivityStatistics {
  final int totalActivities;
  final Map<String, int> typeDistribution;
  final double totalDuration;
  final double averageDuration;
  final Map<String, double> durationByType;
  final List<({String date, int count})> dailyData;
  ActivityStatistics({
    required this.totalActivities,
    required this.typeDistribution,
    required this.totalDuration,
    required this.averageDuration,
    required this.durationByType,
    required this.dailyData,
  });
}

String _formatDate(DateTime dt) {
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$m-$d';
}

/// 统计页的日期标题：今天/昨天/前天，其余为 yyyy年M月d日。
///
/// 评分 tab 与屏幕时长 tab 的日期导航头共用，避免两个页面各写一份口径。
String formatDayLabel(DateTime dt, {DateTime? today}) {
  final base = today ?? DateTime.now();
  final todayDate = DateTime(base.year, base.month, base.day);
  final target = DateTime(dt.year, dt.month, dt.day);
  final diff = todayDate.difference(target).inDays;
  if (diff == 0) {
    return '今天';
  }
  if (diff == 1) {
    return '昨天';
  }
  if (diff == 2) {
    return '前天';
  }
  return '${target.year}年${target.month}月${target.day}日';
}

/// 把柱状图 Y 轴上限抬到便于阅读的整点小时刻度，让右侧标签与网格线落在整数上。
///
/// 屏幕时长趋势按日统计，单日最多 24 小时，调用方通常再 clamp 到 24；
/// 刻度表全部取偶数，保证 maxY/2 仍是整数小时。
double niceHourCeiling(double rawMax) {
  const steps = <double>[2, 4, 6, 8, 12, 16, 20, 24, 32];
  for (final step in steps) {
    if (rawMax <= step) {
      return step;
    }
  }
  // 超出常规量级时按 10 小时向上取整，仍然保证刻度是整数且可被 2 整除
  return (rawMax / 10).ceilToDouble() * 10;
}

dynamic _getValFromMap(Map<String, dynamic> map, List<String> keys) {
  for (final k in keys) {
    if (map.containsKey(k)) return map[k];
    final lowerK = k.toLowerCase();
    for (final entry in map.entries) {
      if (entry.key.toLowerCase() == lowerK) return entry.value;
    }
  }
  return null;
}

double? _parseDouble(dynamic val) {
  if (val is double) return val;
  if (val is int) return val.toDouble();
  if (val is num) return val.toDouble();
  return double.tryParse(val.toString());
}

/// 记录正文的备注预览：压成单行、去首尾空白，过长截断，空则返回 null。
String? _contentPreview(String content) {
  final flat = content.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return null;
  return flat.length > 60 ? '${flat.substring(0, 60)}…' : flat;
}

/// 记录是否带某个标签。
///
/// 不能只看 [DiaryRecord.displayTag]：一条记录可以同时挂多个标签（时间线卡片
/// 会逐段渲染），主标签只决定配色。只按主标签筛选会让「活动 + 记账」这类记录
/// 在记账/饮食统计里整条消失。
bool _hasTag(DiaryRecord record, String name, {String? tagId}) {
  if (record.displayTag == name || record.tags.contains(name)) return true;
  return record.tagEntries.any((e) => e.name == name || (tagId != null && e.id == tagId));
}

/// 取区间内的记账记录（统计与页面共用，避免两处口径分叉）。
List<DiaryRecord> financeRecords(List<DiaryRecord> records) =>
    records.where((r) => _hasTag(r, '记账', tagId: 'consumption')).toList();

/// 取区间内的饮食记录。
List<DiaryRecord> dietRecords(List<DiaryRecord> records) =>
    records.where((r) => _hasTag(r, '饮食', tagId: 'diet')).toList();

/// 按统计 tab 取逐笔明细记录；非逐笔 tab 返回空列表。
List<DiaryRecord> recordsForStatTab(List<DiaryRecord> records, StatTab tab) {
  switch (tab) {
    case StatTab.finance:
      return financeRecords(records);
    case StatTab.diet:
      return dietRecords(records);
    case StatTab.score:
    case StatTab.healthDevice:
    case StatTab.screenTime:
    case StatTab.sleep:
    case StatTab.mood:
    case StatTab.activity:
      return const [];
  }
}

const _dietItemAliases = <String, String>{
  '自制': '自制',
  '自己做的': '自制',
  '做饭': '自制',
  '家常菜': '自制',
  '正餐': '自制',
  '外卖': '外卖',
  '点外卖': '外卖',
  '叫外卖': '外卖',
  '配送': '外卖',
  '堂食': '堂食',
  '餐厅': '堂食',
  '食堂': '堂食',
  '出去吃': '堂食',
  '下馆子': '堂食',
  '零食': '零食',
  '薯片': '零食',
  '蛋糕': '零食',
  '饼干': '零食',
  '水果': '水果',
  '苹果': '水果',
  '香蕉': '水果',
  '饮品': '饮品',
  '水': '饮品',
  '喝水': '饮品',
  '茶': '饮品',
  '喝茶': '饮品',
  '咖啡': '饮品',
  '奶茶': '饮品',
  '果汁': '饮品',
  '含糖饮料': '饮品',
  '补剂': '补剂',
  '维生素': '补剂',
  '蛋白粉': '补剂',
  '鱼油': '补剂',
  '钙片': '补剂',
};

const _activityItemAliases = <String, String>{
  '工作': '工作',
  '写代码': '工作',
  '开会': '工作',
  '上班': '工作',
  '办公': '工作',
  '学习': '学习',
  '看书': '学习',
  '上课': '学习',
  '阅读': '学习',
  '网课': '学习',
  '运动': '运动',
  '跑步': '运动',
  '健身': '运动',
  '打球': '运动',
  '游泳': '运动',
  '社交': '社交',
  '聚会': '社交',
  '约会': '社交',
  '通话': '社交',
  '聊天': '社交',
  '娱乐': '娱乐',
  '玩手机': '娱乐',
  '玩电脑': '娱乐',
  '看剧': '娱乐',
  '打游戏': '娱乐',
  '刷视频': '娱乐',
  '通勤': '通勤',
  '上班路上': '通勤',
  '下班路上': '通勤',
  '坐地铁': '通勤',
  '坐公交': '通勤',
  '家务': '家务',
  '打扫': '家务',
  '洗衣': '家务',
  '拖地': '家务',
  '休息': '休息',
  '午休': '休息',
  '小憩': '休息',
  '发呆': '休息',
  '躺平': '休息',
};

String _resolveDietItem(String raw) {
  return _dietItemAliases[raw] ?? raw;
}

/// 从图片提取的分析（如「图：米饭 约200g 约250kcal、香菇滑鸡 约320kcal，合计约620kcal」）
/// 兜底解析菜品名，供「吃了什么」归类。只认「菜名 [约份量] 约Nkcal」的逐项格式，
/// 说明性文字一律跳过，不做模糊猜测。
///
/// 新版本把图片解读存在 `DiaryRecord.aiAnalysis`，旧数据混在正文里；
/// 调用方把两者拼起来传入，这里按段剥掉「图：」前缀。
String? _parseDietItemsFromNotes(String content) {
  const exclude = {'合计', '总计', '共', '一共'};
  // 份量段可选，兼容旧格式「米饭约250kcal」与新格式「米饭 约200g 约250kcal」
  final itemPattern = RegExp(
    r'^([\u4e00-\u9fa5A-Za-z]{1,12})\s*'
    r'(?:约?\s*\d+(?:\.\d+)?\s*(?:g|克|ml|毫升|个|片|杯|碗|份)\s*)?'
    r'约\s*\d+(?:\.\d+)?\s*(?:kcal|千卡)$',
    caseSensitive: false,
  );
  final names = <String>[];
  for (final rawSeg in content.split(RegExp(r'[、，,；;\n]'))) {
    final seg = rawSeg.replaceFirst(RegExp(r'^\s*图[：:]\s*'), '').trim();
    final m = itemPattern.firstMatch(seg);
    if (m == null) continue;
    final name = m.group(1)!;
    if (exclude.contains(name)) continue;
    names.add(name);
  }
  return names.isEmpty ? null : names.join('、');
}

String _resolveActivityItem(String raw) {
  return _activityItemAliases[raw] ?? raw;
}

SleepStatistics calculateSleepStats(List<DiaryRecord> records, DateTime startDate, DateTime endDate) {
  // Repository 已通过 getEffectiveDate() 按日期范围过滤，无需再过滤
  final sleepRecords = records.where((r) {
    return r.displayTag == '睡眠' && r.startTime != null && r.endTime != null;
  }).toList();

  final rawDaily = <SleepDailyData>[];
  for (final r in sleepRecords) {
    final start = r.startTime!;
    final end = r.endTime!;
    var duration = end.difference(start).inMinutes / 60.0;
    if (duration < 0) duration += 24;
    duration = (duration * 10).roundToDouble() / 10;

    String? quality;
    for (final entry in r.tagEntries) {
      if (entry.name == '睡眠' || entry.id == 'sleep') {
        final q = _getValFromMap(entry.fields, ['quality', '睡眠质量']);
        if (q != null) quality = q.toString();
        break;
      }
    }
    if (quality == null) {
      final qualityMatch = RegExp(r'睡眠质量[：:]\s*(.+)').firstMatch(r.content);
      quality = qualityMatch?.group(1)?.trim();
    }

    rawDaily.add(SleepDailyData(date: _formatDate(r.endTime!), duration: duration, quality: quality));
  }

  final aggregated = <String, SleepDailyData>{};
  for (final d in rawDaily) {
    final existing = aggregated[d.date];
    if (existing != null) {
      aggregated[d.date] = SleepDailyData(
        date: d.date,
        duration: existing.duration + d.duration,
        quality: d.quality ?? existing.quality,
      );
    } else {
      aggregated[d.date] = SleepDailyData(date: d.date, duration: d.duration, quality: d.quality);
    }
  }

  final dailyData = aggregated.values.toList()..sort((a, b) => a.date.compareTo(b.date));

  final totalDuration = dailyData.fold<double>(0, (sum, d) => sum + d.duration);
  final averageDuration = dailyData.isNotEmpty ? totalDuration / dailyData.length : 0.0;

  final qualityDistribution = <String, int>{'极好': 0, '良好': 0, '一般': 0, '较差': 0};
  for (final d in rawDaily) {
    if (d.quality != null && qualityDistribution.containsKey(d.quality)) {
      qualityDistribution[d.quality!] = qualityDistribution[d.quality!]! + 1;
    }
  }

  return SleepStatistics(
    totalRecords: sleepRecords.length,
    averageDuration: averageDuration,
    qualityDistribution: qualityDistribution,
    dailyData: dailyData,
  );
}

FinanceStatistics calculateFinanceStats(List<DiaryRecord> records, DateTime startDate, DateTime endDate) {
  // Repository 已通过 getEffectiveDate() 按日期范围过滤，无需再过滤
  final financeList = financeRecords(records);

  final expenseByType = <String, double>{};
  final incomeByType = <String, double>{};
  final dailyDataMap = <String, FinanceDailyData>{};
  final ledger = <FinanceLedgerEntry>[];
  double totalIncome = 0;
  double totalExpense = 0;

  for (final r in financeList) {
    final date = _formatDate(r.time);
    double recordIncome = 0;
    double recordExpense = 0;

    // 一条记录可能包含多个记账条目（AI 从一个片段里拆出多笔收支），逐条累计。
    // tagEntries 缺失的历史数据再回退到 bodyState（仅主标签为记账时可信）。
    final entryFields = r.tagEntries
        .where((e) => e.name == '记账' || e.id == 'consumption')
        .map((e) => e.fields)
        .toList();
    if (entryFields.isEmpty ||
        (entryFields.length == 1 && entryFields.single.isEmpty && r.displayTag == '记账' && r.bodyState != null)) {
      entryFields
        ..clear()
        ..add(r.displayTag == '记账' && r.bodyState != null ? Map<String, dynamic>.from(r.bodyState!) : const {});
    }

    for (final fields in entryFields) {
      double amount;
      bool? isExpense;
      bool? isIncome;
      String? expenseType;
      String? incomeType;

      final rawAmount = _getValFromMap(fields, ['amount', '金额']);
      if (rawAmount != null) {
        amount = _parseDouble(rawAmount) ?? 0;
      } else {
        final match = RegExp(r'金额.*?[：:]\s*(\d+(?:\.\d+)?)').firstMatch(r.content);
        amount = match != null ? double.parse(match.group(1)!) : 0;
      }

      final category = _getValFromMap(fields, ['_category', 'category']);
      if (category != null) {
        final catStr = category.toString().toLowerCase();
        if (catStr == 'expense' || catStr == '支出') isExpense = true;
        if (catStr == 'income' || catStr == '收入') isIncome = true;
      }
      // _category 缺失时（历史数据在提取规范化阶段被丢弃），按类型字段回退推断，
      // 与时间线卡片 diary_item.dart 的判定逻辑保持一致
      if (isExpense == null && isIncome == null) {
        final hasExpenseType = _getValFromMap(fields, ['type', '支出类型']) != null;
        final hasIncomeType = _getValFromMap(fields, ['incomeType', '收入类型']) != null;
        if (hasExpenseType) {
          isExpense = true;
        } else if (hasIncomeType) {
          isIncome = true;
        }
      }
      if (isExpense == null && isIncome == null) {
        if (entryFields.length == 1) {
          isExpense = r.content.contains('支出') || r.content.contains('支出类型');
          isIncome = r.content.contains('收入') || r.content.contains('收入类型');
        } else {
          // 多条目时正文包含整条记录的所有明细，无法定位到具体条目；
          // 缺方向字段就按记账面板的默认分类（支出）归类，避免同一笔被双向重复累计
          isExpense = true;
        }
      }

      final rawType = _getValFromMap(fields, ['type', '支出类型']);
      if (rawType != null) expenseType = rawType.toString();
      final rawIncomeType = _getValFromMap(fields, ['incomeType', '收入类型']);
      if (rawIncomeType != null) incomeType = rawIncomeType.toString();

      if (isExpense == true) {
        totalExpense += amount;
        recordExpense += amount;
        if (expenseType == null && entryFields.length == 1) {
          final typeMatch = RegExp(r'支出类型[：:]\s*([^ \n，,]+)').firstMatch(r.content);
          expenseType = typeMatch?.group(1)?.trim();
        }
        expenseType ??= '其他';
        expenseByType[expenseType] = (expenseByType[expenseType] ?? 0) + amount;
        ledger.add(
          FinanceLedgerEntry(
            recordId: r.id,
            time: r.time,
            isIncome: false,
            amount: amount,
            category: expenseType,
            note: _contentPreview(r.content),
          ),
        );
      }

      if (isIncome == true) {
        totalIncome += amount;
        recordIncome += amount;
        if (incomeType == null && entryFields.length == 1) {
          final typeMatch = RegExp(r'收入类型[：:]\s*([^ \n，,]+)').firstMatch(r.content);
          incomeType = typeMatch?.group(1)?.trim();
        }
        incomeType ??= '其他';
        incomeByType[incomeType] = (incomeByType[incomeType] ?? 0) + amount;
        ledger.add(
          FinanceLedgerEntry(
            recordId: r.id,
            time: r.time,
            isIncome: true,
            amount: amount,
            category: incomeType,
            note: _contentPreview(r.content),
          ),
        );
      }
    }

    final existing = dailyDataMap[date];
    if (existing != null) {
      dailyDataMap[date] = FinanceDailyData(
        date: date,
        income: existing.income + recordIncome,
        expense: existing.expense + recordExpense,
      );
    } else {
      dailyDataMap[date] = FinanceDailyData(date: date, income: recordIncome, expense: recordExpense);
    }
  }

  final dailyData = dailyDataMap.values.toList()..sort((a, b) => a.date.compareTo(b.date));
  ledger.sort((a, b) => b.time.compareTo(a.time));

  return FinanceStatistics(
    totalIncome: totalIncome,
    totalExpense: totalExpense,
    balance: totalIncome - totalExpense,
    totalRecords: financeList.length,
    incomeByType: incomeByType,
    expenseByType: expenseByType,
    dailyData: dailyData,
    ledger: ledger,
  );
}

DietStatistics calculateDietStats(List<DiaryRecord> records, DateTime startDate, DateTime endDate) {
  // Repository 已通过 getEffectiveDate() 按日期范围过滤，无需再过滤
  final dietList = dietRecords(records);

  final typeDistribution = <String, int>{};
  final healthDistribution = <String, int>{'健康': 0, '一般': 0, '不健康': 0, '过于放纵': 0};
  final meals = <DietMealEntry>[];
  final totalMeals = dietList.length;
  double totalCalories = 0;
  int calorieMealCount = 0;

  for (final r in dietList) {
    String? item;
    String? health;
    double? calories;

    for (final entry in r.tagEntries) {
      if (entry.name == '饮食' || entry.id == 'diet') {
        final fields = entry.fields;
        // item 为新增的食物名，优先取；旧数据的种类/type 仍兼容
        final rawItem = _getValFromMap(fields, ['item', 'type', '种类', '类别'])?.toString();
        if (rawItem != null) item = _resolveDietItem(rawItem);
        final rawHealth = _getValFromMap(fields, ['rating', 'health', '评价'])?.toString();
        if (rawHealth != null && healthDistribution.containsKey(rawHealth)) {
          health = rawHealth;
        }
        final rawCalories = _getValFromMap(fields, ['calories', 'cal', '热量', '千卡', 'kcal']);
        if (rawCalories != null) calories = _parseDouble(rawCalories);
        break;
      }
    }

    if (item == null) {
      final typeMatch = RegExp(r'种类[：:]\s*([^ \n，,]+)').firstMatch(r.content);
      if (typeMatch != null) {
        item = _resolveDietItem(typeMatch.group(1)!.trim());
      }
    }
    // 图片提取的记录没有 item 字段，从分析/正文的逐项热量明细里兜底解析菜品名
    if (item == null) {
      final fromNotes = _parseDietItemsFromNotes('${r.content}\n${r.aiAnalysis}');
      if (fromNotes != null) item = _resolveDietItem(fromNotes);
    }
    if (item != null) {
      typeDistribution[item] = (typeDistribution[item] ?? 0) + 1;
    }

    if (health != null) {
      healthDistribution[health] = healthDistribution[health]! + 1;
    } else {
      healthDistribution['一般'] = healthDistribution['一般']! + 1;
    }

    meals.add(
      DietMealEntry(
        recordId: r.id,
        time: r.time,
        item: item,
        health: health ?? '一般',
        calories: calories,
        note: _contentPreview(r.content),
      ),
    );

    if (calories != null && calories > 0) {
      totalCalories += calories;
      calorieMealCount++;
    }
  }

  meals.sort((a, b) => b.time.compareTo(a.time));

  return DietStatistics(
    totalMeals: totalMeals,
    typeDistribution: typeDistribution,
    healthDistribution: healthDistribution,
    meals: meals,
    totalCalories: totalCalories,
    calorieMealCount: calorieMealCount,
  );
}

MoodStatistics calculateMoodStats(List<DiaryRecord> records, DateTime startDate, DateTime endDate) {
  // Repository 已通过 getEffectiveDate() 按日期范围过滤，无需再过滤
  final moodRecords = records
      .where((r) => (r.displayTag == '状态' || r.displayTag == '健康') && r.bodyState != null)
      .toList();

  const severityMap = {'mild': 3, 'moderate': 2, 'severe': 1, '轻微': 3, '中度': 2, '严重': 1};
  final symptomDistribution = <String, int>{};
  final durationDistribution = <String, int>{};
  final dailyDataMap = <String, ({num severity, int count, String? symptom})>{};
  double totalSeverity = 0;

  for (final r in moodRecords) {
    final bs = r.bodyState!;
    final date = _formatDate(r.time);

    final rawSymptom = bs['symptom'] ?? bs['name'] ?? '未知';
    final List<String> symptomNames;
    if (rawSymptom is List) {
      symptomNames = rawSymptom.map((e) => e.toString()).toList();
    } else {
      symptomNames = [rawSymptom.toString()];
    }
    final primarySymptom = symptomNames.isNotEmpty ? symptomNames.first : '未知';

    final duration = bs['duration'] as String? ?? '未知';
    final severityStr = bs['severity'] as String? ?? 'moderate';
    final sevValue = severityMap[severityStr] ?? 2;
    totalSeverity += sevValue;

    for (final name in symptomNames) {
      symptomDistribution[name] = (symptomDistribution[name] ?? 0) + 1;
    }
    durationDistribution[duration] = (durationDistribution[duration] ?? 0) + 1;

    final existing = dailyDataMap[date];
    if (existing != null) {
      dailyDataMap[date] = (
        severity: existing.severity + sevValue,
        count: existing.count + 1,
        symptom: existing.symptom ?? primarySymptom,
      );
    } else {
      dailyDataMap[date] = (severity: sevValue, count: 1, symptom: primarySymptom);
    }
  }

  final averageSeverity = moodRecords.isNotEmpty ? totalSeverity / moodRecords.length : 0.0;

  final dailyData =
      dailyDataMap.entries
          .map((e) => (date: e.key, severity: e.value.severity / e.value.count, symptom: e.value.symptom))
          .toList()
        ..sort((a, b) => a.date.compareTo(b.date));

  return MoodStatistics(
    averageSeverity: averageSeverity,
    totalRecords: moodRecords.length,
    symptomDistribution: symptomDistribution,
    durationDistribution: durationDistribution,
    dailyData: dailyData,
  );
}

ActivityStatistics calculateActivityStats(List<DiaryRecord> records, DateTime startDate, DateTime endDate) {
  // Repository 已通过 getEffectiveDate() 按日期范围过滤，无需再过滤
  final activityRecords = records.where((r) => r.displayTag == '活动').toList();

  final typeDistribution = <String, int>{};
  final durationByType = <String, double>{};
  final dailyDataMap = <String, int>{};
  double totalDuration = 0;
  int durationCount = 0;

  for (final r in activityRecords) {
    final date = _formatDate(r.time);
    String? type;
    double? duration;

    for (final entry in r.tagEntries) {
      if (entry.name == '活动' || entry.id == 'activity') {
        final fields = entry.fields;
        // 优先匹配字段 ID 'type'，再匹配中文标签 '类型'（与饮食统计对齐）
        final rawItem = _getValFromMap(fields, ['type', 'item', '项目', '类型'])?.toString();
        if (rawItem != null) type = _resolveActivityItem(rawItem);
        final rawDuration = _getValFromMap(fields, ['duration', '时长']);
        if (rawDuration != null) duration = _parseDouble(rawDuration);
        break;
      }
    }

    if (type == null) {
      // 同时匹配 '类型：' 和 '项目：'，兼容不同内容格式
      final typeMatch = RegExp(r'(?:类型|项目)[：:]\s*([^ \n，,]+)').firstMatch(r.content);
      if (typeMatch != null) {
        type = _resolveActivityItem(typeMatch.group(1)!.trim());
      }
    }
    type ??= '其他';

    typeDistribution[type] = (typeDistribution[type] ?? 0) + 1;

    if (duration != null && duration > 0) {
      totalDuration += duration;
      durationCount++;
      durationByType[type] = (durationByType[type] ?? 0) + duration;
    }

    dailyDataMap[date] = (dailyDataMap[date] ?? 0) + 1;
  }

  final dailyData = dailyDataMap.entries.map((e) => (date: e.key, count: e.value)).toList()
    ..sort((a, b) => a.date.compareTo(b.date));

  return ActivityStatistics(
    totalActivities: activityRecords.length,
    typeDistribution: typeDistribution,
    totalDuration: totalDuration,
    averageDuration: durationCount > 0 ? totalDuration / durationCount : 0.0,
    durationByType: durationByType,
    dailyData: dailyData,
  );
}
