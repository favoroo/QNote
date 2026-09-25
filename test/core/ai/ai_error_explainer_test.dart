import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/ai/ai_error_explainer.dart';

void main() {
  group('AiErrorExplainer', () {
    test('DNS 解析失败：提取主机名并给出 VPN 建议（真实报错文本形态）', () {
      final text = AiErrorExplainer.describe(Exception(
        '请求模型失败: DioException [connection error]: The connection errored: '
        "Failed host lookup: '1demacbook-pro.tail77f123.ts.net' This indicates "
        'an error which most likely cannot be solved by the library. Error: '
        "SocketException: Failed host lookup: '1demacbook-pro.tail77f123.ts.net' "
        '(OS Error: No address associated with hostname, errno = 7)',
      ));
      expect(text, contains('无法解析服务器地址'));
      expect(text, contains('1demacbook-pro.tail77f123.ts.net'));
      expect(text, contains('Tailscale'));
      expect(text, contains('技术详情'));
    });

    test('DNS 解析失败：主机名无引号包裹时同样可提取', () {
      final text = AiErrorExplainer.describe(
        'Failed host lookup: my-gateway.example.com',
      );
      expect(text, contains('`my-gateway.example.com`'));
    });

    test('连接超时', () {
      final text = AiErrorExplainer.describe(
        'DioException [connection timeout]: The request connection took longer than 0:00:30.000000',
      );
      expect(text, contains('连接服务器超时'));
    });

    test('连接被拒', () {
      final text = AiErrorExplainer.describe(
        'SocketException: Connection refused (OS Error: Connection refused, errno = 111)',
      );
      expect(text, contains('服务器拒绝了连接'));
    });

    test('TLS 握手失败', () {
      final text = AiErrorExplainer.describe(
        'HandshakeException: Handshake error in client (CERTIFICATE_VERIFY_FAILED)',
      );
      expect(text, contains('安全连接（TLS/证书）校验失败'));
    });

    test('HTTP 401：优先从 DioException 实例读取状态码', () {
      final options = RequestOptions(path: '/v1/chat/completions');
      final error = DioException(
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: 401),
      );
      final text = AiErrorExplainer.describe(error);
      expect(text, contains('API Key 无效或没有访问权限（HTTP 401）'));
    });

    test('HTTP 429：区分「秒级突发」与「额度耗尽」两种限流', () {
      final tpm = AiErrorExplainer.describe(
        'DioException [bad response]: The request returned an invalid status code of 429',
      );
      expect(tpm, contains('额度暂时用满（HTTP 429 · 限流）'));
      expect(tpm, contains('共享的免费额度'));

      final rpsOptions = RequestOptions(path: '/v1/chat/completions');
      final rpsError = AiErrorExplainer.describe(
        DioException(
          requestOptions: rpsOptions,
          type: DioExceptionType.badResponse,
          message: 'status code of 429, rps exhausted',
          response: Response(requestOptions: rpsOptions, statusCode: 429),
        ),
      );
      expect(rpsError, contains('被服务端的排队保护挡下（HTTP 429 · rps）'));

      // SSE 带内错误：HTTP 是 200，状态码提取不到，只能靠服务商错误标识判定
      final inBand = AiErrorExplainer.describe(
        'Exception: 请求模型失败: AI Stream Error: '
        '{message: inference exceeds tpm/rpm limit, code: RateLimitExceeded.EndpointTPMExceeded}',
      );
      expect(inBand, contains('额度暂时用满（HTTP 429 · 限流）'));
    });

    test('HTTP 502：从网关包装文案识别服务端故障', () {
      final text = AiErrorExplainer.describe('Bad response: 502');
      expect(text, contains('服务器内部故障（HTTP 502）'));
    });

    test('HTTP 404：提示检查地址与模型名', () {
      final text = AiErrorExplainer.describe(
        'The request returned an invalid status code of 404',
      );
      expect(text, contains('接口或模型不存在'));
    });

    test('未知错误兜底', () {
      final text = AiErrorExplainer.describe(Exception('某种奇怪的错误'));
      expect(text, contains('未知错误'));
      expect(text, contains('某种奇怪的错误'));
    });

    test('技术详情压成单行并截断到上限', () {
      final long = 'x' * 800;
      final text = AiErrorExplainer.describe(Exception('多行\n错误\n$long'));
      expect(text, contains('技术详情：'));
      expect(text.contains('\n错误'), isFalse);
      expect(text.endsWith('…'), isTrue);
      // 问题/建议/详情前缀之外的正文不应超过截断上限太多
      expect(text.length, lessThan(700));
    });
  });
}
