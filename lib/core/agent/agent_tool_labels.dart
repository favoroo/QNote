/// 工具代码名 → 用户可读中文文案的展示层映射。
///
/// 仅用于 UI 展示（执行中状态、反馈卡标题等），不改动发给模型的工具定义
/// 与会话持久化里的原始工具名，历史消息在渲染时读此映射做转换。
abstract final class AgentToolLabels {
  /// 各工具的执行中文案（进行时措辞），覆盖 14 个注册工具。
  static const Map<String, String> _progressLabels = {
    'generate_image': '正在生成图片',
    'web_search': '正在联网搜索',
    'fetch_url': '正在读取网页',
    'read_file': '正在读取文件',
    'write_file': '正在写入文件',
    'write_files': '正在批量写入',
    'edit_file': '正在编辑文件',
    'move_file': '正在移动文件',
    'delete_file': '正在删除文件',
    'list_dir': '正在查看目录',
    'view_image': '正在查看图片',
    'grep': '正在搜索笔记',
    'skill': '正在调用技能',
    'ask_user': '正在等待你的回答',
  };

  /// 各工具的完成反馈卡标题（名词化措辞）。
  static const Map<String, String> _resultLabels = {
    'generate_image': '生成图片',
    'web_search': '联网搜索',
    'fetch_url': '读取网页',
    'read_file': '读取文件',
    'write_file': '写入文件',
    'write_files': '批量写入',
    'edit_file': '编辑文件',
    'move_file': '移动文件',
    'delete_file': '删除文件',
    'list_dir': '查看目录',
    'view_image': '查看图片',
    'grep': '搜索笔记',
    'skill': '调用技能',
    'ask_user': '向你提问',
  };

  /// 执行中状态文案；未知工具回退为通用措辞，避免暴露代码名。
  static String progressLabel(String toolName, [Map<String, dynamic>? arguments]) {
    final label = _progressLabels[toolName];
    if (label == null) {
      return toolName.isEmpty ? '正在执行操作' : '正在执行 $toolName';
    }
    final detail = _detailFor(toolName, arguments);
    return detail == null ? label : '$label · $detail';
  }

  /// 完成反馈卡标题；未知工具回退显示原始名，保证不丢信息。
  static String resultLabel(String toolName, [Map<String, dynamic>? details]) {
    final label = _resultLabels[toolName];
    if (label == null) {
      return toolName.isEmpty ? '操作反馈' : toolName;
    }
    final detail = _detailFor(toolName, details);
    return detail == null ? label : '$label · $detail';
  }

  /// 从工具参数/结果里提取关键信息做副标题（文件路径、搜索词、域名等）。
  static String? _detailFor(String toolName, Map<String, dynamic>? data) {
    if (data == null || data.isEmpty) return null;
    switch (toolName) {
      case 'read_file':
      case 'write_file':
      case 'edit_file':
      case 'delete_file':
      case 'list_dir':
      case 'view_image':
        return _stringOf(data, const ['path']);
      case 'write_files':
        final files = data['files'];
        return files is List ? '${files.length} 个文件' : null;
      case 'move_file':
        final from = _stringOf(data, const ['from']);
        final to = _stringOf(data, const ['to']);
        if (from == null) return to;
        return to == null ? from : '$from → $to';
      case 'grep':
        return _stringOf(data, const ['pattern', 'query', 'keyword']);
      case 'web_search':
        return _stringOf(data, const ['query']);
      case 'skill':
        return _stringOf(data, const ['name', 'skill']);
      case 'fetch_url':
        final url = _stringOf(data, const ['url']);
        if (url == null) return null;
        return Uri.tryParse(url)?.host;
      case 'generate_image':
        return _stringOf(data, const ['prompt']);
      default:
        return null;
    }
  }

  /// 按候选键取第一个非空字符串值，prompt 等长文本做截断。
  static String? _stringOf(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key];
      if (value is String && value.trim().isNotEmpty) {
        final text = value.trim().replaceAll('\n', ' ');
        return text.length > 24 ? '${text.substring(0, 24)}…' : text;
      }
    }
    return null;
  }
}
