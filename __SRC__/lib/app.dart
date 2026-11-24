// App 根组件：主题、字体缩放、语言与首页挂载，路由用 Navigator.push 直接跳，V1 不引路由框架。
// v1.23：外层套 ValueListenableBuilder 监听「配色方案」，内层再包一个 MediaQuery
// 注入 textScaler 实现全局字号倍率 —— 两处都在根节点，切换即刻全 App 生效。
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'config/build_flavor.dart';
import 'screens/home_screen.dart';
import 'theme/app_theme.dart';
import 'widgets/privacy_gate.dart';

class RecipeApp extends StatelessWidget {
  const RecipeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppPalette>(
      valueListenable: ThemeController.current,
      builder: (context, palette, _) {
        return ValueListenableBuilder<double>(
          valueListenable: FontScale.scale,
          builder: (context, fontScale, _) {
            return MaterialApp(
              title: kAppName,
              debugShowCheckedModeBanner: false,
              theme: AppTheme.forPalette(palette),

              // 全局字号倍率：让项目里所有 Text（含写死 fontSize 的地方）
              // 一起放大/缩小。Flutter 3.0 用 textScaleFactor（不是新版的 textScaler）。
              builder: (context, child) {
                final mq = MediaQuery.of(context);
                return MediaQuery(
                  data: mq.copyWith(textScaleFactor: fontScale),
                  child: child ?? const SizedBox.shrink(),
                );
              },

              // 【v1.12】界面里的中文是我们自己写的，但「长按输入框弹出来的菜单」、
              // 日期选择器、下拉刷新提示这些是系统控件，文案来自 Flutter 自带的翻译包。
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: const [
                Locale('zh', 'CN'),
                Locale('en', 'US'), // 兜底，实际不会用到
              ],
              locale: const Locale('zh', 'CN'),
              localeResolutionCallback: (locale, supported) =>
                  const Locale('zh', 'CN'),

              // 【v1.37】外面包一层隐私政策闸门：首次启动（或政策版本变化后）
              // 会先弹窗征求同意，同意之后才把首页放出来。
              // 小米审核强制要求这一条，且必须是用户主动点「同意」。
              home: const PrivacyGate(child: HomeScreen()),
            );
          },
        );
      },
    );
  }
}
