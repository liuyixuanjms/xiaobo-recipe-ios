// 隐私政策同意状态（v1.37 新增）。
//
// 小米应用商店的要求是「首次启动或注册登录时，以弹窗等形式明确提示用户
// 阅读隐私政策，并需用户主动同意」。三个要素缺一不可：
//   ① 弹窗（不能只是页面底部一行小字）
//   ② 明确的「同意」按钮（不能是「我知道了」这种模糊表述）
//   ③ 必须能读到全文（所以弹窗里有查看全文的入口）
//
// 存的是「同意过的政策版本号」而不是布尔值。这是刻意设计的：
// 政策内容一改，版本号跟着改，用户会被重新问一次。
// 如果只存 bool，就等于第一次同意之后，以后怎么改都不用再问了 ——
// 那在法律上是无效授权。
import 'package:shared_preferences/shared_preferences.dart';

class PrivacyConsent {
  static const String _key = 'privacy_agreed_version';

  /// 返回用户同意过的版本号；从没同意过返回 null。
  static Future<String?> agreedVersion() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getString(_key);
    } catch (_) {
      // 读不出来就当没同意过 —— 宁可多问一次，不能少问
      return null;
    }
  }

  /// 是否已经同意过当前这一版政策。
  static Future<bool> isAgreed(String currentVersion) async =>
      (await agreedVersion()) == currentVersion;

  static Future<void> agree(String version) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, version);
  }
}
