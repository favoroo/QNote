import 'package:flutter/foundation.dart' show visibleForTesting;

/// Edge 在线语音的 Sec-MS-GEC 访问令牌生成器（上游 edge-tts v2 算法的 Dart 移植）。
///
/// 微软在 2026-11 前后把该令牌从「SHA256(ticks + TrustedClientToken)」换成了
/// 「CS64 摘要-SHA256 摘要」的复合格式，并要求 URL 上的 `Sec-MS-GEC-Version`
/// 从 `1-` 升到 `2-`。旧令牌一律被 WAF 挡在握手之前（HTTP 403），表现为
/// **所有非系统音色都静默降级成设备语音**。
///
/// 算法与上游 `edge_tts/drm.py`（7.3.1 起）逐位对齐，golden 用例见
/// `test/core/tts/edge_tts_drm_test.dart`。
///
/// 上游出于防逆向的考虑写成 64 位乘法技巧 + 「中途态」SHA256，这里全部改写成
/// 显式 32 位运算（ROTR + 掩码、乘法拆 16 位半），使 dart2js 在 double 精度下
/// 同样精确；否则 Web 端（Edge 浏览器）算出的令牌会错。
class EdgeTtsDrm {
  EdgeTtsDrm._();

  /// 微软朗读接口的公开可信客户端令牌（浏览器扩展内置常量）
  static const String trustedClientToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';

  /// 令牌里声明的 Chromium 版本（与握手 UA 的 Edg/ 主版本保持一致）
  static const String chromiumFullVersion = '143.0.3650.75';

  /// Chromium 主版本号：握手 UA 与 `Sec-MS-GEC-Version` 都只用到这一段
  static String get chromiumMajorVersion => chromiumFullVersion.split('.').first;

  /// 握手用的 Edge 风格 UA。
  ///
  /// 微软 WAF 只放行 UA 含 `Edg/` 的连接，且 `Sec-MS-GEC-Version` 里声明的版本
  /// 必须与 UA 主版本一致，故两处共用本常量。
  static final String edgeUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/$chromiumMajorVersion.0.0.0 '
      'Safari/537.36 Edg/$chromiumMajorVersion.0.0.0';

  /// URL 参数 `Sec-MS-GEC-Version` 取值：v2 摘要算法对应 `2-<版本>` 前缀
  static String get secMsGecVersion => '2-$chromiumFullVersion';

  /// Windows 文件时间纪元（1601-01-01）相对 Unix 纪元的秒数
  static const double _winEpochSeconds = 11644473600;

  /// 令牌按 5 分钟分桶：桶内任意时刻生成同一令牌
  static const double _bucketSeconds = 300;

  /// 秒 → 100ns 间隔的换算系数（服务端按 Windows 文件时间解释该数值）
  static const double _ticksPerSecond = 1e7;

  /// 生成当前时刻的令牌（`<16位hex>-<64位hex>`）
  static String generateSecMsGec() => generateSecMsGecAt(DateTime.now().toUtc());

  /// 生成指定时刻的令牌
  static String generateSecMsGecAt(DateTime utcNow) =>
      generateSecMsGecForUnixSeconds(utcNow.millisecondsSinceEpoch / 1000);

  /// 生成指定 Unix 秒时刻的令牌（[visibleForTesting]：golden 断言入口）
  @visibleForTesting
  static String generateSecMsGecForUnixSeconds(double unixSeconds) {
    final cs64 = _cs64Part(hashInputForUnixSeconds(unixSeconds));
    final digest = _sha256Part(hashInputForUnixSeconds(unixSeconds));
    return '$cs64-$digest';
  }

  /// 拼出参与摘要的字符串：`<100ns 时间戳><可信令牌>`（[visibleForTesting]）
  @visibleForTesting
  static String hashInputForUnixSeconds(double unixSeconds) {
    var ticks = unixSeconds + _winEpochSeconds;
    ticks -= ticks % _bucketSeconds;
    ticks *= _ticksPerSecond;
    return '${ticks.toInt()}$trustedClientToken';
  }

  /// 令牌前半段：CS64 摘要的 16 位大写 hex
  @visibleForTesting
  static String cs64PartForInput(String input) => _cs64Part(input);

  /// 令牌后半段：定制 SHA256 摘要的 64 位大写 hex
  @visibleForTesting
  static String sha256PartForInput(String input) => _sha256Part(input);

  /// CS64 摘要：两个 32 位字按小端展开成 hex（与上游 `struct.pack("<II")` 一致）
  static String _cs64Part(String input) {
    final data = _asciiBytes(input);
    final (word0, word1) = _cs64Digest(data, _sha256Bytes(data));
    return '${_hexLe32(word0)}${_hexLe32(word1)}';
  }

  /// 定制 SHA256 摘要：8 个 32 位字按大端展开成 hex
  static String _sha256Part(String input) => _sha256Bytes(_asciiBytes(input)).map(_hexByte).join();

  /// SHA256 摘要的字节流（8 个字按大端打包），CS64 以字节为输入再切词
  static List<int> _sha256Bytes(List<int> data) => [
    for (final word in _sha256Digest(data)) ...[
      (word >>> 24) & 0xFF,
      (word >>> 16) & 0xFF,
      (word >>> 8) & 0xFF,
      word & 0xFF,
    ],
  ];

  /// ASCII 字节序列（待哈希内容全部是数字与大写 hex）
  static List<int> _asciiBytes(String input) => input.codeUnits.map((c) => c & 0xFF).toList(growable: false);

  static String _hexLe32(int value) {
    final buffer = StringBuffer();
    for (var shift = 0; shift < 32; shift += 8) {
      buffer.write(_hexByte((value >>> shift) & 0xFF));
    }
    return buffer.toString();
  }

  static String _hexByte(int value) => value.toRadixString(16).padLeft(2, '0').toUpperCase();

  // ── 定制 SHA256 ────────────────────────────────────────────────
  //
  // 上游为混淆把标准 SHA256 拆成了「预处理中途态 + 分段轮函数」：初始寄存器
  // `_sha256State` 与消息前 14 个字 `_sha256Schedule` 都是预先算好的常量，
  // 前 7 字节消息走 `_sha256Init` 单独吸收。这里逐行照搬，不做数学化简。

  /// 待哈希消息比输入串长 57 字节（其余为折叠进常量里的固定前缀）
  static const int _virtualPrefixBytes = 57;

  static List<int> _sha256Digest(List<int> data) {
    if (data.length < 7) {
      throw ArgumentError.value(data.length, 'data', '输入不足 7 字节');
    }
    final messageLength = _virtualPrefixBytes + data.length;
    final padded = <int>[...data.sublist(7), 0x80];
    padded.addAll(List<int>.filled((55 - messageLength) % 64, 0));
    final bitLength = messageLength * 8;
    for (var shift = 56; shift >= 0; shift -= 8) {
      padded.add((bitLength >>> shift) & 0xFF);
    }

    var state = _sha256Init(data.sublist(0, 7));
    for (var offset = 0; offset < padded.length; offset += 64) {
      final words = <int>[
        for (var i = 0; i < 16; i++)
          (padded[offset + i * 4] << 24) |
              (padded[offset + i * 4 + 1] << 16) |
              (padded[offset + i * 4 + 2] << 8) |
              padded[offset + i * 4 + 3],
      ];
      _expandSha256Schedule(words);
      final working = _sha256Rounds(state, words);
      state = [for (var i = 0; i < 8; i++) (state[i] + working[i]) & _mask32];
    }
    return state;
  }

  /// 「中途态」初始化：吸收前 7 字节并补齐前 31 个字，返回本次消息的起始寄存器
  static List<int> _sha256Init(List<int> firstSeven) {
    final words = List<int>.filled(16, 0, growable: true);
    words[14] = (firstSeven[0] << 16) | (firstSeven[1] << 8) | firstSeven[2];
    words[15] = (firstSeven[3] << 24) | (firstSeven[4] << 16) | (firstSeven[5] << 8) | firstSeven[6];
    for (var index = 16; index < 30; index++) {
      var value = _sha256Schedule[index - 16];
      var sigma1 = _sigma1(words[index - 2]);
      if (index == 16) sigma1 ^= _sha256Sigma1Adjustment;
      value += sigma1;
      if (index - 7 >= 14) value += words[index - 7];
      if (index - 15 >= 14) {
        var sigma0 = _sigma0(words[index - 15]);
        if (index == 29) sigma0 ^= _sha256Sigma0Adjustment;
        value += sigma0;
      }
      words.add(value & _mask32);
    }
    words.add(
      (_sigma1(words[28]) +
              words[23] +
              _sigma0(words[15]) +
              words[14] +
              _sha256Adjustment -
              _sha256RoundConstants[14]) &
          _mask32,
    );
    _expandSha256Schedule(words, 31);
    final working = _sha256Rounds(_sha256State, words, 14);
    return [for (var i = 0; i < 8; i++) (_sha256Initial[i] + working[i]) & _mask32];
  }

  /// 消息扩展：由前 16（或前 31）个字推出后面的字
  static void _expandSha256Schedule(List<int> words, [int firstWord = 16]) {
    for (var index = firstWord; index < 64; index++) {
      final x = words[index - 2];
      final y = words[index - 15];
      final sigma1 = _rotr(x, 17) ^ _rotr(x, 19) ^ (x >>> 10);
      final sigma0 = _rotr(y, 7) ^ _rotr(y, 18) ^ (y >>> 3);
      words.add((sigma1 + words[index - 7] + sigma0 + words[index - 16]) & _mask32);
    }
  }

  /// 压缩函数：[firstRound] 供中途态从第 14 轮接续（此时常量表需替换第 14 项）
  static List<int> _sha256Rounds(List<int> state, List<int> words, [int firstRound = 0]) {
    var a = state[0], b = state[1], c = state[2], d = state[3];
    var e = state[4], f = state[5], g = state[6], h = state[7];
    final aligned = (firstRound + 7) ~/ 8 * 8;
    final limit = aligned < 64 ? aligned : 64;
    final constants = firstRound == 14 ? _sha256BlockConstants : _sha256RoundConstants;

    for (var i = firstRound; i < limit; i++) {
      final t1 = h + (_rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25)) + (g ^ (e & (f ^ g))) + constants[i] + words[i];
      final t2 = (_rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22)) + ((a & b) | (c & (a | b)));
      final nextA = (t1 + t2) & _mask32;
      final nextD = (d + t1) & _mask32;
      h = g;
      g = f;
      f = e;
      e = nextD;
      d = c;
      c = b;
      b = a;
      a = nextA;
    }

    // 每 8 轮寄存器角色正好轮转一圈，上游据此把循环体展开成「只改两个变量」
    for (var i = limit; i < 64; i += 8) {
      var t1 = h + (_rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25)) + (g ^ (e & (f ^ g))) + constants[i] + words[i];
      d = (d + t1) & _mask32;
      h = (t1 + (_rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22)) + ((a & b) | (c & (a | b)))) & _mask32;
      t1 = g + (_rotr(d, 6) ^ _rotr(d, 11) ^ _rotr(d, 25)) + (f ^ (d & (e ^ f))) + constants[i + 1] + words[i + 1];
      c = (c + t1) & _mask32;
      g = (t1 + (_rotr(h, 2) ^ _rotr(h, 13) ^ _rotr(h, 22)) + ((h & a) | (b & (h | a)))) & _mask32;
      t1 = f + (_rotr(c, 6) ^ _rotr(c, 11) ^ _rotr(c, 25)) + (e ^ (c & (d ^ e))) + constants[i + 2] + words[i + 2];
      b = (b + t1) & _mask32;
      f = (t1 + (_rotr(g, 2) ^ _rotr(g, 13) ^ _rotr(g, 22)) + ((g & h) | (a & (g | h)))) & _mask32;
      t1 = e + (_rotr(b, 6) ^ _rotr(b, 11) ^ _rotr(b, 25)) + (d ^ (b & (c ^ d))) + constants[i + 3] + words[i + 3];
      a = (a + t1) & _mask32;
      e = (t1 + (_rotr(f, 2) ^ _rotr(f, 13) ^ _rotr(f, 22)) + ((f & g) | (h & (f | g)))) & _mask32;
      t1 = d + (_rotr(a, 6) ^ _rotr(a, 11) ^ _rotr(a, 25)) + (c ^ (a & (b ^ c))) + constants[i + 4] + words[i + 4];
      h = (h + t1) & _mask32;
      d = (t1 + (_rotr(e, 2) ^ _rotr(e, 13) ^ _rotr(e, 22)) + ((e & f) | (g & (e | f)))) & _mask32;
      t1 = c + (_rotr(h, 6) ^ _rotr(h, 11) ^ _rotr(h, 25)) + (b ^ (h & (a ^ b))) + constants[i + 5] + words[i + 5];
      g = (g + t1) & _mask32;
      c = (t1 + (_rotr(d, 2) ^ _rotr(d, 13) ^ _rotr(d, 22)) + ((d & e) | (f & (d | e)))) & _mask32;
      t1 = b + (_rotr(g, 6) ^ _rotr(g, 11) ^ _rotr(g, 25)) + (a ^ (g & (h ^ a))) + constants[i + 6] + words[i + 6];
      f = (f + t1) & _mask32;
      b = (t1 + (_rotr(c, 2) ^ _rotr(c, 13) ^ _rotr(c, 22)) + ((c & d) | (e & (c | d)))) & _mask32;
      t1 = a + (_rotr(f, 6) ^ _rotr(f, 11) ^ _rotr(f, 25)) + (h ^ (f & (g ^ h))) + constants[i + 7] + words[i + 7];
      e = (e + t1) & _mask32;
      a = (t1 + (_rotr(b, 2) ^ _rotr(b, 13) ^ _rotr(b, 22)) + ((b & c) | (d & (b | c)))) & _mask32;
    }
    return [a, b, c, d, e, f, g, h];
  }

  // ── CS64 ──────────────────────────────────────────────────────

  /// CS64 摘要：返回 (swapLast^state, swapAcc^acc) 两个字
  ///
  /// [digestBytes] 是 SHA256 摘要的 32 字节大端流；上游按小端从中解出两个密钥字，
  /// 因此这里同样以字节为输入，不能直接把摘要字当小端整数用（差一趟字节序）。
  static (int, int) _cs64Digest(List<int> data, List<int> digestBytes) {
    var keyA = (digestBytes[0] | (digestBytes[1] << 8) | (digestBytes[2] << 16) | (digestBytes[3] << 24)) & _mask32;
    var keyB = (digestBytes[4] | (digestBytes[5] << 8) | (digestBytes[6] << 16) | (digestBytes[7] << 24)) & _mask32;
    keyA |= 1;
    keyB |= 1;
    final factors = [_mul32(keyA, _cs64Factor), _mul32(keyB, _cs64Factor)];

    final terms = <int>[];
    final offsets = <int>[];
    for (var i = 0; i < _cs64Coefficients.length; i++) {
      terms.add(_mul32(_cs64Coefficients[i][0], factors[i % 2]));
      offsets.add(_cs64Coefficients[i][1]);
    }
    // 待摘要数据前置一个 0 字节后按小端 32 位切词，不足偶数个补 0
    final words = _wordsLe4Even([0, ...data]);
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      var term = _mul32(word, i.isEven ? keyA : keyB);
      var offset = _mul32(_rol16(word), i.isEven ? 0xEF0569FB : 0xC31713DB);
      if (i == 0) {
        term = (term + _mul32(_cs64Adjustment0, factors[0])) & _mask32;
        offset = (offset + _cs64Adjustment1) & _mask32;
      }
      terms.add(term);
      offsets.add(offset);
    }

    var swapAcc = 0;
    var swapLast = 0;
    var state = 0;
    var acc = 0;
    for (var i = 0; i < terms.length; i += 2) {
      final x = terms[i];
      final y = terms[i + 1];
      var t = _rol16((offsets[i] + x) & _mask32);
      var q = _mul32(t, 0x76F50F34);
      swapAcc += (_mul32(_rol16(q), 0xC3EFEA97) + q) & _mask32;
      t = _rol16((offsets[i + 1] + y) & _mask32);
      q = _mul32(t, 0x1881CE3C);
      swapLast = (_mul32(_rol16(q), 0x35BD1EC9) + q) & _mask32;
      swapAcc = (swapAcc + swapLast) & _mask32;

      state = (_mul32(state, keyA) + x) & _mask32;
      state = _mul32(_rol16(state), 0xCF98B111);
      state = _mul32(_rol16(state), 0x87085B9F);
      state = _mul32(_rol16(state), 0x12CEB96D);
      state = _mul32(_rol16(state), 0x257E1D83);
      acc += state;
      var t2 = (_mul32(state, keyB) + y) & _mask32;
      t2 = _mul32(_rol16(t2), 0xA27416F5);
      t2 = _mul32(_rol16(t2), 0xD38396FF);
      state = _mul32(_rol16(_mul32(_rol16(t2), 0x7C932B89)), 0xBFA49F69);
      acc = (acc + state) & _mask32;
    }
    return (swapLast ^ state, swapAcc ^ acc);
  }

  /// 小端 32 位切词并按需补 0 到偶数个，左补 0 字节到 4 的倍数
  static List<int> _wordsLe4Even(List<int> bytes) {
    final padded = [...bytes];
    final remainder = padded.length % 4;
    if (remainder != 0) {
      padded.addAll(List<int>.filled(4 - remainder, 0));
    }
    final words = [
      for (var i = 0; i < padded.length; i += 4)
        (padded[i] | (padded[i + 1] << 8) | (padded[i + 2] << 16) | (padded[i + 3] << 24)) & _mask32,
    ];
    if (words.length.isOdd) words.add(0);
    return words;
  }

  // ── 32 位运算工具 ──────────────────────────────────────────────

  static const int _mask32 = 0xFFFFFFFF;

  /// 32 位循环右移
  static int _rotr(int value, int bits) => ((value >>> bits) | (value << (32 - bits))) & _mask32;

  /// 32 位循环左移 16（等价于高低半字互换）
  static int _rol16(int value) => ((value << 16) | (value >>> 16)) & _mask32;

  /// 32 位小 sigma0
  static int _sigma0(int value) => _rotr(value, 7) ^ _rotr(value, 18) ^ (value >>> 3);

  /// 32 位小 sigma1
  static int _sigma1(int value) => _rotr(value, 17) ^ _rotr(value, 19) ^ (value >>> 10);

  /// 32 位乘法取低 32 位。
  ///
  /// 直接相乘会超过 2^53（dart2js 的 int 就是 double）导致低位丢失，故把乘数拆成
  /// 两个 16 位半字分别相乘，把每一步都压在 double 可精确表示的范围内。
  static int _mul32(int a, int b) {
    final aLow = a & 0xFFFF;
    final aHigh = (a >>> 16) & 0xFFFF;
    final bLow = b & 0xFFFF;
    final bHigh = (b >>> 16) & 0xFFFF;
    final cross = ((aLow * bHigh) + (aHigh * bLow)) & 0xFFFF;
    return (aLow * bLow + (cross << 16)) & _mask32;
  }

  // ── 常量表（由上游 edge_tts/drm.py 生成，勿手改）────────────────

  static const List<int> _sha256Initial = [
    0x6A09E667,
    0xBB67AE85,
    0x3C6EF372,
    0xA54FF53A,
    0x510E527F,
    0x9B05688C,
    0x1F83D9AB,
    0x5BE0CD19,
  ];

  static const List<int> _sha256State = [
    0xFD9FBEA2,
    0x91243CE7,
    0xBE499094,
    0xCD2E1E0A,
    0x6C006F49,
    0x04BD35AB,
    0xFEB0A7E4,
    0x03EFFBD2,
  ];

  static const List<int> _sha256Schedule = [
    0xEB24BF9E,
    0x1558691F,
    0xA0C09EE2,
    0x0CFA32BA,
    0xA622EE8C,
    0xD1DD9491,
    0xC0DD25A0,
    0xF9E70AB6,
    0xF0C31573,
    0x7058CE4E,
    0x7188E606,
    0x00E5AB33,
    0xD258B060,
    0x72766564,
  ];

  static const List<int> _sha256RoundConstants = [
    0x428A2F98,
    0x71374491,
    0xB5C0FBCF,
    0xE9B5DBA5,
    0x3956C25B,
    0x59F111F1,
    0x923F82A4,
    0xAB1C5ED5,
    0xD807AA98,
    0x12835B01,
    0x243185BE,
    0x550C7DC3,
    0x72BE5D74,
    0x80DEB1FE,
    0x9BDC06A7,
    0xC19BF174,
    0xE49B69C1,
    0xEFBE4786,
    0x0FC19DC6,
    0x240CA1CC,
    0x2DE92C6F,
    0x4A7484AA,
    0x5CB0A9DC,
    0x76F988DA,
    0x983E5152,
    0xA831C66D,
    0xB00327C8,
    0xBF597FC7,
    0xC6E00BF3,
    0xD5A79147,
    0x06CA6351,
    0x14292967,
    0x27B70A85,
    0x2E1B2138,
    0x4D2C6DFC,
    0x53380D13,
    0x650A7354,
    0x766A0ABB,
    0x81C2C92E,
    0x92722C85,
    0xA2BFE8A1,
    0xA81A664B,
    0xC24B8B70,
    0xC76C51A3,
    0xD192E819,
    0xD6990624,
    0xF40E3585,
    0x106AA070,
    0x19A4C116,
    0x1E376C08,
    0x2748774C,
    0x34B0BCB5,
    0x391C0CB3,
    0x4ED8AA4A,
    0x5B9CCA4F,
    0x682E6FF3,
    0x748F82EE,
    0x78A5636F,
    0x84C87814,
    0x8CC70208,
    0x90BEFFFA,
    0xA4506CEB,
    0xBEF9A3F7,
    0xC67178F2,
  ];

  /// 中途态压缩时第 14 轮常量被替换为 [_sha256Adjustment]
  static final List<int> _sha256BlockConstants = [
    ..._sha256RoundConstants.take(14),
    _sha256Adjustment,
    ..._sha256RoundConstants.skip(15),
  ];

  static const int _sha256Adjustment = 0xC9DC06A7;
  static const int _sha256Sigma0Adjustment = 0x059C0B80;
  static const int _sha256Sigma1Adjustment = 0x000B92C0;

  static const int _cs64Factor = 0x82893933;
  static const int _cs64Adjustment0 = 0xF2F90B1A;
  static const int _cs64Adjustment1 = 0x0B1A0000;

  static const List<List<int>> _cs64Coefficients = [
    [0xE82E91B1, 0xB32700D0],
    [0x44DE24C6, 0x88DFF51D],
    [0x3BEB65BC, 0x29514038],
    [0xC89C5933, 0xB328CBDF],
    [0x8D1EC211, 0xD405B4D5],
    [0x314EF5D5, 0x26E55F3C],
    [0xE92491B1, 0x607801C6],
    [0xF0A5B9D5, 0x82B2C1FB],
    [0x06064CF3, 0xFA51A3DA],
    [0xDA79FA60, 0x207CC464],
    [0xBED20560, 0x3C3C74F3],
    [0x89F9C9F8, 0xD2D14B61],
    [0x35FA38C6, 0xBB04A2C1],
    [0xCB49E3C6, 0xC5626167],
  ];
}
