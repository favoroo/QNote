import 'package:qnote_flutter/models/diary_record.dart';

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
  FinanceDailyData({
    required this.date,
    required this.income,
    required this.expense,
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
  FinanceStatistics({
    required this.totalIncome,
    required this.totalExpense,
    required this.balance,
    required this.totalRecords,
    required this.incomeByType,
    required this.expenseByType,
    required this.dailyData,
  });
}

class DietStatistics {
  final int totalMeals;
  final Map<String, int> typeDistribution;
  final Map<String, int> healthDistribution;
  DietStatistics({
    required this.totalMeals,
    required this.typeDistribution,
    required this.healthDistribution,
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

List<DiaryRecord> _filterByDateRange(
  List<DiaryRecord> records,
  DateTime startDate,
  DateTime endDate,
) {
  return records.where((r) {
    return !r.time.isBefore(startDate) && !r.time.isAfter(endDate);
  }).toList();
}

String _formatDate(DateTime dt) {
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$m-$d';
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

String _resolveActivityItem(String raw) {
  return _activityItemAliases[raw] ?? raw;
}

SleepStatistics calculateSleepStats(
  List<DiaryRecord> records,
  DateTime startDate,
  DateTime endDate,
) {
  final targetStart = DateTime(startDate.year, startDate.month, startDate.day);
  final targetEnd = DateTime(endDate.year, endDate.month, endDate.day);

  final sleepRecords = records.where((r) {
    if (r.displayTag != '睡眠' || r.startTime == null || r.endTime == null) return false;
    final effectiveDate = r.getEffectiveDate();
    return !effectiveDate.isBefore(targetStart) && !effectiveDate.isAfter(targetEnd);
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

    rawDaily.add(
      SleepDailyData(
        date: _formatDate(r.endTime!),
        duration: duration,
        quality: quality,
      ),
    );
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
      aggregated[d.date] = SleepDailyData(
        date: d.date,
        duration: d.duration,
        quality: d.quality,
      );
    }
  }

  final dailyData = aggregated.values.toList()
    ..sort((a, b) => a.date.compareTo(b.date));

  final totalDuration = dailyData.fold<double>(0, (sum, d) => sum + d.duration);
  final averageDuration = dailyData.isNotEmpty
      ? totalDuration / dailyData.length
      : 0.0;

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

FinanceStatistics calculateFinanceStats(
  List<DiaryRecord> records,
  DateTime startDate,
  DateTime endDate,
) {
  final filtered = _filterByDateRange(records, startDate, endDate);
  final financeRecords = filtered.where((r) => r.displayTag == '记账').toList();

  final expenseByType = <String, double>{};
  final incomeByType = <String, double>{};
  final dailyDataMap = <String, FinanceDailyData>{};
  double totalIncome = 0;
  double totalExpense = 0;

  for (final r in financeRecords) {
    final date = _formatDate(r.time);
    double? amount;
    bool? isExpense;
    bool? isIncome;
    String? expenseType;
    String? incomeType;

    for (final entry in r.tagEntries) {
      if (entry.name == '记账' || entry.id == 'consumption') {
        final fields = entry.fields;
        final rawAmount = _getValFromMap(fields, ['amount', '金额']);
        if (rawAmount != null) amount = _parseDouble(rawAmount);
        final category = _getValFromMap(fields, ['_category', 'category']);
        if (category != null) {
          final catStr = category.toString().toLowerCase();
          if (catStr == 'expense' || catStr == '支出') isExpense = true;
          if (catStr == 'income' || catStr == '收入') isIncome = true;
        }
        final rawType = _getValFromMap(fields, ['type', '支出类型']);
        if (rawType != null) expenseType = rawType.toString();
        final rawIncomeType = _getValFromMap(fields, ['incomeType', '收入类型']);
        if (rawIncomeType != null) incomeType = rawIncomeType.toString();
        break;
      }
    }

    if (amount == null) {
      final match = RegExp(
        r'金额.*?[：:]\s*(\d+(?:\.\d+)?)',
      ).firstMatch(r.content);
      amount = match != null ? double.parse(match.group(1)!) : 0;
    }

    if (isExpense == null && isIncome == null) {
      isExpense = r.content.contains('支出') || r.content.contains('支出类型');
      isIncome = r.content.contains('收入') || r.content.contains('收入类型');
    }

    if (isExpense == true) {
      totalExpense += amount;
      if (expenseType == null) {
        final typeMatch = RegExp(
          r'支出类型[：:]\s*([^ \n，,]+)',
        ).firstMatch(r.content);
        expenseType = typeMatch?.group(1)?.trim() ?? '其他';
      }
      expenseByType[expenseType] = (expenseByType[expenseType] ?? 0) + amount;
    }

    if (isIncome == true) {
      totalIncome += amount;
      if (incomeType == null) {
        final typeMatch = RegExp(
          r'收入类型[：:]\s*([^ \n，,]+)',
        ).firstMatch(r.content);
        incomeType = typeMatch?.group(1)?.trim() ?? '其他';
      }
      incomeByType[incomeType] = (incomeByType[incomeType] ?? 0) + amount;
    }

    final existing = dailyDataMap[date];
    if (existing != null) {
      dailyDataMap[date] = FinanceDailyData(
        date: date,
        income: existing.income + (isIncome == true ? amount : 0),
        expense: existing.expense + (isExpense == true ? amount : 0),
      );
    } else {
      dailyDataMap[date] = FinanceDailyData(
        date: date,
        income: isIncome == true ? amount : 0,
        expense: isExpense == true ? amount : 0,
      );
    }
  }

  final dailyData = dailyDataMap.values.toList()
    ..sort((a, b) => a.date.compareTo(b.date));

  return FinanceStatistics(
    totalIncome: totalIncome,
    totalExpense: totalExpense,
    balance: totalIncome - totalExpense,
    totalRecords: financeRecords.length,
    incomeByType: incomeByType,
    expenseByType: expenseByType,
    dailyData: dailyData,
  );
}

DietStatistics calculateDietStats(
  List<DiaryRecord> records,
  DateTime startDate,
  DateTime endDate,
) {
  final filtered = _filterByDateRange(records, startDate, endDate);
  final dietRecords = filtered.where((r) => r.displayTag == '饮食').toList();

  final typeDistribution = <String, int>{};
  final healthDistribution = <String, int>{'健康': 0, '一般': 0, '不健康': 0};
  int totalMeals = 0;

  for (final r in dietRecords) {
    String? item;
    String? health;

    for (final entry in r.tagEntries) {
      if (entry.name == '饮食' || entry.id == 'diet') {
        final fields = entry.fields;
        final rawItem = _getValFromMap(fields, [
          'type',
          'item',
          '种类',
          '类别',
        ])?.toString();
        if (rawItem != null) item = _resolveDietItem(rawItem);
        final rawHealth = _getValFromMap(fields, [
          'rating',
          'health',
          '评价',
        ])?.toString();
        if (rawHealth != null && healthDistribution.containsKey(rawHealth)) {
          health = rawHealth;
        }
        break;
      }
    }

    if (item == null) {
      final typeMatch = RegExp(r'种类[：:]\s*([^ \n，,]+)').firstMatch(r.content);
      if (typeMatch != null)
        item = _resolveDietItem(typeMatch.group(1)!.trim());
    }
    item ??= '其他';

    typeDistribution[item] = (typeDistribution[item] ?? 0) + 1;
    if (item == '正餐') totalMeals++;

    if (health != null) {
      healthDistribution[health] = healthDistribution[health]! + 1;
    } else {
      healthDistribution['一般'] = healthDistribution['一般']! + 1;
    }
  }

  return DietStatistics(
    totalMeals: totalMeals,
    typeDistribution: typeDistribution,
    healthDistribution: healthDistribution,
  );
}

MoodStatistics calculateMoodStats(
  List<DiaryRecord> records,
  DateTime startDate,
  DateTime endDate,
) {
  final filtered = _filterByDateRange(records, startDate, endDate);
  final moodRecords = filtered
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

  final averageSeverity = moodRecords.isNotEmpty
      ? totalSeverity / moodRecords.length
      : 0.0;

  final dailyData =
      dailyDataMap.entries
          .map(
            (e) => (
              date: e.key,
              severity: e.value.severity / e.value.count,
              symptom: e.value.symptom,
            ),
          )
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

ActivityStatistics calculateActivityStats(
  List<DiaryRecord> records,
  DateTime startDate,
  DateTime endDate,
) {
  final filtered = _filterByDateRange(records, startDate, endDate);
  final activityRecords = filtered.where((r) => r.displayTag == '活动').toList();

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
        final rawItem = _getValFromMap(fields, [
          'item',
          '项目',
          '类型',
        ])?.toString();
        if (rawItem != null) type = _resolveActivityItem(rawItem);
        final rawDuration = _getValFromMap(fields, ['duration', '时长']);
        if (rawDuration != null) duration = _parseDouble(rawDuration);
        break;
      }
    }

    if (type == null) {
      final typeMatch = RegExp(r'项目[：:]\s*([^ \n，,]+)').firstMatch(r.content);
      if (typeMatch != null)
        type = _resolveActivityItem(typeMatch.group(1)!.trim());
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

  final dailyData =
      dailyDataMap.entries.map((e) => (date: e.key, count: e.value)).toList()
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
