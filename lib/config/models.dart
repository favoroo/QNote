/// 厂商模板目录的兼容入口
///
/// 目录本身已迁到 `lib/config/ai_vendors.dart`（本次扩充到 50+ 厂商后，单文件
/// 职责与篇幅都更适合独立成库）。这里只做转发，让既有 `import
/// 'package:qnote_flutter/config/models.dart'` 与测试无需改动。
library;

export 'package:qnote_flutter/config/ai_vendors.dart';
