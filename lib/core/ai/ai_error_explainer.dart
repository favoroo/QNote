import 'package:dio/dio.dart';

/// AI 请求异常的友好化描述工具。
///
/// 小Q的请求失败最终以聊天气泡呈现给用户，原始 DioException 文本（多行英文
/// 错误加内部堆栈帧）对用户没有行动指导意义。本工具把异常——或已经字符串化的
/// 嵌套异常（如 `Exception: 请求模型失败: DioException ...`）——翻译成
/// 「问题 + 建议」的中文说明，末尾保留截断后的技术详情，兼顾可读性与排查需求。
class AiErrorExplainer {
  AiErrorExplainer._();

  /// 技术详情最大保留字符数，防止原始堆栈把气泡撑得过长
  static const int _maxDetailLength = 500;

  /// 把任意错误翻译成友好说明（Markdown 片段：问题/建议 + 技术详情）
  static String describe(Object error) {
    final raw = error.toString();
    final String problem;
    final String advice;

    final statusCode = _extractStatusCode(error, raw);

    if (raw.contains('Failed host lookup')) {
      final host = RegExp(r"Failed host lookup:\s*'?(.+?)'?(?:\s|\(|$)")
          .firstMatch(raw)
          ?.group(1);
      problem = host == null
          ? '无法解析服务器地址（域名没有对应的 IP）'
          : '无法解析服务器地址 `$host`（域名没有对应的 IP）';
      advice =
          '设备当前可能不在该服务所在的网络中。内网/自建域名（如 Tailscale、局域网地址）'
          '需要先连接对应网络或 VPN；公网服务请检查网络连接与域名拼写。';
    } else if (raw.contains('Connection timed out') ||
        raw.contains('connection timeout') ||
        raw.contains('connection took longer')) {
      problem = '连接服务器超时';
      advice = '请检查设备网络是否可用；服务端可能已下线，或服务地址/端口填写有误。';
    } else if (raw.contains('Connection refused')) {
      problem = '服务器拒绝了连接';
      advice = '目标服务可能未启动或端口不正确，请确认服务端在线、地址与端口无误。';
    } else if (raw.contains('Network is unreachable')) {
      problem = '当前网络不可用';
      advice = '设备可能未联网或没有到目标地址的路由，请检查网络连接。';
    } else if (raw.contains('HandshakeException') ||
        raw.contains('TlsException') ||
        raw.contains('CERTIFICATE_VERIFY_FAILED')) {
      problem = '安全连接（TLS/证书）校验失败';
      advice = '自建/内网网关的证书可能不受信任或已过期，请检查服务端证书配置；'
          '若使用动态网关（如 Tailscale），也可能是网关设备暂时离线或正在重连，'
          '稍后可长按本条消息重试。';
    } else if (raw.contains('receive timeout') ||
        raw.contains('receive took longer') ||
        raw.contains('TimeoutException')) {
      problem = '服务器响应超时';
      advice = '模型推理时间过长或服务端负载过高，可稍后重试；若反复出现请检查网关状态。';
    } else if (statusCode == 400) {
      problem = '服务端拒绝了请求（HTTP 400）';
      advice = '请检查模型名称与请求参数是否符合该服务的要求。';
    } else if (statusCode == 401 || statusCode == 403) {
      problem = 'API Key 无效或没有访问权限（HTTP $statusCode）';
      advice = '请到设置中检查该模型的 API Key 是否正确、是否过期，以及账号是否有对应模型的权限。';
    } else if (statusCode == 404) {
      problem = '请求的接口或模型不存在（HTTP 404）';
      advice = '请检查 Base URL 与模型名称拼写是否正确。';
    } else if (statusCode == 429 ||
        raw.contains('EndpointTPMExceeded') ||
        // SSE 带内错误没有 HTTP 状态码可提取（HTTP 本身是 200），只能靠原文里的
        // 服务商错误标识判定，否则用户看到的是一句无信息量的「未知错误」
        raw.contains('AI Stream Error')) {
      // 网关有两层限流，文案要分开：rps 是「你自己发太快了、几秒自愈」，
      // TPM 是「共享额度用完了、要等回填」，混成一句「请求过于频繁」会让人反复重发
      final isBurst = raw.contains('rps') || raw.contains('exhausted');
      problem = isBurst
          ? '短时间内请求太密集，被服务端的排队保护挡下（HTTP 429 · rps）'
          : '内置免费模型的额度暂时用满（HTTP 429 · 限流）';
      advice = isBurst
          ? '小Q 已自动换 Key 重发，通常几秒内自愈；连续追问时可以等上一条回复出来再发。'
          : '内置 Key 是全 App 用户共享的免费额度，按分钟滚动恢复，等十几秒重发即可。'
              '若要稳定不限流，可在「设置 → AI 配置」里绑定自己的模型 API Key。';
    } else if (statusCode != null && statusCode >= 500) {
      problem = '服务器内部故障（HTTP $statusCode）';
      advice = '服务端暂时不可用，请稍后重试。';
    } else {
      problem = '请求过程中发生未知错误';
      advice = '请稍后重试；若反复出现，可复制下方技术详情排查原因。';
    }

    // 压成单行再截断，避免多行堆栈把气泡撑爆
    final detail = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    final truncated = detail.length > _maxDetailLength
        ? '${detail.substring(0, _maxDetailLength)}…'
        : detail;

    return '**问题**：$problem\n'
        '**建议**：$advice\n\n'
        '技术详情：$truncated';
  }

  /// 从错误中提取 HTTP 状态码：优先读 DioException 实例的响应，
  /// 否则从字符串化文本中匹配 dio 的两种典型文案
  static int? _extractStatusCode(Object error, String raw) {
    if (error is DioException) {
      final code = error.response?.statusCode;
      if (code != null) return code;
    }
    // "The request returned an invalid status code of 401"
    final badStatus = RegExp(r'invalid status code of (\d{3})').firstMatch(raw);
    if (badStatus != null) return int.tryParse(badStatus.group(1)!);
    // 部分网关的包装形态："Bad response: 502"
    final badResponse =
        RegExp(r'[Bb]ad response:?\s*(\d{3})').firstMatch(raw);
    return badResponse == null ? null : int.tryParse(badResponse.group(1)!);
  }
}
