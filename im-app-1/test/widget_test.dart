// 企业 IM 骨架冒烟测试：验证应用可构建、Pill Tab 渲染
import 'package:flutter_test/flutter_test.dart';

import 'package:im_app/main.dart';

void main() {
  testWidgets('App boots and shows home shell', (WidgetTester tester) async {
    await tester.pumpWidget(const ImApp());
    await tester.pump();

    // 骨架阶段显示占位页
    expect(find.textContaining('页面建设中'), findsOneWidget);
  });
}
