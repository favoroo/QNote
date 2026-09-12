import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
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
/// 2. 长会话上下文压缩 (Compaction)：超窗成对裁剪 + LLM 结构化摘要
/// 3. 并行与串行混合工具调度 (Parallel & Sequential Tool Execution)
/// 4. 生命周期钩子系统 (beforeToolCall, afterToolCall, shouldStopAfterTurn)
/// 5. 动态中断与取消控制 (AgentCancellationToken)
/// 6. 动态环境上下文注入 system 尾部（对齐 pi 的 before_agent_start 钩子）
/// 7. `<thought>` 标签流式过滤，UI 不闪现协议原文
class AgentLoop {
  final AiService aiService;
  final ToolDispatcher dispatcher;
  final int maxTurns;

  /// 历史消息窗口上限（条数，不含 system 与摘要消息），超过则触发压缩
  final int maxHistoryMessages;
  final Future<void> Function(ToolCall call)? beforeToolCall;
  final Future<void> Function(ToolCall call, ChatMessage result)? afterToolCall;
  final FutureOr<bool> Function(ChatMessage lastAssistantMessage, int turn)? shouldStopAfterTurn;
  final List<ChatMessage> Function(List<ChatMessage> messages)? transformContext;

  AgentLoop({
    required this.aiService,
    required this.dispatcher,
    this.maxTurns = 8,
    this.maxHistoryMessages = 30,
    this.beforeToolCall,
    this.afterToolCall,
    this.shouldStopAfterTurn,
    this.transformContext,
  });

  /// 运行 ReAct 循环
  ///
  /// [dynamicContext] 为动态环境上下文（当前时间、用户资料、关联数据等），
  /// 会拼接到系统提示词尾部，避免污染用户消息原文且保证每轮都可见。
  Stream<AgentEvent> run({
    required List<ChatMessage> conversationHistory,
    required String systemPrompt,
    String? dynamicContext,
    AgentCancellationToken? cancellationToken,
  }) async* {
    yield AgentEvent.agentStart();

    // 将动态取消令牌桥接到 Dio CancelToken：用户点停止的瞬间，
    // 等待中的 HTTP 请求（含首包前的"思考中"阶段）立即断连，无需等下一个数据包到达
    final httpCancelToken = CancelToken();
    void bridgeCancel() {
      if (!httpCancelToken.isCancelled) {
        httpCancelToken.cancel(cancellationToken?.reason);
      }
    }
    cancellationToken?.addListener(bridgeCancel);

    try {
      // 取消检查点：上下文压缩前，点了停止就不再发起摘要请求
      if (cancellationToken?.isCancelled == true) {
        yield AgentEvent.finished(_cancelledMessage(''));
        yield AgentEvent.agentEnd();
        return;
      }

      // 长会话压缩：裁剪早期消息并生成摘要（对齐 pi compaction）
      final compactedHistory =
          await _compactHistory(conversationHistory, cancellationToken, httpCancelToken);

      // 取消检查点：压缩完成后立即响应，不再进入推理循环
      if (cancellationToken?.isCancelled == true) {
        yield AgentEvent.finished(_cancelledMessage(''));
        yield AgentEvent.agentEnd();
        return;
      }

      final String fullSystemPrompt =
          (dynamicContext == null || dynamicContext.trim().isEmpty)
              ? systemPrompt
              : '$systemPrompt\n\n# 当前环境上下文\n$dynamicContext';

      final List<ChatMessage> activeMessages = [
        ChatMessage(role: 'system', content: fullSystemPrompt),
        ...compactedHistory,
      ];

      final toolDefinitions = dispatcher.toFunctionDefinitions();
      int currentTurn = 0;
      // 图片降级重试只允许一次，避免纯文本模型下反复重试浪费请求
      bool imageFallbackTried = false;

      while (currentTurn < maxTurns) {
        if (cancellationToken?.isCancelled == true) {
          LoggerService.instance.logAI('AgentLoop 收到中止信号，提前退出');
          yield AgentEvent.finished(_cancelledMessage(''));
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
        final thoughtFilter = _ThoughtTagFilter();

        try {
          final stream = aiService.chatStreamWithTools(
            messages: transformedMessages,
            tools: toolDefinitions.isNotEmpty ? toolDefinitions : null,
            onToolCallsReady: (calls) {
              streamedToolCalls.addAll(calls);
            },
            cancelToken: httpCancelToken,
          );

          await for (final delta in stream) {
            if (cancellationToken?.isCancelled == true) {
              LoggerService.instance.logAI('流式生成中收到中止信号');
              yield AgentEvent.finished(_cancelledMessage(accumulatedContent.toString()));
              yield AgentEvent.agentEnd();
              return;
            }
            accumulatedContent.write(delta);
            // 过滤 <thought> 标签，UI 只收到干净的正文增量
            final visible = thoughtFilter.feed(delta);
            if (visible.isNotEmpty) {
              yield AgentEvent.contentDelta(visible);
            }
          }
          // 冲刷过滤器中因标签截断而暂扣的尾巴
          final tail = thoughtFilter.flush();
          if (tail.isNotEmpty) {
            yield AgentEvent.contentDelta(tail);
          }
        } catch (e) {
          // 用户主动中止（含 Dio 请求被断连抛出的取消异常）按正常中止收尾，不作为错误上报
          if (cancellationToken?.isCancelled == true) {
            LoggerService.instance.logAI('AgentLoop 流式因用户中止而中断');
            yield AgentEvent.finished(_cancelledMessage(accumulatedContent.toString()));
            yield AgentEvent.agentEnd();
            return;
          }
          LoggerService.instance.logAI('AgentLoop 流式发生错误: $e', level: LogLevel.error);

          // 降级兜底：本轮上下文注入过图片时，可能是纯文本模型或网关拒收图片导致请求失败，
          // 剥离全部图片后原地重试一次，避免整轮对话直接中断
          if (!imageFallbackTried &&
              activeMessages.any((m) => m.images != null && m.images!.isNotEmpty)) {
            imageFallbackTried = true;
            LoggerService.instance.logAI('上下文含图片消息，疑似模型不支持图片输入，剥离图片后重试本次请求');
            _stripAllImages(activeMessages);
            currentTurn--;
            continue;
          }

          yield AgentEvent.error('请求模型失败: $e');
          yield AgentEvent.agentEnd();
          return;
        }

        String content = accumulatedContent.toString().trim();
        String? thought;
        if (thoughtFilter.hasThought) {
          thought = thoughtFilter.thoughtText;
          // 过滤器已将标签内文本收集到 thought，这里整段剥除标签（含内部空白差异）
          content = content
              .replaceAll(RegExp(r'<thought>[\s\S]*?</thought>'), '')
              .replaceAll(RegExp(r'</?thought>'), '')
              .trim();
        } else if (content.contains('<thought>') && content.contains('</thought>')) {
          // 兜底：非流式路径或过滤器未覆盖的格式
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
          // 中止发生在工具派发前：补发 finished 收尾，保证会话中有中止提示
          yield AgentEvent.finished(_cancelledMessage(''));
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
            final contextMsg = _resolveToolResultMessage(results[i], activeMessages);
            await afterToolCall?.call(call, contextMsg);
            yield AgentEvent.toolCompleted(call, contextMsg);
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

            final contextMsg = _resolveToolResultMessage(toolResultMsg, activeMessages);
            await afterToolCall?.call(call, contextMsg);
            yield AgentEvent.toolCompleted(call, contextMsg);
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

      // 超过最大轮次保护：附带已执行操作摘要，方便用户接续指令
      final executedTools = activeMessages
          .where((m) => m.role == 'tool' && m.toolName != null)
          .map((m) => m.toolName!)
          .toSet()
          .join('、');
      final timeoutMsg = ChatMessage(
        role: 'assistant',
        content: executedTools.isEmpty
            ? '小Q执行步骤较多，已达到本轮安全上限。请查看已完成的操作，如有需要可继续向我提问！'
            : '小Q已连续执行多步操作（$executedTools），达到本轮安全上限，已完成的工作均已生效。如需继续，请告诉我下一步！',
        timestamp: DateTime.now(),
      );
      yield AgentEvent.finished(timeoutMsg);
      yield AgentEvent.agentEnd();
    } catch (e) {
      // 承接上下文压缩等阶段被取消的异常：按正常中止收尾，不作为错误上报
      if (cancellationToken?.isCancelled == true) {
        yield AgentEvent.finished(_cancelledMessage(''));
        yield AgentEvent.agentEnd();
        return;
      }
      LoggerService.instance.logAI('AgentLoop 执行异常: $e', level: LogLevel.error);
      yield AgentEvent.error('Agent 执行异常: $e');
      yield AgentEvent.agentEnd();
    } finally {
      cancellationToken?.removeListener(bridgeCancel);
    }
  }

  /// 生成用户主动中止的收尾消息
  ///
  /// [partialContent] 为中止前已流式产出的正文（可为空），有内容时附注在正文之后。
  ChatMessage _cancelledMessage(String partialContent) {
    final trimmed = partialContent.trim();
    return ChatMessage(
      role: 'assistant',
      content: trimmed.isEmpty ? '(操作已被用户主动中止)' : '$trimmed\n\n*(操作已被用户主动中止)*',
      timestamp: DateTime.now(),
    );
  }

  /// 处理工具返回消息并加入本轮上下文
  ///
  /// 若消息携带图片（如 view_image 工具的返回），先剥离图片生成干净的消息
  /// （tool 角色在 OpenAI 协议下不支持图片内容，且该消息会随事件流落库），
  /// 再以合成 user 消息把图片注入上下文。图片只存在于循环内部的
  /// [activeMessages]，不随 toolCompleted 事件持久化，下一轮对话自然消失，
  /// 因此模型本轮可见图片而数据库与后续请求不受 base64 体积影响。
  ChatMessage _resolveToolResultMessage(ChatMessage resultMsg, List<ChatMessage> activeMessages) {
    final images = resultMsg.images;
    final contextMsg = (images == null || images.isEmpty) ? resultMsg : _stripImages(resultMsg);
    activeMessages.add(contextMsg);

    if (images != null && images.isNotEmpty) {
      final source = resultMsg.uiDetails?['path'] as String? ?? '未知路径';
      activeMessages.add(ChatMessage(
        role: 'user',
        content: '[系统注入] 工具 ${resultMsg.toolName ?? "tool"} 的结果附带 ${images.length} 张图片'
            '（来源: $source）。图片已附加在本条消息中，请直接基于图片画面内容继续分析，无需再次调用工具读取。',
        images: images,
        timestamp: DateTime.now(),
      ));
    }
    return contextMsg;
  }

  /// 剥离单条消息的图片字段（copyWith 的 `??` 语义无法置空字段，需新建对象）
  ChatMessage _stripImages(ChatMessage msg) {
    return ChatMessage(
      role: msg.role,
      content: msg.content,
      timestamp: msg.timestamp,
      thought: msg.thought,
      toolCalls: msg.toolCalls,
      toolCallId: msg.toolCallId,
      toolName: msg.toolName,
      isError: msg.isError,
      uiDetails: msg.uiDetails,
      undoLog: msg.undoLog,
    );
  }

  /// 剥离上下文中全部图片（降级重试用），并把依赖图片存在的提示语改为降级说明
  void _stripAllImages(List<ChatMessage> messages) {
    for (int i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (m.images == null || m.images!.isEmpty) continue;
      String content = m.content;
      if (m.role == 'user' && content.startsWith('[系统注入]')) {
        content = '[系统注入] 图片已剥离：当前模型不支持图片输入，无法查看图片内容，'
            '请如实告知用户当前模型无法看图，或改用文字方式处理。';
      } else if (m.role == 'tool' && m.toolName == 'view_image') {
        content = '图片加载失败：当前模型不支持图片输入，无法查看图片内容。';
      }
      messages[i] = _stripImages(m).copyWith(content: content);
    }
  }

  /// 长会话上下文压缩（简化版 pi compaction）
  ///
  /// 历史超过 [maxHistoryMessages] 时裁剪早期消息，并生成一条摘要注入窗口头部。
  /// 裁剪点必须保证 assistant(tool_calls) 与其 tool 结果成对完整，
  /// 否则 OpenAI 兼容接口会因 tool_call_id 失配直接返回 400。
  Future<List<ChatMessage>> _compactHistory(
    List<ChatMessage> history,
    AgentCancellationToken? cancellationToken,
    CancelToken? httpCancelToken,
  ) async {
    if (history.length <= maxHistoryMessages) return history;

    int cut = history.length - maxHistoryMessages;
    // 窗口起点不能落在孤立的 tool 结果上：向前回退到配对的 assistant(tool_calls) 之前
    while (cut > 0 && history[cut].role == 'tool') {
      cut--;
    }
    if (cut <= 0) return history;

    final removed = history.sublist(0, cut);
    final kept = history.sublist(cut);

    final summary = await _summarizeMessages(removed, cancellationToken, httpCancelToken);
    LoggerService.instance.logAI(
      '触发上下文压缩: 裁剪 ${removed.length} 条早期消息, 保留 ${kept.length} 条',
    );

    return [
      ChatMessage(
        role: 'user',
        content: '[以下是此前对话的压缩摘要，供你了解上下文背景，无需直接回应]\n$summary',
        timestamp: removed.first.timestamp,
      ),
      ...kept,
    ];
  }

  /// 将被裁剪的历史压缩为结构化摘要：优先 LLM 生成，失败时降级为机械拼接
  Future<String> _summarizeMessages(
    List<ChatMessage> messages,
    AgentCancellationToken? cancellationToken,
    CancelToken? httpCancelToken,
  ) async {
    final buffer = StringBuffer();
    for (final m in messages) {
      if (m.role == 'system') continue;
      final label = m.role == 'user'
          ? '用户'
          : m.role == 'assistant'
              ? '小Q'
              : '工具结果';
      var text = m.content.trim();
      if (text.length > 400) text = '${text.substring(0, 400)}…';
      if (text.isEmpty) continue;
      buffer.writeln('[$label] $text');
    }
    final transcript = buffer.toString().trim();
    if (transcript.isEmpty) return '（无有效内容）';

    try {
      final llmSummary = await aiService.chat([
        ChatMessage(
          role: 'system',
          content: '你是会话压缩器。将以下对话历史压缩为简洁的要点列表摘要，必须保留：'
              '1) 用户的目标与偏好；2) 已完成的操作（涉及的数据类型与路径）；'
              '3) 关键决定；4) 未完成事项。控制在 300 字以内。',
        ),
        ChatMessage(role: 'user', content: transcript),
      ], cancelToken: httpCancelToken);
      if (llmSummary.trim().isNotEmpty) return llmSummary.trim();
    } catch (e) {
      // 用户主动中止：向上抛出由主循环按中止收尾，禁止降级为机械摘要后继续跑完任务
      if (cancellationToken?.isCancelled == true) rethrow;
      LoggerService.instance.logAI(
        'LLM 会话摘要生成失败，降级为机械摘要: $e',
        level: LogLevel.warning,
      );
    }
    // 机械降级：截断保护，避免摘要本身反而撑爆上下文
    return transcript.length > 2000 ? '${transcript.substring(0, 2000)}…' : transcript;
  }

  /// 默认上下文修剪与 Token 防爆治理策略（对齐 Pi Agent 的 transformContext）
  List<ChatMessage> _defaultTransformContext(List<ChatMessage> messages) {
    if (messages.isEmpty) return messages;

    final List<ChatMessage> transformed = [];

    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];

      // 系统提示词保持完整
      if (msg.role == 'system') {
        transformed.add(msg);
        continue;
      }

      // 对工具返回超大内容进行截断保护（超过 2200 字符折叠）
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

/// `<thought>` 标签流式过滤器
///
/// 标签可能被流式增量从中间切开（如 `<tho` + `ught>`），因此用前缀暂扣缓冲：
/// 确定是标签前缀时等待后续增量，确定不是时按普通文本放行。
/// 思考内容被拦截到 [thought]，不进入 UI 展示流。
class _ThoughtTagFilter {
  static const String _openTag = '<thought>';
  static const String _closeTag = '</thought>';

  final StringBuffer thought = StringBuffer();
  final StringBuffer _pending = StringBuffer();
  bool _inThought = false;

  /// 输入流式增量，返回可安全展示的文本（不含 thought 标签及其内容）
  String feed(String delta) {
    _pending.write(delta);
    final output = StringBuffer();

    while (_pending.isNotEmpty) {
      final pending = _pending.toString();
      final tag = _inThought ? _closeTag : _openTag;

      // 1. 完整命中标签：切换状态并消费
      if (pending.startsWith(tag)) {
        _pending.clear();
        _inThought = !_inThought;
        continue;
      }

      // 2. 是标签前缀但尚未完整（可能被增量切断）：暂扣等待
      if (pending.length < tag.length && tag.startsWith(pending)) {
        break;
      }

      // 3. 普通文本：一次性输出到下一个 '<' 之前
      final searchFrom = pending.startsWith('<') ? 1 : 0;
      final lt = pending.indexOf('<', searchFrom);
      if (lt == -1) {
        _emit(output, pending);
        _pending.clear();
      } else {
        _emit(output, pending.substring(0, lt));
        _pending.clear();
        _pending.write(pending.substring(lt));
      }
    }

    return output.toString();
  }

  void _emit(StringBuffer output, String text) {
    if (_inThought) {
      thought.write(text);
    } else {
      output.write(text);
    }
  }

  /// 流结束时冲刷暂扣缓冲（未闭合的 thought 归入思考内容）
  String flush() {
    final rest = _pending.toString();
    _pending.clear();
    if (_inThought) {
      thought.write(rest);
      return '';
    }
    return rest;
  }

  bool get hasThought => thought.isNotEmpty;

  String get thoughtText => thought.toString().trim();
}
