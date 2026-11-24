// App 版本号的唯一来源（v1.20）。
//
// 以前设置页写死 1.17.0，三处运行日志的环境快照又分别写 1.8.0 / 1.17.0 / 1.9.0，
// 发版时只改了 pubspec.yaml 和 build.gradle，这些字符串全没跟着动 ——
// 用户明明装了新版，设置页和导出的日志却还显示旧号，排障时很容易被误导。
//
// 现在统一从原生读 APK 自己的 versionName（就是 build.gradle 里那个值），
// 以后发版不用再改任何 Dart 文件。
import 'package:flutter/services.dart';

class AppInfo {
  AppInfo._();

  static const MethodChannel _channel =
      MethodChannel('com.xiaobo.recipe/share');

  static String _version = '未知';

  /// 同步值。main() 启动时会先 load() 预热，正常打开页面时已是真实版本号。
  static String get version => _version;

  /// 从系统读一次并缓存；读不到就保留「未知」，不让设置页或日志崩。
  static Future<String> load() async {
    try {
      final v = await _channel.invokeMethod<String>('getAppVersion');
      if (v != null && v.trim().isNotEmpty && v.trim() != '未知') {
        _version = v.trim();
      }
    } catch (_) {}
    return _version;
  }
}
