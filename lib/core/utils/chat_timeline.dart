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

  /// 本轮请求失败的错误详情
  ///
  /// 错误提示属于 UI 反馈而非模型输出，折入工作流尾部后不再单独占据一整个气泡；
  /// 折叠行只留一行标题，完整错误展开可见。
  error,
}

/// 折叠工作流中的单条时间线步骤
class WorkflowStep {
  final WorkflowStepKind kind;
  final ChatMessage message;

  /// 该步骤在原始 `session.messages` 中的下标（仅错误步骤需要，用于定位重试）
  final int? stateIndex;

  const WorkflowStep({required this.kind, required this.message, this.stateIndex});

  bool get isError => kind == WorkflowStepKind.error || message.isError == true;

  String get toolName => message.toolName ?? '';

  int? get thoughtSeconds => message.thoughtSeconds;
}

/// 错误详情的单行标题：取第一行有效文本并去掉 Markdown 标记。
///
/// 折叠行只展示这一行（让用户知道本轮失败、可点开看详情），
/// 完整错误正文由展开区展示。
String workflowErrorTitle(String content) {
  for (final rawLine in content.split('\n')) {
    var line = rawLine.trim();
    if (line.isEmpty) continue;
    line = line.replaceFirst(RegExp(r'^#+\s*'), '').replaceAll('**', '').trim();
    if (line.isNotEmpty) return line;
  }
  return '本轮对话请求失败';
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

  /// 其中因「本轮请求失败」折入的错误步骤数（区别于工具执行失败）
  final int errorStepCount;

  const WorkflowSummary({
    this.thoughtCount = 0,
    this.totalThoughtSeconds = 0,
    this.readCount = 0,
    this.writeCount = 0,
    this.skillCount = 0,
    this.otherToolCount = 0,
    this.proseCount = 0,
    this.errorCount = 0,
    this.errorStepCount = 0,
  });

  int get totalToolCount => readCount + writeCount + skillCount + otherToolCount;

  int get totalStepCount => thoughtCount + totalToolCount + proseCount + errorStepCount;

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
    var errorStepCount = 0;

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
        case WorkflowStepKind.error:
          errorStepCount++;
          errorCount++;
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
      errorStepCount: errorStepCount,
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

  /// 本段工作的时间跨度：起点为本轮 user 消息落库时间，终点为触发结算的消息
  /// （最终答复 / 外露卡片 / 下一条 user）的落库时间；运行中结束时间为 null。
  /// 缺任一端（旧数据、测试样例）时折叠行回退为步骤汇总文案
  final DateTime? startedAt;
  final DateTime? endedAt;

  const WorkflowData({
    required this.turnKey,
    required this.steps,
    required this.summary,
    this.isLive = false,
    this.startedAt,
    this.endedAt,
  });

  /// 完成态折叠行的「已工作 X 分 Y 秒」总耗时（对齐 ZCode）；
  /// 不足 1 秒或缺起止时间时返回 null，由调用方回退步骤汇总
  String? get totalWorkDurationText {
    final start = startedAt;
    final end = endedAt;
    if (start == null || end == null) return null;
    final seconds = end.difference(start).inSeconds;
    if (seconds < 1) return null;
    final duration = formatWorkflowDuration(seconds);
    return duration.isEmpty ? null : '已工作 $duration';
  }

  /// 本轮失败的错误步骤（若有）；折叠行据此展示单行错误标题
  WorkflowStep? get errorStep {
    for (var i = steps.length - 1; i >= 0; i--) {
      if (steps[i].kind == WorkflowStepKind.error) return steps[i];
    }
    return null;
  }
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
/// 2. `ask_user`、`generate_image`、`turn_limit` 保持外露；本轮请求失败的错误详情
///    作为 `WorkflowStepKind.error` 折入工作流尾部（折叠行只留一行标题），
///    保证出错后此前的工作过程仍可展开查看；
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

  // [endedAt] 为触发本次结算的消息落库时间（最终答复 / 外露卡片 / 下一条 user），
  // 与段起点组成「已工作」总耗时；运行中的收尾结算不传（结束时间未定）。
  // 段起点取「上一段结算时间」，多段轮次（ask_user / 步数上限后继续）不把
  // 用户停顿的时间算进下一段工作量
  DateTime? lastSegmentEnd;
  void flushPending({required bool live, DateTime? endedAt}) {
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
    // 段起点：优先取上一段结算后新出现的 user 消息时间（用户停顿不计入下一段），
    // 没有新 user（ask_user 以工具结果续跑等）则沿用上一段结算时间
    final userTs = currentUserIndex >= 0 ? messages[currentUserIndex].timestamp : null;
    final prevEnd = lastSegmentEnd;
    final startedAt = (userTs != null && (prevEnd == null || userTs.isAfter(prevEnd))) ? userTs : (prevEnd ?? userTs);
    final workflow = WorkflowData(
      turnKey: turnKey,
      steps: steps,
      summary: summary,
      isLive: live,
      startedAt: startedAt,
      endedAt: endedAt,
    );
    if (endedAt != null) {
      lastSegmentEnd = endedAt;
    }
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
      flushPending(live: false, endedAt: i > 0 ? messages[i - 1].timestamp : null);
      entries.add(ChatTimelineEntry(msg, i));
      currentUserIndex = i;
      segmentIndex = 0;
      continue;
    }

    if (msg.role == 'tool') {
      if (isGroupableToolMessage(msg)) {
        pendingSteps.add(WorkflowStep(kind: WorkflowStepKind.tool, message: msg));
      } else {
        flushPending(live: false, endedAt: msg.timestamp);
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

      // 请求失败：错误详情作为工作流最后一步收进折叠区，不再单独占据一整张气泡；
      // 带上原始下标，展开区据此定位并「重试本轮」
      if (msg.isError == true) {
        pendingSteps.add(
          WorkflowStep(
            kind: WorkflowStepKind.error,
            message: thought.isEmpty ? msg : msg.copyWith(thought: ''),
            stateIndex: i,
          ),
        );
        flushPending(live: false, endedAt: msg.timestamp);
        continue;
      }

      // 步数上限卡片始终外露（需要保留「继续/暂停」按钮）
      if (msg.uiDetails != null) {
        flushPending(live: false, endedAt: msg.timestamp);
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
      flushPending(live: false, endedAt: msg.timestamp);
      entries.add(ChatTimelineEntry(thought.isEmpty ? msg : msg.copyWith(thought: ''), i));
      continue;
    }

    if (isChatTimelineVisibleMessage(msg)) {
      flushPending(live: false, endedAt: msg.timestamp);
      entries.add(ChatTimelineEntry(msg, i));
    }
  }

  flushPending(live: isLiveTurn);
  return entries;
}
