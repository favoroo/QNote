/// 模型引用：指向某个厂商条目下的一个模型，或一个模型路由组
///
/// 角色绑定（小Q 对话 / 时间线提取 / 生图）与模型选择器都用它做身份标识，
/// 取代旧版「一个模型 = 一行 ai_configs」的配置 id。序列化为
/// `providerId::modelName` 字符串存进 `AiRoles` JSON。
///
/// 路由组复用同一编码：[groupMarker] 作为哨兵 modelName，`providerId` 位置放组 id
/// （`<groupId>::__route_group__`）。这样角色配置、选择器、备份与同步都不需要新格式，
/// 解析时由 `AiRouteService` 按组策略选出真实成员。
class AiModelRef {
  final String providerId;
  final String modelName;

  const AiModelRef({required this.providerId, required this.modelName});

  /// 路由组引用的哨兵模型名
  ///
  /// 真实模型名不可能等于它（带双下划线且语义专属），即使手动构造也不会与
  /// 出厂模型列表撞车；解析侧还会用组表再做一次存在性校验。
  static const String groupMarker = '__route_group__';

  static const String _separator = '::';

  /// 路由组引用：`providerId` 位置放组 id
  factory AiModelRef.routeGroup(String groupId) => AiModelRef(providerId: groupId, modelName: groupMarker);

  /// 是否指向模型路由组（而非具体模型）
  bool get isRouteGroup => modelName == groupMarker;

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
      other is AiModelRef && other.providerId == providerId && other.modelName == modelName;

  @override
  int get hashCode => Object.hash(providerId, modelName);

  @override
  String toString() => encode();
}
