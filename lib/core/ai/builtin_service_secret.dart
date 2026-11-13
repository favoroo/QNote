/// 内置模型服务（小Q 免费模型）用到的客户端常量。
///
/// ⚠️ 这些常量会随 App 一起分发，任何人都能从安装包或公开仓库里提取，
/// **不是真正的密钥**。真正的防线在网关侧：
/// 按安装 ID / IP 的配额、模型白名单、全局维护开关。
/// 这里的签名只用来挡掉随手扫描公网地址的脚本，不能当作安全边界。
library;

/// 安装签名用的 secret。
///
/// 发布构建可用 `--dart-define=QNOTE_BUILTIN_APP_SECRET=...` 注入；
/// 未注入时 App 不发签名头，网关在内测阶段默认 `requireSignature: false`。
const String builtinAppSecret = String.fromEnvironment('QNOTE_BUILTIN_APP_SECRET');

/// 远程配置完整性校验用的公开常量（不是密钥，只防误写与损坏）。
const String builtinConfigChecksumKey = 'qnote-builtin-config-v1';

/// 是否具备发送签名的条件
bool get hasBuiltinAppSecret => builtinAppSecret.trim().isNotEmpty;
