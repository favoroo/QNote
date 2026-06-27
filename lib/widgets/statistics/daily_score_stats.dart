import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:intl/intl.dart';

import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/daily_score.dart';
import 'package:qnote_flutter/providers/daily_score_provider.dart';
import 'package:qnote_flutter/widgets/statistics/score_heatmap.dart';

class DailyScoreStats extends ConsumerStatefulWidget {
  const DailyScoreStats({super.key});

  @override
  ConsumerState<DailyScoreStats> createState() => _DailyScoreStatsState();
}

class _DailyScoreStatsState extends ConsumerState<DailyScoreStats> {
  bool _isScoring = false;

  void _onPrevDay(DateTime current) {
    ref.read(selectedDateProvider.notifier).state = current.subtract(const Duration(days: 1));
  }

  void _onNextDay(DateTime current) {
    ref.read(selectedDateProvider.notifier).state = current.add(const Duration(days: 1));
  }

  Future<void> _selectDate(BuildContext context, DateTime current) async {
    final result = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: const Locale('zh', 'CN'),
    );
    if (result != null && mounted) {
      ref.read(selectedDateProvider.notifier).state = DateTime(result.year, result.month, result.day);
    }
  }

  Future<void> _performScoreAction(BuildContext context, DateTime date, {bool isRescore = false}) async {
    setState(() => _isScoring = true);
    Toast.show(context, '正在分析今日数据...', duration: const Duration(seconds: 15));
    try {
      DailyScore score;
      if (isRescore) {
        score = await ref.read(dailyScoreProvider.notifier).rescore(date);
      } else {
        score = await ref.read(dailyScoreProvider.notifier).performScore(date);
      }
      if (mounted && context.mounted) {
        Toast.success(context, '评分完成！今日得分 ${score.totalScore} 分');
      }
    } catch (e) {
      if (mounted && context.mounted) {
        Toast.error(context, '评分失败：$e');
      }
    } finally {
      if (mounted) {
        setState(() => _isScoring = false);
      }
    }
  }

  Future<void> _confirmAndRescore(BuildContext context, DateTime date) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重新评分'),
        content: const Text('确定要重新评分吗？这会清除该日期的旧评分并重新调用 AI 进行评估。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted && context.mounted) {
      _performScoreAction(context, date, isRescore: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final selectedDate = ref.watch(selectedDateProvider);
    final scoreAsync = ref.watch(dailyScoreProvider);
    final recordsAsync = ref.watch(dailyRecordsProvider);
    final historyAsync = ref.watch(dailyScoreHistoryProvider(7));
    final heatmapAsync = ref.watch(dailyScoreHeatmapProvider);

    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final yesterdayDate = todayDate.subtract(const Duration(days: 1));
    final beforeYesterdayDate = todayDate.subtract(const Duration(days: 2));

    String formatDayLabel(DateTime dt) {
      if (dt == todayDate) return '今天';
      if (dt == yesterdayDate) return '昨天';
      if (dt == beforeYesterdayDate) return '前天';
      return DateFormat('yyyy年M月d日').format(dt);
    }

    final dateLabel = formatDayLabel(selectedDate);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Date selection header
        Card(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              width: 0.5,
            ),
          ),
          elevation: 0,
          color: theme.colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left),
                      onPressed: _isScoring ? null : () => _onPrevDay(selectedDate),
                    ),
                    GestureDetector(
                      onTap: _isScoring ? null : () => _selectDate(context, selectedDate),
                      child: Row(
                        children: [
                          Text(
                            dateLabel,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(width: 4),
                          Icon(Icons.calendar_month, size: 16, color: theme.colorScheme.primary),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right),
                      onPressed: _isScoring ? null : () => _onNextDay(selectedDate),
                    ),
                  ],
                ),
                const Divider(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildQuickDateBtn('前天', beforeYesterdayDate, selectedDate),
                    _buildQuickDateBtn('昨天', yesterdayDate, selectedDate),
                    _buildQuickDateBtn('今天', todayDate, selectedDate),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Core scoring display
        if (_isScoring)
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                width: 0.5,
              ),
            ),
            elevation: 0,
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('正在评估今日健康数据，请稍候...'),
                  ],
                ),
              ),
            ),
          )
        else
          scoreAsync.when(
            loading: () => Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                  width: 0.5,
                ),
              ),
              elevation: 0,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
            error: (err, stack) => Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                  width: 0.5,
                ),
              ),
              elevation: 0,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
                child: Center(child: Text('加载评分失败: $err')),
              ),
            ),
            data: (score) {
              if (score != null) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Score wheel card
                    Card(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                          width: 0.5,
                        ),
                      ),
                      elevation: 0,
                      color: theme.colorScheme.surface,
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            _ScoreCircle(score: score.totalScore),
                            const SizedBox(height: 12),
                            TextButton.icon(
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text('重新评分', style: TextStyle(fontSize: 12)),
                              onPressed: () => _confirmAndRescore(context, selectedDate),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Dimension breakdown card
                    Card(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                          width: 0.5,
                        ),
                      ),
                      elevation: 0,
                      color: theme.colorScheme.surface,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Icon(Icons.bar_chart, size: 18, color: theme.colorScheme.primary),
                                ),
                                const SizedBox(width: 8),
                                const Text(
                                  '各维度评分',
                                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            _DimensionScoreBar(
                              name: '睡眠',
                              score: score.dimensionScores['sleep'] ?? 0,
                              color: Colors.indigo,
                            ),
                            _DimensionScoreBar(
                              name: '饮食',
                              score: score.dimensionScores['diet'] ?? 0,
                              color: Colors.green,
                            ),
                            _DimensionScoreBar(
                              name: '活动',
                              score: score.dimensionScores['activity'] ?? 0,
                              color: Colors.orange,
                            ),
                            _DimensionScoreBar(
                              name: '健康',
                              score: score.dimensionScores['health'] ?? 0,
                              color: Colors.redAccent,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // AI Comments and Suggestions
                    _AiSuggestionCard(
                      summary: score.summary,
                      suggestions: score.suggestions,
                    ),
                  ],
                );
              } else {
                // No score exists yet: evaluate records list
                return recordsAsync.when(
                  loading: () => Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                        width: 0.5,
                      ),
                    ),
                    elevation: 0,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 48),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ),
                  error: (err, stack) => Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                        width: 0.5,
                      ),
                    ),
                    elevation: 0,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
                      child: Center(child: Text('检查日记记录失败: $err')),
                    ),
                  ),
                  data: (records) {
                    final count = records.length;
                    if (count < 3) {
                      return Card(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(
                            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                            width: 0.5,
                          ),
                        ),
                        elevation: 0,
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.warning_amber_rounded,
                                size: 48,
                                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                  '当日记录过少',
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                ),
                              const SizedBox(height: 12),
                              Text(
                                '今日仅有 $count 条日记记录，AI 至少需要 3 条记录才能做出准确的生活评分与建议。请记录更多的日常信息（日记、睡眠、饮食或运动记录）后再来评分！',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: theme.colorScheme.onSurfaceVariant,
                                  height: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    } else {
                      return Card(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(
                            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                            width: 0.5,
                          ),
                        ),
                        elevation: 0,
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.insights,
                                size: 48,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                  '分析今日表现',
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                ),
                              const SizedBox(height: 12),
                              Text(
                                '您今天已记录了 $count 条日常信息，快让 AI 为您的一天进行全方位的健康评分和建议吧！',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: theme.colorScheme.onSurfaceVariant,
                                  height: 1.5,
                                ),
                              ),
                              const SizedBox(height: 20),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                  icon: const Icon(Icons.auto_awesome),
                                  label: const Text('开始 AI 智能评分', style: TextStyle(fontWeight: FontWeight.bold)),
                                  onPressed: () => _performScoreAction(context, selectedDate),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                  },
                );
              }
            },
          ),

        const SizedBox(height: 24),
        // 评分热力图卡片
        Card(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              width: 0.5,
            ),
          ),
          elevation: 0,
          color: theme.colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.grid_on, size: 18, color: theme.colorScheme.primary),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      '评分热力图 (近3个月)',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                heatmapAsync.when(
                  loading: () => const SizedBox(
                    height: 140,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (err, stack) => SizedBox(
                    height: 140,
                    child: Center(child: Text('加载热力图失败: $err')),
                  ),
                  data: (scores) => ScoreHeatmap(scores: scores, isDark: isDark),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        // History line chart card
        Card(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              width: 0.5,
            ),
          ),
          elevation: 0,
          color: theme.colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.show_chart, size: 18, color: theme.colorScheme.primary),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      '历史评分趋势 (近7天)',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                historyAsync.when(
                  loading: () => const SizedBox(
                    height: 160,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (err, stack) => SizedBox(
                    height: 160,
                    child: Center(child: Text('加载历史失败: $err')),
                  ),
                  data: (historyScores) => _ScoreHistoryChart(
                    historyScores: historyScores,
                    isDark: isDark,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildQuickDateBtn(String label, DateTime btnDate, DateTime activeDate) {
    final theme = Theme.of(context);
    final isActive = btnDate.year == activeDate.year &&
        btnDate.month == activeDate.month &&
        btnDate.day == activeDate.day;

    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: isActive ? theme.colorScheme.onPrimary : theme.colorScheme.primary,
        backgroundColor: isActive ? theme.colorScheme.primary : Colors.transparent,
        side: BorderSide(
          color: isActive ? Colors.transparent : theme.colorScheme.outlineVariant,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      onPressed: _isScoring
          ? null
          : () {
              ref.read(selectedDateProvider.notifier).state = btnDate;
            },
      child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

class _ScoreCircle extends StatelessWidget {
  final int score;
  const _ScoreCircle({required this.score});

  Color _getScoreColor(int score) {
    if (score >= 90) return Colors.green;
    if (score >= 80) return Colors.blue;
    if (score >= 60) return Colors.orangeAccent;
    if (score >= 40) return Colors.orange;
    return Colors.red;
  }

  String _getScoreLabel(int score) {
    if (score >= 90) return '优秀 ⭐';
    if (score >= 80) return '良好';
    if (score >= 60) return '一般';
    if (score >= 40) return '需改进';
    return '较差';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _getScoreColor(score);
    return Center(
      child: Column(
        children: [
          SizedBox(
            width: 160,
            height: 160,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 150,
                  height: 150,
                  child: CircularProgressIndicator(
                    value: score / 100,
                    strokeWidth: 12,
                    backgroundColor: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$score',
                      style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '/ 100',
                      style: TextStyle(fontSize: 14, color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _getScoreLabel(score),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _DimensionScoreBar extends StatelessWidget {
  final String name;
  final int score;
  final Color color;

  const _DimensionScoreBar({
    required this.name,
    required this.score,
    required this.color,
  });

  String _getScoreLabel(int score) {
    if (score >= 90) return '优秀';
    if (score >= 80) return '良好';
    if (score >= 60) return '一般';
    if (score >= 40) return '需改进';
    return '较差';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(
              name,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: score / 100,
                backgroundColor: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
                valueColor: AlwaysStoppedAnimation(color),
                minHeight: 10,
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 32,
            child: Text(
              '$score',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              _getScoreLabel(score),
              style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}

class _AiSuggestionCard extends StatelessWidget {
  final String summary;
  final String suggestions;

  const _AiSuggestionCard({required this.summary, required this.suggestions});

  /// 将 AI 返回的文本预处理为 Markdown 格式。
  /// 如果文本已经包含 Markdown 标记（换行、加粗、列表等），直接返回；
  /// 如果是纯文本（如 "[1. xxx。，2. xxx。]"），则自动转换为 Markdown 列表。
  static String _formatMarkdownText(String text) {
    // 已包含 Markdown 换行或列表标记，直接返回
    if (text.contains('\n') || text.contains('**') || text.contains('- ') || text.contains('* ')) {
      return text;
    }

    // 处理方括号包裹的列表格式：[1. xxx。，2. xxx。，3. xxx。]
    final trimmed = text.trim();
    if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
      final inner = trimmed.substring(1, trimmed.length - 1).trim();
      // 按 "，" 或 ", " 分隔各条目
      final items = inner.split(RegExp(r'[，,]\s*'));
      return items.map((item) => '- ${item.trim()}').join('\n');
    }

    // 处理 "1. xxx。2. xxx。" 这种编号列表格式（无换行、无方括号）
    final numberedMatch = RegExp(r'\d+\.\s').hasMatch(text);
    if (numberedMatch) {
      // 在每个 "数字. " 前面插入换行（第一个除外）
      final result = text.replaceAllMapped(
        RegExp(r'(?<=\S)\s*(\d+\.\s)'),
        (match) => '\n${match.group(1)}',
      );
      return result;
    }

    // 其他纯文本，直接返回
    return text;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          width: 0.5,
        ),
      ),
      color: theme.colorScheme.surface,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.chat_bubble_outline, size: 18, color: theme.colorScheme.primary),
                ),
                const SizedBox(width: 8),
                const Text(
                  'AI 评价与建议',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (summary.isNotEmpty) ...[
              MarkdownBody(
                data: _formatMarkdownText(summary),
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(fontSize: 14, color: theme.colorScheme.onSurface, height: 1.5),
                ),
              ),
              const Divider(height: 24),
            ],
            if (suggestions.isNotEmpty) ...[
              Row(
                children: [
                  Icon(Icons.lightbulb_outline, size: 16, color: Colors.amber[700]),
                  const SizedBox(width: 4),
                  const Text(
                    '建议',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.blueGrey),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              MarkdownBody(
                data: _formatMarkdownText(suggestions),
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(fontSize: 14, color: theme.colorScheme.onSurface, height: 1.5),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ScoreHistoryChart extends StatelessWidget {
  final List<DailyScore> historyScores;
  final bool isDark;

  const _ScoreHistoryChart({required this.historyScores, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (historyScores.isEmpty) {
      return const SizedBox(
        height: 160,
        child: Center(child: Text('近 7 天暂无评分历史')),
      );
    }

    final spots = <FlSpot>[];
    for (var i = 0; i < historyScores.length; i++) {
      spots.add(FlSpot(i.toDouble(), historyScores[i].totalScore.toDouble()));
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
      height: 200,
      child: LineChart(
        LineChartData(
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: 20,
            getDrawingHorizontalLine: (value) => FlLine(
              color: isDark ? const Color(0xFF2A2D36) : const Color(0xFFE4E4E7),
              strokeWidth: 1,
            ),
          ),
          titlesData: FlTitlesData(
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 32,
                getTitlesWidget: (value, meta) {
                  final idx = value.toInt();
                  if (idx < 0 || idx >= historyScores.length) return const SizedBox.shrink();
                  final scoreDate = historyScores[idx].date;
                  final label = '${scoreDate.month}/${scoreDate.day}';
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                      ),
                    ),
                  );
                },
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 36,
                interval: 20,
                getTitlesWidget: (value, meta) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                      '${value.toInt()}',
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                      ),
                      textAlign: TextAlign.end,
                    ),
                  );
                },
              ),
            ),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          borderData: FlBorderData(show: false),
          minY: 0,
          maxY: 100,
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: theme.colorScheme.primary,
              barWidth: 3,
              dotData: const FlDotData(show: true),
              belowBarData: BarAreaData(
                show: true,
                color: theme.colorScheme.primary.withValues(alpha: 0.1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
