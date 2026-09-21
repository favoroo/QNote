import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// 单日健康采样折线图（x 轴固定 0~24 点）
///
/// 心率 / 血氧 / 压力详情页共用：小米云端这三类返回的都是 `{t: 秒级时间戳, v: 数值}`
/// 采样点，差异只在量程与配色，因此收敛成一个组件，避免各页各画一遍后样式漂移。
class HealthDayLineChart extends StatelessWidget {
  const HealthDayLineChart({
    super.key,
    required this.samples,
    required this.color,
    required this.emptyHint,
    this.height = 190,
    this.unit = '',
    this.referenceValue,
    this.referenceLabel,
  });

  /// 采样点，元素形如 `{'t': 秒级时间戳, 'v': 数值}`
  final List<Map<String, dynamic>> samples;
  final Color color;

  /// 无采样时的说明文案
  final String emptyHint;
  final double height;

  /// 数值单位后缀，用于左侧刻度与提示
  final String unit;

  /// 基准线（如静息心率）及其说明
  final double? referenceValue;
  final String? referenceLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spots = _toSpots();

    if (spots.isEmpty) {
      return Container(
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Text(
          emptyHint,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }

    final values = spots.map((s) => s.y).toList();
    final dataMin = values.reduce((a, b) => a < b ? a : b);
    final dataMax = values.reduce((a, b) => a > b ? a : b);
    // 上下各留 12% 余量，折线不会贴边被裁掉
    final span = (dataMax - dataMin).abs() < 1 ? 2.0 : (dataMax - dataMin).abs();
    final minY = (dataMin - span * 0.12).floorToDouble();
    final maxY = (dataMax + span * 0.12).ceilToDouble();
    final axisColor = scheme.onSurfaceVariant.withValues(alpha: 0.6);

    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minY: minY,
          maxY: maxY,
          clipData: const FlClipData.all(),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (value) => FlLine(
              color: scheme.outlineVariant.withValues(alpha: 0.4),
              strokeWidth: 1,
            ),
          ),
          extraLinesData: referenceValue == null
              ? const ExtraLinesData()
              : ExtraLinesData(
                  horizontalLines: [
                    HorizontalLine(
                      y: referenceValue!,
                      color: color.withValues(alpha: 0.55),
                      strokeWidth: 1,
                      dashArray: const [5, 4],
                    ),
                  ],
                ),
          titlesData: FlTitlesData(
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                interval: 6,
                getTitlesWidget: (value, meta) {
                  if (value < 0 || value > 24) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('${value.toInt()}时', style: TextStyle(fontSize: 10, color: axisColor)),
                  );
                },
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 38,
                getTitlesWidget: (value, meta) {
                  return Text(
                    '${value.toInt()}$unit',
                    style: TextStyle(fontSize: 10, color: axisColor),
                  );
                },
              ),
            ),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          borderData: FlBorderData(show: false),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              curveSmoothness: 0.2,
              preventCurveOverShooting: true,
              color: color,
              barWidth: 2.2,
              isStrokeCapRound: true,
              dotData: FlDotData(
                show: spots.length <= 40,
                getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
                  radius: 2.4,
                  color: color,
                  strokeWidth: 0,
                ),
              ),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0.0)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 采样点转图表坐标：x 用本地小时（含分钟小数），同一小时内的多点按时间排序
  List<FlSpot> _toSpots() {
    final parsed = <({double x, double y})>[];
    for (final s in samples) {
      final t = (s['t'] as num?)?.toInt() ?? 0;
      final v = (s['v'] as num?)?.toDouble();
      if (t <= 0 || v == null) continue;
      final dt = DateTime.fromMillisecondsSinceEpoch(t * 1000);
      parsed.add((x: dt.hour + dt.minute / 60.0, y: v));
    }
    parsed.sort((a, b) => a.x.compareTo(b.x));
    return parsed.map((p) => FlSpot(p.x, p.y)).toList();
  }
}

/// 基准线说明行（与 [HealthDayLineChart.referenceValue] 配套使用）
class HealthChartReferenceNote extends StatelessWidget {
  const HealthChartReferenceNote({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          width: 18,
          height: 2,
          color: color.withValues(alpha: 0.6),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
