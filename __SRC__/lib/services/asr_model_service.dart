// 语音模型按需下载（v1.24 引入，v1.26 加强）。
//
// 为什么从 APK assets 移到「下载到手机私有目录」：
//   79MB 的 Paraformer 模型以前打包进 APK，导致安装包 139MB，每次下载/升级都要重新拉。
//   现在安装包瘦身到 ~60MB，模型第一次用「听视频讲解」时下载一次，
//   存到 App 私有目录（filesDir，覆盖安装不会清），从此以后任何版本升级都不再下。
//
// 【v1.26 的教训：为什么之前「下载不下来」】
//   1) 下到临时目录 —— 系统清缓存 / 进程被杀，进度全没了；
//   2) 失败就抛异常，用户再点一次从 0 字节重来，80MB 在手机流量网络下几乎不可能一次成功；
//   3) 没有分段，网关中途断流只能整段重下；
//   4) 进度条拿不到 Content-Length 就一直是 0%，看着像卡死。
//   现在的做法：
//   - 存 App 私有目录（不是缓存目录），断点文件 `*.part` 一直留着；
//   - 每次请求带 `Range: bytes=<已下字节>-`，服务端给 206 就接着写，给 200 就从头写（自动兼容）；
//   - 失败自动重试 4 次（2s/4s/8s 退避），每次都是从断点续，不是从 0；
//   - 进度按「已知总大小」算百分比，没 Content-Length 也不会显示成 0%；
//   - 响应开头若不是二进制（网关挡了返回 HTML）立即报错，不白下 80MB 垃圾。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'alarm_service.dart';

/// 模型没下载好时抛这个，上层据此引导而不是当成"识别失败"。
class AsrModelMissing implements Exception {
  final String message;
  AsrModelMissing(this.message);
  @override
  String toString() => message;
}

class AsrDownloadProgress {
  final int received;
  final int total;
  final double percent;

  /// 瞬时速度（字节/秒），拿不到就是 0。UI 用来给「还要多久」一个体感。
  final double bytesPerSec;
  const AsrDownloadProgress(
    this.received,
    this.total,
    this.percent, [
    this.bytesPerSec = 0,
  ]);

  String get human {
    final mb = (received / 1048576).toStringAsFixed(1);
    final tmb = total > 0 ? (total / 1048576).toStringAsFixed(0) : '?';
    final pct = total > 0 ? '${(percent * 100).round()}%' : '';
    final speed = bytesPerSec > 0
        ? ' · ${(bytesPerSec / 1048576).toStringAsFixed(2)} MB/s'
        : '';
    return '$mb / $tmb MB $pct$speed'.replaceAll('  ', ' ');
  }
}

class AsrModelService {
  static const MethodChannel _ch = MethodChannel('com.xiaobo.recipe/share');

  // 托管在已有的公网发布域名下，和 APK 同一个 sharecode 机制。
  // 换托管位置时只改这两个常量 + 保持文件名不变即可。
  static const String _baseUrl =
      'https://recipe-apk-download.app.workbuddy.host';
  static const String _share = '?sharecode=PZ7H6TPYOA';
  static const String _modelUrl = '$_baseUrl/model.int8.onnx$_share';
  static const String _tokensUrl = '$_baseUrl/tokens.txt$_share';

  /// 给「复制链接」兜底用：App 内下不动时，用户可以丢进浏览器/下载器。
  static String get modelDownloadUrl => _modelUrl;

  // 精确大小：源文件就是这两个字节数。用来判断「续传是不是已经下完」，
  // 也用来在下不到 Content-Length 时兜底算进度。
  static const int modelExpectedBytes = 81828675;
  static const int tokensExpectedBytes = 75352;

  /// 断点文件留在这个目录（私有、持久），卸载 App 才没。
  static const String _dirName = 'asr_dl';

  /// 单次请求最多重试几轮。
  ///
  /// 注意：托管网关（CloudStudio Gateway）**不支持 Range**，实测带
  /// `Range: bytes=...` 仍回 200 + 完整文件。所以这里的重试其实是从 0 重下，
  /// 不能给太多次 —— 3 次已经够扛过手机换网/瞬时断流，再多就是白烧用户流量。
  /// 续传代码保留着，换支持 Range 的托管时立刻生效，不用改逻辑。
  static const int _maxAttempts = 3;

  bool _downloading = false;
  bool get isDownloading => _downloading;

  Future<bool> isReady() async {
    try {
      return (await _ch.invokeMethod<bool>('asrModelReady')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 【v1.37】模型是否随安装包内置。
  ///
  /// 内置之后「就绪」是装完就成立的，用户不需要也不应该再看到「下载语音包」按钮。
  /// 单独问一次而不是用 [isReady] 推断，是因为旧版本用户可能私有目录里
  /// 已经下过一份，那种情况是「已下载」而非「已内置」，文案要区分。
  Future<bool> isBundled() async {
    try {
      return (await _ch.invokeMethod<bool>('asrModelBundled')) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<int> localSize() async {
    try {
      return (await _ch.invokeMethod<int>('asrModelSize')) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 当前是否连着 WiFi（原生判断；判断不了返回 false，绝不偷跑流量）。
  Future<bool> isOnWifi() async {
    try {
      return (await _ch.invokeMethod<bool>('isOnWifi')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 确保模型就绪；否则抛 AsrModelMissing。供 transcribe 前调用。
  Future<void> requireReady() async {
    if (await isReady()) return;
    throw AsrModelMissing('语音包还没下载到手机，点一下「下载语音包」就行（约 79MB，建议连 WiFi）。');
  }

  /// 上次下到一半留下的字节数（0 表示没有断点）。设置页一进来就显示，
  /// 让用户知道「点一下能接着下」，不是从头再来。
  Future<int> pendingBytes() async {
    try {
      final f = File('${(await _dir()).path}/model.int8.onnx.part');
      if (!f.existsSync()) return 0;
      final n = f.lengthSync();
      return n >= modelExpectedBytes ? 0 : n;
    } catch (_) {
      return 0;
    }
  }

  Future<Directory> _dir() async {
    // 用 ApplicationSupport（不是 Temporary）：系统清理缓存不会动它，
    // 手机上「下到一半关掉 App 明天接着下」这条路才成立。
    Directory base;
    try {
      base = await getApplicationSupportDirectory();
    } catch (_) {
      base = await getTemporaryDirectory();
    }
    final d = Directory('${base.path}/$_dirName');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 下载并安装模型。onProgress 可用于 UI 进度条。
  /// 返回安装后的模型字节数；失败抛异常（含网络/校验/安装）。
  Future<int> download({void Function(AsrDownloadProgress)? onProgress}) async {
    if (_downloading) throw StateError('语音包正在下载中');
    _downloading = true;
    http.Client? client;
    // 下载期间让屏幕别灭：Android 进休眠会把 socket 挂起，
    // 80MB 传到一半被系统掐断就是「下载不下来」的另一种死法。
    await AlarmService.keepScreenOn(true);
    try {
      final dir = await _dir();
      final modelTmp = File('${dir.path}/model.int8.onnx.part');
      final tokensTmp = File('${dir.path}/tokens.txt.part');

      client = http.Client();

      // 先下小词表（75KB，快，早失败早知道；它下不下来就说明网络/网关有问题）。
      await _fetchWithRetry(client, _tokensUrl, tokensTmp, tokensExpectedBytes);
      if (tokensTmp.lengthSync() < 1000) {
        throw const FormatException('词表下载不完整，稍后重试');
      }

      await _fetchWithRetry(
        client,
        _modelUrl,
        modelTmp,
        modelExpectedBytes,
        onProgress: onProgress,
      );
      if (modelTmp.lengthSync() < modelExpectedBytes) {
        throw FormatException(
            '模型只下到 ${(modelTmp.lengthSync() / 1048576).toStringAsFixed(1)} MB'
            '（应 ${(modelExpectedBytes / 1048576).toStringAsFixed(0)} MB），已保留断点，可重试续下');
      }

      // 交给原生：二次大小校验 + 原子移动到私有目录 + 重置识别器
      Map<String, dynamic>? res;
      try {
        res = await _ch.invokeMapMethod<String, dynamic>(
          'installAsrModel',
          <String, dynamic>{
            'model': modelTmp.path,
            'tokens': tokensTmp.path,
          },
        );
      } on PlatformException catch (e) {
        // 文件已经完整下好了，装不上只是「最后一个环节」出错。
        // 断点文件必须留着 —— 下次点下载会跳过下载直接重装，不用再烧 80MB。
        if (e.code == 'BAD_MODEL' || e.code == 'BAD_TOKENS') {
          throw FormatException(
              '文件已经下完（${(modelTmp.lengthSync() / 1048576).toStringAsFixed(1)} MB），'
              '但安装校验没过：${e.message ?? e.code}。'
              '文件留着，下次点下载会直接装，不用重新下。');
        }
        throw FormatException('安装语音包失败：${e.message ?? e.code}');
      }
      final ok = (res?['ok'] as bool?) ?? false;
      final size = ((res?['size'] as num?) ?? 0).toInt();
      if (!ok || size < modelExpectedBytes) {
        throw const FormatException('模型安装校验没过，稍后重试');
      }
      // 装好了就清掉断点文件，别白占 80MB
      try {
        modelTmp.deleteSync();
      } catch (_) {}
      try {
        tokensTmp.deleteSync();
      } catch (_) {}
      return size;
    } finally {
      _downloading = false;
      client?.close();
      // 下载结束（成功或失败）立刻放开，别让用户以为 App 卡着不放屏
      await AlarmService.keepScreenOn(false);
    }
  }

  /// 带重试的下载：每次失败都从 `.part` 的现有长度续传，不回到 0。
  ///
  /// 重试策略：网络类异常（连接断、超时、5xx）都重试；4xx 直接抛，
  /// 那是地址/鉴权问题，重试一百次也一样，早点把话说明白给用户。
  Future<void> _fetchWithRetry(
    http.Client client,
    String url,
    File target,
    int expected, {
    void Function(AsrDownloadProgress)? onProgress,
  }) async {
    Object? last;
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        await _fetchOnce(client, url, target, expected, onProgress);
        return;
      } on _FatalDownload catch (e) {
        throw FormatException(e.message);
      } catch (e) {
        last = e;
        if (attempt >= _maxAttempts) break;
        // 2s / 4s / 8s —— 手机上换基站、切 WiFi 常要几秒
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
      }
    }
    final have = target.existsSync() ? target.lengthSync() : 0;
    throw FormatException(
        '下载失败（已保留断点 ${(have / 1048576).toStringAsFixed(1)} MB，重试会接着下）：$last');
  }

  /// 单次请求。带 Range 续传；服务端不理 Range（回 200）就自动从头写。
  Future<void> _fetchOnce(
    http.Client client,
    String url,
    File target,
    int expected,
    void Function(AsrDownloadProgress)? onProgress,
  ) async {
    var start = target.existsSync() ? target.lengthSync() : 0;
    // 断点比目标还大 = 脏文件（上次写坏了），删掉重来
    if (start > expected) {
      try {
        target.deleteSync();
      } catch (_) {}
      start = 0;
    }
    if (start == expected && expected > 0) return; // 已经下全了，直接进安装

    final req = http.Request('GET', Uri.parse(url));
    if (start > 0) {
      req.headers['Range'] = 'bytes=$start-';
    }
    // 关键：让网关别 gzip。压缩后 Content-Length 和 Range 都对不上，
    // 续传会拼出坏文件。
    req.headers['Accept-Encoding'] = 'identity';
    req.headers['User-Agent'] = 'XiaoBoRecipe/1.26 (Android)';

    final resp = await client.send(req).timeout(const Duration(seconds: 45));

    if (resp.statusCode == 403 || resp.statusCode == 404) {
      final head = await resp.stream.take(1).join();
      throw _FatalDownload('地址打不开（HTTP ${resp.statusCode}）'
          '${head.contains('<') ? '，返回的是网页不是文件' : ''}');
    }
    if (resp.statusCode != 200 && resp.statusCode != 206) {
      throw HttpException('下载失败 HTTP ${resp.statusCode}', uri: Uri.parse(url));
    }

    final append = resp.statusCode == 206;
    final base = append ? start : 0;
    final total = resp.contentLength != null && resp.contentLength! > 0
        ? base + resp.contentLength!
        : expected;

    final sink = append
        ? target.openWrite(mode: FileMode.append)
        : target.openWrite(mode: FileMode.write);

    var received = base;
    var first = true;
    final sw = Stopwatch()..start();
    final speedWin = _SpeedWindow();
    try {
      await for (final chunk in resp.stream.timeout(
        const Duration(seconds: 60),
        onTimeout: (s) =>
            s.addError(TimeoutException('下载中断（已收 $received 字节）')),
      )) {
        // 第一个块像 HTML（网关 403 页 / 人机验证页）就立刻停，别写 80MB 垃圾。
        //
        // 【v1.26.1 修正】v1.26 的写法是「首字节是 `<` 就算网页」，结果把
        // tokens.txt 干掉了 —— 那个文件的头就是 `<blank> 0<s> 1</s> 2<OOV> 3`，
        // 于是一下载词表就报「服务器返回的是网页」，语音包永远下不下来。
        // 现在按真正的 HTML/XHTML 特征判断，文本词表不会再被误伤。
        if (first && !append) {
          first = false;
          if (looksLikeHtml(chunk)) {
            final head = String.fromCharCodes(
                chunk.take(160).where((c) => c >= 32 && c < 127));
            throw _FatalDownload('服务器返回的是网页不是文件（$head）');
          }
        }
        sink.add(chunk);
        received += chunk.length;
        speedWin.add(chunk.length, sw.elapsedMilliseconds);
        if (onProgress != null && total > 0) {
          onProgress(AsrDownloadProgress(
            received,
            total,
            (received / total).clamp(0.0, 1.0),
            speedWin.bytesPerSec,
          ));
        }
      }
    } finally {
      await sink.close();
    }

    // 下完了但不够：说明断流。抛异常让上层重试，重试会从新长度续。
    if (total > 0 && received < total) {
      throw TimeoutException('连接提前结束（$received / $total 字节）');
    }
  }
}

/// 判断响应开头是不是「网页」而不是我们要的文件。
///
/// **不能只看首字节是不是 `<`** —— sherpa-onnx 的 tokens.txt 头几行就是
/// `<blank> 0`、`<s> 1`、`</s> 2`、`<OOV> 3`，首字节天然是 0x3C。
/// 按 HTML 标签特征判断才稳，纯文本词表不会被误伤。
///
/// 暴露成顶层函数是为了能单测：这条判断写错一次，语音包就整个下不了。
bool looksLikeHtml(List<int> head) {
  if (head.isEmpty) return false;
  // 用 utf8 解码（容忍坏字节）：二进制文件会解出替换字符，不影响判断；
  // 用 String.fromCharCodes 的话 UTF-8 的 BOM 会变成 "ï»¿"，去不掉。
  final s = utf8
      .decode(head.take(400).toList(), allowMalformed: true)
      .toLowerCase()
      .replaceFirst('\ufeff', '')
      .trimLeft();
  return s.startsWith('<!doctype') ||
      s.startsWith('<?xml') ||
      s.startsWith('<html') ||
      s.contains('<html') ||
      s.contains('<head') ||
      s.contains('<body');
}

/// 4xx 这类重试没意义的错误。
class _FatalDownload implements Exception {
  final String message;
  _FatalDownload(this.message);
  @override
  String toString() => message;
}

/// 滚动窗口算速度：最近 ~2 秒内的平均，比「总字节/总耗时」更贴近当下体感。
class _SpeedWindow {
  final List<int> _t = <int>[];
  final List<int> _b = <int>[];

  void add(int bytes, int ms) {
    _t.add(ms);
    _b.add(bytes);
    while (_t.length > 2 && ms - _t.first > 2000) {
      _t.removeAt(0);
      _b.removeAt(0);
    }
  }

  double get bytesPerSec {
    if (_t.length < 2) return 0;
    final span = _t.last - _t.first;
    if (span <= 0) return 0;
    var sum = 0;
    for (var i = 1; i < _b.length; i++) {
      sum += _b[i];
    }
    return sum * 1000 / span;
  }
}
