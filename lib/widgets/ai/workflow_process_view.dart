import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/agent/agent_tool_labels.dart';
import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/theme/app_typography.dart';
import 'package:qnote_flutter/core/utils/chat_timeline.dart';
import 'package:qnote_flutter/core/utils/expand_reveal.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/widgets/common/app_collapsible.dart';
import 'package:qnote_flutter/widgets/common/thinking_process_view.dart';

/// 通用「单行折叠工作流」组件（对齐 ZCode 对话流交互）：
/// - 默认折叠为一行：运行中单行流水展示最新思考或当前/刚完成的工具动作，
///   完成后自动收拢为聚合摘要（如「思考 8 秒 · 查阅 4 项，修改 1 项」）；
/// - 点击标题行平滑展开，带左侧竖向时间引导线，按顺序展示思考段、工具详情与过程说明；
/// - 通过 [expanded] / [onExpandedChanged] 支持由外层按 turnKey 跨「流式 → 落库」保留展开态。
class WorkflowProcessView extends StatefulWidget {
  final WorkflowData workflow;

  /// 工具步骤详情构建器；由宿主注入以复用主对话专属卡片或悬浮窗精简条
  final Widget Function(BuildContext context, ChatMessage toolMessage) toolBuilder;

  /// 受控展开态；为 null 时由组件内部自管
  final bool? expanded;
  final ValueChanged<bool>? onExpandedChanged;

  /// 紧凑布局（供悬浮小Q 面板等小空间使用）
  final bool compact;

  /// 以下字段仅在 `workflow.isLive == true` 时用于单行流水与展开区实时尾部展示
  final String? liveThought;
  final DateTime? liveTurnStartedAt;
  final String? liveStatusText;
  final DateTime? liveStartedAt;

  /// 最终答复正文是否已开始流式输出；已开始时收拢为汇总行，
  /// 进行中信号由正文本身承载（「工作中」徽章挂在身份行，见 AgentWorkingBadge）
  final bool hasStreamingOutput;

  /// 展开区错误步骤的「重试本轮」回调；为 null 时不展示重试入口
  final VoidCallback? onRetry;

  /// 长按折叠行时回调（宿主用于弹出错误操作菜单）；为 null 时长按不响应
  final VoidCallback? onErrorLongPress;

  const WorkflowProcessView({
    super.key,
    required this.workflow,
    required this.toolBuilder,
    this.expanded,
    this.onExpandedChanged,
    this.compact = false,
    this.liveThought,
    this.liveTurnStartedAt,
    this.liveStatusText,
    this.liveStartedAt,
    this.hasStreamingOutput = false,
    this.onRetry,
    this.onErrorLongPress,
  });

  @override
  State<WorkflowProcessView> createState() => _WorkflowProcessViewState();
}

class _WorkflowProcessViewState extends State<WorkflowProcessView> {
  bool _internalExpanded = false;

  /// 折叠区根部（标题行 + 展开内容）：展开后据此把内容滚入视野（只需刚好完整露出）
  final _revealKey = GlobalKey();
  late final _revealer = ExpandRevealFollower(_revealKey);

  bool get _isExpanded => widget.expanded ?? _internalExpanded;

  @override
  void dispose() {
    _revealer.cancel();
    super.dispose();
  }

  void _toggle() {
    final next = !_isExpanded;
    if (next) {
      _revealer.start();
    } else {
      _revealer.cancel();
    }
    if (widget.onExpandedChanged != null) {
      widget.onExpandedChanged!(next);
      return;
    }
    setState(() => _internalExpanded = next);
  }

  static bool _isThinkingOrPrepStatus(String? text) {
    if (text == null || text.isEmpty) return false;
    return text.startsWith('小Q思考中') || text.startsWith('小Q准备中');
  }

  static bool _isRateLimitStatus(String? text) {
    if (text == null || text.isEmpty) return false;
    return text.startsWith('服务商限流');
  }

  static String _stripStatusPrefix(String text) {
    return text.startsWith('⚡ ') ? text.substring(2) : text;
  }

  static IconData _iconForTool(String toolName, {bool isError = false}) {
    if (isError) return Icons.error_outline_rounded;
    return switch (AgentToolLabels.categoryOf(toolName)) {
      AgentToolCategory.read => Icons.search_rounded,
      AgentToolCategory.write => Icons.edit_note_rounded,
      AgentToolCategory.skill => Icons.extension_outlined,
      AgentToolCategory.other => Icons.bolt_rounded,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final expanded = _isExpanded;
    final workflow = widget.workflow;
    final isLive = workflow.isLive;
    final liveThought = widget.liveThought?.trim() ?? '';
    final liveStatus = widget.liveStatusText?.trim();
    final hasActiveToolStatus =
        isLive &&
        !widget.hasStreamingOutput &&
        liveStatus != null &&
        liveStatus.isNotEmpty &&
        !_isThinkingOrPrepStatus(liveStatus) &&
        !_isRateLimitStatus(liveStatus);
    final hasLiveThought = isLive && !widget.hasStreamingOutput && !hasActiveToolStatus && liveThought.isNotEmpty;

    final Widget headerContent = _buildHeaderContent(
      context: context,
      theme: theme,
      expanded: expanded,
      isLive: isLive,
      liveThought: liveThought,
      liveStatus: liveStatus,
      hasActiveToolStatus: hasActiveToolStatus,
      hasLiveThought: hasLiveThought,
    );

    final hasExpandableSteps = workflow.steps.isNotEmpty || (isLive && (liveThought.isNotEmpty || hasActiveToolStatus));

    return Column(
      key: _revealKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 顶部折叠行：运行中作单行流水展示，完成后作汇总行，点击平滑展开/收起
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: hasExpandableSteps ? _toggle : null,
            onLongPress: widget.onErrorLongPress,
            borderRadius: BorderRadius.circular(8),
            child: Semantics(
              button: hasExpandableSteps,
              label: expanded ? '收起工作流' : '展开工作流',
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: widget.compact ? 2 : 4, vertical: widget.compact ? 4 : 5),
                child: Row(
                  children: [
                    Expanded(
                      child: AppMotion.switcher(context: context, scale: false, child: headerContent),
                    ),
                    if (hasExpandableSteps) ...[
                      const SizedBox(width: 6),
                      AnimatedRotation(
                        turns: expanded ? 0.5 : 0,
                        duration: AppMotion.duration(context, AppDurations.normal),
                        curve: AppCurves.emphasized,
                        child: Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: colorScheme.outline),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        // 展开态：左侧竖向时间引导线 + 全部步骤
        AppCollapsible(
          expanded: expanded && hasExpandableSteps,
          rise: 0,
          child: expanded && hasExpandableSteps
              ? _buildExpandedTimeline(
                  context: context,
                  theme: theme,
                  isLive: isLive,
                  liveThought: liveThought,
                  liveStatus: liveStatus,
                  hasActiveToolStatus: hasActiveToolStatus,
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildHeaderContent({
    required BuildContext context,
    required ThemeData theme,
    required bool expanded,
    required bool isLive,
    required String liveThought,
    required String? liveStatus,
    required bool hasActiveToolStatus,
    required bool hasLiveThought,
  }) {
    final colorScheme = theme.colorScheme;
    final workflow = widget.workflow;
    final stepCount = workflow.steps.length;

    // 0. 本轮以错误收尾：折叠行只留一行错误标题。
    // 此前已完成的思考/工具步骤仍完整保留在展开区，用户可以先看清工作到哪一步再决定重试。
    final errorStep = workflow.errorStep;
    if (!expanded && errorStep != null) {
      return Row(
        key: ValueKey('wf_error_${workflow.turnKey}'),
        children: [
          Icon(Icons.error_outline_rounded, size: 15, color: colorScheme.error),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              workflowErrorTitle(errorStep.message.content),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTypography.bodySmall,
                fontWeight: FontWeight.w500,
                color: colorScheme.error,
              ),
            ),
          ),
        ],
      );
    }

    // 1. 正在执行/调用工具（运行中且折叠态，优先展示实时工具动作）
    if (!expanded && hasActiveToolStatus) {
      final cleanStatus = _stripStatusPrefix(liveStatus!);
      return Row(
        key: ValueKey('wf_live_tool_$stepCount'),
        children: [
          ThinkingBreathingGlyph(isStreaming: true, icon: Icons.bolt_rounded, color: theme.accentInk),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              cleanStatus,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTypography.bodySmall,
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurface.withValues(alpha: 0.88),
              ),
            ),
          ),
        ],
      );
    }

    // 2. 正在思考（运行中且折叠态）
    if (!expanded && hasLiveThought) {
      final latest = thoughtPreviewText(liveThought);
      return Row(
        key: ValueKey('wf_live_thought_$stepCount'),
        children: [
          ThinkingBreathingGlyph(isStreaming: true, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 7),
          Text(
            '思考',
            style: TextStyle(
              fontSize: AppTypography.bodySmall,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          StreamingThoughtClock(startedAt: widget.liveTurnStartedAt),
          const SizedBox(width: 8),
          Expanded(
            child: RollingSingleLineText(
              text: latest,
              style: TextStyle(
                fontSize: AppTypography.bodySmall,
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
              ),
            ),
          ),
        ],
      );
    }

    // 3. 运行中但处于步骤间隙且已产出步骤（折叠态展示刚刚完成的最新一步，对齐 ZCode 图 2）
    if (isLive && !expanded && !widget.hasStreamingOutput && workflow.steps.isNotEmpty) {
      final lastStep = workflow.steps.last;
      return _buildCompletedStepPreviewRow(
        key: ValueKey('wf_done_step_${stepCount - 1}'),
        colorScheme: colorScheme,
        step: lastStep,
      );
    }

    // 4. 运行中但尚未有步骤与思考（准备阶段兜底）
    if (isLive && !expanded && !widget.hasStreamingOutput && workflow.steps.isEmpty) {
      final status = liveStatus?.isNotEmpty == true ? liveStatus! : '小Q思考中';
      return Row(
        key: const ValueKey('wf_live_prep'),
        children: [
          ThinkingBreathingGlyph(isStreaming: true, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTypography.bodySmall,
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          StreamingThoughtClock(startedAt: widget.liveStartedAt),
        ],
      );
    }

    // 5. 已完成 / 已展开 / 正在输出正文：展示汇总文案
    final summary = workflow.summary;
    final hasError = summary.hasError;
    // 完成后对齐 ZCode 只显示「已工作 X 分 Y 秒」总耗时（异常数保留），动作计数收进展开区；
    // 缺起止时间（旧数据 / 测试样例）时回退步骤汇总
    final totalText = isLive ? null : workflow.totalWorkDurationText;
    final summaryText = isLive && summary.totalStepCount == 0
        ? '处理中'
        : isLive
        ? (widget.hasStreamingOutput ? summary.formatText() : '进行中 · ${summary.formatText()}')
        : (totalText != null
              ? (hasError ? '$totalText · ${summary.errorCount} 项异常' : totalText)
              : summary.formatText());

    return Row(
      key: ValueKey('wf_summary_${workflow.turnKey}_${isLive}_$stepCount'),
      children: [
        Icon(
          hasError ? Icons.error_outline_rounded : Icons.timeline_rounded,
          size: 15,
          color: hasError ? colorScheme.error : colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            summaryText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppTypography.bodySmall,
              fontWeight: FontWeight.w500,
              color: hasError ? colorScheme.error : colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCompletedStepPreviewRow({
    required Key key,
    required ColorScheme colorScheme,
    required WorkflowStep step,
  }) {
    switch (step.kind) {
      case WorkflowStepKind.tool:
        final label = AgentToolLabels.completedLineLabel(
          step.toolName,
          details: step.message.uiDetails,
          isError: step.isError,
        );
        return Row(
          key: key,
          children: [
            Icon(
              _iconForTool(step.toolName, isError: step.isError),
              size: 15,
              color: step.isError ? colorScheme.error : colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppTypography.bodySmall,
                  fontWeight: FontWeight.w500,
                  color: step.isError ? colorScheme.error : colorScheme.onSurface.withValues(alpha: 0.88),
                ),
              ),
            ),
          ],
        );
      case WorkflowStepKind.thought:
        final durationText = formatWorkflowDuration(step.thoughtSeconds);
        return Row(
          key: key,
          children: [
            Icon(Icons.psychology_outlined, size: 15, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 7),
            Text(
              '思考',
              style: TextStyle(
                fontSize: AppTypography.bodySmall,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (durationText.isNotEmpty)
              Text(
                ' · $durationText',
                style: TextStyle(fontSize: AppTypography.bodySmall, color: colorScheme.outline),
              ),
            const SizedBox(width: 8),
            Expanded(
              // 与实时思考行同样贴尾滚动：步骤完成后仍露出最新内容，
              // 只取最后一行时遇到结尾的「简短回答」这类短语会只剩几个字
              child: RollingSingleLineText(
                text: thoughtPreviewText(step.message.content),
                style: TextStyle(
                  fontSize: AppTypography.bodySmall,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
                ),
              ),
            ),
          ],
        );
      case WorkflowStepKind.prose:
        final excerpt = step.message.content.trim().replaceAll('\n', ' ');
        return Row(
          key: key,
          children: [
            Icon(Icons.notes_rounded, size: 15, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                excerpt,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppTypography.bodySmall,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.88),
                ),
              ),
            ),
          ],
        );
      case WorkflowStepKind.error:
        return Row(
          key: key,
          children: [
            Icon(Icons.error_outline_rounded, size: 15, color: colorScheme.error),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                workflowErrorTitle(step.message.content),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: AppTypography.bodySmall, color: colorScheme.error),
              ),
            ),
          ],
        );
    }
  }

  Widget _buildExpandedTimeline({
    required BuildContext context,
    required ThemeData theme,
    required bool isLive,
    required String liveThought,
    required String? liveStatus,
    required bool hasActiveToolStatus,
  }) {
    final colorScheme = theme.colorScheme;
    final steps = widget.workflow.steps;

    return Padding(
      padding: EdgeInsets.only(left: widget.compact ? 8 : 10, top: 2, bottom: widget.compact ? 4 : 6),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.55), width: 1.5)),
        ),
        padding: EdgeInsets.only(left: widget.compact ? 10 : 12),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: widget.compact ? 220 : 420),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < steps.length; i++) _buildStepItem(context, theme, steps[i]),
                if (isLive && !widget.hasStreamingOutput && liveThought.isNotEmpty)
                  ThinkingProcessView(
                    thought: liveThought,
                    isStreaming: !hasActiveToolStatus,
                    startedAt: widget.liveTurnStartedAt,
                    compact: true,
                  ),
                if (isLive && hasActiveToolStatus && liveStatus != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                    child: Row(
                      children: [
                        ThinkingBreathingGlyph(
                          isStreaming: true,
                          icon: Icons.bolt_rounded,
                          color: theme.accentInk,
                          size: 14,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _stripStatusPrefix(liveStatus),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: AppTypography.bodySmall, color: colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStepItem(BuildContext context, ThemeData theme, WorkflowStep step) {
    switch (step.kind) {
      case WorkflowStepKind.thought:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: ThinkingProcessView(
            thought: step.message.content,
            durationSeconds: step.thoughtSeconds,
            compact: true,
          ),
        );
      case WorkflowStepKind.tool:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: widget.toolBuilder(context, step.message),
        );
      case WorkflowStepKind.prose:
        return _IntermediateProseStep(text: step.message.content.trim(), theme: theme);
      case WorkflowStepKind.error:
        return _ErrorStep(text: step.message.content.trim(), compact: widget.compact, onRetry: widget.onRetry);
    }
  }
}

/// 展开区里的错误详情步骤：完整错误正文 + 「重试本轮」入口。
///
/// 错误正文只在这里完整展示，折叠行仅保留一行标题，避免失败提示抢占整个屏幕。
class _ErrorStep extends StatelessWidget {
  final String text;
  final bool compact;
  final VoidCallback? onRetry;

  const _ErrorStep({required this.text, required this.compact, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: EdgeInsets.symmetric(vertical: compact ? 2 : 4),
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10, vertical: compact ? 6 : 8),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.error.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.error_outline_rounded, size: 14, color: colorScheme.error),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: AppTypography.bodySmall,
                    height: 1.45,
                    color: colorScheme.onSurface.withValues(alpha: 0.9),
                  ),
                ),
              ),
            ],
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 2),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 15),
                label: const Text('重试本轮'),
                style: TextButton.styleFrom(
                  foregroundColor: colorScheme.error,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 展开态中的「中间过渡文本」步骤（如工具调用前的「我先查一下…」）：
/// 超长时默认截取前 2 行并支持点击展开全文，不抢占最终输出重心。
class _IntermediateProseStep extends StatefulWidget {
  final String text;
  final ThemeData theme;

  const _IntermediateProseStep({required this.text, required this.theme});

  @override
  State<_IntermediateProseStep> createState() => _IntermediateProseStepState();
}

class _IntermediateProseStepState extends State<_IntermediateProseStep> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = widget.theme.colorScheme;
    final isLong = widget.text.length > 80 || widget.text.contains('\n');
    return InkWell(
      onTap: isLong ? () => setState(() => _expanded = !_expanded) : null,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(Icons.notes_rounded, size: 14, color: colorScheme.outline),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                widget.text,
                maxLines: _expanded ? null : 2,
                overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                style: TextStyle(fontSize: AppTypography.bodySmall, height: 1.45, color: colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
