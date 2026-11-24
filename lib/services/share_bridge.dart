// 安卓「系统分享」接入的 Dart 侧。
// 用户在抖音/小红书点「分享 → 选本 App」，平台会把「文案 + 短链」通过 Intent 递过来，
// Kotlin 侧（android/.../MainActivity.kt）读出来，再经 MethodChannel 送到这里。
// 这是合法稳定的路径：不是爬平台，是平台自己把公开文案递给用户选的应用。
import 'dart:async';

import 'package:flutter/services.dart';

class ShareBridge {
  ShareBridge._();
  static final ShareBridge instance = ShareBridge._();

  // 必须与 MainActivity.kt 里的 channelName 完全一致
  static const String _channelName = 'com.xiaobo.recipe/share';

  final MethodChannel _channel = const MethodChannel(_channelName);
  final StreamController<String> _controller = StreamController<String>.broadcast();

  /// App 已经开着时又收到分享，会推到这个流（首页订阅）
  Stream<String> get onSharedText => _controller.stream;

  String? _pending;

  Future<void> init() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSharedText' && call.arguments is String) {
        final text = call.arguments as String;
        _pending = text;
        _controller.add(text);
      }
    });

    // 冷启动：App 本来没开，由分享动作拉起
    try {
      final initial = await _channel.invokeMethod<String>('getInitialShare');
      if (initial != null && initial.trim().isNotEmpty) _pending = initial;
    } on PlatformException {
      // 通道异常时忽略，手动粘贴照样能用
    }
  }

  /// 取走一次冷启动带入的分享内容（取完清空，避免重复弹新建页）
  String? consumePending() {
    final v = _pending;
    _pending = null;
    return v;
  }
}

/// 分享文案通常长这样：「xxx https://v.douyin.com/abc 复制此链接，打开Dou音搜索...」
/// 这里拆出第一个网址当出处，剩下的当正文；平台引导语可在校对页自行删改。
/// 拆分结果。特意不用 Dart 3 的 record，改用普通类，保证 Dart 2.17 也能编译。
class SharedContent {
  final String url; // 出处链接
  final String text; // 去掉链接后的正文

  const SharedContent({required this.url, required this.text});
}

class ShareParser {
  // 【V1.4】抖音分享文案里的链接经常不带 https://（只有 v.douyin.com/xxx），
  // 所以协议头可选、域名白名单明确，避免把正文里的普通英文也当成链接。
  static final RegExp _url = RegExp(
    r'(?:https?://)?(?:v\.douyin\.com|www\.douyin\.com|www\.iesdouyin\.com|douyin\.com|xhslink\.com|www\.xiaohongshu\.com|xiaohongshu\.com)/[^\s，,。;；\]\)\}）]+',
    caseSensitive: false,
  );
  static final RegExp _anyUrl = RegExp(
    r'https?://[^\s，,。;；\]\)\}）]+',
    caseSensitive: false,
  );

  static SharedContent parse(String raw) {
    var match = _url.firstMatch(raw);
    match ??= _anyUrl.firstMatch(raw);
    if (match == null) return SharedContent(url: '', text: raw.trim());
    var url = raw.substring(match.start, match.end).trim();
    if (!url.startsWith('http')) url = 'https://$url';
    final text = raw.replaceRange(match.start, match.end, ' ').trim();
    return SharedContent(url: url, text: text);
  }
}
