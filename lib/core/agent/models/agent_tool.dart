/// 工具执行结果
///
/// 借鉴 opencode / pi-agent 的双向设计：
/// - [modelOutput]：作为字符串返回给 LLM 模型的精炼输出（带有最大字数截断保护，防止冲爆上下文）
/// - [uiDetails]：结构化对象，传递给客户端 UI 渲染交互卡片（如待办列表、修改高亮等）
/// - [images]：随结果附带给模型的图片（data URI 形式，如 view_image 工具），
///   由 AgentLoop 转为合成 user 消息注入本轮上下文，不随会话落库
/// - [isError]：执行是否异常
class ToolResult {
  final String modelOutput;
  final Map<String, dynamic>? uiDetails;
  final List<String>? images;
  final bool isError;

  const ToolResult({
    required this.modelOutput,
    this.uiDetails,
    this.images,
    this.isError = false,
  });

  factory ToolResult.success(
    String message, {
    Map<String, dynamic>? uiDetails,
    List<String>? images,
  }) {
    return ToolResult(
      modelOutput: message,
      uiDetails: uiDetails,
      images: images,
      isError: false,
    );
  }

  factory ToolResult.error(String error, {Map<String, dynamic>? uiDetails}) {
    return ToolResult(
      modelOutput: '错误: $error',
      uiDetails: uiDetails,
      isError: true,
    );
  }
}

/// 工具执行调度模式（对齐 Pi Agent 设计）
enum ToolExecutionMode {
  /// 并行模式：无副作用的只读/检索类工具，可与其他 parallel 工具并发执行
  parallel,

  /// 串行模式：涉及写、改、删、人机确认的工具，必须按序严格串行执行
  sequential,
}

/// Agent 工具抽象基类
abstract class AgentTool {
  /// 工具名称（英文唯一标识，如 "manage_todo"）
  String get name;

  /// 工具调度执行模式，默认串行安全
  ToolExecutionMode get executionMode => ToolExecutionMode.sequential;

  /// 工具的自然语言中文描述，供大模型理解何时调用
  String get description;

  /// 参数的 JSON Schema 定义（与 OpenAI Function Calling 规范一致）
  Map<String, dynamic> get parametersSchema;

  /// 执行具体工具逻辑
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  });

  /// 转换为符合 OpenAI `tools` 参数的 function definition
  Map<String, dynamic> toFunctionDefinition() {
    return {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'parameters': parametersSchema,
      },
    };
  }

  /// 辅助工具方法：输出文本截断保护（防止 grep 或读大文件导致 Token 溢出）
  String truncateOutput(String text, {int maxLength = 3000}) {
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}\n... (输出已截断，前 $maxLength 个字符已展示)';
  }
}
