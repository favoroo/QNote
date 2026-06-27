import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/widgets/stats_card.dart';

const _expenseColors = [Color(0xFF10B981), Color(0xFF3B82F6), Color(0xFFF59E0B), Color(0xFFEF4444), Color(0xFF8B5CF6)];

class FinanceStatsWidget extends StatelessWidget {
  final FinanceStatistics stats;

  const FinanceStatsWidget({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final expenseData = stats.expenseByType.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: StatsCard(
                title: '收入',
                value: '¥${stats.totalIncome.toStringAsFixed(0)}',
                icon: Icons.trending_up,
                iconColor: Colors.green,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatsCard(
                title: '支出',
                value: '¥${stats.totalExpense.toStringAsFixed(0)}',
                icon: Icons.trending_down,
                iconColor: Colors.red,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: StatsCard(
                title: '结余',
                value: '¥${stats.balance.toStringAsFixed(0)}',
                icon: Icons.account_balance_wallet,
                iconColor: stats.balance >= 0 ? Colors.green : Colors.red,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatsCard(
                title: '记录笔数',
                value: '${stats.totalRecords}笔',
                icon: Icons.bar_chart,
                iconColor: Colors.blue,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _FinanceCard(
          isDark: isDark,
          title: '收支趋势',
          child: SizedBox(
            height: 192,
            child: stats.dailyData.isNotEmpty
                ? _FinanceTrendChart(dailyData: stats.dailyData, isDark: isDark)
                : Center(child: Text('暂无数据', style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF94A3B8)))),
          ),
        ),
        const SizedBox(height: 16),
        if (expenseData.isNotEmpty)
          _FinanceCard(
            isDark: isDark,
            title: '支出分类排行',
            child: SizedBox(
              height: expenseData.length * 40.0 + 20,
              child: _ExpenseTypeChart(expenseData: expenseData, isDark: isDark),
            ),
          ),
      ],
    );
  }
}

class _FinanceCard extends StatelessWidget {
  final bool isDark;
  final String title;
  final Widget child;

  const _FinanceCard({required this.isDark, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isDark ? const Color(0x1A383C47) : const Color(0xFFC2C6D6),
          width: 0.5,
        ),
      ),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: isDark ? const Color(0xFFE2E2E9) : const Color(0xFF191B23),
              ),
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _FinanceTrendChart extends StatelessWidget {
  final List<FinanceDailyData> dailyData;
  final bool isDark;

  const _FinanceTrendChart({required this.dailyData, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final incomeSpots = <FlSpot>[];
    final expenseSpots = <FlSpot>[];
    for (var i = 0; i < dailyData.length; i++) {
      incomeSpots.add(FlSpot(i.toDouble(), dailyData[i].income));
      expenseSpots.add(FlSpot(i.toDouble(), dailyData[i].expense));
    }

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (value) => FlLine(
            color: isDark ? const Color(0xFF2A2D36) : const Color(0xFFE4E4E7),
            strokeWidth: 1,
          ),
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx < 0 || idx >= dailyData.length) return const SizedBox.shrink();
                final parts = dailyData[idx].date.split('-');
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${parts[1]}/${parts[2]}',
                    style: TextStyle(fontSize: 10, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF94A3B8)),
                  ),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              getTitlesWidget: (value, meta) => Text(
                '¥${value.toInt()}',
                style: TextStyle(fontSize: 9, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF94A3B8)),
              ),
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: incomeSpots,
            isCurved: true,
            color: Colors.green,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: false),
          ),
          LineChartBarData(
            spots: expenseSpots,
            isCurved: true,
            color: Colors.red,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: false),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) {
              return spots.map((spot) {
                final isIncome = spot.bar.color == Colors.green;
                return LineTooltipItem(
                  '${isIncome ? "收入" : "支出"}: ¥${spot.y.toStringAsFixed(0)}',
                  TextStyle(color: isIncome ? Colors.green : Colors.red, fontSize: 12),
                );
              }).toList();
            },
          ),
        ),
      ),
    );
  }
}

class _ExpenseTypeChart extends StatelessWidget {
  final List<MapEntry<String, double>> expenseData;
  final bool isDark;

  const _ExpenseTypeChart({required this.expenseData, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final maxVal = expenseData.fold<double>(0, (max, e) => e.value > max ? e.value : max);

    return Column(
      children: expenseData.asMap().entries.map((entry) {
        final idx = entry.key;
        final item = entry.value;
        final color = _expenseColors[idx % _expenseColors.length];
        final pct = maxVal > 0 ? item.value / maxVal : 0.0;

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                child: Text(
                  item.key,
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? const Color(0xFFC2C6D6) : const Color(0xFF424754),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: pct,
                    backgroundColor: isDark ? const Color(0xFF2A2D36) : const Color(0xFFECEDF7),
                    valueColor: AlwaysStoppedAnimation(color),
                    minHeight: 12,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 48,
                child: Text(
                  '¥${item.value.toStringAsFixed(0)}',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF94A3B8),
                  ),
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
