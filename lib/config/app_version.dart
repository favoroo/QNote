/// 应用版本号相关配置。
///
/// 版本号的唯一来源是 `pubspec.yaml` 的 `version` 字段，
/// 通过 `package_info_plus` 在运行时读取构建产物中的版本信息，
/// 无需在代码中手动维护副本。
library;

import 'package:package_info_plus/package_info_plus.dart';

/// GitHub 仓库所有者，用于拉取 Release 更新信息。
const String kRepoOwner = 'favoroo';

/// GitHub 仓库名称，用于拉取 Release 更新信息。
const String kRepoName = 'QNote';

/// Gitee 仓库所有者，用于国内首选 Release 更新信息。
const String kGiteeOwner = 'favo9';

/// Gitee 仓库名称，用于国内首选 Release 更新信息。
const String kGiteeRepo = 'qnote';

/// 应用版本号工具类。
///
/// 在应用启动时调用 [init] 一次，之后直接读取 [version] 即可。
/// 版本号最终来源于 `pubspec.yaml`，通过 `PackageInfo` 读取。
class AppVersion {
  AppVersion._();

  /// 当前应用版本号（语义化三段式，如 `0.1.0`）。
  static late String version;

  static bool _initialized = false;

  /// 从构建产物读取版本号，需在应用启动时调用一次。
  static Future<void> init() async {
    if (_initialized) return;
    final info = await PackageInfo.fromPlatform();
    version = info.version;
    _initialized = true;
  }
}
