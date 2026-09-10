import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// 首选安装包下载地址（优先国内镜像加速直链）。
  final String downloadUrl;

  /// 原始安装包下载直链（未代理），供备选与浏览器打开。
  final String originalDownloadUrl;

  /// 可用的候选下载地址列表（按优先级：国内加速镜像 → 原始直链）。
  final List<String> candidateDownloadUrls;

  /// Release 页面地址，供用户查看完整说明。
  final String releaseUrl;

  /// APK 体积（字节），未知时为 null。
  final int? fileSize;

  /// 是否包含合法的 APK 安装包产物。
  final bool hasApk;

  const UpdateInfo({
    required this.version,
    required this.tagName,
    required this.releaseName,
    required this.releaseNotes,
    required this.downloadUrl,
    required this.originalDownloadUrl,
    required this.candidateDownloadUrls,
    required this.releaseUrl,
    this.fileSize,
    this.hasApk = false,
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
/// 数据源为 GitHub Releases 的 latest 接口，并配合国内加速镜像服务，与本地版本号 [AppVersion.version] 做语义化比较。
class UpdateService {
  UpdateService._();

  /// 服务单例。
  static final UpdateService instance = UpdateService._();

  /// GitHub Releases 最新版本官方接口地址。
  static const String _directReleaseUrl =
      'https://api.github.com/repos/$kRepoOwner/$kRepoName/releases/latest';

  /// 国内 GitHub 加速镜像前缀（末尾带斜杠）。
  static const List<String> kGithubProxies = <String>[
    'https://ghfast.top/',
    'https://ghproxy.net/',
    'https://gh-proxy.com/',
    'https://github.moeyy.xyz/',
  ];

  static const String _kAutoCheckKey = 'auto_check_update_enabled';
  static const String _kLastCheckTimeKey = 'last_update_check_time';

  /// 查询是否开启了启动时自动检查更新（默认开启）。
  Future<bool> isAutoCheckEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kAutoCheckKey) ?? true;
  }

  /// 设置是否开启启动时自动检查更新。
  Future<void> setAutoCheckEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoCheckKey, enabled);
  }

  /// 记录本次检查更新的时间戳。
  Future<void> recordCheckTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kLastCheckTimeKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// 判断当前冷启动是否应当触发静默更新检查。
  ///
  /// 条件：
  /// 1. 用户开启了自动检查；
  /// 2. 距离上次检查已超过 24 小时（节流），避免频繁请求触发限流。
  Future<bool> shouldRunStartupCheck() async {
    final enabled = await isAutoCheckEnabled();
    if (!enabled) return false;

    final prefs = await SharedPreferences.getInstance();
    final lastTimeMs = prefs.getInt(_kLastCheckTimeKey);
    if (lastTimeMs == null) return true;

    final lastCheck = DateTime.fromMillisecondsSinceEpoch(lastTimeMs);
    final diff = DateTime.now().difference(lastCheck);
    return diff.inHours >= 24;
  }

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
    headers: <String, String>{'Accept': 'application/vnd.github+json'},
  ));

  /// 检查是否存在新版本。
  ///
  /// [currentVersion] 为当前版本号，缺省取 [AppVersion.version]。
  /// 优先直连官方接口，若失败会自动顺延尝试国内镜像加速地址。
  Future<UpdateCheckResult> checkForUpdate({String? currentVersion}) async {
    final localVersion = currentVersion ?? AppVersion.version;

    // 组合候选接口地址：官方直连优先，失败后依次尝试国内镜像
    final candidateEndpoints = <String>[
      _directReleaseUrl,
      ...kGithubProxies.map((proxy) => '$proxy$_directReleaseUrl'),
    ];

    Map<String, dynamic>? releaseData;
    String? lastErrorReason;

    for (final endpoint in candidateEndpoints) {
      try {
        final response = await _dio.get<dynamic>(endpoint);
        if (response.statusCode == 200 && response.data is Map<String, dynamic>) {
          releaseData = response.data as Map<String, dynamic>;
          break;
        }
      } on DioException catch (e) {
        lastErrorReason = e.message;
        LoggerService.instance.warning(
          '更新检查接口 ($endpoint) 访问失败: ${e.message}，尝试下一个备用地址',
          category: LogCategory.network,
        );
      } catch (e) {
        lastErrorReason = e.toString();
        LoggerService.instance.warning(
          '更新检查接口 ($endpoint) 异常: $e，尝试下一个备用地址',
          category: LogCategory.network,
        );
      }
    }

    if (releaseData == null) {
      return UpdateCheckResult.failed('网络请求失败，请稍后重试（$lastErrorReason）');
    }

    try {
      // 草稿与预发布版本不推送给普通用户
      if (releaseData['draft'] == true || releaseData['prerelease'] == true) {
        return UpdateCheckResult.upToDate;
      }

      final tagName = releaseData['tag_name']?.toString() ?? '';
      if (tagName.isEmpty) {
        return UpdateCheckResult.failed('Release 缺少版本号');
      }

      if (!isVersionNewer(candidate: tagName, current: localVersion)) {
        return UpdateCheckResult.upToDate;
      }

      // 优先寻找 APK 附件
      String? rawApkUrl;
      int? apkSize;
      final assets = releaseData['assets'];
      if (assets is List) {
        for (final item in assets) {
          if (item is! Map<String, dynamic>) continue;
          final name = item['name']?.toString() ?? '';
          if (!name.toLowerCase().endsWith('.apk')) continue;
          rawApkUrl = item['browser_download_url']?.toString();
          final size = item['size'];
          if (size is int) apkSize = size;
          break;
        }
      }

      final releaseUrl = releaseData['html_url']?.toString() ?? '';
      final hasApk = rawApkUrl != null && rawApkUrl.isNotEmpty;

      // 构建下载候选列表：优先国内镜像加速直链，末尾兜底原始链接
      final candidateDownloadUrls = <String>[];
      if (hasApk) {
        if (rawApkUrl.startsWith('https://github.com/')) {
          for (final proxy in kGithubProxies) {
            candidateDownloadUrls.add('$proxy$rawApkUrl');
          }
        }
        candidateDownloadUrls.add(rawApkUrl);
      } else {
        candidateDownloadUrls.add(releaseUrl);
      }

      return UpdateCheckResult.available(UpdateInfo(
        version: normalizeVersion(tagName),
        tagName: tagName,
        releaseName: releaseData['name']?.toString() ?? tagName,
        releaseNotes: releaseData['body']?.toString() ?? '',
        downloadUrl: candidateDownloadUrls.first,
        originalDownloadUrl: rawApkUrl ?? releaseUrl,
        candidateDownloadUrls: candidateDownloadUrls,
        releaseUrl: releaseUrl,
        fileSize: apkSize,
        hasApk: hasApk,
      ));
    } catch (e, stackTrace) {
      LoggerService.instance.error(
        '解析更新数据异常: $e',
        category: LogCategory.network,
        details: stackTrace.toString(),
      );
      return UpdateCheckResult.failed('检查更新时发生异常');
    }
  }

  /// 下载 APK 安装包到本地缓存临时目录。
  ///
  /// [candidateUrls] 候选下载地址列表（按优先级尝试：国内加速镜像 → 原始地址）。
  /// [onProgress] 回调已接收字节与总字节数。
  /// [cancelToken] 取消令牌。
  /// 返回下载成功的本地文件完整路径；若全部失败或被取消则抛出异常。
  Future<String> downloadApk({
    required List<String> candidateUrls,
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final savePath = '${tempDir.path}/qnote_update.apk';
    final targetFile = File(savePath);

    // 下载专用 Dio 实例：连接超时 15 秒，接收超时 10 分钟
    final downloadDio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 10),
      followRedirects: true,
      maxRedirects: 5,
    ));

    Object? lastError;
    for (final url in candidateUrls) {
      if (cancelToken?.isCancelled ?? false) {
        throw DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.cancel,
          error: '用户取消下载',
        );
      }

      try {
        if (await targetFile.exists()) {
          await targetFile.delete();
        }

        await downloadDio.download(
          url,
          savePath,
          cancelToken: cancelToken,
          onReceiveProgress: onProgress,
          deleteOnError: true,
        );

        if (await targetFile.exists() && (await targetFile.length()) > 0) {
          return savePath;
        }
      } on DioException catch (e) {
        lastError = e;
        if (CancelToken.isCancel(e)) {
          rethrow;
        }
        LoggerService.instance.warning(
          'APK 下载节点失败 ($url): ${e.message}，准备尝试下一个镜像',
          category: LogCategory.network,
        );
      } catch (e) {
        lastError = e;
        LoggerService.instance.warning(
          'APK 下载节点异常 ($url): $e，准备尝试下一个镜像',
          category: LogCategory.network,
        );
      }
    }

    throw Exception('所有下载镜像均不可用，请稍后重试或使用浏览器下载 (错误: $lastError)');
  }
}
