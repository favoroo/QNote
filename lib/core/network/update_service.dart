import 'package:dio/dio.dart';

import 'package:qnote_flutter/config/app_version.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/utils/version_utils.dart';

/// 更新检查的结果状态。
enum UpdateCheckStatus {
  /// 当前已是最新版本。
  upToDate,

  /// 存在可用更新。
  available,

  /// 检查失败（网络异常、接口返回异常等）。
  failed,
}

/// 单次更新检查的结果。
///
/// 通过命名的构造入口区分状态，调用方无需同时判空 [updateInfo] 与 [errorMessage]。
class UpdateCheckResult {
  /// 检查状态。
  final UpdateCheckStatus status;

  /// 发现更新时的详情；其余状态为 null。
  final UpdateInfo? updateInfo;

  /// 检查失败时的原因；其余状态为 null。
  final String? errorMessage;

  const UpdateCheckResult._(this.status, {this.updateInfo, this.errorMessage});

  /// 已是最新版本。
  static const UpdateCheckResult upToDate = UpdateCheckResult._(UpdateCheckStatus.upToDate);

  /// 发现新版本。
  factory UpdateCheckResult.available(UpdateInfo info) =>
      UpdateCheckResult._(UpdateCheckStatus.available, updateInfo: info);

  /// 检查失败。
  factory UpdateCheckResult.failed(String message) =>
      UpdateCheckResult._(UpdateCheckStatus.failed, errorMessage: message);
}

/// 一个可用的应用更新。
class UpdateInfo {
  /// 远端版本号，已去除 tag 前缀，如 `1.1.0`。
  final String version;

  /// GitHub Release 的原始 tag 名，如 `v1.1.0`。
  final String tagName;

  /// Release 标题。
  final String releaseName;

  /// Release 更新说明原文（GitHub Markdown）。
  final String releaseNotes;

  /// 安装包下载地址；Release 未附带 APK 时回退为 Release 页面地址。
  final String downloadUrl;

  /// Release 页面地址，供用户查看完整说明。
  final String releaseUrl;

  /// APK 体积（字节），未知时为 null。
  final int? fileSize;

  const UpdateInfo({
    required this.version,
    required this.tagName,
    required this.releaseName,
    required this.releaseNotes,
    required this.downloadUrl,
    required this.releaseUrl,
    this.fileSize,
  });

  /// 体积的可读文本，如 `29.0 MB`；体积未知时返回空串。
  String get fileSizeText {
    final size = fileSize;
    if (size == null) return '';
    return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// 应用更新检查服务。
///
/// 数据源为 GitHub Releases 的 latest 接口，与本地版本号 [AppVersion.version] 做语义化比较。
/// 该接口匿名访问限额为每 IP 每小时 60 次，对单次启动检查足够。
class UpdateService {
  UpdateService._();

  /// 服务单例。
  static final UpdateService instance = UpdateService._();

  /// GitHub Releases 最新版本接口地址。
  static const String _latestReleaseUrl =
      'https://api.github.com/repos/$kRepoOwner/$kRepoName/releases/latest';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
    // GitHub 建议显式声明 API 版本，避免默认版本变动影响字段结构
    headers: <String, String>{'Accept': 'application/vnd.github+json'},
  ));

  /// 检查是否存在新版本。
  ///
  /// [currentVersion] 为当前版本号，缺省取 [AppVersion.version]。
  /// 本方法不向外抛异常：失败原因通过 [UpdateCheckResult.errorMessage] 返回，
  /// 便于「静默检查」与「手动检查」两种场景复用同一份逻辑。
  Future<UpdateCheckResult> checkForUpdate({String? currentVersion}) async {
    final localVersion = currentVersion ?? AppVersion.version;

    try {
      final response = await _dio.get<dynamic>(_latestReleaseUrl);

      if (response.statusCode != 200) {
        return UpdateCheckResult.failed('请求失败（${response.statusCode}）');
      }

      final data = response.data;
      if (data is! Map<String, dynamic>) {
        return UpdateCheckResult.failed('返回数据格式异常');
      }

      // 草稿与预发布版本不推送给普通用户
      if (data['draft'] == true || data['prerelease'] == true) {
        return UpdateCheckResult.upToDate;
      }

      final tagName = data['tag_name']?.toString() ?? '';
      if (tagName.isEmpty) {
        return UpdateCheckResult.failed('Release 缺少版本号');
      }

      if (!isVersionNewer(candidate: tagName, current: localVersion)) {
        return UpdateCheckResult.upToDate;
      }

      // 优先取 APK 附件；找不到就退回 Release 页面让用户自行选择
      String? apkUrl;
      int? apkSize;
      final assets = data['assets'];
      if (assets is List) {
        for (final item in assets) {
          if (item is! Map<String, dynamic>) continue;
          final name = item['name']?.toString() ?? '';
          if (!name.toLowerCase().endsWith('.apk')) continue;
          apkUrl = item['browser_download_url']?.toString();
          final size = item['size'];
          if (size is int) apkSize = size;
          break;
        }
      }

      final releaseUrl = data['html_url']?.toString() ?? '';

      return UpdateCheckResult.available(UpdateInfo(
        version: normalizeVersion(tagName),
        tagName: tagName,
        releaseName: data['name']?.toString() ?? tagName,
        releaseNotes: data['body']?.toString() ?? '',
        downloadUrl: apkUrl ?? releaseUrl,
        releaseUrl: releaseUrl,
        fileSize: apkSize,
      ));
    } on DioException catch (e, stackTrace) {
      LoggerService.instance.warning(
        '检查更新失败: ${e.message}',
        category: LogCategory.network,
        details: stackTrace.toString(),
      );
      return UpdateCheckResult.failed('网络请求失败，请稍后重试');
    } catch (e, stackTrace) {
      LoggerService.instance.error(
        '检查更新异常: $e',
        category: LogCategory.network,
        details: stackTrace.toString(),
      );
      return UpdateCheckResult.failed('检查更新时发生异常');
    }
  }
}
