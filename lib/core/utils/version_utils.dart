/// 版本号解析与比较工具。
library;

/// 将任意形态的版本字符串解析为整数分段。
///
/// 兼容 `v1.2.0`、`1.2.0+3`、`1.2.0-beta` 等常见写法；
/// 无法识别为非负整数的分段按 0 处理，保证比较过程不会抛异常。
List<int> parseVersion(String version) {
  // 先去掉 tag 前缀，再剥离 build 号与预发布后缀，只留纯版本主干
  final withoutPrefix = version.trim().replaceFirst(RegExp(r'^[vV]'), '');
  final mainPart = withoutPrefix.split('+').first.split('-').first.trim();
  if (mainPart.isEmpty) return const [0];
  return mainPart.split('.').map((part) => int.tryParse(part.trim()) ?? 0).toList();
}

/// 判断 [candidate] 是否严格比 [current] 新。
///
/// 逐段比较语义化版本，位数不足的一侧补 0（例如 `1.2` 与 `1.2.0` 视为相等）。
bool isVersionNewer({required String candidate, required String current}) {
  final candidateParts = parseVersion(candidate);
  final currentParts = parseVersion(current);
  final length =
      candidateParts.length > currentParts.length ? candidateParts.length : currentParts.length;

  for (var i = 0; i < length; i++) {
    final remote = i < candidateParts.length ? candidateParts[i] : 0;
    final local = i < currentParts.length ? currentParts[i] : 0;
    if (remote > local) return true;
    if (remote < local) return false;
  }
  return false;
}

/// 规范化版本号文本：去掉 `v` 前缀与 build 号，得到 `x.y.z` 形式。
String normalizeVersion(String version) => parseVersion(version).join('.');
