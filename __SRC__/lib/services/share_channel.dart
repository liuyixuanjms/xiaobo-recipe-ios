// 系统分享 / 剪贴板的小封装（v1.30）。
//
// 安卓侧（MainActivity.kt）早就实现了 shareText / shareFile 两个方法，
// 之前只给「导出运行日志」用。v1.30 要给菜谱加「发到微信」，
// 与其每个页面各写一遍 MethodChannel + try/catch，不如收在这里。
//
// 不引 share_plus 这类第三方包：原生 30 行就够，还省了一个依赖要维护。
import 'dart:io';

import '../config/build_flavor.dart';

import 'package:flutter/services.dart';

class ShareChannel {
  ShareChannel._();

  static const MethodChannel _ch =
      MethodChannel('com.xiaobo.recipe/share');

  /// 发一段纯文字（微信、备忘录、短信都接得住）
  static Future<void> shareText(String text,
      {String subject = '小波菜谱'}) async {
    await _ch.invokeMethod('shareText', <String, dynamic>{
      'text': text,
      'subject': subject,
    });
  }

  /// 发一个文件（长图 PNG / 备份 zip）。mime 由原生按扩展名判断。
  static Future<void> shareFile(String path,
      {String subject = '小波菜谱'}) async {
    await _ch.invokeMethod('shareFile', <String, dynamic>{
      'path': path,
      'subject': subject,
    });
  }

  static bool fileReady(String path) {
    if (path.trim().isEmpty) return false;
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 把菜谱排成一段适合在微信里读的文字：先菜名，再用料，再步骤。
  /// 刻意不带 Markdown 标记 —— 微信不渲染，带 # 和 ** 只会更乱。
  static String recipeAsText({
    required String title,
    required List<String> ingredients,
    required List<String> steps,
    String sourceUrl = '',
  }) {
    final b = StringBuffer();
    b.writeln('【$title】');
    if (ingredients.isNotEmpty) {
      b.writeln('');
      b.writeln('用料');
      for (final i in ingredients) {
        b.writeln('· $i');
      }
    }
    if (steps.isNotEmpty) {
      b.writeln('');
      b.writeln('做法');
      for (var i = 0; i < steps.length; i++) {
        b.writeln('${i + 1}. ${steps[i]}');
      }
    }
    if (sourceUrl.trim().isNotEmpty) {
      b.writeln('');
      b.writeln('原视频：${sourceUrl.trim()}');
    }
    b.writeln('');
    b.writeln('—— 来自「$kAppName」');
    return b.toString().trimRight();
  }
}

class ClipboardChannel {
  ClipboardChannel._();

  static Future<bool> copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    } catch (_) {
      return false;
    }
  }
}
