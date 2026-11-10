// 2026-11-13 修复「AI 机器人主页朋友圈看不到」（问题9 真因）回归测试：
// 签名块 Row(crossAxisAlignment: stretch) 直接放进 ListView（无界高度）时，
// stretch 会给 3px 竖条 Container 下发 tightFor(height: ∞)（flex.dart
// _constraintsForNonFlexChild），release 包跳过断言 → 签名块无限高，
// 主页按钮/朋友圈标题/动态被推到无穷远，页面可以无限拖动全是背景色。
// 修复 = IntrinsicHeight 包裹（本测试验证修复后的结构与滚动范围）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget buildSignatureBlock(String signature) {
  return MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [
          const SizedBox(height: 300),
          // 与 user_profile_page.dart 修复后的签名块同构
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 3, color: Colors.red),
                Expanded(
                  child: Container(
                    color: Colors.blue,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Text(signature),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('修复后：签名块 stretch Row 在 ListView 中不再产生无限约束/滚动范围',
      (tester) async {
    await tester.pumpWidget(buildSignatureBlock(
        '虚拟旅行接待形象｜成都旅行灵感与地陪咨询，具体线下服务以实际沟通确认为准'));
    await tester.pumpAndSettle();

    final rowSize = tester.getSize(find.byType(Row));
    expect(rowSize.height.isFinite, isTrue, reason: 'Row 高度必须有限');
    expect(rowSize.height, greaterThan(0));

    // 竖条与文字等高（stretch 生效）
    final bar = tester.getSize(find.byWidgetPredicate(
        (w) => w is Container && w.color == Colors.red));
    expect(bar.height, closeTo(rowSize.height, 0.5));

    // 内容不满一屏，不应出现大量可滚动空白
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.maxScrollExtent, lessThan(100));
  });

  testWidgets('修复后：长签名（6 行截断）也不会撑爆列表', (tester) async {
    await tester.pumpWidget(buildSignatureBlock('长' * 600));
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.maxScrollExtent.isFinite, isTrue);
    expect(scrollable.position.maxScrollExtent, lessThan(500));
  });
}
