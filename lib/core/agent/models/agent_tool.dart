/// 工具执行结果
///
/// 借鉴 opencode / pi-agent 的双向设计：
/// - [modelOutput]：作为字符串返回给 LLM 模型的精炼输出（带有最大字数截断保护，防止冲爆上下文）
/// - [uiDetails]：结构化对象，传递给客户端 UI 渲染交互卡片（如待办列表、修改高亮等）
/// - [isError]：执行是否异常
class ToolResult {
  final String modelOutput;
  final Map<String, dynamic>? uiDetails;
  final bool isError;

  const ToolResult({
    required this.modelOutput,
    this.uiDetails,
    this.isError = false,
  });

  factory ToolResult.success(String message, {Map<String, dynamic>? uiDetails}) {
    return ToolResult(
      modelOutput: message,
      uiDetails: uiDetails,
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

/// Agent 工具抽象基类
abstract class AgentTool {
  /// 工具名称（英文唯一标识，如 "manage_todo"）
  String get name;

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
