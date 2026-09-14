import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 工具注册中心与分发器
class ToolDispatcher {
  final Map<String, AgentTool> _tools = {};

  /// 注册工具
  void register(AgentTool tool) {
    _tools[tool.name] = tool;
  }

  /// 批量注册
  void registerAll(Iterable<AgentTool> tools) {
    for (final tool in tools) {
      register(tool);
    }
  }

  /// 获取所有已注册工具的 Function Definitions 供 LLM tools 参数使用
  List<Map<String, dynamic>> toFunctionDefinitions() {
    return _tools.values.map((t) => t.toFunctionDefinition()).toList();
  }

  /// 是否包含某工具
  bool hasTool(String name) => _tools.containsKey(name);

  /// 根据名称获取工具
  AgentTool? getTool(String name) => _tools[name];

  /// 执行工具调用
  ///
  /// 当工具返回图片（如 view_image）时，图片以 data URI 挂在返回消息的 [ChatMessage.images]
  /// 上，仅作为内存中的临时通道供 AgentLoop 提取；AgentLoop 会剥离图片后把消息
  /// 加入上下文与 UI 事件流，因此落库的消息永远不携带 base64 图片数据。
  Future<ChatMessage> dispatch(
    ToolCall call, {
    void Function(String progress)? onProgress,
  }) async {
    final tool = _tools[call.name];
    if (tool == null) {
      LoggerService.instance.logAI(
        '执行工具失败: 未知工具 "${call.name}"',
        level: LogLevel.warning,
      );
      return ChatMessage(
        role: 'tool',
        content: '错误: 找不到工具 "${call.name}"',
        toolCallId: call.id,
        toolName: call.name,
        isError: true,
        timestamp: DateTime.now(),
      );
    }

    try {
      LoggerService.instance.logAI(
        '调度执行工具 [${call.name}]',
        details: '参数: ${call.arguments}',
      );
      final result = await tool.execute(call.arguments, onProgress: onProgress);
      return ChatMessage(
        role: 'tool',
        content: result.modelOutput,
        toolCallId: call.id,
        toolName: call.name,
        isError: result.isError,
        uiDetails: result.uiDetails,
        images: result.images,
        timestamp: DateTime.now(),
      );
    } catch (e, stack) {
      LoggerService.instance.logAI(
        '工具执行抛出异常: ${call.name}, error=$e',
        level: LogLevel.error,
        details: stack.toString(),
      );
      return ChatMessage(
        role: 'tool',
        content: '执行工具 "${call.name}" 发生异常: $e',
        toolCallId: call.id,
        toolName: call.name,
        isError: true,
        timestamp: DateTime.now(),
      );
    }
  }
}
