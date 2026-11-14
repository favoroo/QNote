import 'package:qnote_flutter/core/agent/agent_tool_labels.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 耗时展示文案（如「3 秒」「1 分 20 秒」）；无有效秒数返回空串
///
/// 秒数缺失时不展示，避免出现「0 秒」这类没有信息量的占位。
String formatWorkflowDuration(int? seconds) {
  if (seconds == null || seconds < 1) {
    return '';
  }
  if (seconds < 60) {
    return '$seconds 秒';
  }
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  return rest == 0 ? '$minutes 分' : '$minutes 分 $rest 秒';
}

/// 工作流内的单个步骤类型
enum WorkflowStepKind {
  /// 模型思考段
  thought,

  /// 常规工具执行结果
  tool,

  /// 工具调用前的中间过渡说明文本（非最终答复）
  prose,
}

/// 折叠工作流中的单条时间线步骤
class WorkflowStep {
  final WorkflowStepKind kind;
  final ChatMessage message;

  const WorkflowStep({required this.kind, required this.message});

  bool get isError => message.isError == true;

  String get toolName => message.toolName ?? '';

  int? get thoughtSeconds => message.thoughtSeconds;
}

/// 一段工作流的汇总统计，用于折叠态单行文案生成
class WorkflowSummary {
  final int thoughtCount;
  final int totalThoughtSeconds;
  final int readCount;
  final int writeCount;
  final int skillCount;
  final int otherToolCount;
  final int proseCount;
  final int errorCount;

  const WorkflowSummary({
    this.thoughtCount = 0,
    this.totalThoughtSeconds = 0,
    this.readCount = 0,
    this.writeCount = 0,
    this.skillCount = 0,
    this.otherToolCount = 0,
    this.proseCount = 0,
    this.errorCount = 0,
  });

  int get totalToolCount => readCount + writeCount + skillCount + otherToolCount;

  int get totalStepCount => thoughtCount + totalToolCount + proseCount;

  bool get hasError => errorCount > 0;

  factory WorkflowSummary.fromSteps(List<WorkflowStep> steps) {
    var thoughtCount = 0;
    var totalThoughtSeconds = 0;
    var readCount = 0;
    var writeCount = 0;
    var skillCount = 0;
    var otherToolCount = 0;
    var proseCount = 0;
    var errorCount = 0;

    for (final step in steps) {
      switch (step.kind) {
        case WorkflowStepKind.thought:
          thoughtCount++;
          final sec = step.thoughtSeconds;
          if (sec != null && sec > 0) {
            totalThoughtSeconds += sec;
          }
        case WorkflowStepKind.tool:
          if (step.isError) errorCount++;
          switch (AgentToolLabels.categoryOf(step.toolName)) {
            case AgentToolCategory.read:
              readCount++;
            case AgentToolCategory.write:
              writeCount++;
            case AgentToolCategory.skill:
              skillCount++;
            case AgentToolCategory.other:
              otherToolCount++;
          }
        case WorkflowStepKind.prose:
          proseCount++;
      }
    }

    return WorkflowSummary(
      thoughtCount: thoughtCount,
      totalThoughtSeconds: totalThoughtSeconds,
      readCount: readCount,
      writeCount: writeCount,
      skillCount: skillCount,
      otherToolCount: otherToolCount,
      proseCount: proseCount,
      errorCount: errorCount,
    );
  }

  /// 生成 ZCode 风格的折叠单行汇总文案（如「思考 8 秒 · 查阅 4 项，修改 1 项」）
  String formatText() {
    final actionParts = <String>[
      if (readCount > 0) '查阅 $readCount 项',
      if (writeCount > 0) '修改 $writeCount 项',
      if (skillCount > 0) '调用技能 $skillCount 次',
      if (otherToolCount > 0) '执行 $otherToolCount 项',
    ];
    final actionText = actionParts.join('，');

    String? thoughtText;
    if (thoughtCount > 0) {
      final duration = formatWorkflowDuration(totalThoughtSeconds);
      if (duration.isNotEmpty) {
        thoughtText = totalToolCount == 0 && thoughtCount > 1 ? '思考 $thoughtCount 轮 · $duration' : '思考 $duration';
      } else {
        thoughtText = totalToolCount == 0 && thoughtCount > 1 ? '思考 $thoughtCount 轮' : '已思考';
      }
    }

    String base;
    if (thoughtText != null && actionText.isNotEmpty) {
      base = '$thoughtText · $actionText';
    } else if (thoughtText != null) {
      base = thoughtText;
    } else if (actionText.isNotEmpty) {
      base = actionText;
    } else if (proseCount > 0) {
      base = '过程记录 $proseCount 条';
    } else {
      base = '工作流';
    }

    if (errorCount > 0) {
      return '$base · $errorCount 项异常';
    }
    return base;
  }
}

/// 挂在 `role: 'workflow'` 时间线消息 `uiDetails['workflow']` 上的只读视图数据
class WorkflowData {
  /// 轮次锚点键（同一轮流式与落库后相同，用于保持用户的手动展开态）
  final String turnKey;
  final List<WorkflowStep> steps;
  final WorkflowSummary summary;

  /// 该段工作流是否位于当前仍在执行的活跃轮次尾部
  final bool isLive;

  const WorkflowData({required this.turnKey, required this.steps, required this.summary, this.isLive = false});
}

/// 会话时间线上的一个展示项
///
/// [stateIndex] 指向该项在原始 `session.messages` 中的下标（撤回/重试要用）；
/// 思考步骤与折叠工作流属于派生项，没有原始行，保持 null。
class ChatTimelineEntry {
  final ChatMessage message;
  final int? stateIndex;

  const ChatTimelineEntry(this.message, [this.stateIndex]);
}

/// 单条消息是否需要作为独立气泡展示
///
/// Agent 在每轮发起工具调用前，都会生成一条「正文为空、仅承载 tool_calls」的
/// assistant 消息来维持协议完整。这类消息属于内部中转，不应单独成泡；
/// 它的思考段会在 [buildChatTimelineEntries] 里被归入工作流步骤。
bool isChatTimelineVisibleMessage(ChatMessage message) {
  if (message.role == 'user') return true;
  if (message.content.trim().isNotEmpty) return true;
  if (message.role == 'tool') return true;
  if (message.uiDetails != null) return true;
  return false;
}

/// 工具结果是否可收进折叠工作流
///
/// `ask_user` 需保持独立交互确认卡片；`generate_image` 需保持独立大图卡片——
/// 若被折叠隐藏，正文里的同图又已按「卡片已展示」去重，用户将看不到图片或问答结果。
bool isGroupableToolMessage(ChatMessage message) {
  return message.toolName != 'ask_user' && message.toolName != 'generate_image';
}

/// 把会话消息归一成 ZCode 风格的时间线展示项。
///
/// 规则：
/// 1. 同一轮回复（从上一条 `user` 消息到下一条 `user` 消息之间）的所有思考段、
///    常规工具结果与中间过渡文案归并成一条默认折叠的 `role: 'workflow'` 项；
/// 2. `ask_user`、`generate_image`、`turn_limit` 与 `isError` 助手消息保持外露；
/// 3. 单段纯思考（仅 1 条 `thought`、无工具且无过渡文案，且非流式进行中）直接输出
///    `role: 'thought'`，点击一次即可展开思考全文，避免无意义的二层嵌套；
/// 4. 当 [isLiveTurn] 为 true 时，最后一轮末尾的工作流标记 `isLive: true`，
///    由工作流组件直接承接流式思考/工具进度，避免流式占位与已落库步骤割裂。
List<ChatTimelineEntry> buildChatTimelineEntries(List<ChatMessage> messages, {bool isLiveTurn = false}) {
  final entries = <ChatTimelineEntry>[];
  var pendingSteps = <WorkflowStep>[];
  var currentUserIndex = -1;
  var segmentIndex = 0;

  String nextTurnKey() {
    final key = 'turn_${currentUserIndex}_$segmentIndex';
    segmentIndex++;
    return key;
  }

  void flushPending({required bool live}) {
    if (pendingSteps.isEmpty) return;
    final steps = List<WorkflowStep>.unmodifiable(pendingSteps);
    pendingSteps = <WorkflowStep>[];
    final turnKey = nextTurnKey();

    // 非流式进行中且仅有一段纯思考时直出 thought 行，一次点击即展开
    if (!live && steps.length == 1 && steps.first.kind == WorkflowStepKind.thought) {
      final msg = steps.first.message;
      entries.add(ChatTimelineEntry(msg.copyWith(uiDetails: {...?msg.uiDetails, 'turnKey': turnKey})));
      return;
    }

    final summary = WorkflowSummary.fromSteps(steps);
    final workflow = WorkflowData(turnKey: turnKey, steps: steps, summary: summary, isLive: live);
    entries.add(
      ChatTimelineEntry(
        ChatMessage(
          role: 'workflow',
          content: '',
          timestamp: steps.first.message.timestamp,
          uiDetails: {'workflow': workflow},
        ),
      ),
    );
  }

  // 判断当前下标之后、下一条 user 消息之前，是否还有工具或助手消息（用于识别中间过渡文案）
  bool hasLaterActivityInTurn(int index) {
    for (var k = index + 1; k < messages.length; k++) {
      final next = messages[k];
      if (next.role == 'user') return false;
      if (next.role == 'tool') return true;
      if (next.role == 'assistant' && isChatTimelineVisibleMessage(next)) {
        return true;
      }
      if (next.role == 'assistant' && (next.thought?.trim().isNotEmpty ?? false)) {
        return true;
      }
    }
    return false;
  }

  for (var i = 0; i < messages.length; i++) {
    final msg = messages[i];

    if (msg.role == 'user') {
      flushPending(live: false);
      entries.add(ChatTimelineEntry(msg, i));
      currentUserIndex = i;
      segmentIndex = 0;
      continue;
    }

    if (msg.role == 'tool') {
      if (isGroupableToolMessage(msg)) {
        pendingSteps.add(WorkflowStep(kind: WorkflowStepKind.tool, message: msg));
      } else {
        flushPending(live: false);
        entries.add(ChatTimelineEntry(msg, i));
      }
      continue;
    }

    if (msg.role == 'assistant') {
      final thought = msg.thought?.trim() ?? '';
      if (thought.isNotEmpty) {
        pendingSteps.add(
          WorkflowStep(
            kind: WorkflowStepKind.thought,
            message: ChatMessage(
              role: 'thought',
              content: thought,
              thoughtSeconds: msg.thoughtSeconds,
              timestamp: msg.timestamp,
            ),
          ),
        );
      }

      // 步数上限与错误卡片始终外露，不折入工作流
      final isTurnLimitOrError = msg.uiDetails != null || msg.isError == true;
      if (isTurnLimitOrError) {
        flushPending(live: false);
        entries.add(ChatTimelineEntry(thought.isEmpty ? msg : msg.copyWith(thought: ''), i));
        continue;
      }

      if (!isChatTimelineVisibleMessage(msg)) {
        continue;
      }

      // 附带 toolCalls 或同轮后面还有工具/后续回复：属于中间过渡文案，收进工作流
      final hasToolCalls = msg.toolCalls?.isNotEmpty ?? false;
      if (hasToolCalls || hasLaterActivityInTurn(i)) {
        pendingSteps.add(
          WorkflowStep(
            kind: WorkflowStepKind.prose,
            message: thought.isEmpty ? msg : msg.copyWith(thought: ''),
          ),
        );
        continue;
      }

      // 到达本轮最终输出：先结算前面累积的工作流，再外露最终答复气泡
      flushPending(live: false);
      entries.add(ChatTimelineEntry(thought.isEmpty ? msg : msg.copyWith(thought: ''), i));
      continue;
    }

    if (isChatTimelineVisibleMessage(msg)) {
      flushPending(live: false);
      entries.add(ChatTimelineEntry(msg, i));
    }
  }

  flushPending(live: isLiveTurn);
  return entries;
}
