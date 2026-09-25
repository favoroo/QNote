import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/tools/general/describe_image_tool.dart';

class _RealHttpOverrides extends HttpOverrides {}

/// `describe_image` 的真实链路端到端测试（会打商汤网关，与 `live_glm52_test.dart` 同性质）
///
/// 单测的 fake 只能证明分支正确，证明不了「压缩后的 JPEG data URI 真的能被识图链路读懂」——
/// 而这正是整条兜底成立的前提。测试环境默认拦截 HTTP（一律返回 400），
/// 因此这里必须像 live_glm52 那样显式覆盖 `HttpOverrides.global`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => HttpOverrides.global = _RealHttpOverrides());

  test('内置识图链路能把左红右蓝的图读成红/蓝', () async {
    final dir = await Directory.systemTemp.createTemp('qnote_describe_image');
    final file = File('${dir.path}/probe.png');
    await file.writeAsBytes(_png64());

    final result = await DescribeImageTool().execute({
      'path': file.path,
      'question': '这张图片的左半边和右半边分别是什么颜色？只用中文回答：左=…，右=…',
    });

    expect(result.isError, isFalse, reason: result.modelOutput);
    expect(result.modelOutput, contains('识图结果'));
    expect(result.modelOutput, contains('红'), reason: '看不见图时拿不到这个字');
    expect(result.modelOutput, contains('蓝'));
    expect(result.uiDetails?['model'], 'sensenova-6.8-flash-lite');
    // 只回文字，绝不把图片本体再注入一轮上下文
    expect(result.images, isNull);
  }, timeout: const Timeout(Duration(minutes: 4)));
}

/// 造一张 64×64 左红右蓝 PNG（zlib + CRC32 手搓，不引第三方图像库）
Uint8List _png64() {
  final crcTable = <int>[];
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    crcTable.add(c.toUnsigned(32));
  }

  int crc(List<int> data) {
    var c = 0xFFFFFFFF;
    for (final b in data) {
      c = crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    return (c ^ 0xFFFFFFFF).toUnsigned(32);
  }

  List<int> be32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();

  List<int> chunk(String type, List<int> data) {
    final t = utf8.encode(type);
    return [...be32(data.length), ...t, ...data, ...be32(crc([...t, ...data]))];
  }

  const w = 64, h = 64;
  final raw = Uint8List(h * (1 + w * 3));
  for (var y = 0; y < h; y++) {
    final rowStart = y * (1 + w * 3);
    raw[rowStart] = 0;
    for (var x = 0; x < w; x++) {
      final p = rowStart + 1 + x * 3;
      if (x < w ~/ 2) {
        raw[p] = 220;
        raw[p + 1] = 30;
        raw[p + 2] = 30;
      } else {
        raw[p] = 30;
        raw[p + 1] = 60;
        raw[p + 2] = 220;
      }
    }
  }

  final ihdr = (ByteData(13)..setUint32(0, w)).buffer.asUint8List();
  ihdr.buffer.asByteData().setUint32(4, h);
  ihdr[8] = 8;
  ihdr[9] = 2;

  return Uint8List.fromList([
    ...[137, 80, 78, 71, 13, 10, 26, 10],
    ...chunk('IHDR', ihdr),
    ...chunk('IDAT', zlib.encode(raw)),
    ...chunk('IEND', const <int>[]),
  ]);
}
