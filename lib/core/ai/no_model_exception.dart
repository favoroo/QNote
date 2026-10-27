/// 「还没有可用的 AI 模型」异常
///
/// 旧版本 App 内置免费模型，取不到配置时只会抛裸 `Exception('No AI config
/// available')`，UI 只能在错误气泡里显示技术文案。现在没有内置模型兜底，
/// 「未配置」是一件需要引导用户去添加模型的事件，因此用独立异常类型让它
/// 与网络失败、鉴权失败区分开：UI 层捕获后弹「去添加模型」引导弹窗，
/// 错误解释层也据此给出可执行建议。
class NoModelConfiguredException implements Exception {
  /// 触发场景（角色 key 或功能名），用于日志与文案定位
  final String scene;

  NoModelConfiguredException([this.scene = '']);

  @override
  String toString() => '尚未配置可用的 AI 模型${scene.isEmpty ? '' : '（$scene）'}';
}