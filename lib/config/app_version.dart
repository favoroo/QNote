/// 应用版本号相关配置。
///
/// 这里集中维护 QNote 的版本号，供「关于」页展示与「检查更新」比对使用。
library;

/// 当前应用版本号（语义化三段式，如 `1.0.0`）。
///
/// 命名带上 App 前缀避免与其它常量语义混淆。
/// 发布新版本时必须同时修改 `pubspec.yaml` 的 `version` 字段（取 `+` 前面的部分），
/// 两者不一致会导致「检查更新」把已发布版本误判为新版本。
const String kAppVersion = '1.0.0';

/// GitHub 仓库所有者，用于拉取 Release 更新信息。
const String kRepoOwner = 'favoroo';

/// GitHub 仓库名称，用于拉取 Release 更新信息。
const String kRepoName = 'QNote';
