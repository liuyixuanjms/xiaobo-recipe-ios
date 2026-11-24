// 读取结果的中间产物缓存（v1.49）。
//
// 为什么要它：真机日志里同一条视频（同一作品 id）在 10:20、14:12、20:23
// 被处理了三次。视频本身早就缓存了，但「抽帧 18s + OCR 7~18s」每次都重跑，
// 三次就是一分多钟。改个菜名、调个分类、重新整理，都得再等这 25 秒。
//
// 缓存的是 `DouyinReader.read` 返回的整包结果（帧 + 字幕 + 配图）。
// 在这一层缓存，而不是缓存「原始 OCR 文本再重放后处理」，是为了绝不出现
// 缓存里的流程和当前代码不一致（水印规则、词表、融合算法都在变）。
//
// key 用视频文件的「大小 + 修改时间」，不用作品 id —— 本机视频也能用，
// 且文件一变 key 就变，绝不会读到过期字幕。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'douyin_reader.dart'
    show ReadRecipeResult, SubLine, VideoFrame;

class CachedRead {
  final ReadRecipeResult result;
  final DateTime savedAt;

  const CachedRead({required this.result, required this.savedAt});
}

class FrameCache {
  FrameCache._();

  /// 一帧 JPEG 约 100~250KB，130 帧可达 30MB。最多留 2 条，
  /// 和视频缓存的 keep=4 一个量级，避免把手机撑爆。
  static const int maxEntries = 2;

  /// 由调用方注入支持目录，避免这里再引 path_provider（保持可单测）。
  static Future<Directory> Function() getAppSupportDir =
      () async => Directory.systemTemp;

  static String _key(String videoPath) {
    final f = File(videoPath);
    // 用 size + mtime 当指纹：视频一变 key 就变，绝不会命中过期字幕。
    return '${f.lengthSync()}_${f.lastModifiedSync().millisecondsSinceEpoch}';
  }

  static Future<Directory> _dir() async {
    final base = await getAppSupportDir();
    final d = Directory('${base.path}/frame_cache');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  static File _metaFile(Directory dir, String key) =>
      File('${dir.path}/$key.json');
  static File _framesFile(Directory dir, String key) =>
      File('${dir.path}/$key.bin');
  static File _photosFile(Directory dir, String key) =>
      File('${dir.path}/$key.photos.bin');

  /// 命中返回整包结果，未命中 / 任何损坏都返回 null（缓存坏了绝不影响整理）。
  static Future<CachedRead?> load(String videoPath) async {
    try {
      final f = File(videoPath);
      if (!f.existsSync()) return null;
      final key = _key(videoPath);
      final dir = await _dir();
      final metaF = _metaFile(dir, key);
      final framesF = _framesFile(dir, key);
      final photosF = _photosFile(dir, key);
      if (!metaF.existsSync() || !framesF.existsSync() ||
          !photosF.existsSync()) {
        return null;
      }

      final meta =
          json.decode(await metaF.readAsString()) as Map<String, dynamic>;
      final lengths = (meta['lengths'] as List?)?.cast<num>() ?? const <num>[];
      if (lengths.isEmpty) return null;

      final blob = await framesF.readAsBytes();
      if (blob.isEmpty) return null;
      var off = 0;
      final frames = <VideoFrame>[];
      final secs = (meta['secs'] as List?)?.cast<num>() ?? const <num>[];
      final sharp = (meta['sharp'] as List?)?.cast<num>() ?? const <num>[];
      final bright = (meta['bright'] as List?)?.cast<num>() ?? const <num>[];
      final hashes = (meta['hash'] as List?)?.cast<String>() ?? const <String>[];
      final texts = (meta['texts'] as List?)?.cast<String>() ?? const <String>[];
      for (var i = 0; i < lengths.length; i++) {
        final len = lengths[i].toInt();
        if (len <= 0 || off + len > blob.length) return null;
        frames.add(VideoFrame(
          jpeg: blob.sublist(off, off + len),
          sec: i < secs.length ? secs[i].toInt() : 0,
          sharp: i < sharp.length ? sharp[i].toDouble() : 0,
          bright: i < bright.length ? bright[i].toDouble() : 128,
          hash: i < hashes.length ? hashes[i] : '',
          text: i < texts.length ? texts[i] : '',
        ));
        off += len;
      }
      // 配图是挑出来的那 6 张，不是前几帧 —— 单独存，原样读回。
      final photoLengths =
          (meta['photoLengths'] as List?)?.cast<num>() ?? const <num>[];
      final photoBlob = await photosF.readAsBytes();
      final photos = <Uint8List>[];
      var poff = 0;
      for (final pl in photoLengths) {
        final len = pl.toInt();
        if (len <= 0 || poff + len > photoBlob.length) return null;
        photos.add(Uint8List.fromList(photoBlob.sublist(poff, poff + len)));
        poff += len;
      }
      final subRaw = (meta['subtitleLines'] as List?) ?? const <dynamic>[];
      final subLines = <SubLine>[];
      for (final item in subRaw) {
        if (item is! List || item.length < 2) continue;
        subLines.add(SubLine((item[0] as num).toInt(), item[1].toString()));
      }
      final savedMs = (meta['savedAt'] as num?)?.toInt() ?? 0;

      return CachedRead(
        savedAt: DateTime.fromMillisecondsSinceEpoch(savedMs),
        result: ReadRecipeResult(
          title: (meta['title'] ?? '').toString(),
          desc: (meta['desc'] ?? '').toString(),
          subtitleText: (meta['subtitleText'] ?? '').toString(),
          subtitleLines: subLines,
          photos: photos,
          frames: frames,
          audioText: (meta['audioText'] ?? '').toString(),
          frameCount: (meta['frameCount'] as num?)?.toInt() ?? frames.length,
          videoPath: (meta['videoPath'] ?? videoPath).toString(),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// 写入缓存。失败静默 —— 缓存写不进去不影响这一次的结果。
  static Future<void> save(ReadRecipeResult r) async {
    try {
      if (r.videoPath.isEmpty || r.frames.isEmpty) return;
      final key = _key(r.videoPath);
      final dir = await _dir();
      final lengths = r.frames.map((f) => f.jpeg.length).toList();
      final blob = <int>[];
      for (final f in r.frames) {
        blob.addAll(f.jpeg);
      }
      await _framesFile(dir, key).writeAsBytes(blob);
      final photoLengths = r.photos.map((p) => p.length).toList();
      final photoBlob = <int>[];
      for (final p in r.photos) {
        photoBlob.addAll(p);
      }
      await _photosFile(dir, key).writeAsBytes(photoBlob);
      await _metaFile(dir, key).writeAsString(json.encode(<String, dynamic>{
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'title': r.title,
        'desc': r.desc,
        'subtitleText': r.subtitleText,
        'subtitleLines':
            r.subtitleLines.map((s) => <dynamic>[s.sec, s.text]).toList(),
        'audioText': r.audioText,
        'frameCount': r.frameCount,
        'videoPath': r.videoPath,
        'photoLengths': photoLengths,
        'lengths': lengths,
        'secs': r.frames.map((f) => f.sec).toList(),
        'sharp': r.frames.map((f) => f.sharp).toList(),
        'bright': r.frames.map((f) => f.bright).toList(),
        'hash': r.frames.map((f) => f.hash).toList(),
        'texts': r.frames.map((f) => f.text).toList(),
      }));
      await _prune(dir);
    } catch (_) {}
  }

  static Future<void> _prune(Directory dir) async {
    try {
      final metas = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) =>
            b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      for (final old in metas.skip(maxEntries)) {
        final stem = old.path.substring(0, old.path.length - 5);
        for (final suffix in <String>['.bin', '.photos.bin']) {
          try {
            File('$stem$suffix').deleteSync();
          } catch (_) {}
        }
        try {
          old.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }
}
