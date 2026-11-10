import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../theme/app_theme.dart'; // 主题色常量
import '../widgets/app_back_button.dart'; // 全 App 统一返回键
import '../widgets/v2_kit.dart'; // v2Scale（按屏宽等比缩放）
import '../widgets/v2_settings.dart'; // context.setPageBg / setTitle（V2 主题扩展）
import 'create_channel_sheet.dart' show CreateChannelSheet;

/// 「新建频道」独立页面（2026-10-08）。
///
/// 由原 bottom sheet 改为整页：内部表单 UI（频道名 / 描述 / 频道号 / 公开私密）
/// **完全沿用** `CreateChannelSheet`（像素级复刻设计稿，内部坐标/圆角/间距不动），
/// 只换外层容器：去掉 sheet 的顶部圆角 + 屏高 85% 限制，改为 Scaffold 全屏。
///
/// 2026-10-10 需求2：sheet 内部的「取消 / 新建频道 / 创建」头栏在页面模式下
/// **不再渲染**（此前与 AppBar 标题重复出现两个标题）；「创建」按钮挪到
/// AppBar 右侧（名称为空置灰禁用），「取消」由左上角返回键等效承担。
///
/// 与 sheet 的差异仅在外壳：
///   - sheet：home_shell Stack 里挂 scrim + 面板（白导航胶囊压在 sheet 之上）；
///   - page：标准路由 `Navigator.push`（系统返回手势/返回键天然可用）。
class CreateChannelPage extends StatelessWidget {
  const CreateChannelPage({super.key});

  /// 表单实例：AppBar 的「创建」按钮需要访问 canCreate 状态与创建动作
  /// （2026-10-10 需求2，见 CreateChannelSheet.canCreate / createInPage）
  final _sheet = const CreateChannelSheet(inPage: true);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    return Scaffold(
      backgroundColor: context.setPageBg,
      // 顶部与状态栏同色（V2 口径：状态栏底色跟随页面顶色）
      appBar: AppBar(
        leading: const AppBackButton(),
        backgroundColor: context.setPageBg,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: Text(t('newChannelTitle'),
            style: TextStyle(
                fontSize: 17 * s,
                fontWeight: FontWeight.w600,
                color: context.setTitle)),
        // 2026-10-10 需求2：创建按钮（名称为空时置灰禁用，与原头栏右侧一致）
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: _sheet.canCreate,
            builder: (context, can, _) => TextButton(
              onPressed: can ? () => _sheet.createInPage(context) : null,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                minimumSize: const Size(48, 44),
              ),
              child: Text(t('chcCreate'),
                  style: TextStyle(
                      fontSize: 16 * s,
                      fontWeight: FontWeight.w600,
                      color: can
                          ? AppTheme.primary
                          : context.cs.onSurfaceVariant)),
            ),
          ),
        ],
      ),
      // 复用 sheet 内部全部表单 UI；外层再包一层 SingleChildScrollView 由
      // sheet 自己提供（它内部已是 SingleChildScrollView），此处不重复包裹。
      body: _sheet,
    );
  }
}
