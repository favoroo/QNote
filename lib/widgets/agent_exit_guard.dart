import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';

/// 与 `MainActivity` 的 widgets 通道同名，用于「退出到桌面但保留引擎」。
const MethodChannel _channel = MethodChannel('com.appone.qnote_flutter/widgets');

/// 根标签页（shell 路由）的返回键守卫。
///
/// 为什么必须放在 shell 路由内部：`MaterialApp.builder` 的子树位于 Router 之上，
/// `ModalRoute.of` 取不到路由，`PopScope` 在那里注册不到任何路由（等于死代码）。
/// 而根路由若完全没有 `PopScope`，框架会通过 `NavigationNotification` 告诉系统
/// 「我不处理返回」，Android 13+ 预测性返回下系统会**直接结束 Activity**，
/// 连 `didPopRoute` 都不会回调——所以只能靠 `PopScope(canPop: false)` 声明拦截，
/// 让框架把返回交回 Dart 侧（顺带保住预测性返回的手势动画）。
///
/// 只在真正需要拦的时候 `canPop: false`：其余情况保持 `true`，抽屉（走路由的
/// local history）、子页面、弹窗的返回全部按框架默认逻辑处理，与改动前一致。
class AgentExitGuard extends ConsumerWidget {
  const AgentExitGuard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 悬浮面板展开时，返回先收成气泡（会话保留）
    final panelOpen = ref.watch(floatingQProvider.select((s) => s.panelMode == FloatingQPanelMode.panel));
    // 小Q 任务进行中：悬浮面板与 /ai 全页面是两条独立管线，都要算
    final panelRunning = ref.watch(floatingQProvider.select((s) => s.runActive));
    final fullPageRunning = ref.watch(agentRunningSessionsProvider.select((s) => s.isNotEmpty));

    return PopScope(
      canPop: !(panelOpen || panelRunning || fullPageRunning),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 抽屉展开时不抢返回：抽屉子树里也有 PopScope（内嵌 Navigator 的逐级返回），
        // 它会紧随本回调执行并把抽屉/内层页面关掉。这里若继续往下走，
        // 就会在收抽屉的同时又弹出退出确认，两层叠在一起。
        if (rootScaffoldKey.currentState?.isDrawerOpen ?? false) return;
        if (panelOpen) {
          FocusManager.instance.primaryFocus?.unfocus();
          ref.read(floatingQProvider.notifier).minimizePanel();
          return;
        }
        if (panelRunning || fullPageRunning) {
          _confirmExitWhileAgentRunning(context);
        }
      },
      child: child,
    );
  }

  /// 小Q 运行中退出 App 的二次确认。
  ///
  /// 有前台服务保活，退出只是把任务挪到后台继续跑、不会中断，因此这里主要是
  /// 「告知 + 给一个明确出口」；真要中断需回对话点「停止」。
  Future<void> _confirmExitWhileAgentRunning(BuildContext context) async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('小Q 正在工作中'),
        content: const Text('退出应用后小Q 会在后台继续执行，完成后会通知你。\n若要立即中断，请先在对话里点「停止」。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('继续等待')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('退出')),
        ],
      ),
    );
    if ((leave ?? false) && context.mounted) {
      await _leaveAppKeepingAgentAlive();
    }
  }

  /// 退出到桌面但**不销毁** Flutter 引擎。
  ///
  /// 不能用 `SystemNavigator.pop()`：它会 finish Activity，FlutterActivity 随之销毁引擎，
  /// 正在跑的小Q 任务会当场断掉，与弹窗里「后台继续执行」的说法矛盾。
  /// 改走原生 `moveTaskToBack`：界面退回桌面，进程、引擎与前台服务都保留，
  /// 任务照常跑完；用户点桌面图标回来还是原来的会话。
  Future<void> _leaveAppKeepingAgentAlive() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _channel.invokeMethod<bool>('moveTaskToBack');
        return;
      } catch (e) {
        // 原生通道异常时退回系统退出，至少不要卡在弹窗里出不去
        LoggerService.instance.warning('小Q 运行中退出到后台失败: $e', category: LogCategory.system);
      }
    }
    await SystemNavigator.pop();
  }
}
