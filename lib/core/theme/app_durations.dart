/// 全局动效时长令牌，与 [AppCurves] / [AppMotion] 配合使用。
///
/// 按「交互语义」而不是具体控件选值，避免同一个按压反馈在页面间出现
/// 90/140/160/200ms 多套手感：
/// - [press]: 按压/松开等即时反馈
/// - [fast]: 图标、文字、颜色等小范围状态切换
/// - [normal]: 展开/折叠、内容淡入等常规过渡
/// - [page]: 路由与分段页切换
/// - [medium]: 卡片入场、完成/删除等需要被看清的位移
/// - [slow]: 大范围布局变化或刻意放慢的强调动效
abstract class AppDurations {
  /// 按压反馈（缩放、描边、按下底色）
  static const Duration press = Duration(milliseconds: 100);

  /// 小范围状态切换
  static const Duration fast = Duration(milliseconds: 150);

  /// 常规展开/淡入
  static const Duration normal = Duration(milliseconds: 200);

  /// 路由与分段页切换
  static const Duration page = Duration(milliseconds: 240);

  /// 卡片入场、完成/删除等可见位移
  static const Duration medium = Duration(milliseconds: 300);

  /// 大范围布局变化或强调动效
  static const Duration slow = Duration(milliseconds: 450);

  /// 弹窗/底部面板的进出场。
  ///
  /// Flutter 默认是 250ms 线性（`_kBottomSheetEnterDuration`），与 App 其他转场
  /// （强调曲线、起手快收尾缓）不同调，面板滑上来会显得「匀速推到顶」。
  /// 统一用 [page] 档 + [AppCurves.emphasized]，与路由转场同节奏。
  static const Duration sheet = page;
}
