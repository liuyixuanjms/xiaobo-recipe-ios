// 从**本机已有视频**整理菜谱（v1.33 · 上架版入口）
//
// 和 douyin_reader.read() 的关系：
//   那条路是「贴链接 → 解析作品页 → 下载 → 处理」；
//   这条路是「用户选一个本机视频文件 → 处理」。
//   前半段完全不同，**后半段一字不差** —— 抽帧、读画面硬字幕、
//   听口播、筛掉糊帧、挑进长图的实拍组，全部复用 DouyinReader 里那套。
//
// 为什么单独放一个文件：
//   上架版要求「产物里不含解析第三方链接的代码」。把本地入口独立出来之后，
//   ingest_job 在 kInternal == false 时只会走到这里，链接那条分支变成死代码，
//   AOT 编译会把它连带引用的网络/解析方法一起剔除。
//
// 边界：本文件不发起任何网络请求，不读任何平台页面，不认链接。
import 'dart:io';

import 'asr_policy.dart';
import 'douyin_reader.dart'
    show DouyinReader, ReadRecipeResult, SubLine, VideoFrame;
import 'log_service.dart';

/// 本地视频处理失败。message 是给人看的整句话，直接弹在页面上。
class LocalVideoReadException implements Exception {
  final String message;
  const LocalVideoReadException(this.message);
  @override
  String toString() => message;
}

class LocalVideoReader {
  /// 认得的视频后缀。只按后缀判断，不读文件头 ——
  /// 走到这里文件已经被系统选择器筛过一遍了，再解析文件头是重复劳动。
  static const List<String> videoExts = <String>[
    '.mp4',
    '.mov',
    '.m4v',
    '.3gp',
    '.mkv',
    '.webm',
    '.avi',
  ];

  static bool looksLikeVideo(String path) {
    final p = path.toLowerCase();
    for (final e in videoExts) {
      if (p.endsWith(e)) return true;
    }
    return false;
  }

  /// 从文件名猜个菜名。
  ///
  /// 相册导出的基本是 `IMG_1234.MOV` / `VID_20261113_142530.mp4` 这种，
  /// 一个字的菜名信息都没有 —— 这种情况返回空串，让上层用默认名，
  /// 别把「IMG_1234」当成菜名糊到用户脸上。
  static String titleFromPath(String path) {
    var name = path.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    // 注意是 >= 0 而不是 > 0：`.mp4` 这种只有后缀的隐藏文件名，
    // 用 > 0 会原样返回「.mp4」当成菜名。
    if (dot >= 0) name = name.substring(0, dot);
    name = name.trim();
    if (name.isEmpty) return '';
    if (RegExp(r'^[0-9_\-\s]+$').hasMatch(name)) return '';
    if (RegExp(r'^(IMG|VID|MOV|PXL|DSC|mmexport|wx_camera)[_\-]?\d',
            caseSensitive: false)
        .hasMatch(name)) {
      return '';
    }
    return name;
  }

  static Future<void> _log(LogSink? onLog, String tag, String msg) async {
    if (onLog == null) return;
    try {
      await onLog(tag, msg);
    } catch (_) {}
  }

  /// 读一个本机视频，产出和 `DouyinReader.read()` 同构的结果，
  /// 好让下游（IngestJob / LocalRecipeBuilder / FrameMatcher）两不相干地复用。
  ///
  /// [titleHint] 用户自己填的菜名；为空时退到文件名，再退到「新菜谱」。
  Future<ReadRecipeResult> readLocal(
    String path, {
    String? titleHint,
    void Function(String label)? onStage,
    LogSink? onLog,
    bool skipAudio = false,
  }) async {
    final f = File(path);
    if (!await f.exists()) {
      throw const LocalVideoReadException('这个文件不在了，可能被移走或清理掉了');
    }
    final size = await f.length();
    if (size < 64 * 1024) {
      throw const LocalVideoReadException('这个文件只有几十 KB，不像是视频，换一个试试');
    }
    await _log(
        onLog,
        '本地视频',
        '文件 ${f.path.split(Platform.pathSeparator).last}'
            '｜${(size / 1024 / 1024).toStringAsFixed(1)} MB');

    final media = DouyinReader();

    try {
      onStage?.call('正在抽帧读字幕…');
      final List<VideoFrame> frames =
          await media.extractFrames(path, const <int>[], onLog);
      if (frames.isEmpty) {
        throw const LocalVideoReadException(
            '这个视频抽不出画面 —— 可能编码不标准，或者只有声音没有画面');
      }

      final subLines = <SubLine>[];
      onStage?.call('正在读图片上的文字…');
      final subtitle = await media.ocrFrames(frames, onLog, outLines: subLines);
      await _log(
          onLog,
          '字幕时间轴',
          subLines.isEmpty
              ? '（没有可用时间轴，配图退回按比例猜）'
              : '${subLines.length} 行字幕带上了秒数，'
                  '范围 ${subLines.first.sec}s ~ ${subLines.last.sec}s');

      // v1.43：和线上那条路一样，字幕够密就不等口播，稀疏才听且硬限时。
      var audio = '';
      final han = subtitle.replaceAll(RegExp(r'[^\u4e00-\u9fa5]'), '').length;
      if (!AsrPolicy.shouldListen(skipAudio: skipAudio, subtitleHan: han)) {
        await _log(
            onLog,
            '语音识别',
            AsrPolicy.skipReason(skipAudio: skipAudio, subtitleHan: han));
      } else {
        await _log(onLog, '语音识别', AsrPolicy.listenReason(han));
        onStage?.call('正在听视频里说了什么…');
        audio = await media.transcribe(path, onLog);
      }

      final kept = media.pickUsable(frames, onLog);
      await _log(
          onLog,
          '挑图',
          '去掉黑屏、糊帧、重复画面后剩 ${kept.length} 张能用'
              '${kept.isEmpty ? ' ←← 这段视频几乎全是转场，只能不配图' : ''}');

      final picks = DouyinReader.spread(kept, 6).map((x) => x.jpeg).toList();

      final hint = (titleHint ?? '').trim();
      final fromName = titleFromPath(path);
      final title = hint.isNotEmpty
          ? hint
          : (fromName.isNotEmpty ? fromName : '新菜谱');

      final result = ReadRecipeResult(
        title: title,
        desc: '',
        subtitleText: subtitle,
        subtitleLines: subLines,
        audioText: audio,
        photos: picks,
        frames: kept,
        frameCount: frames.length,
        videoPath: path,
      );
      await _log(
          onLog,
          '本地视频结果',
          '菜名「$title」｜语音 ${audio.length} 字'
              '｜画面字幕 ${subtitle.length} 字'
              '｜实拍图 ${picks.length} 张｜总抽帧 ${frames.length}');
      return result;
    } on LocalVideoReadException catch (e) {
      await _log(onLog, '失败', '本地视频读取中断：${e.message}');
      rethrow;
    } catch (e) {
      await _log(onLog, '失败', '本地视频读取未预期异常：${e.runtimeType} $e');
      throw LocalVideoReadException('这个视频处理不了：$e');
    }
    // 注意：这里**没有** finally 删文件。
    // 网上下到临时目录的缓存用完要删，但这是用户自己相册/文件里的原件，
    // 删了就是删用户的东西 —— 宁可多占几十兆也不能动。
  }
}
