// 菜谱里那个原视频，到底能不能用（v1.17）。
//
// 起因：v1.16 存视频时，原生转码被 3 分钟超时掐断，MediaMuxer 已经把文件
// 建出来了，但里面没有 moov 原子 —— 文件「存在」，可是任何播放器都放不出来。
// 上层只判断「文件在不在」，于是给它挂了一个播放键，用户点开是黑的。
//
// 所以「能不能用」必须同时看两件事：文件在、而且不是个空壳。
// 10KB 这个门槛很宽松：一条 720p 的视频哪怕只有 1 秒也有几十 KB，
// 真掉到 10KB 以下，一定是没写完的半截货。
import 'dart:io';

class VideoFile {
  VideoFile._();

  /// 小于这个字节数，一律当成坏文件
  static const int minBytes = 10240;

  static bool usable(String path) {
    if (path.trim().isEmpty) return false;
    try {
      final f = File(path);
      if (!f.existsSync()) return false;
      return f.lengthSync() >= minBytes;
    } catch (_) {
      return false;
    }
  }

  /// 给人看的大小，例如「42.7MB」/「860KB」
  static String human(int bytes) {
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)}MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)}KB';
    return '${bytes}B';
  }
}
