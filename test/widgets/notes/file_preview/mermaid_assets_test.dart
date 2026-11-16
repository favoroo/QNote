import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/widgets/notes/file_preview/mermaid_assets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('内置 mermaid 运行库随包发布、可读取且为全局挂载的经典脚本', () async {
    final js = await MermaidAssets.load();
    expect(js, isNotNull, reason: 'assets/js/mermaid.min.js 应随包发布（pubspec 已声明 assets/js/）');
    expect(js!.length, greaterThan(100000), reason: '应是完整运行库而非占位');
    // 预览把运行库内联进 <script>，必须靠全局挂载暴露 mermaid；且不能含提前闭合序列
    expect(js, contains('globalThis.mermaid'));
    expect(js.contains('</script'), isFalse, reason: '内联前不得含可提前闭合 <script> 的序列');
  });
}
