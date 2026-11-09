import 'package:qnote_flutter/core/ai/autoclaw_auth_service.dart';
import 'package:qnote_flutter/core/ai/loomy_auth_service.dart';
import 'package:qnote_flutter/core/ai/raccoon_auth_service.dart';

/// 账号型厂商的入口：按厂商模板 id 找到对应的账号服务
///
/// 发信层与设置页只依赖 [AccountAuthService] 接口，不再直接写死某个厂商。
class AccountAuthRegistry {
  AccountAuthRegistry._();

  /// 所有账号型厂商（新增厂商时只改这里）
  static final List<AccountAuthService> _services = [
    RaccoonAuthService.instance,
    AutoClawAuthService.instance,
    LoomyAuthService.instance,
  ];

  static AccountAuthService forVendor(String? vendorId) {
    if (vendorId == AutoClawAuthService.templateId) {
      return AutoClawAuthService.instance;
    }
    if (vendorId == LoomyAuthService.templateId) {
      return LoomyAuthService.instance;
    }
    return RaccoonAuthService.instance;
  }

  /// 是否账号型厂商（基址已含完整聊天路径前缀，端点直接拼 `chat/completions`）
  static bool isAccountVendor(String? vendorId) =>
      _services.any((service) => service.vendorId == vendorId);

  /// 数据管理页清空/恢复数据后，所有账号服务的进程内缓存都要一起清
  static void clearAllCaches() {
    for (final service in _services) {
      service.clearCache();
    }
  }

  /// 删除某厂商条目下的全部登录态（切换凭证类型或删除条目时用）
  ///
  /// 同一 providerId 可能残留过另一种账号型厂商的账号，全部清一遍；
  /// `ai_accounts` 的删除按 providerId 做，重复调用无副作用。
  static Future<void> logoutProvider(String providerId) async {
    for (final service in _services) {
      await service.logoutProvider(providerId);
    }
  }
}