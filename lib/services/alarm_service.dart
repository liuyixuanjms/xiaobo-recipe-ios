// v1.13 · 倒计时到点「真的响」
//
// 以前只有 HapticFeedback.vibrate()：一下极短的震动，桌面都听不见，
// 人在灶台前更不可能注意到。做饭错过一次计时就是糊一锅菜，这个不能将就。
//
// 现在走原生：闹钟铃声（STREAM_ALARM，静音模式也会响）+ 循环震动，
// 最多 30 秒自己停，用户点「知道了」也能立刻停。
import 'package:flutter/services.dart';

class AlarmService {
  static const MethodChannel _ch = MethodChannel('com.xiaobo.recipe/share');

  /// 响铃。[seconds] 是自动停止的时间，默认 30 秒。
  ///
  /// 失败不抛异常：铃声播不出来也不该让做菜页崩掉，
  /// 界面上还有横幅和震动兜着。
  static Future<void> ring({int seconds = 30}) async {
    try {
      await _ch.invokeMethod<void>('ringAlarm', {'seconds': seconds});
    } on PlatformException {
      // 老包/模拟器没有这个方法时静默降级，界面照常
      return;
    } on MissingPluginException {
      // 同上
      return;
    }
  }

  static Future<void> stop() async {
    try {
      await _ch.invokeMethod<void>('stopAlarm');
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  /// 做菜页常亮。做饭时手上都是油，没人会去点屏幕；
  /// 顺带解决「锁屏后 Dart 的 Timer 被系统冻结、计时不准」。
  static Future<void> keepScreenOn(bool on) async {
    try {
      await _ch.invokeMethod<void>('keepScreenOn', {'on': on});
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }
}
