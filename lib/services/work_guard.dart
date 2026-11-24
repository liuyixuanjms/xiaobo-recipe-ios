// 整理期间的后台保活（v1.45）。
//
// 真机日志里 7 条运行记录有 2 条只写到「开始读链接」就断了，看门狗也没触发 ——
// Dart 的 Timer 跟进程一起被系统杀掉，连失败原因都留不下。
// 现在整理一开始就在通知栏挂常驻服务，Android 会把它当「用户正在用的应用」，
// 内存紧张时优先保留；结束或失败立刻收掉。
//
// 设计约束：
//   · 这里所有调用都必须 fire-and-forget —— 保活是辅助能力，
//     不管它成功失败，都不能让整理流程卡住或报错。
//   · 通道和 MainActivity 用的是同一个（com.xiaobo.recipe/share），
//     原生侧已用 try/catch 包住，没有通知权限也只是没图标，不影响功能。
import 'package:flutter/services.dart';

class WorkGuard {
  const WorkGuard._();

  static const MethodChannel _channel =
      MethodChannel('com.xiaobo.recipe/share');

  /// 开始整理时调用。不 await，不抛错。
  static void start() {
    try {
      // invokeMethod 的异常是异步抛的：只靠 try/catch 接不住，
      // 没有插件的测试环境里会变成 unhandled exception。
      _channel
          .invokeMethod<bool>('startWorkService')
          .catchError((_) => false);
    } catch (_) {}
  }

  /// 整理结束（成功或失败）时调用。不 await，不抛错。
  static void stop() {
    try {
      _channel.invokeMethod<bool>('stopWorkService').catchError((_) => false);
    } catch (_) {}
  }
}
