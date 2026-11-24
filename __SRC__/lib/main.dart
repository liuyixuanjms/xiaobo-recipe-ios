// 入口：初始化绑定、锁定竖屏、启动系统分享桥接，然后跑 App。
// 为什么锁竖屏：统一风格长图是竖版排版，横屏会让版式和截图宽度乱掉。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'services/app_info.dart';
import 'services/log_service.dart';
import 'services/settings_service.dart';
import 'services/share_bridge.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  // v1.27：把「闪退」也录进黑匣子。
  //
  // 用户反馈近两版会闪退，但导出的日志里只有业务步骤、没有崩溃信息 ——
  // 因为崩溃发生在 Flutter 的回调里，没人捕获就直接被系统杀了。
  // 这里三条路都接住：框架绘制/layout 异常、Dart 异步未捕获异常、原生层异常。
  // 记录本身不弹窗、不打扰，下次用户在日志页导出时就能看到崩溃栈。
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();

    FlutterError.onError = (FlutterErrorDetails d) {
      FlutterError.presentError(d);
      LogService.recordCrash(
        d.exception,
        d.stack,
        where: '${d.library ?? 'Flutter'}｜${d.context?.toString() ?? ''}',
      );
    };

    // 注：Flutter 3.0 还没有 PlatformDispatcher.onError，
    // 异步未捕获异常由外层 runZonedGuarded 的 handler 接住（见文件末尾），
    // 两者合起来就是「Dart 侧再没有漏网的异常」。

    // 上一进程如果是原生崩溃（内存不足等），把它写的现场捞进来
    await LogService.drainNativeCrash();

    // 版本号预热：设置页和所有运行日志都读 AppInfo.version，
    // 启动就取一次，保证第一份日志也不会写成「未知」。
    await AppInfo.load();

    // 外观偏好预热：在 runApp 之前把上次选的配色和字号设好，
    // 首帧就是用户上次的设置，不会先闪一下默认色。
    final prefs = SettingsService();
    ThemeController.setPalette(ThemeController.byKey(await prefs.getPaletteKey()));
    FontScale.scale.value = FontScale.clampToStep(await prefs.getFontScale());

    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    // 读取「从抖音/小红书分享进来」的冷启动内容
    await ShareBridge.instance.init();

    runApp(const RecipeApp());
  }, (Object error, StackTrace stack) {
    LogService.recordCrash(error, stack, where: 'Zone 未捕获异常');
  });
}
