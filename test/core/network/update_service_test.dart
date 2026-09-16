import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/network/update_service.dart';

void main() {
  group('UpdateService.extractApkAsset', () {
    test('assets 中包含 .apk 附件时返回 url 和 size', () {
      final releaseData = <String, dynamic>{
        'assets': [
          {
            'name': 'QNote-v0.1.48-arm64-v8a.apk',
            'browser_download_url':
                'https://github.com/favoroo/QNote/releases/download/v0.1.48/QNote-v0.1.48-arm64-v8a.apk',
            'size': 32380330,
          },
          {
            'name': 'source.zip',
            'browser_download_url': 'https://example.com/source.zip',
            'size': 1024,
          },
        ],
      };

      final result = UpdateService.extractApkAsset(releaseData);

      expect(result, isNotNull);
      expect(
        result!.url,
        'https://github.com/favoroo/QNote/releases/download/v0.1.48/QNote-v0.1.48-arm64-v8a.apk',
      );
      expect(result.size, 32380330);
    });

    test('assets 中不包含 .apk 附件时返回 null', () {
      final releaseData = <String, dynamic>{
        'assets': [
          {
            'name': 'source.zip',
            'browser_download_url': 'https://example.com/source.zip',
            'size': 1024,
          },
          {
            'name': 'source.tar.gz',
            'browser_download_url': 'https://example.com/source.tar.gz',
            'size': 2048,
          },
        ],
      };

      final result = UpdateService.extractApkAsset(releaseData);

      expect(result, isNull);
    });

    test('assets 为空列表时返回 null', () {
      final releaseData = <String, dynamic>{'assets': <Map<String, dynamic>>[]};

      final result = UpdateService.extractApkAsset(releaseData);

      expect(result, isNull);
    });

    test('assets 字段不存在时返回 null', () {
      final releaseData = <String, dynamic>{'tag_name': 'v0.1.48'};

      final result = UpdateService.extractApkAsset(releaseData);

      expect(result, isNull);
    });

    test('assets 非 List 时返回 null', () {
      final releaseData = <String, dynamic>{'assets': 'not-a-list'};

      final result = UpdateService.extractApkAsset(releaseData);

      expect(result, isNull);
    });

    test('APK 附件缺少 browser_download_url 时跳过', () {
      final releaseData = <String, dynamic>{
        'assets': [
          {
            'name': 'QNote-v0.1.48-arm64-v8a.apk',
            'browser_download_url': '',
            'size': 32380330,
          },
        ],
      };

      final result = UpdateService.extractApkAsset(releaseData);

      expect(result, isNull);
    });

    test('APK 附件 size 非 int 时返回 size=0', () {
      final releaseData = <String, dynamic>{
        'assets': [
          {
            'name': 'QNote-v0.1.48-arm64-v8a.apk',
            'browser_download_url':
                'https://gitee.com/favo9/qnote/releases/download/v0.1.48/QNote-v0.1.48-arm64-v8a.apk',
            'size': 'unknown',
          },
        ],
      };

      final result = UpdateService.extractApkAsset(releaseData);

      expect(result, isNotNull);
      expect(result!.size, 0);
    });

    test('assets 中多个 APK 时只取第一个', () {
      final releaseData = <String, dynamic>{
        'assets': [
          {
            'name': 'QNote-v0.1.48-arm64-v8a.apk',
            'browser_download_url': 'https://first.example.com/app.apk',
            'size': 100,
          },
          {
            'name': 'QNote-v0.1.48-armeabi-v7a.apk',
            'browser_download_url': 'https://second.example.com/app.apk',
            'size': 200,
          },
        ],
      };

      final result = UpdateService.extractApkAsset(releaseData);

      expect(result, isNotNull);
      expect(result!.url, 'https://first.example.com/app.apk');
      expect(result.size, 100);
    });
  });

  group('UpdateService 下载候选 URL 构建', () {
    // 验证 Gitee 源有 APK 时的候选列表构建逻辑
    // 这是 checkForUpdate 内部的行为，通过 extractApkAsset 的输出间接验证

    test('Gitee APK url 可正确提取用于后续候选构建', () {
      final giteeReleaseData = <String, dynamic>{
        'tag_name': 'v0.1.48',
        'html_url': 'https://gitee.com/favo9/qnote/releases/tag/v0.1.48',
        'assets': [
          {
            'name': 'QNote-v0.1.48-arm64-v8a.apk',
            'browser_download_url':
                'https://gitee.com/favo9/qnote/releases/download/v0.1.48/QNote-v0.1.48-arm64-v8a.apk',
            'size': 32380330,
          },
        ],
      };

      final apk = UpdateService.extractApkAsset(giteeReleaseData);

      expect(apk, isNotNull);
      expect(apk!.url.contains('gitee.com'), isTrue);
    });

    test('GitHub 源 APK url 可正确提取用于后续候选构建', () {
      final githubReleaseData = <String, dynamic>{
        'tag_name': 'v0.1.48',
        'html_url': 'https://github.com/favoroo/QNote/releases/tag/v0.1.48',
        'assets': [
          {
            'name': 'QNote-v0.1.48-arm64-v8a.apk',
            'browser_download_url':
                'https://github.com/favoroo/QNote/releases/download/v0.1.48/QNote-v0.1.48-arm64-v8a.apk',
            'size': 32380330,
          },
        ],
      };

      final apk = UpdateService.extractApkAsset(githubReleaseData);

      expect(apk, isNotNull);
      expect(apk!.url.startsWith('https://github.com/'), isTrue);
    });

    test('Gitee 源无 APK 时 extractApkAsset 返回 null（触发补查逻辑）', () {
      // 模拟 Gitee 配额满未上传 APK 的场景
      final giteeNoApkData = <String, dynamic>{
        'tag_name': 'v0.1.48',
        'html_url': 'https://gitee.com/favo9/qnote/releases/tag/v0.1.48',
        'assets': [
          {
            'name': 'v0.1.48.zip',
            'browser_download_url':
                'https://gitee.com/favo9/qnote/archive/refs/tags/v0.1.48.zip',
          },
          {
            'name': 'v0.1.48.tar.gz',
            'browser_download_url':
                'https://gitee.com/favo9/qnote/archive/refs/tags/v0.1.48.tar.gz',
          },
        ],
      };

      final apk = UpdateService.extractApkAsset(giteeNoApkData);

      // 首选源没有 APK → checkForUpdate 将向 GitHub 补查
      expect(apk, isNull);
    });

    test('GitHub 补查源的 APK url 可正确提取', () {
      // 模拟补查 GitHub 时拿到的 Release 数据
      final githubFallbackData = <String, dynamic>{
        'tag_name': 'v0.1.48',
        'html_url': 'https://github.com/favoroo/QNote/releases/tag/v0.1.48',
        'assets': [
          {
            'name': 'QNote-v0.1.48-arm64-v8a.apk',
            'browser_download_url':
                'https://github.com/favoroo/QNote/releases/download/v0.1.48/QNote-v0.1.48-arm64-v8a.apk',
            'size': 32380330,
            'state': 'uploaded',
          },
        ],
      };

      final apk = UpdateService.extractApkAsset(githubFallbackData);

      expect(apk, isNotNull);
      expect(apk!.url.startsWith('https://github.com/'), isTrue);
      expect(apk.size, 32380330);
    });

    test('两端都无 APK 时均返回 null', () {
      final giteeNoApk = <String, dynamic>{
        'assets': [
          {'name': 'source.zip'},
        ],
      };
      final githubNoApk = <String, dynamic>{
        'assets': [
          {'name': 'source.zip'},
        ],
      };

      expect(UpdateService.extractApkAsset(giteeNoApk), isNull);
      expect(UpdateService.extractApkAsset(githubNoApk), isNull);
    });
  });
}
