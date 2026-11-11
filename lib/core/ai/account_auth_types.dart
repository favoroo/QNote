import 'package:qnote_flutter/core/ai/raccoon_account_router.dart' show AiRequestScope;
import 'package:qnote_flutter/models/account_checkin_result.dart';
import 'package:qnote_flutter/models/account_quota.dart';
import 'package:qnote_flutter/models/ai_account.dart';
import 'package:qnote_flutter/models/ai_provider.dart';

/// 订阅账号没有可用登录态：发信前抛出，交给界面提示重新登录
class AccountAuthRequiredException implements Exception {
  final String providerId;
  final String message;

  /// 账号类型（`raccoon` / `autoclaw` / `loomy`），便于日志定位
  final String kind;

  const AccountAuthRequiredException(
    this.providerId, {
    this.message = '账号未登录或已过期，请到「设置 → AI 模型配置」重新登录',
    this.kind = '',
  });

  @override
  String toString() => message;
}

/// 商汤小浣熊的登录态异常（保留原名，现有调用方与测试无需改动）
class RaccoonAuthRequiredException extends AccountAuthRequiredException {
  const RaccoonAuthRequiredException(super.providerId, {super.message = '小浣熊账号未登录或已过期，请到「设置 → AI 模型配置」重新登录'})
    : super(kind: AiAccount.kindRaccoon);
}

/// 一次发信要用的账号与凭证
class AccountSession {
  final AiAccount account;
  final String accessToken;

  const AccountSession({required this.account, required this.accessToken});
}

/// 一次短信验证码登录的挑战：手机号 + 厂商发码时给的续接凭据
///
/// 各厂商的续接凭据含义不同（AutoClaw 是本次登录的 `device_id`，Loomy 是发码
/// 接口返回的 `msgid`），但校验验证码时都必须与发码时一致，因此统一由弹层
/// 持有并在验码时原样回传。
class AccountSmsChallenge {
  final String phone;

  /// 发码响应里的续接凭据（AutoClaw: device_id / Loomy: msgid）
  final String ticket;

  const AccountSmsChallenge({required this.phone, required this.ticket});
}

/// 订阅账号型厂商需要实现的统一能力
///
/// 发信层、设置页与数据管理页只依赖这个接口；具体厂商（小浣熊、AutoClaw、
/// Loomy）各自实现登录、刷新、额度与签到。这样新增一个账号型厂商时，不需要
/// 再去改 `AiService` 里散落的 `vendorId == ...` 分支。
abstract class AccountAuthService {
  /// 厂商模板 id（与 `AiProvider.vendorId` 一致）
  String get vendorId;

  /// 账号类型（写入 `ai_accounts.kind`）
  String get kind;

  /// 界面上称呼这个厂商的名字（「小浣熊」「AutoClaw」「Loomy」）
  String get vendorLabel;

  /// 是否支持「手机号 + 短信验证码」登录
  ///
  /// 小浣熊走浏览器回环授权，其余厂商是短信登录，设置页据此决定弹哪个登录层。
  bool get supportsSmsLogin => false;

  /// 短信验证码最长位数（弹层输入框的长度限制；厂商只发 6 位时收紧）
  int get smsCodeMaxLength => 8;

  /// 本次厂商对应的「未登录」异常（文案带厂商名）
  AccountAuthRequiredException notLoggedIn(String providerId);

  /// 刷新后仍被拒绝时的「登录失效」异常（文案带厂商名）
  AccountAuthRequiredException authExpired(String providerId);

  Future<List<AiAccount>> accountsFor(String providerId, {bool forceReload = false});

  Future<AccountSession?> sessionForRequest(
    String providerId, {
    String routing = 'rotate',
    String affinity = 'session',
    AiRequestScope? scope,
    Set<String> triedAccountIds = const {},
    bool advance = true,
  });

  Future<bool> hasAlternateAccount(
    String providerId, {
    String routing = 'rotate',
    String affinity = 'session',
    AiRequestScope? scope,
    Set<String> triedAccountIds = const {},
  });

  Future<AiAccount?> accountById(String accountId);

  AiAccount? accountFromCache(String accountId);

  void markAccountFailed(AiAccount account, Object error, {String affinity = 'session'});

  void markAccountSucceeded(AiAccount account);

  bool isAccountCooling(String accountId);

  Future<String?> accessTokenForAccount(AiAccount account);

  Future<AiAccount> refreshAccount(String accountId, {bool force = false});

  Future<AiAccount> refresh(String providerId, {bool force = false});

  Future<AccountQuota> fetchQuota(AiAccount account);

  Future<AccountCheckInResult> checkIn(AiAccount account);

  Future<List<AiProviderModel>> fetchModelsForProvider(String providerId);

  Future<void> logout(String accountId);

  Future<void> logoutProvider(String providerId);

  Future<AiAccount> updateAccount(AiAccount account, {String? alias, bool? enabled});

  Future<List<AiAccount>> reorderAccounts(String providerId, List<String> orderedIds);

  /// 数据管理页清空全部数据后清掉进程内缓存（账号、选号游标、冷却表）
  void clearCache();

  /// 发信层逐请求覆写的鉴权头（含厂商要求的客户端指纹头）
  ///
  /// 默认是 OpenAI 兼容的 `Bearer`；AutoClaw 这类把 token 放在自定义头里的厂商
  /// 覆写它。返回的 map 里用 null 显式移除另一家的凭证头，避免串用。
  Map<String, dynamic> requestHeaders(String token, {required String model}) => {
    'Authorization': 'Bearer $token',
    'x-goog-api-key': null,
  };

  /// 发信前按厂商协议改写请求体（默认不改）
  ///
  /// 放在这里而不是散在 `AiService` 里：网关对字段的取舍（拒收 max_tokens、
  /// 只认三档思考强度、旧版 DeepSeek 的图片标记）属于厂商知识。
  void adaptChatBody(Map<String, dynamic> body, {required String model}) {}

  /// 发送短信验证码；[supportsSmsLogin] 为假时不会被调用
  Future<AccountSmsChallenge> sendLoginCode(String providerId, String phone) =>
      throw UnsupportedError('$vendorLabel 不支持短信登录');

  /// 用短信验证码完成登录；[accountId] 非空表示重新登录已有账号
  Future<AiAccount> verifyLoginCode(
    String providerId,
    AccountSmsChallenge challenge,
    String code, {
    String? accountId,
  }) => throw UnsupportedError('$vendorLabel 不支持短信登录');
}
