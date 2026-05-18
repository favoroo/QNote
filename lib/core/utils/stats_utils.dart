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
  FinanceDailyData({required this.date, required this.income, required this.expense});
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
  final double totalWaterIntake;
  final int totalMeals;
  final List<({String date, double amount})> dailyWaterIntake;
  final Map<String, int> typeDistribution;
  DietStatistics({
    required this.totalWaterIntake,
    required this.totalMeals,
    required this.dailyWaterIntake,
    required this.typeDistribution,
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
  final List<({String date, int count})> dailyData;
  ActivityStatistics({
    required this.totalActivities,
    required this.typeDistribution,
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

SleepStatistics calculateSleepStats(
  List<DiaryRecord> records,
  DateTime startDate,
  DateTime endDate,
) {
  final filtered = _filterByDateRange(records, startDate, endDate);
  final sleepRecords =
      filtered.where((r) => r.displayTag == '睡眠' && r.startTime != null && r.endTime != null).toList();

  final rawDaily = <SleepDailyData>[];
  for (final r in sleepRecords) {
    final start = r.startTime!;
    final end = r.endTime!;
    var duration = end.difference(start).inMinutes / 60.0;
    if (duration < 0) duration += 24;
    duration = (duration * 10).roundToDouble() / 10;

    final qualityMatch = RegExp(r'睡眠质量[：:]\s*(.+)').firstMatch(r.content);
    final quality = qualityMatch?.group(1)?.trim();

    rawDaily.add(SleepDailyData(
      date: _formatDate(r.time),
      duration: duration,
      quality: quality,
    ));
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
  final averageDuration = dailyData.isNotEmpty ? totalDuration / dailyData.length : 0.0;

  final qualityDistribution = <String, int>{
    '极好': 0,
    '良好': 0,
    '一般': 0,
    '较差': 0,
  };
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

  double parseAmount(DiaryRecord r) {
    final match = RegExp(r'金额.*?[：:]\s*(\d+(?:\.\d+)?)').firstMatch(r.content);
    return match != null ? double.parse(match.group(1)!) : 0;
  }

  final expenseByType = <String, double>{};
  final incomeByType = <String, double>{};
  final dailyDataMap = <String, FinanceDailyData>{};
  double totalIncome = 0;
  double totalExpense = 0;

  for (final r in financeRecords) {
    final amount = parseAmount(r);
    final date = _formatDate(r.time);
    final isExpense = r.content.contains('支出') || r.content.contains('支出类型');
    final isIncome = r.content.contains('收入') || r.content.contains('收入类型');

    if (isExpense) {
      totalExpense += amount;
      final typeMatch = RegExp(r'支出类型[：:]\s*([^ \n，,]+)').firstMatch(r.content);
      final type = typeMatch?.group(1)?.trim() ?? '其他';
      expenseByType[type] = (expenseByType[type] ?? 0) + amount;
    }

    if (isIncome) {
      totalIncome += amount;
      final typeMatch = RegExp(r'收入类型[：:]\s*([^ \n，,]+)').firstMatch(r.content);
      final type = typeMatch?.group(1)?.trim() ?? '其他';
      incomeByType[type] = (incomeByType[type] ?? 0) + amount;
    }

    final existing = dailyDataMap[date];
    if (existing != null) {
      dailyDataMap[date] = FinanceDailyData(
        date: date,
        income: existing.income + (isIncome ? amount : 0),
        expense: existing.expense + (isExpense ? amount : 0),
      );
    } else {
      dailyDataMap[date] = FinanceDailyData(
        date: date,
        income: isIncome ? amount : 0,
        expense: isExpense ? amount : 0,
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
  final dailyWaterMap = <String, double>{};
  double totalWaterIntake = 0;
  int totalMeals = 0;

  for (final r in dietRecords) {
    final date = _formatDate(r.time);
    final typeMatch = RegExp(r'种类[：:]\s*([^ \n，,]+)').firstMatch(r.content);
    final type = typeMatch?.group(1)?.trim() ?? '其他';
    typeDistribution[type] = (typeDistribution[type] ?? 0) + 1;

    if (type == '正餐') totalMeals++;

    final waterMatch = RegExp(r'水量[：:]\s*(\d+)ml').firstMatch(r.content);
    if (waterMatch != null) {
      final amount = double.parse(waterMatch.group(1)!);
      totalWaterIntake += amount;
      dailyWaterMap[date] = (dailyWaterMap[date] ?? 0) + amount;
    }
  }

  final dailyWaterIntake = dailyWaterMap.entries
      .map((e) => (date: e.key, amount: e.value))
      .toList()
    ..sort((a, b) => a.date.compareTo(b.date));

  return DietStatistics(
    totalWaterIntake: totalWaterIntake,
    totalMeals: totalMeals,
    dailyWaterIntake: dailyWaterIntake,
    typeDistribution: typeDistribution,
  );
}

MoodStatistics calculateMoodStats(
  List<DiaryRecord> records,
  DateTime startDate,
  DateTime endDate,
) {
  final filtered = _filterByDateRange(records, startDate, endDate);
  final moodRecords = filtered.where((r) => r.displayTag == '状态' && r.bodyState != null).toList();

  const severityMap = {'mild': 3, 'moderate': 2, 'severe': 1};
  final symptomDistribution = <String, int>{};
  final durationDistribution = <String, int>{};
  final dailyDataMap = <String, ({num severity, int count, String? symptom})>{};
  double totalSeverity = 0;

  for (final r in moodRecords) {
    final bs = r.bodyState!;
    final date = _formatDate(r.time);
    final name = bs['name'] as String? ?? '未知';
    final duration = bs['duration'] as String? ?? '未知';
    final severityStr = bs['severity'] as String? ?? 'moderate';
    final sevValue = severityMap[severityStr] ?? 2;
    totalSeverity += sevValue;

    symptomDistribution[name] = (symptomDistribution[name] ?? 0) + 1;
    durationDistribution[duration] = (durationDistribution[duration] ?? 0) + 1;

    final existing = dailyDataMap[date];
    if (existing != null) {
      dailyDataMap[date] = (
        severity: existing.severity + sevValue,
        count: existing.count + 1,
        symptom: existing.symptom ?? name,
      );
    } else {
      dailyDataMap[date] = (severity: sevValue, count: 1, symptom: name);
    }
  }

  final averageSeverity = moodRecords.isNotEmpty ? totalSeverity / moodRecords.length : 0.0;

  final dailyData = dailyDataMap.entries
      .map((e) => (
            date: e.key,
            severity: e.value.severity / e.value.count,
            symptom: e.value.symptom,
          ))
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
  final dailyDataMap = <String, int>{};

  for (final r in activityRecords) {
    final date = _formatDate(r.time);
    final typeMatch = RegExp(r'项目[：:]\s*([^ \n，,]+)').firstMatch(r.content);
    final type = typeMatch?.group(1)?.trim() ?? '其他';
    typeDistribution[type] = (typeDistribution[type] ?? 0) + 1;
    dailyDataMap[date] = (dailyDataMap[date] ?? 0) + 1;
  }

  final dailyData = dailyDataMap.entries
      .map((e) => (date: e.key, count: e.value))
      .toList()
    ..sort((a, b) => a.date.compareTo(b.date));

  return ActivityStatistics(
    totalActivities: activityRecords.length,
    typeDistribution: typeDistribution,
    dailyData: dailyData,
  );
}
