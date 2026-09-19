import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/models/user_profile.dart';
import 'package:qnote_flutter/pages/ai_page.dart';
import 'package:qnote_flutter/providers/user_profile_provider.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';

/// 测试用空壳 Notifier：继承真实类型以满足 provider override 的返回类型，
/// state 由测试体在 provider mount 后赋值（构造期间赋 state 会触发 state_notifier 断言）
class _FixedProfileNotifier extends UserProfileNotifier {
  _FixedProfileNotifier() : super();
}

UserProfile _profile({String? nickname, String? name, String avatarPath = ''}) {
  return UserProfile(
    id: 'test-profile',
    nickname: nickname,
    name: name,
    avatarPath: avatarPath,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}

Widget _harness(UserProfileNotifier notifier) {
  return ProviderScope(
    overrides: [userProfileNotifierProvider.overrideWith((ref) => notifier)],
    child: MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            ChatBubble(
              message: ChatMessage(role: 'user', content: '你好'),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  // 1x1 透明 PNG：UnifiedImage 对真实存在的文件会直接走 Image.file 加载，
  // 避免触发「图片文件不存在」日志及其 5 秒防抖持久化 Timer（测试中会报 pending timer）
  final pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );
  late File avatarFile;

  setUp(() async {
    avatarFile = File(
      '${Directory.systemTemp.createTempSync('qnote_avatar_test').path}/avatar.png',
    );
    await avatarFile.writeAsBytes(pngBytes);
  });

  tearDown(() {
    avatarFile.parent.deleteSync(recursive: true);
  });

  testWidgets('未设置资料时显示 You 与人形兜底图标，不渲染头像图', (tester) async {
    final notifier = _FixedProfileNotifier();
    await tester.pumpWidget(_harness(notifier));
    await tester.pump();

    expect(find.text('You'), findsOneWidget);
    expect(find.byIcon(Icons.person_rounded), findsOneWidget);
    expect(find.byType(UnifiedImage), findsNothing);
  });

  testWidgets('设置了昵称与头像时显示昵称文本与头像图', (tester) async {
    final notifier = _FixedProfileNotifier();
    await tester.pumpWidget(_harness(notifier));
    notifier.state = _profile(nickname: '阿明', avatarPath: avatarFile.path);
    await tester.pump();

    expect(find.text('阿明'), findsOneWidget);
    expect(find.byIcon(Icons.person_rounded), findsNothing);
    expect(find.byType(UnifiedImage), findsOneWidget);
  });

  testWidgets('昵称为空时回退显示姓名', (tester) async {
    final notifier = _FixedProfileNotifier();
    await tester.pumpWidget(_harness(notifier));
    notifier.state = _profile(name: '王小明');
    await tester.pump();

    expect(find.text('王小明'), findsOneWidget);
    expect(find.text('You'), findsNothing);
  });
}
