// 统一设计规范：配色 / 字号 / 圆角 / 输入框样式。
// 需求文档「附：UI 设计规范」里的数值就落在这一个文件里，改风格只需改这里。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// v1.23：多套配色。所有界面仍引用 AppColors.*，但 AppColors 的字段不再是
/// 写死的 const，而是从「当前方案」动态读 —— 换肤时只改一个 notifier 的值，
/// 全 App 重建，100 多处引用点一行都不用动。
class AppPalette {
  final String key;
  final String label;
  final Color primary;
  final Color primarySoft;
  final Color cream;
  final Color bg;
  final Color card;
  final Color ink;
  final Color subInk;
  final Color line;
  final Color warn;
  final Color danger;
  final Color done;
  final bool dark;

  const AppPalette({
    required this.key,
    required this.label,
    required this.primary,
    required this.primarySoft,
    required this.cream,
    required this.bg,
    required this.card,
    required this.ink,
    required this.subInk,
    required this.line,
    required this.warn,
    required this.danger,
    required this.done,
    this.dark = false,
  });
}

/// 五套方案。默认是 v1.30 新增的「雾粉玫瑰」——用户提的要求是
/// 「文字表述和界面设计变得更容易让女性喜欢」，那么默认皮肤就得先换掉。
///
/// 挑色的取舍：粉得太亮会显得廉价、也压不住白字，所以用的是偏灰的玫瑰色
/// （#AE6473，白字对比约 4.3:1），配奶白底，像手工纸和干花那种调子。
/// 抹茶绿、米白、淡蓝、夜间都留着 —— 换肤是用户自己的事，我们只改默认值。
const List<AppPalette> kPalettes = [
  AppPalette(
    key: 'rose',
    label: '雾粉玫瑰（默认）',
    primary: Color(0xFFAE6473),
    primarySoft: Color(0xFFFBEBEE),
    cream: Color(0xFFFDF6F5),
    bg: Color(0xFFFAF2F1),
    card: Color(0xFFFFFFFF),
    ink: Color(0xFF3B2C2E),
    subInk: Color(0xFF96807F),
    line: Color(0xFFF3E5E3),
    warn: Color(0xFFC89A5B),
    danger: Color(0xFFD2695A),
    done: Color(0xFFAE6473),
  ),
  AppPalette(
    key: 'matcha',
    label: '抹茶绿',
    primary: Color(0xFF5C8768),
    primarySoft: Color(0xFFE9F1E5),
    cream: Color(0xFFF4F8F2),
    bg: Color(0xFFEFF5EC),
    card: Color(0xFFFFFFFF),
    ink: Color(0xFF28302A),
    subInk: Color(0xFF7E8A7F),
    line: Color(0xFFE6EDE2),
    warn: Color(0xFFC89A5B),
    danger: Color(0xFFD96A4E),
    done: Color(0xFF5C8768),
  ),
  AppPalette(
    key: 'paper',
    label: '米白',
    primary: Color(0xFFB07D52),
    primarySoft: Color(0xFFF3E9DC),
    cream: Color(0xFFFBF6EE),
    bg: Color(0xFFF7F1E7),
    card: Color(0xFFFFFFFB),
    ink: Color(0xFF3A2E23),
    subInk: Color(0xFF8A7A68),
    line: Color(0xFFEBE1D3),
    warn: Color(0xFFC89A5B),
    danger: Color(0xFFC85A45),
    done: Color(0xFFB07D52),
  ),
  AppPalette(
    key: 'sky',
    label: '淡蓝',
    primary: Color(0xFF4E7FA8),
    primarySoft: Color(0xFFE4EEF6),
    cream: Color(0xFFF1F6FA),
    bg: Color(0xFFECF3F8),
    card: Color(0xFFFFFFFF),
    ink: Color(0xFF22323E),
    subInk: Color(0xFF718798),
    line: Color(0xFFDDE8F0),
    warn: Color(0xFFC89A5B),
    danger: Color(0xFFD96A4E),
    done: Color(0xFF4E7FA8),
  ),
  AppPalette(
    key: 'night',
    label: '夜间深色',
    primary: Color(0xFF7FB08A),
    primarySoft: Color(0xFF2A3A31),
    cream: Color(0xFF25302A),
    bg: Color(0xFF171C19),
    card: Color(0xFF232A25),
    ink: Color(0xFFE8EFE9),
    subInk: Color(0xFF9EADA2),
    line: Color(0xFF36423A),
    warn: Color(0xFFD8A863),
    danger: Color(0xFFE0806A),
    done: Color(0xFF7FB08A),
    dark: true,
  ),
];

/// 把系统状态栏 / 导航栏也刷成当前皮肤的颜色。
///
/// 用户的原话：「屏幕最上方这一分界线太丑了，能不能最上面时间信号电量这一栏的
/// 背景颜色与 app 颜色保持一致」。以前一行都没设，安卓就按主题里那个半透明
/// scrim 画 —— 于是标题栏是白的、状态栏是灰的，中间像贴了一条胶带。
///
/// 关键取舍：**状态栏跟着 AppBar 的 card 色，不是跟着页面底色**。
/// 因为标题栏是白卡片、内容区是米白/雾粉，状态栏要是刷成页面色，
/// 顶上就变成「白-粉-粉」多出一道新的界线，等于把胶带换个位置贴。
///
/// 图标亮度必须跟着底色走：浅色皮肤配深色图标，夜间皮肤配浅色图标。
/// 这一步不能省 —— 夜间模式下深色图标压在深底上，比原来的灰线还难认。
SystemUiOverlayStyle systemBarStyle(AppPalette p) {
  final iconBrightness =
      p.card.computeLuminance() > 0.5 ? Brightness.dark : Brightness.light;
  return SystemUiOverlayStyle(
    statusBarColor: p.card,
    statusBarIconBrightness: iconBrightness, // 安卓：图标自身的明暗
    statusBarBrightness: iconBrightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark, // iOS：说的是「背景」的明暗，语义正好相反
    systemNavigationBarColor: p.bg,
    systemNavigationBarIconBrightness: iconBrightness,
    systemNavigationBarDividerColor: p.bg,
  );
}

/// 把上面那份样式真正推给系统。
///
/// 拆成两个函数是为了可测：SystemChrome.latestStyle 要等 MethodChannel
/// 那次调用回写完才更新，测试里读它永远慢一拍（会读到上一个皮肤的颜色）。
/// 纯函数版本让「该是什么颜色」这件事能直接断言。
void applySystemBars(AppPalette p) {
  SystemChrome.setSystemUIOverlayStyle(systemBarStyle(p));
}

/// 当前配色方案。默认抹茶绿；App 启动时从本地读用户上次的选择再 set。
/// 用 ValueNotifier 而不是 InheritedWidget：换肤是全局低频操作，
/// 顶层 ValueListenableBuilder 监听即可，无需改动每个页面。
class ThemeController {
  static final ValueNotifier<AppPalette> current =
      ValueNotifier<AppPalette>(kPalettes.first);

  static AppPalette get palette => current.value;

  static AppPalette byKey(String? key) => kPalettes.firstWhere(
        (p) => p.key == key,
        orElse: () => kPalettes.first,
      );

  static void setPalette(AppPalette p) {
    // ValueNotifier 在值相等时本来就不通知，不用再判一次；
    // 但系统栏必须每次都刷 —— 冷启动时 current 已经是默认皮肤，
    // 判断 key 会把它跳过，状态栏就还是系统那个灰底。
    current.value = p;
    applySystemBars(p);
  }
}

/// 全局字体缩放档位。Flutter 的 Text 默认跟随 MediaQuery.textScaler，
/// 所以在 MaterialApp 顶层注入一个 textScaler 即可让全项目（含写死字号的
/// 地方）一起放大/缩小，不必改 109 处 fontSize。
class FontScale {
  static final ValueNotifier<double> scale = ValueNotifier<double>(1.0);

  static const List<double> options = [0.9, 1.0, 1.15, 1.3];
  static const List<String> labels = ['偏小', '标准', '偏大', '特大'];

  static double get value => scale.value;

  static double clampToStep(double v) {
    // 选最接近的档位，防止存进来的脏值落在档位之间
    double best = options.first;
    double bestD = (v - best).abs();
    for (final o in options) {
      final d = (v - o).abs();
      if (d < bestD) {
        best = o;
        bestD = d;
      }
    }
    return best;
  }

  static String labelOf(double v) {
    final i = options.indexOf(clampToStep(v));
    return labels[i < 0 ? 1 : i];
  }
}

/// 全项目所有颜色都走这里（getter 读当前方案），改风格/换肤只动一处。
class AppColors {
  static AppPalette get _p => ThemeController.palette;
  static Color get primary => _p.primary;
  static Color get primarySoft => _p.primarySoft;
  static Color get cream => _p.cream;
  static Color get bg => _p.bg;
  static Color get card => _p.card;
  static Color get ink => _p.ink;
  static Color get subInk => _p.subInk;
  static Color get line => _p.line;
  static Color get warn => _p.warn;
  static Color get danger => _p.danger;
  static Color get done => _p.done;
}

class AppText {
  // 字号用动态 getter 读基础尺寸；真正的缩放由 MaterialApp 的 textScaler 完成。
  // 这里仍返回固定 TextStyle，是因为 textScaler 会在 Text 绘制时再乘一次倍率。
  static TextStyle get title => TextStyle(
      fontSize: 28, fontWeight: FontWeight.w800, color: AppColors.ink, height: 1.25);
  static TextStyle get section => TextStyle(
      fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.ink);
  static TextStyle get body =>
      TextStyle(fontSize: 16, color: AppColors.ink, height: 1.5);
  static TextStyle get bodySub =>
      TextStyle(fontSize: 15, color: AppColors.subInk, height: 1.5);
  static TextStyle get tip => TextStyle(
      fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.primary, height: 1.45);
  static TextStyle get caption =>
      TextStyle(fontSize: 11, color: AppColors.subInk, height: 1.4);
}

class AppTheme {
  static ThemeData forPalette(AppPalette p) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: p.dark ? Brightness.dark : Brightness.light,
      colorScheme: ColorScheme(
        brightness: p.dark ? Brightness.dark : Brightness.light,
        primary: p.primary,
        onPrimary: p.dark ? Colors.black : Colors.white,
        secondary: p.primary,
        onSecondary: p.dark ? Colors.black : Colors.white,
        surface: p.card,
        onSurface: p.ink,
        background: p.bg,
        onBackground: p.ink,
        error: p.danger,
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: p.bg,
      canvasColor: p.bg,
      cardColor: p.card,
    );

    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: p.line),
    );

    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: p.card,
        foregroundColor: p.ink,
        iconTheme: IconThemeData(color: p.ink),
        elevation: 0,
        centerTitle: true,
        // 和 applySystemBars 一致。AppBar 在部分页面会自己重设系统栏样式，
        // 这里再钉一次，避免「有的页面白、有的页面灰」。
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: p.card,
          statusBarIconBrightness:
              p.card.computeLuminance() > 0.5 ? Brightness.dark : Brightness.light,
          systemNavigationBarColor: p.bg,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: p.primary,
        foregroundColor: p.dark ? Colors.black : Colors.white,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.card,
        contentPadding:  EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: BorderSide(color: p.primary, width: 1.5),
        ),
        labelStyle: AppText.bodySub,
      ),
      textTheme: base.textTheme.apply(bodyColor: p.ink, displayColor: p.ink),
      dialogBackgroundColor: p.card,
      bottomSheetTheme: BottomSheetThemeData(backgroundColor: p.card),
      dividerColor: p.line,
      visualDensity: VisualDensity.adaptivePlatformDensity,
    );
  }

  /// 兼容旧调用点
  static ThemeData get light => forPalette(ThemeController.palette);
}
