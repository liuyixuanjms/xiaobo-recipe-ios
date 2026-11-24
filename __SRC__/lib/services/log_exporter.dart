// V0.14 · 日志导出：把日志文本送出去的三条路。
//
// 1) 复制：写进系统剪贴板，用户去微信长按粘贴 —— 零依赖、最稳；
// 2) 发文字：原生 ACTION_SEND 纯文本，一键直接选微信/QQ；
// 3) 发文件：先把日志写成 .txt，再用原生 FileProvider 以附件分享，
//    不受微信单条文字长度限制，最适合「日志报告」这种长内容。
//
// 三条路都只在用户主动点击时才把内容带出手机，App 平时不上传任何东西。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class LogExporter {
  static const MethodChannel _channel =
      MethodChannel('com.xiaobo.recipe/share');

  static Future<void> copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  static Future<void> shareText(String text) async {
    await _channel.invokeMethod<bool>('shareText', <String, dynamic>{
      'text': text,
      'subject': '小波菜谱 运行日志',
    });
  }

  /// 写一份 .txt 到 App 自己的目录（无需存储权限），返回绝对路径。
  static Future<String> writeFile(String text) async {
    Directory? dir = await getExternalStorageDirectory();
    dir ??= await getApplicationDocumentsDirectory();
    final logDir = Directory('${dir.path}/logs');
    if (!await logDir.exists()) await logDir.create(recursive: true);
    final now = DateTime.now();
    String p2(int n) => n.toString().padLeft(2, '0');
    final stamp = '${now.year}${p2(now.month)}${p2(now.day)}_'
        '${p2(now.hour)}${p2(now.minute)}${p2(now.second)}';
    final f = File('${logDir.path}/xiaobo_log_$stamp.txt');
    await f.writeAsString(text, flush: true);
    return f.path;
  }

  static Future<void> shareFile(String path) async {
    await _channel.invokeMethod<bool>('shareFile', <String, dynamic>{
      'path': path,
      'subject': '小波菜谱 运行日志',
    });
  }
}
