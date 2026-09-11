import 'dart:async';
import 'dart:convert';
import 'package:qnote_flutter/core/agent/engine/agent_cancellation_token.dart';
import 'package:qnote_flutter/core/agent/engine/agent_events.dart';
import 'package:qnote_flutter/core/agent/engine/tool_dispatcher.dart';
import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 「小Q」全智能 Agent ReAct 循环引擎（对齐 Pi Agent 架构）
///
/// 核心特性：
/// 1. 十级细粒度生命周期事件流 (Lifecycle Events)
/// 2. 上下文转换与防爆机制 (transformContext)
/// 3. 并行与串行混合工具调度 (Parallel & Sequential Tool Execution)
/// 4. 生命周期钩子系统 (beforeToolCall, afterToolCall, shouldStopAfterTurn)
/// 5. 动态中断与取消控制 (AgentCancellationToken)
class AgentLoop {
  final AiService aiService;
  final ToolDispatcher dispatcher;
  final int maxTurns;
  final Future<void> Function(ToolCall call)? beforeToolCall;
  final Future<void> Function(ToolCall call, ChatMessage result)? afterToolCall;
  final FutureOr<bool> Function(ChatMessage lastAssistantMessage, int turn)? shouldStopAfterTurn;
  final List<ChatMessage> Function(List<ChatMessage> messages)? transformContext;

  AgentLoop({
    required this.aiService,
    required this.dispatcher,
    this.maxTurns = 10,
    this.beforeToolCall,
    this.afterToolCall,
    this.shouldStopAfterTurn,
    this.transformContext,
  });

  /// 运行 ReAct 循环
  Stream<AgentEvent> run({
    required List<ChatMessage> conversationHistory,
    required String systemPrompt,
    AgentCancellationToken? cancellationToken,
  }) async* {
    yield AgentEvent.agentStart();

    final List<ChatMessage> activeMessages = [
      ChatMessage(role: 'system', content: systemPrompt),
      ...conversationHistory,
    ];

    final toolDefinitions = dispatcher.toFunctionDefinitions();
    int currentTurn = 0;

    try {
      while (currentTurn < maxTurns) {
        if (cancellationToken?.isCancelled == true) {
          LoggerService.instance.logAI('AgentLoop 收到中止信号，提前退出');
          final cancelMsg = ChatMessage(
            role: 'assistant',
            content: '已根据您的要求中止当前操作。',
            timestamp: DateTime.now(),
          );
          yield AgentEvent.finished(cancelMsg);
          yield AgentEvent.agentEnd();
          return;
        }

        currentTurn++;
        yield AgentEvent.turnStart(currentTurn);

        // 应用 transformContext 进行上下文修剪与防爆处理
        final transformedMessages = transformContext != null
            ? transformContext!(activeMessages)
            : _defaultTransformContext(activeMessages);

        LoggerService.instance.logAI(
          'AgentLoop 开始第 $currentTurn 轮流式推理 (消息数=${transformedMessages.length})',
        );

        final accumulatedContent = StringBuffer();
        final List<ToolCall> streamedToolCalls = [];

        try {
          final stream = aiService.chatStreamWithTools(
            messages: transformedMessages,
            tools: toolDefinitions.isNotEmpty ? toolDefinitions : null,
            onToolCallsReady: (calls) {
              streamedToolCalls.addAll(calls);
            },
          );

          await for (final delta in stream) {
            if (cancellationToken?.isCancelled == true) {
              LoggerService.instance.logAI('流式生成中收到中止信号');
              final cancelMsg = ChatMessage(
                role: 'assistant',
                content: '${accumulatedContent.toString().trim()}\n\n*(操作已被用户主动中止)*',
                timestamp: DateTime.now(),
              );
              yield AgentEvent.finished(cancelMsg);
              yield AgentEvent.agentEnd();
              return;
            }
            accumulatedContent.write(delta);
            yield AgentEvent.contentDelta(delta);
          }
        } catch (e) {
          LoggerService.instance.logAI('AgentLoop 流式发生错误: $e', level: LogLevel.error);
          yield AgentEvent.error('请求模型失败: $e');
          yield AgentEvent.agentEnd();
          return;
        }

        String content = accumulatedContent.toString().trim();
        String? thought;
        if (content.contains('<thought>') && content.contains('</thought>')) {
          final startIdx = content.indexOf('<thought>') + 9;
          final endIdx = content.indexOf('</thought>');
          if (endIdx > startIdx) {
            thought = content.substring(startIdx, endIdx).trim();
            content = (content.substring(0, startIdx - 9) + content.substring(endIdx + 10)).trim();
          }
        }

        if (thought != null && thought.isNotEmpty) {
          yield AgentEvent.thoughtUpdate(thought);
        }

        List<ToolCall> toolCalls = List.from(streamedToolCalls);

        // 容灾解析：如果模型没有原生 tool_calls，但内容包含 Action: tool_name 格式
        if (toolCalls.isEmpty && _containsTextToolCall(content)) {
          toolCalls = _parseTextToolCalls(content);
        }

        final assistantResponse = ChatMessage(
          role: 'assistant',
          content: content,
          thought: thought,
          toolCalls: toolCalls.isNotEmpty ? toolCalls : null,
          timestamp: DateTime.now(),
        );

        // 若没有触发任何工具调用，说明 ReAct 循环收敛，得到最终回复
        if (toolCalls.isEmpty) {
          LoggerService.instance.logAI('AgentLoop 循环收敛，输出最终答复');
          yield AgentEvent.assistantMessage(assistantResponse);
          yield AgentEvent.turnEnd(currentTurn);
          yield AgentEvent.finished(assistantResponse);
          yield AgentEvent.agentEnd();
          return;
        }

        // 存在工具调用，先将 assistant 的意图存入上下文并派发给 UI
        activeMessages.add(assistantResponse);
        yield AgentEvent.assistantMessage(assistantResponse);

        if (cancellationToken?.isCancelled == true) {
          yield AgentEvent.agentEnd();
          return;
        }

        // 检查是否所有工具都支持并行执行 (Parallel Tool Execution)
        final bool canRunParallel = toolCalls.length > 1 &&
            toolCalls.every((call) {
              final tool = dispatcher.getTool(call.name);
              return tool?.executionMode == ToolExecutionMode.parallel;
            });

        if (canRunParallel) {
          LoggerService.instance.logAI('触发并行工具调度 (数量=${toolCalls.length})');
          for (final call in toolCalls) {
            yield AgentEvent.toolExecuting(call, progress: '并行执行中...');
            await beforeToolCall?.call(call);
          }

          final results = await Future.wait(toolCalls.map((call) => dispatcher.dispatch(call)));

          for (int i = 0; i < toolCalls.length; i++) {
            final call = toolCalls[i];
            final resultMsg = results[i];
            activeMessages.add(resultMsg);
            await afterToolCall?.call(call, resultMsg);
            yield AgentEvent.toolCompleted(call, resultMsg);
          }
        } else {
          // 串行安全执行 (Sequential Tool Execution)
          for (final call in toolCalls) {
            if (cancellationToken?.isCancelled == true) {
              break;
            }

            yield AgentEvent.toolExecuting(call);
            await beforeToolCall?.call(call);

            final toolResultMsg = await dispatcher.dispatch(
              call,
              onProgress: (progress) {
                // 可上报中间进度
              },
            );

            activeMessages.add(toolResultMsg);
            await afterToolCall?.call(call, toolResultMsg);
            yield AgentEvent.toolCompleted(call, toolResultMsg);
          }
        }

        yield AgentEvent.turnEnd(currentTurn);

        // 检查后置停止钩子
        if (shouldStopAfterTurn != null) {
          final shouldStop = await shouldStopAfterTurn!(assistantResponse, currentTurn);
          if (shouldStop) {
            LoggerService.instance.logAI('shouldStopAfterTurn 触发停止判定');
            yield AgentEvent.finished(assistantResponse);
            yield AgentEvent.agentEnd();
            return;
          }
        }
      }

      // 超过最大轮次保护
      final timeoutMsg = ChatMessage(
        role: 'assistant',
        content: '小Q执行步骤较多，已达到本轮安全上限。请查看已完成的操作，如有需要可继续向我提问！',
        timestamp: DateTime.now(),
      );
      yield AgentEvent.finished(timeoutMsg);
      yield AgentEvent.agentEnd();
    } finally {
      // 循环退出保障
    }
  }

  /// 默认上下文修剪与 Token 防爆治理策略（对齐 Pi Agent 的 transformContext）
  List<ChatMessage> _defaultTransformContext(List<ChatMessage> messages) {
    if (messages.isEmpty) return messages;

    final List<ChatMessage> transformed = [];

    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];

      // 1. 系统提示词保持完整
      if (msg.role == 'system') {
        transformed.add(msg);
        continue;
      }

      // 2. 对工具返回超大内容进行截断保护（超过 2200 字符折叠）
      if (msg.role == 'tool') {
        final content = msg.content;
        if (content.length > 2200) {
          final head = content.substring(0, 1200);
          final tail = content.substring(content.length - 600);
          final omittedCount = content.length - 1800;
          final safeContent = '$head\n\n... [为保护上下文已省略中间 $omittedCount 字符] ...\n\n$tail';
          transformed.add(msg.copyWith(content: safeContent));
          continue;
        }
      }

      // 3. 对历史中过旧的工具消息做状态压缩（仅保留最近 12 条完整记录）
      if (messages.length > 14 && i < messages.length - 10 && msg.role == 'tool') {
        final brief = '[已执行 ${msg.toolName ?? "tool"}: 成功]';
        transformed.add(msg.copyWith(content: brief));
        continue;
      }

      transformed.add(msg);
    }

    return transformed;
  }

  /// 检查文本是否包含模型生成的模拟 Action
  bool _containsTextToolCall(String text) {
    return text.contains('```action') ||
        (text.contains('Action:') && text.contains('Action Input:'));
  }

  /// 解析模拟文本中的 Action
  List<ToolCall> _parseTextToolCalls(String text) {
    final List<ToolCall> calls = [];
    final id = 'call_${DateTime.now().millisecondsSinceEpoch}';

    // 格式 1: ```action \n {"name":"...", "arguments":{...}} \n ```
    final codeBlockRegex = RegExp(r'```(?:action|json:action)\s*([\s\S]*?)\s*```');
    final match = codeBlockRegex.firstMatch(text);
    if (match != null) {
      try {
        final json = jsonDecode(match.group(1)!) as Map<String, dynamic>;
        calls.add(ToolCall(
          id: id,
          name: json['name'] as String? ?? json['tool'] as String? ?? '',
          arguments: json['arguments'] as Map<String, dynamic>? ?? json['args'] as Map<String, dynamic>? ?? {},
        ));
        return calls;
      } catch (_) {}
    }

    // 格式 2: Action: xxx \n Action Input: {...}
    final actionRegex = RegExp(r'Action:\s*([a-zA-Z0-9_-]+)\s*\nAction Input:\s*(\{[\s\S]*?\})');
    final actionMatch = actionRegex.firstMatch(text);
    if (actionMatch != null) {
      final name = actionMatch.group(1)!.trim();
      final argsStr = actionMatch.group(2)!.trim();
      try {
        final args = jsonDecode(argsStr) as Map<String, dynamic>;
        calls.add(ToolCall(id: id, name: name, arguments: args));
      } catch (_) {}
    }

    return calls;
  }
}

