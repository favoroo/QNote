part of 'ai_provider_edit_page.dart';
// 本文件从 ai_provider_edit_page.dart 机械拆出，仅承载页面 State 之外的辅助类。
// 厂商选择弹层已抽到 lib/widgets/ai/vendor_picker_sheet.dart，与「添加模型服务」
// 入口共用同一套分组 + 搜索布局。

/// 单个模型的测速结果。
///
/// 失败与耗时分开建模，避免用字符串「失败」当哨兵值再做字符串判断。
class _ModelLatency {
  const _ModelLatency.success(this.duration) : failed = false;
  const _ModelLatency.failure() : duration = null, failed = true;

  final Duration? duration;
  final bool failed;
}
