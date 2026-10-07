import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/health/screen_usage_service.dart';
import 'package:qnote_flutter/pages/settings/screen_usage_page.dart';
import 'package:qnote_flutter/providers/selected_date_provider.dart';

class _UnsupportedUsageService extends ScreenUsageService {
  @override
  bool get isSupported => false;
}

void main() {
  testWidgets('ScreenUsagePage 传入 initialDate 时同步更新 selectedDateProvider', (tester) async {
    final container = ProviderContainer(
      overrides: [
        screenUsageServiceProvider.overrideWithValue(_UnsupportedUsageService()),
      ],
    );
    addTearDown(container.dispose);

    final targetDate = DateTime(2026, 10, 5, 23, 0);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: ScreenUsagePage(initialDate: targetDate),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('屏幕使用时间'), findsOneWidget);
    expect(container.read(selectedDateProvider), DateTime(2026, 10, 5));
  });
}
