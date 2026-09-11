import 'dart:async';
import 'dart:convert';
import 'package:qnote_flutter/core/agent/engine/agent_events.dart';
import 'package:qnote_flutter/core/agent/engine/tool_dispatcher.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 「小Q」全智能 Agent ReAct 循环引擎
///
/// 借鉴 pi-agent 的双层循环与 opencode 的事件机制：
/// 1. 启动循环，注入全局系统提示词与上下文
/// 2. Inner Loop（最大 maxTurns 轮）：
///    - 请求大模型 (带 tools 声明)
///    - 若大模型吐出思考 (Thought)，实时上报 UI
///    - 若大模型发出 Tool Calls，调度 Dispatcher 本地执行，并将 Observation 以 role='tool' 追加进对话上下文
///    - 若大模型不再调用工具并给出最终回答，跳出循环并完成
/// 3. 支持容灾降级（针对部分不支持原生 function calling 的模型解析文本格式工具指令）
class AgentLoop {
  final AiService aiService;
  final ToolDispatcher dispatcher;
  final int maxTurns;

  AgentLoop({
    required this.aiService,
    required this.dispatcher,
    this.maxTurns = 10,
  });

  /// 运行 ReAct 循环
  Stream<AgentEvent> run({
    required List<ChatMessage> conversationHistory,
    required String systemPrompt,
  }) async* {
    final List<ChatMessage> activeMessages = [
      ChatMessage(role: 'system', content: systemPrompt),
      ...conversationHistory,
    ];

    final toolDefinitions = dispatcher.toFunctionDefinitions();
    int currentTurn = 0;

    while (currentTurn < maxTurns) {
      currentTurn++;
      yield AgentEvent.turnStart(currentTurn);

      LoggerService.instance.logAI(
        'AgentLoop 开始第 $currentTurn 轮推理 (消息数=${activeMessages.length})',
      );

      ChatMessage assistantResponse;
      try {
        assistantResponse = await aiService.chatResponse(
          activeMessages,
          tools: toolDefinitions.isNotEmpty ? toolDefinitions : null,
        );
      } catch (e) {
        LoggerService.instance.logAI('AgentLoop 发生错误: $e', level: LogLevel.error);
        yield AgentEvent.error('请求模型失败: $e');
        return;
      }

      // 如果模型内容包含 <thought> 或带有思考段落，上报事件
      String content = assistantResponse.content;
      String? thought;
      if (content.contains('<thought>') && content.contains('</thought>')) {
        final startIdx = content.indexOf('<thought>') + 9;
        final endIdx = content.indexOf('</thought>');
        if (endIdx > startIdx) {
          thought = content.substring(startIdx, endIdx).trim();
          content = (content.substring(0, startIdx - 9) + content.substring(endIdx + 10)).trim();
          assistantResponse = assistantResponse.copyWith(
            content: content,
            thought: thought,
          );
        }
      }

      if (thought != null && thought.isNotEmpty) {
        yield AgentEvent.thoughtUpdate(thought);
      }

      // 检查是否有原生 tool_calls
      List<ToolCall> toolCalls = assistantResponse.toolCalls ?? [];

      // 容灾解析：如果模型没有原生 tool_calls，但内容包含 Action: tool_name 格式
      if (toolCalls.isEmpty && _containsTextToolCall(content)) {
        toolCalls = _parseTextToolCalls(content);
      }

      // 若没有触发任何工具调用，说明 ReAct 循环收敛，得到最终回复
      if (toolCalls.isEmpty) {
        LoggerService.instance.logAI('AgentLoop 循环收敛，输出最终答复');
        yield AgentEvent.assistantMessage(assistantResponse);
        yield AgentEvent.finished(assistantResponse);
        return;
      }

      // 存在工具调用，先将 assistant 的意图存入上下文并派发给 UI
      activeMessages.add(assistantResponse);
      yield AgentEvent.assistantMessage(assistantResponse);

      // 执行每一个工具调用并收集结果
      for (final call in toolCalls) {
        yield AgentEvent.toolExecuting(call);
        
        final toolResultMsg = await dispatcher.dispatch(
          call,
          onProgress: (progress) {
            // 可通过事件流上报工具执行中间状态
          },
        );

        // 将工具的观察结果 (Observation) 作为 role='tool' 追加到上下文中
        activeMessages.add(toolResultMsg);
        yield AgentEvent.toolCompleted(call, toolResultMsg);
      }

      // 继续进入下一轮循环，供大模型阅读 Observation 并决定下一步动作
    }

    // 超过最大轮次保护
    final timeoutMsg = ChatMessage(
      role: 'assistant',
      content: '小Q执行步骤较多，已达到本轮安全上限。请查看已完成的操作，如有需要可继续向我提问！',
      timestamp: DateTime.now(),
    );
    yield AgentEvent.finished(timeoutMsg);
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
