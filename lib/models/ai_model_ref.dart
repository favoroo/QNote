/// 模型引用：指向某个厂商条目下的一个模型
///
/// 角色绑定（小Q 对话 / 时间线提取 / 生图）与模型选择器都用它做身份标识，
/// 取代旧版「一个模型 = 一行 ai_configs」的配置 id。序列化为
/// `providerId::modelName` 字符串存进 `AiRoles` JSON。
class AiModelRef {
  final String providerId;
  final String modelName;

  const AiModelRef({required this.providerId, required this.modelName});

  static const String _separator = '::';

  String encode() => '$providerId$_separator$modelName';

  /// 解析绑定串；格式不符（例如旧版残留的裸配置 id）返回 null，调用方按「未绑定」处理
  static AiModelRef? tryParse(String? raw) {
    if (raw == null) return null;
    final text = raw.trim();
    if (text.isEmpty) return null;
    final index = text.indexOf(_separator);
    if (index <= 0 || index >= text.length - _separator.length) return null;
    final providerId = text.substring(0, index);
    final modelName = text.substring(index + _separator.length);
    if (providerId.isEmpty || modelName.isEmpty) return null;
    return AiModelRef(providerId: providerId, modelName: modelName);
  }

  @override
  bool operator ==(Object other) =>
      other is AiModelRef &&
      other.providerId == providerId &&
      other.modelName == modelName;

  @override
  int get hashCode => Object.hash(providerId, modelName);

  @override
  String toString() => encode();
}