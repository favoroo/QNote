import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/tts/tts_player.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/pages/ai_page.dart';
import 'package:qnote_flutter/providers/user_profile_provider.dart';
import 'package:qnote_flutter/widgets/ai/bubble_action_bar.dart';

/// 空资料 Notifier 壳：ChatBubble 会 watch 用户资料，用子类占位避免读真实配置
class _EmptyProfileNotifier extends UserProfileNotifier {}

/// 固定播放态的假播放器：避免测试触碰 just_audio / 网络合成
class _FakeTtsPlayer extends TtsPlayer {
  final TtsPlaybackState state0;

  /// 记录气泡上的朗读点击，供断言入口接线
  ChatMessage? toggled;

  /// 记录中断次数（覆盖真实 stop，避免触碰音频播放器）
  int stopCount = 0;

  _FakeTtsPlayer([this.state0 = TtsPlaybackState.idle]);

  @override
  TtsPlaybackState build() => state0;

  @override
  Future<void> toggleMessage(ChatMessage message) async {
    toggled = message;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }
}

Widget _harness(
  Widget child, {
  TtsPlaybackState playback = TtsPlaybackState.idle,
  _FakeTtsPlayer? player,
}) {
  return ProviderScope(
    overrides: [
      ttsPlaybackProvider.overrideWith(
        () => player ?? _FakeTtsPlayer(playback),
      ),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

ChatMessage _assistantReply() => ChatMessage(
  role: 'assistant',
  content: '今天已经完成 3 项待办',
  timestamp: DateTime(2026, 9, 19),
);

/// 渲染完整 [ChatBubble]：气泡会 watch 用户资料，需一并 override
Widget _bubbleHarness(
  ChatBubble bubble, {
  _FakeTtsPlayer? player,
  TtsPlaybackState playback = TtsPlaybackState.idle,
}) {
  return ProviderScope(
    overrides: [
      userProfileNotifierProvider.overrideWith(
        (ref) => _EmptyProfileNotifier(),
      ),
      ttsPlaybackProvider.overrideWith(
        () => player ?? _FakeTtsPlayer(playback),
      ),
    ],
    child: MaterialApp(
      home: Scaffold(body: ListView(children: [bubble])),
    ),
  );
}

void main() {
  testWidgets('助手气泡操作条渲染三个纯图标按钮', (tester) async {
    await tester.pumpWidget(
      _harness(
        BubbleActionBar(message: _assistantReply(), onRegenerate: () {}),
      ),
    );

    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    // 只出图标，不出「复制/朗读/重新生成」文字标签
    expect(find.text('复制'), findsNothing);
    expect(find.text('朗读'), findsNothing);
    expect(find.text('重新生成'), findsNothing);
  });

  testWidgets('未提供重新生成回调时不渲染该入口', (tester) async {
    await tester.pumpWidget(
      _harness(BubbleActionBar(message: _assistantReply())),
    );

    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
  });

  testWidgets('点击复制写入正文并提示已复制', (tester) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        });

    await tester.pumpWidget(
      _harness(
        BubbleActionBar(message: _assistantReply(), onRegenerate: () {}),
      ),
    );
    await tester.tap(find.byIcon(Icons.copy_rounded));
    await tester.pump();

    expect(copied, '今天已经完成 3 项待办');
    expect(find.text('已复制'), findsOneWidget);

    // 放完 Toast 的驻留与淡出，避免遗留 Timer
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('点击朗读走 TTS 切换入口', (tester) async {
    final player = _FakeTtsPlayer();
    final message = _assistantReply();
    await tester.pumpWidget(
      _harness(
        BubbleActionBar(message: message, onRegenerate: () {}),
        player: player,
      ),
    );
    await tester.tap(find.byIcon(Icons.volume_up_rounded));
    await tester.pump();

    expect(player.toggled?.content, message.content);
  });

  testWidgets('播放中改为停止图标并高亮当前条', (tester) async {
    final message = _assistantReply();
    await tester.pumpWidget(
      _harness(
        BubbleActionBar(message: message, onRegenerate: () {}),
        playback: TtsPlaybackState(
          messageId: TtsPlayer.messageKeyOf(message),
          status: TtsPlaybackStatus.playing,
        ),
      ),
    );

    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    expect(find.byIcon(Icons.volume_up_rounded), findsNothing);
  });

  testWidgets('非当前消息的播放状态不影响本条图标', (tester) async {
    await tester.pumpWidget(
      _harness(
        BubbleActionBar(message: _assistantReply(), onRegenerate: () {}),
        playback: const TtsPlaybackState(
          messageId: 'msg_assistant_other',
          status: TtsPlaybackStatus.playing,
        ),
      ),
    );

    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
    expect(find.byIcon(Icons.stop_rounded), findsNothing);
  });

  testWidgets('重新生成按钮触发回调，禁用时不可点', (tester) async {
    var pressed = 0;
    await tester.pumpWidget(
      _harness(
        BubbleActionBar(
          message: _assistantReply(),
          onRegenerate: () => pressed++,
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.refresh_rounded));
    expect(pressed, 1);

    await tester.pumpWidget(
      _harness(
        BubbleActionBar(
          message: _assistantReply(),
          onRegenerate: () => pressed++,
          regenerateEnabled: false,
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.pumpAndSettle();

    expect(pressed, 1);
  });

  group('与气泡的连体几何', () {
    testWidgets('操作条与助手气泡同宽同左、间距收到 6', (tester) async {
      await tester.pumpWidget(
        _bubbleHarness(
          ChatBubble(message: _assistantReply(), onRegenerate: () {}),
        ),
      );
      await tester.pump();

      // 量装饰盒而非 Container：Container 的 margin 会计入 getRect，
      // 用 DecoratedBox 才能测出两段之间真实的视觉间距
      final bubble = find
          .ancestor(
            of: find.byType(MarkdownBody),
            matching: find.byType(DecoratedBox),
          )
          .first;
      final bar = find.byType(BubbleActionBar);
      expect(bar, findsOneWidget);

      final bubbleRect = tester.getRect(bubble);
      final barRect = tester.getRect(bar);
      expect(barRect.width, bubbleRect.width);
      expect(barRect.left, bubbleRect.left);
      expect(barRect.top - bubbleRect.bottom, closeTo(6, 0.01));
    });

    testWidgets('用户气泡与错误气泡不挂操作条', (tester) async {
      await tester.pumpWidget(
        _bubbleHarness(
          ChatBubble(
            message: ChatMessage(role: 'user', content: '你好'),
          ),
        ),
      );
      expect(find.byType(BubbleActionBar), findsNothing);

      await tester.pumpWidget(
        _bubbleHarness(
          ChatBubble(
            message: ChatMessage(
              role: 'assistant',
              content: '请求失败',
              isError: true,
            ),
          ),
        ),
      );
      expect(find.byType(BubbleActionBar), findsNothing);
    });
  });

  group('点击气泡中断朗读', () {
    testWidgets('本条正在播放时点击卡片停止朗读', (tester) async {
      final message = _assistantReply();
      final player = _FakeTtsPlayer(
        TtsPlaybackState(
          messageId: TtsPlayer.messageKeyOf(message),
          status: TtsPlaybackStatus.playing,
        ),
      );
      await tester.pumpWidget(
        _bubbleHarness(
          ChatBubble(message: message, onRegenerate: () {}),
          player: player,
        ),
      );
      await tester.pump();

      // 点卡片留白处也要能中断：命中区域是整张气泡而非正文文本
      final bubbleRect = tester.getRect(
        find
            .ancestor(
              of: find.byType(MarkdownBody),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      await tester.tapAt(Offset(bubbleRect.left + 6, bubbleRect.center.dy));
      await tester.pump();

      expect(player.stopCount, 1);
      expect(player.toggled, isNull);
    });

    testWidgets('合成中同样可点击中断', (tester) async {
      final message = _assistantReply();
      final player = _FakeTtsPlayer(
        TtsPlaybackState(
          messageId: TtsPlayer.messageKeyOf(message),
          status: TtsPlaybackStatus.synthesizing,
        ),
      );
      await tester.pumpWidget(
        _bubbleHarness(
          ChatBubble(message: message, onRegenerate: () {}),
          player: player,
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(MarkdownBody));
      await tester.pump();

      expect(player.stopCount, 1);
    });

    testWidgets('空闲或他条播放时点击不打断朗读', (tester) async {
      final message = _assistantReply();
      final idlePlayer = _FakeTtsPlayer();
      await tester.pumpWidget(
        _bubbleHarness(
          ChatBubble(message: message, onRegenerate: () {}),
          player: idlePlayer,
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(MarkdownBody));
      await tester.pump();
      expect(idlePlayer.stopCount, 0);

      // 正在读的是另一条：点本条不应把那条停掉
      final otherPlayer = _FakeTtsPlayer(
        const TtsPlaybackState(
          messageId: 'msg_assistant_other',
          status: TtsPlaybackStatus.playing,
        ),
      );
      await tester.pumpWidget(
        _bubbleHarness(
          ChatBubble(message: message, onRegenerate: () {}),
          player: otherPlayer,
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(MarkdownBody));
      await tester.pump();

      expect(otherPlayer.stopCount, 0);
    });
  });
}
