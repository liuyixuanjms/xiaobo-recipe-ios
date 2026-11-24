// 轻量设置项。走 SharedPreferences（和菜谱列表同一套存储），不引额外依赖。
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const String _chefReviewKey = 'chef_review_enabled';

  /// v1.23：外观偏好。配色存方案 key，字号存倍率（0.9 / 1.0 / 1.15 / 1.3）。
  static const String _paletteKey = 'theme_palette';
  static const String _fontScaleKey = 'font_scale';

  /// v1.24：语音包是否允许 WiFi 下自动下载（默认开，用户可关）。
  static const String _asrAutoKey = 'asr_auto_download';

  /// v1.16：默认倒计时秒数。
  ///
  /// 用户的原话：「倒计时的设置是固定的，不能来回拉动长度……我希望它有一个默认的
  /// 倒计时。如果不准，我可以调一下。设置一次之后，退出、返回，它自动保存那个时间。」
  ///
  /// 所以这里存的是**用户上一次亲手调过的时长**：步骤文字里没写时间时用它，
  /// 下次再进任何一道菜、任何一步都不用重新设。
  static const String _timerKey = 'default_timer_sec';

  /// 没设置过时的兜底：5 分钟。家常菜里「焖一会儿」「煮一下」大多在这个量级。
  static const int fallbackTimerSec = 300;

  Future<bool> isChefReviewEnabled() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_chefReviewKey) ?? true;
  }

  Future<void> setChefReviewEnabled(bool value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_chefReviewKey, value);
  }

  Future<int> getDefaultTimerSec() async {
    final sp = await SharedPreferences.getInstance();
    final v = sp.getInt(_timerKey) ?? fallbackTimerSec;
    // 存进来的值可能被改坏，夹一下范围，别让界面出现 0:00 或者 9 小时
    if (v < 10) return 10;
    if (v > 3 * 3600) return 3 * 3600;
    return v;
  }

  Future<void> setDefaultTimerSec(int sec) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_timerKey, sec.clamp(10, 3 * 3600));
  }

  /// 读取已保存的配色 key。没存过返回 null，由上层用默认抹茶绿。
  Future<String?> getPaletteKey() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_paletteKey);
  }

  Future<void> setPaletteKey(String key) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_paletteKey, key);
  }

  Future<double> getFontScale() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getDouble(_fontScaleKey) ?? 1.0;
  }

  Future<void> setFontScale(double v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble(_fontScaleKey, v);
  }

  Future<bool> isAsrAutoDownloadEnabled() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_asrAutoKey) ?? true;
  }

  Future<void> setAsrAutoDownload(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_asrAutoKey, v);
  }
}
