// V0.13 · 贴链接自动读（抖音视频作品）
// V0.14 · 每一步都接 LogSink 回吐细节，方便「跑不通」时导出日志定位断点。
//
// 完整链路，全部在手机本机完成，不需要后端、不需要第三方 Key：
//   分享口令 → 解析出作品 id → 原生 WebView 以桌面 UA 打开公开视频页
//   → 从渲染后的 HTML 里取「标题/话题/作者/时间」和「视频直链」
//   → 下载 MP4 到临时目录 → 原生 MediaMetadataRetriever 按秒抽帧
//   → ML Kit 中文 OCR 读出画面上烧录的硬字幕 → 交给 DeepSeek 整理成菜谱
//   → 抽出来的真实帧同时当「实拍参考」成组排进长图。
//
// 【实测依据 2026-11-10 · 第二轮】
//   1) 短链 `v.douyin.com/xxx/` 确实 302 到 `iesdouyin.com/share/video/<id>/`，
//      再 302 到 `douyin.com/video/<id>`。作品 id 在 **Location 响应头**里。
//   2) 纯 http 拿到的正文是 `_$jsvmprt` 反爬挑战页（body 为空 + 一段 JS VM），
//      一定读不到内容；必须让浏览器执行脚本。
//   3) 真正可解析的数据在 `<script id="RENDER_DATA">` 里 —— 它是 **URL 编码的 JSON**，
//      要先 Uri.decodeComponent 再 jsonDecode，里面才有 desc 和 video.play_addr。
//      老写法只找 `<meta name="description">` 和 `<source src>`，在新版页面上永远是空的。
//   4) 桌面页 / 手机页对部分作品会返回「抱歉出错了 / 请尝试在抖音内观看」，
//      这是作品本身受限（需登录、已删、或仅 App 内可见），不是链接贴错。
//
// 【v1.5 的关键修正】v1.4 用 package:http 的 `resp.request.url` 当落地页 ——
//   那是 **原始请求地址**，不是跳转后的地址，于是永远看不到 /video/，
//   于是把「反爬挑战页」误判成「你贴的是主页口令」。这就是本次日志里的假结论。
//   现在改成 dart:io HttpClient + followRedirects=false，逐跳读 Location。
//
// 【边界，不许说满】平台风控/页面结构会变；真机 WebView 与桌面 Chromium 不完全
// 等价。读不到时由 App 自己重试、换入口再试，并把断点写进日志，不把活推给用户。
// 只处理单条作品链接；用户主页口令（/share/user/）不适用。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'asr_fixer.dart';
import 'asr_model_service.dart';
import 'asr_policy.dart';
import 'cloud_ocr.dart';
import 'frame_cache.dart';
import 'kitchen_lexicon.dart';
import 'log_service.dart';
import 'subtitle_clean.dart';
import 'subtitle_fuse.dart';

/// 一行字幕 + 它出现在视频的第几秒。
///
/// 以前只把字幕拼成一整段纯文本交给 AI，时间信息就丢了；
/// 结果「这一步配哪张图」只能靠文字相似度猜，步骤一改写就错位。
/// 带上秒数之后，模型可以直接把每一步指到某一句上。
class SubLine {
  final int sec;
  final String text;
  const SubLine(this.sec, this.text);
}

class ReadRecipeResult {
  final String title; // 从 meta description 里拆出的菜名
  final String desc; // 完整文案（标题 + 话题 + 作者 + 时间）
  final String subtitleText; // OCR 从画面硬字幕里读到的文字
  final List<SubLine> subtitleLines; // 同上，但每行带着它出现的秒数
  final List<Uint8List> photos; // 筛过的真实帧，成组排进长图
  final List<VideoFrame> frames; // 全部帧（带时间/清晰度/该帧文字），用来给每一步配图
  final String audioText; // 语音转文字（v1.8，本机离线识别；没跑就是空）
  final int frameCount; // 实际抽到多少帧

  /// v1.16：下载下来的原始视频在本机的临时路径。
  /// 空字符串 = 这条没有视频（图文笔记）。
  /// 上层决定是压一遍存进菜谱，还是用完删掉 —— 读取这一步不再自作主张删。
  final String videoPath;

  const ReadRecipeResult({
    this.title = '',
    this.desc = '',
    this.subtitleText = '',
    this.subtitleLines = const <SubLine>[],
    this.photos = const <Uint8List>[],
    this.frames = const <VideoFrame>[],
    this.audioText = '',
    this.frameCount = 0,
    this.videoPath = '',
  });

  bool get hasContent =>
      subtitleText.trim().isNotEmpty ||
      audioText.trim().isNotEmpty ||
      photos.isNotEmpty;
}

/// 一帧画面 + 它的质量指标 + 这一帧上认出来的字。
///
/// 为什么要把「指标」和「文字」跟图绑在一起：长图里每一步要配一张「正在做这一步」的画面，
/// 只靠时间比例切分经常切到黑屏或手部特写。有了 per-frame 的文字，就能拿步骤文字去跟
/// 每帧的文字比对，挑出真正在讲这一步的那一帧。
class VideoFrame {
  final Uint8List jpeg;
  final int sec; // 这一帧在视频里的第几秒
  final double sharp; // 拉普拉斯方差：越大越清晰
  final double bright; // 平均亮度 0~255
  final String hash; // 8x8 均值哈希，用来判重
  String text; // 这一帧 OCR 出来的文字（可能为空）

  VideoFrame({
    required this.jpeg,
    required this.sec,
    required this.sharp,
    required this.bright,
    required this.hash,
    this.text = '',
  });

  /// 能不能用：黑屏、闪白、糊成一团的帧直接不要。
  bool get isUsable =>
      bright > 36 && bright < 236 && sharp > 2.0;

  @override
  String toString() => '第 ${sec}s（清晰度 ${sharp.toStringAsFixed(0)}，亮度 ${bright.toStringAsFixed(0)}）';
}

class DouyinReadException implements Exception {
  final String message;
  const DouyinReadException(this.message);
  @override
  String toString() => message;
}

/// 从渲染后的页面里抽出来的东西。
/// 一份页面可能只有视频、只有图（图文作品）、或者什么都没有（被拦/需登录）。
class _PageData {
  final String desc; // 作品文案：标题 + 话题 + @作者
  final String videoUrl; // 无水印视频直链（douyinvod），没有就是空
  final List<String> images; // 图文作品的图，或视频封面
  final String pageTitle; // <title> 或 og:title，兜底用

  const _PageData({
    this.desc = '',
    this.videoUrl = '',
    this.images = const <String>[],
    this.pageTitle = '',
  });

  /// 这份页面值不值得收下：有文案或有视频或有图，才算真读到了内容。
  bool get usable =>
      videoUrl.isNotEmpty ||
      images.isNotEmpty ||
      desc.trim().length >= 8; // 1~7 字基本是页面配置的脏数据，不算作品文案
}

/// 一次「打开作品页」拿回来的全部原始材料（v1.6）。
///
/// 抖音把作品数据放在页面自己请求的 `/aweme/v1/web/aweme/detail/` 响应里，
/// HTML 里既没有 desc 也没有可用的 RENDER_DATA。所以这里同时带回：
/// [detail]（截到的接口 JSON，最关键）、[text]（页面可见文字）、
/// [captcha]（有没有弹人机验证）、[hits]（截到过哪些接口，排查用）。
class _PageSnapshot {
  final String html;
  final String detail;
  final String href;
  final String title;
  final String text;
  final String videoSrc;
  final bool captcha;
  final String hits;

  /// v1.7：页面**实际发出的网络请求**里，像视频的那些地址。
  /// 作品接口给的播放地址有可能被平台抹掉（风控降级），但页面只要真播了视频，
  /// 分片请求就摆在这儿 —— 这是绕开「接口里没地址」的一条活路。
  final String res;

  /// 这次要读的作品 id：用来核对截到的数据是不是「这条」，避免拿到推荐流里的别人。
  final String targetId;

  const _PageSnapshot({
    this.html = '',
    this.detail = '',
    this.href = '',
    this.title = '',
    this.text = '',
    this.videoSrc = '',
    this.captcha = false,
    this.hits = '',
    this.res = '',
    this.targetId = '',
  });

  bool get isEmpty => html.isEmpty && detail.isEmpty && text.isEmpty;
}

class DouyinReader {
  static const MethodChannel _channel =
      MethodChannel('com.xiaobo.recipe/share');
  static const String ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 手机身份。官方分享页只在手机 UA 下把作品 SSR 出来。
  static const String mobileUa =
      'Mozilla/5.0 (Linux; Android 12; SM-G991B) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  static final RegExp _urlReg = RegExp(
    r'https?://[^\s，,。;；\]\)\}）]+',
    caseSensitive: false,
  );

  /// 视频作品 id：/video/7577221970073397371
  static final RegExp _idReg = RegExp(r'/video/(\d{10,})');

  /// 图文作品 id：/note/7577221970073397371 或 query 里的 modal_id / item_ids
  static final RegExp _noteIdReg = RegExp(r'/(?:note|slides)/(\d{10,})');
  static final RegExp _queryIdReg =
      RegExp(r'(?:modal_id|item_ids|aweme_id)=(\d{10,})');
  static final RegExp _descReg = RegExp(
    r'<meta[^>]*name="description"[^>]*content="([^"]*)"',
    caseSensitive: false,
  );
  static final RegExp _sourceReg = RegExp(
    r'<source[^>]*\bsrc="([^"]+)"',
    caseSensitive: false,
  );

  static Future<void> _log(LogSink? onLog, String tag, String msg) async {
    if (onLog != null) await onLog(tag, msg);
  }

  static String extractUrl(String raw) {
    final m = _urlReg.firstMatch(raw);
    return m == null ? '' : raw.substring(m.start, m.end).trim();
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('\\u0026', '&')
      .replaceAll('\\/', '/');

  /// 从任意一段文本/链接里找出作品 id（视频页、图文页、query 参数都认）。
  static String? _pickId(String s) {
    for (final re in <RegExp>[_idReg, _noteIdReg, _queryIdReg]) {
      final m = re.firstMatch(s);
      if (m != null) return m.group(1);
    }
    return null;
  }

  /// 逐跳跟 302，只读 `Location` 响应头，拿到作品 id。
  /// 返回 null 表示「没解析出来」，**不再当成致命错误** ——
  /// 拿不到 id 也照样让 WebView 直接打开原始短链，由浏览器自己跟跳转。
  Future<String?> _resolveId(String url, LogSink? onLog) async {
    final direct = _pickId(url);
    if (direct != null) {
      await _log(onLog, '读链接', '链接里直接带作品 id=$direct，无需跳转');
      return direct;
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12)
      ..findProxy = HttpClient.findProxyFromEnvironment;
    var cur = Uri.parse(url);
    try {
      for (var hop = 1; hop <= 6; hop++) {
        final req = await client.getUrl(cur).timeout(const Duration(seconds: 15));
        // 关键：不自动跟跳转，自己读 Location，才能拿到真正的落地地址
        req.followRedirects = false;
        req.headers.set(HttpHeaders.userAgentHeader, ua);
        req.headers.set(HttpHeaders.acceptLanguageHeader, 'zh-CN,zh;q=0.9');
        final resp = await req.close().timeout(const Duration(seconds: 15));
        final loc = resp.headers.value(HttpHeaders.locationHeader);

        await _log(onLog, '读链接',
            '第 $hop 跳｜HTTP ${resp.statusCode}｜来自 $cur｜Location ${loc ?? '（无，已到终点）'}');

        if (loc != null) {
          cur = cur.resolve(loc);
          final hit = _pickId(cur.toString());
          if (hit != null) {
            await _log(onLog, '读链接', '解析出作品 id=$hit（落地 $cur）');
            return hit;
          }
          continue;
        }

        // 没有跳转了：正文可能是分享页 SSR 的 JSON，也可能就是挑战页
        final body = await resp.transform(utf8.decoder).join();
        final hit = _pickId(body);
        if (hit != null) {
          await _log(onLog, '读链接', '从落地页正文里扫到作品 id=$hit');
          return hit;
        }
        if (body.contains('jsvmprt')) {
          await _log(onLog, '读链接',
              '落地页是平台的反爬挑战页（_\$jsvmprt，正文 ${body.length} 字），纯网络一定读不到，下一步换手机内嵌浏览器');
        } else {
          await _log(onLog, '读链接',
              '落地页里没有作品 id（正文 ${body.length} 字），下一步直接用浏览器打开原始短链再试');
        }
        return null;
      }
      await _log(onLog, '读链接', '跳转超过 6 跳还没拿到 id，交给浏览器打开原始短链');
    } on Exception catch (e) {
      await _log(onLog, '读链接', '短链请求异常：${e.runtimeType} $e —— 交给浏览器打开原始短链再试');
    } finally {
      client.close(force: true);
    }
    return null;
  }

  /// v1.7 · 第 0 条路：不开浏览器，直接用手机身份抓官方分享页。
  ///
  /// 为什么值得单开一条：官方的 `iesdouyin.com/share/video/<id>/` 在手机 UA 下
  /// 会把整条作品 SSR 进 HTML（`window._ROUTER_DATA`），里面就有 play_addr。
  /// 这条路**不依赖 WebView 的登录态、不等人机验证、不受页面脚本影响**，
  /// 而且几百毫秒就回来。PC 页被平台降级时，它常常一步就把料拿到。
  Future<_PageSnapshot?> _fetchSharePageDirect(
      String id, LogSink? onLog) async {
    final url = 'https://www.iesdouyin.com/share/video/$id/';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      await _log(onLog, '直抓分享页', '不开浏览器，用手机身份直接抓 $url');
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      req.followRedirects = true;
      req.headers.set(HttpHeaders.userAgentHeader, mobileUa);
      req.headers.set(HttpHeaders.acceptLanguageHeader, 'zh-CN,zh;q=0.9');
      final resp = await req.close().timeout(const Duration(seconds: 12));
      final body = await resp.transform(utf8.decoder).join();
      await _log(onLog, '直抓分享页',
          'HTTP ${resp.statusCode}｜正文 ${body.length} 字'
          '｜带作品数据 ${body.contains('_ROUTER_DATA') ? '是' : '否'}');
      if (body.isEmpty) return null;
      return _PageSnapshot(html: body, href: url, targetId: id);
    } on Exception catch (e) {
      await _log(onLog, '直抓分享页', '没抓到：${e.runtimeType}，交给浏览器那几条路');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 让原生 WebView 加载页面并带回材料（v1.6）。
  ///
  /// 关键变化：**不再把「HTML 里有没有 desc」当成读没读到的判据**。
  /// 实测那条路永远是空的（抖音把数据放在页面自己发的接口响应里，
  /// 未登录时接口还返回 200 + 0 字节）。现在原生会把页面请求到的作品 JSON 截下来，
  /// 这才是真正有料的信号。
  Future<_PageSnapshot?> _fetchHtml(
    String pageUrl,
    String targetId,
    LogSink? onLog, {
    bool mobile = false,
  }) async {
    await _log(onLog, '打开页面',
        '让手机内嵌浏览器打开 $pageUrl（同时截它自己请求的作品接口）');
    final sw = Stopwatch()..start();
    try {
      final dynamic raw = await _channel.invokeMethod<dynamic>(
        'fetchPage',
        <String, dynamic>{
          'url': pageUrl,
          'id': targetId,
          'mobile': mobile,
        },
      );
      if (raw == null) {
        await _log(onLog, '打开页面', '原生返回 null（WebView 可能没起来）');
        return null;
      }
      final s = raw.toString();
      if (s.isEmpty || s == 'null') {
        await _log(onLog, '打开页面',
            '原生返回空字符串 ${sw.elapsedMilliseconds}ms —— 页面没加载 / 20 秒硬超时');
        return null;
      }

      var html = '';
      var detail = '';
      var href = '';
      var title = '';
      var text = '';
      var videoSrc = '';
      var captcha = false;
      var hits = '';
      var trace = '';
      var res = '';
      try {
        final decoded = jsonDecode(s);
        if (decoded is Map) {
          html = (decoded['html'] ?? '').toString();
          detail = (decoded['detail'] ?? '').toString();
          href = (decoded['finalUrl'] ?? '').toString();
          title = (decoded['title'] ?? '').toString();
          text = (decoded['text'] ?? '').toString();
          videoSrc = (decoded['videoSrc'] ?? '').toString();
          captcha = decoded['captcha'] == true;
          hits = (decoded['hits'] ?? '').toString();
          trace = (decoded['trace'] ?? '').toString();
          res = (decoded['res'] ?? '').toString();
        } else if (decoded is String) {
          html = decoded;
        }
      } on Exception {
        html = s;
      }
      if (trace.isNotEmpty) {
        await _log(onLog, '打开页面', '浏览器轨迹：$trace');
      }
      if (href.isNotEmpty) {
        await _log(onLog, '打开页面', '浏览器最终停在：$href');
      }
      final snap = _PageSnapshot(
        html: html,
        detail: detail,
        href: href,
        title: title,
        text: text,
        videoSrc: videoSrc,
        captcha: captcha,
        hits: hits,
        res: res,
        targetId: targetId,
      );
      if (snap.isEmpty) {
        await _log(onLog, '打开页面',
            '什么都没带回来（${sw.elapsedMilliseconds}ms）：HTML 空、接口空、可见文字空');
        return null;
      }
      // 页面上常年挂着一个隐藏的验证 iframe，所以「有」不等于真被拦。
      // 判断标准只有一个：接口数据有没有回来。数据回来了就说明没被拦。
      final captchaNote = !captcha
          ? '无'
          : (detail.isNotEmpty
              ? '有（页面上挂着的，但接口数据已经拿到了，不是它挡的）'
              : '有 ←← 这次就是被它挡住的');
      await _log(onLog, '打开页面',
          'HTML ${html.length} 字｜作品接口数据 ${detail.length} 字'
          '｜页面标题 ${title.isEmpty ? '（空）' : '有'}'
          '｜可见文字 ${text.length} 字'
          '｜页面请求里的视频地址 ${res.isEmpty ? '没抓到' : '${res.split('\n').length} 条'}'
          '｜人机验证 $captchaNote'
          '｜耗时 ${sw.elapsedMilliseconds}ms');
      if (detail.isEmpty) {
        await _log(onLog, '打开页面',
            '没截到作品接口数据。截到过的接口：${hits.isEmpty ? '（一条都没截到）' : hits}');
      }
      return snap;
    } on PlatformException catch (e) {
      await _log(onLog, '失败',
          'WebView 调用报错：${e.code} ${e.message ?? '未知'}｜耗时 ${sw.elapsedMilliseconds}ms');
      throw DouyinReadException('页面没加载出来：${e.message ?? '未知原因'}');
    }
  }

  /// 只取页面 `<title>` 的前 80 字，日志和兜底菜名用。
  static String _titleSnippet(String html) {
    final m = RegExp(r'<title>([\s\S]*?)</title>', caseSensitive: false)
        .firstMatch(html);
    final t = (m?.group(1) ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return '（无 title）';
    return t.length > 80 ? t.substring(0, 80) : t;
  }

  /// 新版抖音页面的数据全在 `<script id="RENDER_DATA">` 里，而且内容是
  /// **URL 编码过的 JSON**（%7B%22app%22...），必须先 Uri.decodeComponent。
  /// 老的两条路（meta description / <source src>）在新页面上基本是空的，
  /// 所以这里按可靠性排序：RENDER_DATA → meta / og → <video src> → 裸正则兜底。
  Future<_PageData> _parsePage(_PageSnapshot snap, LogSink? onLog) async {
    final html = snap.html;
    var desc = '';
    var videoUrl = '';
    final images = <String>[];

    // ---- ⓿ 页面自己请求到的作品 JSON（v1.6 主路径）----
    // 抖音把 desc / play_addr 放在 `/aweme/v1/web/aweme/detail/` 的响应里，
    // HTML 里没有。原生钩子把那条响应截了下来，这里直接当 JSON 解。
    if (snap.detail.isNotEmpty) {
      try {
        dynamic root = jsonDecode(snap.detail);
        if (root is String) root = jsonDecode(root);
        dynamic aweme;
        final target = snap.targetId;
        if (root is Map) {
          aweme = root['aweme_detail'];
          final list = root['aweme_details'] ?? root['aweme_list'];
          // 只挑「这条作品」：页面在详情之前还会拉推荐流，里面有十几条别人的视频，
          // 取第一条就会把别人的菜谱当成你的（实测踩过）。
          if (aweme == null && list is List) {
            for (final item in list) {
              final aid = (item is Map ? (item['aweme_id'] ?? '') : '').toString();
              if (target.isEmpty || aid == target) {
                aweme = item;
                break;
              }
            }
          }
        }
        if (aweme is Map) {
          final gotId = (aweme['aweme_id'] ?? '').toString();
          if (target.isNotEmpty && gotId.isNotEmpty && gotId != target) {
            await _log(onLog, '解析接口',
                '截到的是别的作品（$gotId ≠ $target），丢掉重来');
            aweme = null;
          }
        }
        if (aweme is Map) {
          desc = (aweme['desc'] ?? '').toString().trim();
          final cands = <String>[];
          final v = aweme['video'];
          if (v is Map) {
            // bit_rate 是清晰度分档。抽帧只要 720p 就够 —— 1080p 原片常见 90MB，
            // 下它既慢又容易把低端机的内存吃满。
            final br = v['bit_rate'];
            if (br is List) {
              final maps = br.whereType<Map>().toList();
              int pref(Map m) {
                final g = (m['gear_name'] ?? '').toString();
                if (g.contains('720')) return 0;
                if (g.contains('1080')) return 1;
                return 2;
              }

              maps.sort((a, b) {
                final p = pref(a).compareTo(pref(b));
                if (p != 0) return p;
                final x = a['bit_rate'];
                final y = b['bit_rate'];
                final nx = x is num ? x.toDouble() : 0;
                final ny = y is num ? y.toDouble() : 0;
                return ny.compareTo(nx);
              });
              for (final it in maps) {
                cands.addAll(_urlsIn(it['play_addr']));
              }
            }
            for (final k in <String>[
              'play_addr_h264',
              'play_addr',
              'play_addr_265',
              'download_addr',
            ]) {
              cands.addAll(_urlsIn(v[k]));
            }
            // 只剩一个 uri 的情况：用抖音自己的播放接口按 uri 现取
            final pa = v['play_addr'];
            final uri = pa is Map ? (pa['uri'] ?? '').toString() : '';
            if (uri.isNotEmpty && !uri.startsWith('http')) {
              cands.add(
                  'https://www.douyin.com/aweme/v1/play/?video_id=$uri&ratio=1080p&line=0');
            }
            if (images.isEmpty) {
              final cov = _firstUrlIn(
                  v['cover'] ?? v['origin_cover'] ?? v['dynamic_cover']);
              if (cov.isNotEmpty) images.add(cov);
            }
          }
          // 字段名换了也不怕：整条作品 JSON 全树扫一遍像视频的地址
          cands.addAll(_videoUrlsIn(aweme));
          videoUrl = _pickBestVideo(cands);

          final imgs = aweme['images'];
          if (imgs is List) {
            for (final im in imgs) {
              final u = _firstUrlIn(im);
              if (u.isNotEmpty && !images.contains(u)) images.add(u);
            }
          }
          if (videoUrl.contains('playwm')) {
            videoUrl = videoUrl.replaceAll('playwm', 'play');
          }
          await _log(onLog, '解析接口',
              '作品 JSON 解出来了｜文案 ${desc.length} 字'
              '｜视频直链 ${videoUrl.isEmpty ? '没有' : '有'}'
              '｜图片 ${images.length} 张'
              '｜翻到疑似播放地址 ${cands.length} 条');
          if (videoUrl.isEmpty) {
            // 地址是空的，就必须让日志说清楚「空在哪」：字段名、play_addr 实际长什么样。
            // 没有这段，下一版还是只能瞎猜。
            await _log(onLog, '解析接口',
                '这条作品的字段：${aweme.keys.take(18).join(' / ')}');
            if (v is Map) {
              await _log(onLog, '解析接口',
                  'video 里的字段：${v.keys.take(26).join(' / ')}');
              try {
                final pa = v['play_addr'];
                await _log(onLog, '解析接口',
                    'play_addr 实际内容：${_snippet(jsonEncode(pa), 240)}');
              } catch (_) {}
            }
          } else {
            // 接口里素材已经齐了，就没必要再去翻 90 万字的 HTML：
            // 省几百毫秒，也免得多打一行「没有 RENDER_DATA」的干扰信息。
            return _PageData(
              desc: desc.trim(),
              videoUrl: videoUrl,
              images: images,
              pageTitle: snap.title.isNotEmpty ? snap.title : _titleSnippet(html),
            );
          }
        } else {
          await _log(onLog, '解析接口',
              '接口 JSON 里没有 aweme_detail（${snap.detail.length} 字），改看 HTML 兜底');
        }
      } on Exception catch (e) {
        await _log(onLog, '解析接口', '接口 JSON 解不动：${e.runtimeType}；改看 HTML 兜底');
      }
    } else if (snap.captcha) {
      await _log(onLog, '解析接口',
          '页面弹了人机验证，作品接口没被调用 —— 这就是这次读不到的真正原因');
    }

    // ---- ① RENDER_DATA：URL 编码的 JSON ----
    final rd = RegExp(
      r'<script[^>]*id="RENDER_DATA"[^>]*>([\s\S]*?)</script>',
      caseSensitive: false,
    ).firstMatch(html);
    if (rd != null) {
      final raw = rd.group(1) ?? '';
      String jsonText = raw;
      // 页面里是百分号编码；解一次再试，解不动就按原文当 JSON
      try {
        final decoded = Uri.decodeComponent(raw);
        if (decoded.trimLeft().startsWith('{')) jsonText = decoded;
      } on Exception {
        // 保持原样
      }
      dynamic root;
      try {
        root = jsonDecode(jsonText);
      } on Exception {
        root = null;
      }
      if (root != null) {
        _walkJson(root, (key, value) {
          if (value is String) {
            final v = value.trim();
            // 只认 desc 这一个键。以前把 title 键也当文案，结果抓到页面配置里的
            // "PC Tab" 这种脏数据 —— 看着「有内容」，其实什么都不是。
            if (key == 'desc' && v.length > desc.length) desc = v;
          }
          // 视频地址：play_addr / play_addr_h264 / download_addr 里的 url_list
          if (key == 'play_addr' ||
              key == 'play_addr_h264' ||
              key == 'play_addr_265' ||
              key == 'download_addr') {
            final u = _firstUrlIn(value);
            if (u.isNotEmpty && (videoUrl.isEmpty || u.contains('douyinvod'))) {
              videoUrl = u;
            }
          }
          // 图文作品：images[].url_list
          if (key == 'images' && value is List) {
            for (final item in value) {
              final u = _firstUrlIn(item);
              if (u.isNotEmpty && !images.contains(u)) images.add(u);
            }
          }
          if (key == 'cover' || key == 'origin_cover') {
            final u = _firstUrlIn(value);
            if (u.isNotEmpty && images.isEmpty) images.add(u);
          }
        });
        await _log(onLog, '解析页面',
            'RENDER_DATA 解码 ${jsonText.length} 字｜文案 ${desc.length} 字｜视频直链 ${videoUrl.isEmpty ? '没取到' : '取到了'}｜图片 ${images.length} 张');
      } else {
        await _log(onLog, '解析页面',
            'RENDER_DATA 找到了但 JSON 解不动（${raw.length} 字），改用 meta/标签兜底');
      }
    } else {
      await _log(onLog, '解析页面', '页面里没有 RENDER_DATA，改用 meta/标签兜底');
    }

    // ---- ①b window._ROUTER_DATA（官方分享页的 SSR 数据）----
    // iesdouyin.com/share/video/<id>/ 在**手机 UA** 下会把整条作品塞进
    // window._ROUTER_DATA 里 SSR 出来，里面有 video.play_addr.url_list。
    // 这条路和 PC 页的 detail 接口互不相干，等于多一个独立的取料口。
    if (videoUrl.isEmpty && html.contains('_ROUTER_DATA')) {
      final idx = html.indexOf('_ROUTER_DATA');
      final brace = idx < 0 ? -1 : html.indexOf('{', idx);
      final jsonText = brace < 0 ? '' : _balancedJson(html, brace);
      if (jsonText.isNotEmpty) {
        try {
          final root = jsonDecode(jsonText);
          _walkJson(root, (key, value) {
            if (value is String) {
              final s = value.trim();
              if (key == 'desc' && s.length > desc.length) desc = s;
            }
            if (key == 'play_addr' ||
                key == 'play_addr_h264' ||
                key == 'play_addr_265' ||
                key == 'download_addr') {
              final u = _firstUrlIn(value);
              if (u.isNotEmpty && videoUrl.isEmpty) videoUrl = u;
            }
            if (key == 'images' && value is List) {
              for (final item in value) {
                final u = _firstUrlIn(item);
                if (u.isNotEmpty && !images.contains(u)) images.add(u);
              }
            }
          });
          if (videoUrl.isEmpty) videoUrl = _pickBestVideo(_videoUrlsIn(root));
          if (videoUrl.contains('playwm')) {
            videoUrl = videoUrl.replaceAll('playwm', 'play');
          }
          await _log(onLog, '解析页面',
              'ROUTER_DATA 解出来了（${jsonText.length} 字）｜文案 ${desc.length} 字'
              '｜视频直链 ${videoUrl.isEmpty ? '没取到' : '取到了'}｜图片 ${images.length} 张');
        } on Exception {
          await _log(onLog, '解析页面',
              '_ROUTER_DATA 找到了但解不动（${jsonText.length} 字），改看 meta/标签兜底');
        }
      }
    }

    // ---- ② meta / og ----
    if (desc.isEmpty) {
      final m = _descReg.firstMatch(html);
      final og = RegExp(
        r'<meta[^>]*property="og:title"[^>]*content="([^"]*)"',
        caseSensitive: false,
      ).firstMatch(html);
      desc = _unescape(m?.group(1) ?? og?.group(1) ?? '').trim();
    }

    // ---- ③ 页面里的 video / source 标签（blob: 是假地址，别要）----
    if (videoUrl.isEmpty) {
      final v = RegExp(
        r'<video[^>]*\bsrc="([^"]+)"',
        caseSensitive: false,
      ).firstMatch(html);
      final s = _sourceReg.firstMatch(html);
      final cand = _unescape(v?.group(1) ?? s?.group(1) ?? '');
      if (cand.startsWith('http')) videoUrl = cand;
    }

    // ---- ④ 裸地址兜底：douyinvod 直链 ----
    if (videoUrl.isEmpty) {
      final m = RegExp(
        r'https?://[^\s"\\]*douyinvod[^\s"\\]+',
        caseSensitive: false,
      ).firstMatch(html);
      if (m != null) videoUrl = _unescape(m.group(0)!);
    }

    // ---- ⑤ 页面自己请求过的视频（v1.7）----
    // 接口只给文案、不给播放地址（风控降级）时，只要页面真的在播，
    // 视频分片请求就留在 performance 里 —— 从这儿捡一条真地址。
    if (videoUrl.isEmpty && snap.res.isNotEmpty) {
      final list = snap.res
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      final u = _pickBestVideo(list);
      if (u.isNotEmpty) {
        videoUrl = u;
        await _log(onLog, '解析页面',
            '接口没给播放地址，但从页面自己的网络请求里捡到 ${list.length} 条视频地址，用其中一条');
      } else {
        await _log(onLog, '解析页面',
            '页面请求里有 ${list.length} 条记录，但没有一条像视频');
      }
    }

    // 播放地址里带 playwm 的是带水印版，换成 play 拿无水印
    if (videoUrl.contains('playwm')) {
      videoUrl = videoUrl.replaceAll('playwm', 'play');
    }

    return _PageData(
      desc: desc.trim(),
      videoUrl: videoUrl,
      images: images,
      pageTitle: snap.title.isNotEmpty ? snap.title : _titleSnippet(html),
    );
  }

  /// 深度遍历 JSON，把每个 key/value 交给回调（只认前 14 层，防止异常深的树）。
  ///
  /// 【v1.7 修的关键 bug】数组里的**字符串元素**以前根本没被回调过。
  /// 抖音的地址一律长这样：`{"play_addr":{"url_list":["https://..."]}}` ——
  /// URL 在数组里，于是「翻遍了 JSON 却一条地址都找不到」，
  /// 1.6 版日志里「文案有了、视频直链没有、图片 0 张」全是这个原因，跟平台无关。
  static void _walkJson(
    dynamic node,
    void Function(String key, dynamic value) visit, {
    int depth = 0,
  }) {
    if (depth > 14) return;
    if (node is Map) {
      node.forEach((k, v) {
        visit(k.toString(), v);
        _walkJson(v, visit, depth: depth + 1);
      });
    } else if (node is List) {
      for (final v in node) {
        if (v is String) {
          visit('', v); // 数组里的字符串也要交出去
        } else {
          _walkJson(v, visit, depth: depth + 1);
        }
      }
    }
  }

  /// 从一个 {url_list:[...]} 形状的节点里取最合适的一条 http 地址。
  static String _firstUrlIn(dynamic node) {
    String? best;
    _walkJson(node, (key, value) {
      if (value is String && value.startsWith('http')) {
        best ??= value;
        // 优先取无水印 / 抖音自家 CDN
        if (value.contains('douyinvod')) best = value;
      }
    });
    return best ?? '';
  }

  /// 把节点下所有 http 地址按出现顺序收集起来（同一个地址只留一份）。
  static List<String> _urlsIn(dynamic node) {
    final out = <String>[];
    _walkJson(node, (key, value) {
      if (value is String && value.startsWith('http') && !out.contains(value)) {
        out.add(value);
      }
    });
    return out;
  }

  /// 看起来像**视频**、而不像图片的地址。
  /// 抖音的图在 douyinpic / byteimg，视频在 douyinvod / video/tos —— 域名就能分开。
  static final RegExp _videoish = RegExp(
    r'douyinvod|/video/tos/|aweme/v1/play|\.mp4',
    caseSensitive: false,
  );
  static final RegExp _imageish = RegExp(
    r'douyinpic|byteimg|douyinstatic|pstatp|\.(?:jpe?g|png|webp|heic)',
    caseSensitive: false,
  );

  static bool _looksVideo(String u) {
    if (!u.startsWith('http')) return false;
    final noQuery = u.split('?').first;
    return _videoish.hasMatch(u) && !_imageish.hasMatch(noQuery);
  }

  /// 从一堆候选里挑最可能能播的那条：无水印 CDN 直链优先，带水印的垫底。
  static String _pickBestVideo(List<String> cands) {
    String? best;
    var bestScore = -1;
    for (final u in cands) {
      if (!_looksVideo(u)) continue;
      var score = 0;
      if (u.contains('douyinvod')) score += 4;
      if (u.contains('/video/tos/')) score += 4;
      if (u.contains('/aweme/v1/play')) score += 1;
      if (u.contains('playwm')) score -= 3;
      if (score > bestScore) {
        bestScore = score;
        best = u;
      }
    }
    return best ?? '';
  }

  /// 整条作品 JSON 里翻「像视频」的地址（字段名变了也能命中）。
  static List<String> _videoUrlsIn(dynamic node) {
    final out = <String>[];
    _walkJson(node, (key, value) {
      if (value is String && _looksVideo(value) && !out.contains(value)) {
        out.add(value);
      }
    });
    return out;
  }

  /// 日志里截一段带上下文，不要把整个 JSON 倒进日志。
  static String _snippet(String s, int max) {
    if (s.length <= max) return s;
    return '${s.substring(0, max)}…（共 ${s.length} 字）';
  }

  /// 从 [start] 处的 `{` 开始按括号配对切出完整 JSON。
  /// 用正则切到 `</script>` 会被字符串里的 `}` 提前截断。
  static String _balancedJson(String s, int start) {
    if (start < 0 || start >= s.length || s[start] != '{') return '';
    var depth = 0;
    var inStr = false;
    var esc = false;
    for (var i = start; i < s.length; i++) {
      final c = s[i];
      if (inStr) {
        if (esc) {
          esc = false;
        } else if (c == r'\') {
          esc = true;
        } else if (c == '"') {
          inStr = false;
        }
        continue;
      }
      if (c == '"') {
        inStr = true;
      } else if (c == '{' || c == '[') {
        depth++;
      } else if (c == '}' || c == ']') {
        depth--;
        if (depth == 0) return s.substring(start, i + 1);
      }
    }
    return '';
  }

  /// 把图文作品里的图下载下来（最多 8 张），当长图的「实拍参考」。
  /// 这一步就是「App 自己找图」：用户只贴链接，不需要自己截图。
  Future<List<Uint8List>> _downloadImages(
      List<String> urls, LogSink? onLog) async {
    final out = <Uint8List>[];
    final seen = <String>{};
    for (final u in urls) {
      if (out.length >= 8) break;
      final key = u.split('?').first;
      if (!seen.add(key)) continue;
      try {
        final resp = await http.get(
          Uri.parse(u),
          headers: <String, String>{
            'User-Agent': ua,
            'Referer': 'https://www.douyin.com/',
          },
        ).timeout(const Duration(seconds: 30));
        if (resp.statusCode == 200 && resp.bodyBytes.length > 2048) {
          out.add(resp.bodyBytes);
        }
      } on Exception catch (e) {
        await _log(onLog, '取图', '单张失败（跳过）：${e.runtimeType}');
      }
    }
    await _log(onLog, '取图', '候选 ${urls.length} 张｜成功下载 ${out.length} 张');
    return out;
  }

  /// 把视频下到临时文件。抖音、小红书共用这一份。
  ///
  /// [referer] 必须按平台给：小红书 CDN 拿到抖音的 Referer 会当成盗链。
  /// v1.17：只把视频直链取回来，不跑「抽帧 / 听语音 / AI 整理」那些。
  ///
  /// 用途：菜谱早就做好了，但当初存视频那一步失败（转码被超时掐断），
  /// 用户不想为了一个视频把整道菜重做一遍 —— 那就照原链接再下一次。
  /// 入口顺序和 read() 完全一样：直抓分享页 → PC 作品页 → 手机分享页 → 短链，
  /// 拿到直链就收工。风控是偶发的，所以整体再重试一轮。
  Future<String> fetchVideoUrl(String rawUrl, LogSink? onLog) async {
    final url = extractUrl(rawUrl);
    if (url.isEmpty) throw const DouyinReadException('这道菜没存来源链接');
    if (!url.contains('douyin') && !url.contains('iesdouyin')) {
      throw const DouyinReadException('这条链接不是抖音的');
    }
    final id = await _resolveId(url, onLog);
    if (id != null) {
      final direct = await _fetchSharePageDirect(id, onLog);
      if (direct != null) {
        final p = await _parsePage(direct, onLog);
        if (p.videoUrl.isNotEmpty) return p.videoUrl;
      }
    }
    final candidates = <Map<String, Object>>[
      if (id != null)
        <String, Object>{'url': 'https://www.douyin.com/video/$id/', 'mobile': false},
      if (id != null)
        <String, Object>{
          'url': 'https://www.iesdouyin.com/share/video/$id/',
          'mobile': true,
        },
      <String, Object>{'url': url, 'mobile': true},
    ];
    for (var round = 0; round < 2; round++) {
      for (final c in candidates) {
        final snap = await _fetchHtml(
          c['url'].toString(),
          id ?? '',
          onLog,
          mobile: c['mobile'] == true,
        );
        if (snap == null || snap.isEmpty) continue;
        final p = await _parsePage(snap, onLog);
        if (p.videoUrl.isNotEmpty) return p.videoUrl;
      }
      if (round == 0) {
        await _log(onLog, '补视频', '第一轮没取到，隔 1.5 秒再试一轮');
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }
    }
    throw const DouyinReadException('没从这条链接里取到视频（可能本来就是图文笔记，或者被风控挡了）');
  }

  /// 同一条视频「正在下」的 Future，按作品 id 索引。
  ///
  /// 用户在新建页着急点了两下、或从两个入口同时进来时，会并发跑两遍整条链路 ——
  /// 日志里就是两条 [下载视频] 同时开始、各自吃掉 60MB 流量。这里让第二次直接
  /// 复用第一次的下载结果，不再重复拉。
  static final Map<String, Future<String>> _videoInflight =
      <String, Future<String>>{};

  /// 视频缓存目录：私有目录，覆盖安装不清，专治「同一条视频每次重跑都重下」。
  ///
  /// 用户实测日志：同一条 59.7MB 的抖音原片在一次使用里被下了 4 遍
  /// （14:35、14:36、14:37 各一次，14:37 还并发下了两遍），白烧 200MB 流量。
  Future<Directory> _videoCacheDir() async {
    Directory base;
    try {
      base = await getApplicationSupportDirectory();
    } catch (_) {
      base = await getTemporaryDirectory();
    }
    final d = Directory('${base.path}/video_cache');
    if (!d.existsSync()) d.createSync(recursive: true);
    // v1.49：读取缓存放同一个支持目录，key 用视频文件大小+mtime。
    FrameCache.getAppSupportDir = () async => base;
    return d;
  }

  /// 只留最近 [keep] 条视频，其余删掉，避免缓存把手机撑爆。
  Future<void> _pruneVideoCache(Directory dir, {int keep = 4}) async {
    try {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.mp4'))
          .toList()
        ..sort((a, b) =>
            b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      for (final f in files.skip(keep)) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<String> downloadVideo(
    String url,
    LogSink? onLog, {
    String referer = 'https://www.douyin.com/',
    String cacheKey = '',
  }) async {
    if (cacheKey.isEmpty) return _downloadVideo(url, onLog, referer: referer);
    // 并发去重：同一条视频同时只跑一次下载
    final running = _videoInflight[cacheKey];
    if (running != null) {
      await _log(onLog, '下载视频', '同一条视频正在下载中，等它下完直接复用');
      return running;
    }
    final fut = _downloadVideo(url, onLog, referer: referer, cacheKey: cacheKey);
    _videoInflight[cacheKey] = fut;
    try {
      return await fut;
    } finally {
      _videoInflight.remove(cacheKey);
    }
  }

  Future<String> _downloadVideo(
    String url,
    LogSink? onLog, {
    String referer = 'https://www.douyin.com/',
    String cacheKey = '',
  }) async {
    // ① 已经有这条视频的完整文件 → 直接用，绝不重新下载
    if (cacheKey.isNotEmpty) {
      try {
        final dir = await _videoCacheDir();
        final cached = File('${dir.path}/$cacheKey.mp4');
        if (cached.existsSync() && cached.lengthSync() > 65536) {
          await _log(
              onLog,
              '下载视频',
              '这条视频本机已经有了（${(cached.lengthSync() / 1048576).toStringAsFixed(1)} MB）'
              '，跳过下载，直接用原片');
          return cached.path;
        }
      } catch (_) {}
    }

    await _log(onLog, '下载视频',
        '开始下载｜地址前 120 字：${url.substring(0, url.length > 120 ? 120 : url.length)}');
    final sw = Stopwatch()..start();
    final client = http.Client();
    IOSink? sink;
    File? partFile;
    File? finalFile;
    try {
      final req = http.Request('GET', Uri.parse(url));
      req.headers['User-Agent'] = ua;
      req.headers['Referer'] = referer;
      final resp = await client
          .send(req)
          .timeout(const Duration(seconds: 30));
      await _log(onLog, '下载视频',
          'HTTP ${resp.statusCode}｜预计 ${resp.contentLength ?? -1} 字节');

      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw DouyinReadException('视频下载失败（${resp.statusCode}）');
      }

      final File f;
      if (cacheKey.isNotEmpty) {
        // 写进缓存目录：先写 .part，完整了再改名，半截文件不会被下次误复用
        final dir = await _videoCacheDir();
        finalFile = File('${dir.path}/$cacheKey.mp4');
        partFile = File('${finalFile.path}.part');
        f = partFile;
        if (partFile.existsSync()) {
          try {
            partFile.deleteSync();
          } catch (_) {}
        }
      } else {
        final dir = await getTemporaryDirectory();
        f = File('${dir.path}/video_${DateTime.now().millisecondsSinceEpoch}.mp4');
      }
      sink = f.openWrite();

      // 边下边写盘，不把整段视频堆在内存里：
      // 抖音原片常见 80~100MB，一次性 read 会在低端机上直接 OOM。
      var got = 0;
      await for (final chunk in resp.stream.timeout(
        const Duration(seconds: 40),
        onTimeout: (s) => s.addError(
            TimeoutException('下载中断（已收 $got 字节）')),
      )) {
        sink.add(chunk);
        got += chunk.length;
      }
      await sink.flush();
      await sink.close();
      sink = null;

      await _log(onLog, '下载视频',
          '存到本地 ${(got / 1048576).toStringAsFixed(1)} MB｜${sw.elapsedMilliseconds}ms');
      if (got < 65536) {
        // 小于 64KB 基本是错误页/空响应，别拿它去抽帧
        throw DouyinReadException('视频只下到 ${(got / 1024).toStringAsFixed(0)} KB，不是有效视频');
      }
      // 缓存模式：下全了才把 .part 改名成正式文件，下次直接用
      if (partFile != null && finalFile != null) {
        try {
          if (finalFile.existsSync()) finalFile.deleteSync();
          partFile.renameSync(finalFile.path);
          await _log(onLog, '下载视频', '已存进本机视频缓存，下次同一条视频不再下载');
          await _pruneVideoCache(partFile.parent);
          return finalFile.path;
        } catch (e) {
          await _log(onLog, '下载视频', '存缓存失败（不影响这次整理）：$e');
          return partFile.path;
        }
      }
      return f.path;
    } on DouyinReadException catch (e) {
      await _log(onLog, '失败', '视频下载被拒：${e.message}');
      rethrow;
    } on Exception catch (e) {
      await _log(onLog, '失败', '视频下载异常：${e.runtimeType} $e');
      throw DouyinReadException('视频下载失败：$e');
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close();
    }
  }

  Future<List<VideoFrame>> extractFrames(
      String path, List<int> seconds, LogSink? onLog) async {
    try {
      final dynamic raw = await _channel.invokeMethod<dynamic>(
        'extractFrames',
        <String, dynamic>{
          'path': path,
          'seconds': seconds,
          // 【v1.44】按 2026-11-15 真机日志再调采样。
          //
          // 逐行诊断（tool/diagnose_ocr.py）的结论：
          //   · 51 秒视频：41 帧、1.1 秒一帧 —— 采样够密，核心步骤全读到了，
          //     错的是「1勺老迪」这类小字调料行（那是 OCR 能力问题，不是采样）；
          //   · 427 秒视频：90 帧、4.7 秒一帧 —— 字幕读出来几乎全是乱码，
          //     一句只闪 2 秒的字幕被整段跨过去；
          //   · 324 秒视频：90 帧、3.6 秒一帧，17 条调料行里同一句出现 3~4 个错版。
          //
          // 所以长视频必须多采。90→130 帧、1.2 秒→1.0 秒，长视频降到约 3.3 秒一帧；
          // 短视频受 minInterval 约束，只从 41 帧增到约 51 帧，多花一两秒。
          // 代价诚实写进日志：427 秒视频的 OCR 会从约 14 秒涨到约 21 秒，
          // 但换回来的是原本整段丢掉的字幕 —— 那部分联网 OCR 也救不了，
          // 因为根本没有图送进去。
          'count': 0,
          'maxFrames': 130,
          'minIntervalMs': 1000,
          // 900 宽：1080p 竖屏的字幕缩到 720 后只剩十几像素，ML Kit 开始认错偏旁
          'width': 900,
        },
      );
      final frames = <VideoFrame>[];
      if (raw is Map) {
        final list = (raw['frames'] as List?) ?? const <dynamic>[];
        final meta = (raw['meta'] as List?) ?? const <dynamic>[];
        for (var i = 0; i < list.length; i++) {
          final m = i < meta.length && meta[i] is Map
              ? Map<String, dynamic>.from(meta[i] as Map)
              : <String, dynamic>{};
          // v1.49：原生直接给二进制 Uint8List，不再走 base64。
          // 保留 base64兜底：混版本（新 Dart + 旧原生）时不至于全军覆没。
          final rawFrame = list[i];
          final bytes = rawFrame is Uint8List
              ? rawFrame
              : base64Decode(rawFrame.toString());
          frames.add(VideoFrame(
            jpeg: bytes,
            sec: (m['t'] as num?)?.toInt() ?? 0,
            sharp: (m['sharp'] as num?)?.toDouble() ?? 0,
            bright: (m['bright'] as num?)?.toDouble() ?? 128,
            hash: (m['hash'] ?? '').toString(),
          ));
        }
      }
      final usable = frames.where((f) => f.isUsable).length;
      final span = frames.isEmpty
          ? 0
          : frames.map((f) => f.sec).reduce((a, b) => a > b ? a : b);
      final gap = frames.length > 1 ? span / (frames.length - 1) : 0.0;
      await _log(onLog, '抽帧',
          '实际抽出 $frames.length 帧｜其中 $usable 帧不是黑屏/糊帧'
          '｜平均 ${gap.toStringAsFixed(1)} 秒一帧（共 $span 秒）'
          '${frames.isEmpty ? '（0 帧通常表示视频解码失败或直链已失效）' : ''}');
      return frames;
    } on PlatformException catch (e) {
      await _log(onLog, '失败', '抽帧调用报错：${e.code} ${e.message ?? '未知'}');
      throw DouyinReadException('抽帧失败：${e.message ?? '未知原因'}');
    }
  }

  /// 把视频里的讲解听成文字（原生 sherpa-onnx + Paraformer，离线）。
  /// 失败不算错误：主流程还有画面字幕兜底，只是少一份交叉校验的材料。
  ///
  /// v1.15：返回值从「一个字符串」变成「文字 + 这段音频到底有没有人说话」。
  /// 起因是用户的一条 64 秒视频，日志写「只听出 4 个字 —— 机器没听清这段口音」，
  /// 看着像识别不准。把音频导出来在电脑上跑三个引擎，全认不出字，
  /// 那条视频压根没人讲话，只有一条从头响到尾的 BGM。冤枉了机器也误导了人。
  /// v1.24：模型已移出安装包，首次用要先下载到手机。缺模型时不打断整理流程
  /// （画面字幕仍然兜底），但记一条醒目日志并打上标志，让界面提示用户去下载语音包。
  static bool asrModelWasMissing = false;

  Future<String> transcribe(String path, LogSink? onLog) async {
    try {
      final ready = await AsrModelService().isReady();
      if (!ready) {
        asrModelWasMissing = true;
        await _log(onLog, '语音识别',
            '语音包还没下载到手机（安装包已瘦身，模型改为按需下载）。'
            '这道菜已用画面字幕整理，不影响使用；连 WiFi 后到「设置 → 语音包」下载，'
            '以后识别更准、且下过一次永久免下');
        return '';
      }
      final sw = Stopwatch()..start();
      // v1.43：原来是 240 秒硬等，真机日志两次跑满超时、0 产出。
      // 现在给一个短预算，到点就放弃这一路，字幕结果照常出。
      Map<String, dynamic>? res;
      try {
        res = await _channel
            .invokeMapMethod<String, dynamic>(
              'transcribeAudio',
              <String, dynamic>{'path': path},
            )
            .timeout(Duration(seconds: AsrPolicy.budgetSeconds));
      } on TimeoutException {
        await _log(onLog, '语音识别',
            '口播超过 ${AsrPolicy.budgetSeconds} 秒没出结果，放弃这一路；'
            '画面字幕已经够用，不等了');
        return '';
      }
      final text = ((res?['text'] as String?) ?? '').trim();
      final seconds = (res?['seconds'] as num?)?.toDouble() ?? 0;
      final pause = (res?['pauseRatio'] as num?)?.toDouble() ?? 0;
      final std = (res?['energyStd'] as num?)?.toDouble() ?? 0;
      final truncated = (res?['truncated'] as bool?) ?? false;
      final han = text.replaceAll(RegExp(r'[^\u4e00-\u9fa5]'), '').length;
      if (truncated) {
        await _log(onLog, '语音识别',
            '视频超过 10 分钟，只听前 10 分钟（后面的基本是过程和摆盘，配料都在开头）');
      }

      if (han == 0 && pause < 0.08 && std < 12) {
        // 人讲话必然一顿一顿的：说一句、换口气、再说。音乐是从头响到尾一个音量。
        // 实测：纯 BGM 视频 停顿 3.0% / 波动 5.8dB；真人朗读 停顿 34.8% / 波动 42.3dB。
        await _log(onLog, '语音识别',
            '这段 ${seconds.round()} 秒从头到尾音量几乎没起伏'
            '（停顿只占 ${(pause * 100).round()}%），是纯背景音乐、没人讲话。'
            '语音这块没东西可听，内容全部来自画面字幕');
        return '';
      }
      if (han == 0) {
        await _log(onLog, '语音识别',
            '听了 ${seconds.round()} 秒，一个字都没听出来'
            '（音频有说话的起伏，但太糊或口音太重）');
        return '';
      }

      await _log(onLog, '语音识别',
          '听了 ${seconds.round()} 秒，识别出 $han 个汉字'
          '｜耗时 ${sw.elapsedMilliseconds}ms（Paraformer 离线模型，'
          '实测错字 2%~5%，比原来那套低一个数量级）');

      // 同音字兜底：引擎再准，「梨 / 尖青椒 / 去根」这种冷门食材名还是会错。
      // 不改的话 AI 会把「煎青椒」当菜名、把「离」当量词，直接漏掉这两样。
      final hits = <String>[];
      final fixed = AsrFixer.fix(text, hits: hits);
      if (hits.isNotEmpty) {
        await _log(onLog, '语音纠错',
            '按读音改回 ${hits.length} 处：${hits.join('、')}');
      }

      await _log(onLog, '语音原文',
          fixed.substring(0, fixed.length > 1200 ? 1200 : fixed.length));
      return fixed;
    } on Exception catch (e) {
      await _log(onLog, '语音识别', '没跑成，不影响主流程：$e');
      return '';
    }
  }

  Future<String> ocrFrames(
    List<VideoFrame> frames,
    LogSink? onLog, {
    List<SubLine>? outLines,
    Future<String?> Function(Uint8List jpeg)? cloudOcr,
  }) async {
    if (frames.isEmpty) return '';
    try {
      // 只把「不是黑屏/糊帧」的送 OCR：省时间，也少一堆垃圾行
      final targets = frames.where((f) => f.isUsable).toList();
      if (targets.isEmpty) return '';
      // v1.49：Uint8List 走 StandardMessageCodec 的二进制通道，
      // 不再 base64 编码一遍（130 帧约省 35MB 字符串 + 两侧各一次编解码）。
      final sw = Stopwatch()..start();
      final res = await _channel.invokeMethod<List<dynamic>>(
        'ocrFrames',
        <String, dynamic>{'frames': targets.map((f) => f.jpeg).toList()},
      );
      // 每帧现在是一段多行文本（原生已按「先上后下、同高度从左到右」排过序）。
      // 这里**按行**去重，而不是把整帧压成一行 —— 一屏里往往既有第 3 步的字幕、
      // 又有配方表的残留，压成一行会把两件事糊在一起，也会白白丢掉帧与帧之间的差异。
      final seen = <String>{};
      final collected = <SubLine>[]; // 先全收下来（含重复），用来认水印
      var rawLines = 0;
      var cloudUsed = 0;
      final texts = (res ?? <dynamic>[]);
      for (var i = 0; i < targets.length; i++) {
        var raw = i < texts.length ? texts[i].toString() : '';
        // v1.44：只对「本地明显没认出来的调料行」花云端额度，且有硬上限。
        // 云端失败返回 null，静默用本地结果，不影响整理流程。
        final local = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (cloudOcr != null &&
            cloudUsed < CloudOcr.maxRetriesPerVideo &&
            CloudOcr.needsCloudRetry(local)) {
          final cloud = await cloudOcr(targets[i].jpeg);
          if (cloud != null && cloud.trim().isNotEmpty) {
            raw = cloud;
            cloudUsed++;
          }
        }
        // 顺手把这一帧的文字留在帧上，后面给每一步配图时要按文字相似度匹配
        targets[i].text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
        for (final piece in raw.split('\n')) {
          final line = piece.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
          if (line.length < 2) continue;
          rawLines++;
          collected.add(SubLine(targets[i].sec, line));
        }
      }

      if (cloudUsed > 0) {
        await _log(onLog, '云端 OCR',
            '低置信调料行补识别 $cloudUsed 帧（上限 ${CloudOcr.maxRetriesPerVideo}）');
      }

      // 【v1.13】去账号水印。
      //
      // 实测：一条 62 秒的小红书视频，「麦香厨房」在字幕里出现了 8 次
      // （画面上那个号名水印被每帧都读了一遍）。这些字既不是配方，
      // 又占掉 AI 输入的很大一截，还容易把菜名带偏成「麦香厨房」。
      //
      // 判定很保守：**同一行出现 ≥3 次 + 长度 ≤10 + 一个烹饪/食材字都没有**，
      // 三条同时满足才算水印。「热锅凉油」「下五花肉」这种重复出现的正经字幕
      // 因为含「锅」「油」「肉」，一律保留。
      final freq = <String, int>{};
      for (final l in collected) {
        freq[l.text] = (freq[l.text] ?? 0) + 1;
      }

      final buf = StringBuffer();
      var dropped = 0;
      // 先按「精确 + 水印」筛一遍，再对留下的做近似去重（两字组相似度）
      final candidates = <SubLine>[];
      for (final l in collected) {
        if (isWatermark(l.text, freq[l.text] ?? 1)) {
          dropped++;
          continue;
        }
        if (!seen.add(l.text)) continue;
        candidates.add(l);
      }
      // 【v1.27】近似重复也要压掉：同一句配料表被 OCR 读成十几个错版，
      // 精确去重认不出，会让步骤切碎、用料抽乱。详见 TextSim.nearDupMask。
      //
      // 【v1.29 改法】压掉 ≠ 丢掉。以前这一步是「只留最先出现的那条，其余扔了」，
      // 等于把同一句话的 5~10 次独立 OCR 采样白扔 9 次。而 OCR 的错是**随机的**
      // （这一帧把 g 认成 8，下一帧就认对了），正确答案在多数帧里是稳定的 ——
      // 少数服从多数就能把错的那个字压下去。现在改成：先聚簇，再把一簇里
      // 所有错版逐位投票合成一条。这一步跟大模型没有半点关系，
      // 是「重新把丢掉的信息捡回来」，比事后猜准得多。
      final ids = SubtitleFuse.clusterIds(
        candidates.map((e) => e.text).toList(),
        secs: candidates.map((e) => e.sec).toList(),
      );
      final common = SubtitleFuse.charFreq(candidates.map((e) => e.text).toList());
      final order = <int>[];
      final firstSec = <int, int>{};
      final groupTexts = <int, List<String>>{};
      for (var i = 0; i < candidates.length; i++) {
        final id = ids[i];
        if (!groupTexts.containsKey(id)) {
          order.add(id);
          firstSec[id] = candidates[i].sec;
          groupTexts[id] = <String>[];
        }
        groupTexts[id]!.add(candidates[i].text);
      }

      final fused = <SubLine>[];
      var mergedAway = 0;
      for (final id in order) {
        final vs = groupTexts[id]!;
        mergedAway += vs.length - 1;
        fused.add(SubLine(
            firstSec[id]!, SubtitleFuse.fuseCluster(vs, common: common)));
      }

      // 单位归一：OCR 把数字后面的 g 读成 8/A/p/元，是**系统性**错误，
      // 投票压不掉（每帧都错成一样）。但可以整份字幕一起判断：
      // 如果这份菜谱里「数字+g」出现得够多，那「数字+8」的 8 就该是 g。
      final unitHits = <String>[];
      final unitFixed = SubtitleClean.normalizeUnits(
        fused.map((e) => e.text).toList(),
        hits: unitHits,
      );
      // v1.44：小字调料行先把数字后的「河/句/勾」按证据改回「勺」
      //（日志里「1河老抽」应是「1勺老抽」），再走规范词表。
      final spoonHits = <String>[];
      final spoonFixed =
          SubtitleClean.normalizeSpoonUnits(unitFixed, hits: spoonHits);
      // v1.43.1：单位归一之后再走一遍规范词表。只在整词精确命中时改，
      // 例如日志里「1勺老迪」→「1勺老抽」、「1勺耗油」→「1勺蚝油」。
      final lexHits = <String>[];
      final texts2 = KitchenLexicon.normalizeLines(spoonFixed, hits: lexHits);

      for (var i = 0; i < fused.length; i++) {
        buf.writeln(texts2[i]);
        // 这一行出现在第几秒，后面配图要用
        outLines?.add(SubLine(fused[i].sec, texts2[i]));
      }
      if (dropped > 0) {
        await _log(onLog, '字幕识别', '去掉账号水印 $dropped 行');
      }
      if (mergedAway > 0) {
        await _log(
            onLog,
            '字幕融合',
            '把 $mergedAway 条 OCR 错版按多数投票合成——'
            '同一句被读成好几个版本时，不是挑一条，而是逐字取多数，'
            '认错的那个字会被别的版本纠正回来（最终 ${fused.length} 句）');
      }
      for (final h in unitHits) {
        await _log(onLog, '量词修正', h);
      }
      for (final h in spoonHits) {
        await _log(onLog, '勺字修正', h);
      }
      for (final h in lexHits) {
        await _log(onLog, '词表纠正', h);
      }
      final frameCount = texts.length;
      final lineCount = fused.length;
      await _log(onLog, '字幕识别',
          'ML Kit 中文 OCR 返回 $frameCount 帧'
          '｜读到 $rawLines 行｜去重后 $lineCount 行'
          '｜耗时 ${sw.elapsedMilliseconds}ms');
      final text = buf.toString().trim();
      await _log(onLog, '字幕识别',
          '字幕共 ${text.length} 字'
          '${text.isEmpty ? ' ←← 一个字都没认出来，后面整理器就没有配方可用' : ''}');
      // 原文是诊断关键，完整留出前 1200 字
      await _log(onLog, '字幕原文',
          text.isEmpty ? '（空）' : text.substring(0, text.length > 1200 ? 1200 : text.length));
      return text;
    } on PlatformException catch (e) {
      await _log(onLog, '失败', 'OCR 调用报错：${e.code} ${e.message ?? '未知'}');
      throw DouyinReadException('字幕识别失败：${e.message ?? '未知原因'}');
    }
  }

  /// 从抽出来的帧里挑「能看的图」：去黑屏、去糊帧、去重复画面。
  ///
  /// 以前是「均匀挑 6 张」，于是黑屏、转场、糊成一团的手部特写都会被塞进长图 ——
  /// 用户说的「照片截取的对应不上，有的是无效照片」就是这个。
  List<VideoFrame> pickUsable(List<VideoFrame> frames, LogSink? onLog) {
    final ok = frames.where((f) => f.isUsable).toList();
    if (ok.isEmpty) return <VideoFrame>[];
    // 清晰度按中位数卡一道：同一支视频里糊帧的分数往往只有清晰帧的几十分之一
    final sharpSorted = ok.map((f) => f.sharp).toList()..sort();
    final median = sharpSorted[sharpSorted.length ~/ 2];
    final floor = median * 0.28;
    final kept = <VideoFrame>[];
    for (final f in ok) {
      if (f.sharp < floor) continue;
      // 跟上一张留下的比：画面几乎一样就跳过（定格讲解、字幕没变的那种）
      if (kept.isNotEmpty && _hamming(f.hash, kept.last.hash) <= 4) continue;
      kept.add(f);
    }
    return kept;
  }

  /// 从列表里均匀取 n 个（顺序不变，不重复）。
  static List<T> spread<T>(List<T> src, int n) {
    if (src.isEmpty) return <T>[];
    if (src.length <= n) return List<T>.from(src);
    final out = <T>[];
    for (var i = 0; i < n; i++) {
      final idx = (src.length * (i + 0.5) / n).floor().clamp(0, src.length - 1);
      if (out.isEmpty || !identical(out.last, src[idx])) out.add(src[idx]);
    }
    return out;
  }

  /// 两个 8x8 均值哈希的汉明距离，用来判断「这两帧是不是同一个画面」。
  static int _hamming(String a, String b) {
    if (a.length != b.length || a.isEmpty) return 99;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      final x = int.tryParse(a[i], radix: 16) ?? 0;
      final y = int.tryParse(b[i], radix: 16) ?? 0;
      var v = x ^ y;
      while (v != 0) {
        d += v & 1;
        v >>= 1;
      }
    }
    return d;
  }

  /// 打开 App 内抖音登录页（只需一次）。
  /// 登录成功后 cookie 留在系统 WebView 里，之后打开作品页就是已登录状态，
  /// 平台才会把作品数据返回给我们 —— 这是「只贴链接」能长期成立的前提。
  /// 让人在网页里亲眼看一眼（顺便完成人机验证）。
  /// 有些作品只对「真人操作过的网页会话」放行，这一步是留给用户的活口。
  Future<bool> openPage(String url, LogSink? onLog) async {
    await _log(onLog, '验证', '打开网页让人确认：$url');
    try {
      final ok = await _channel.invokeMethod<bool>(
            'openPage',
            <String, dynamic>{'url': url},
          ) ??
          false;
      await _log(onLog, '验证', ok ? '用户看完回来了，准备重读' : '用户没看完就退出');
      return ok;
    } on PlatformException catch (e) {
      await _log(onLog, '失败', '网页打不开：${e.code} ${e.message ?? '未知'}');
      return false;
    }
  }

  Future<bool> openLogin(LogSink? onLog) async {
    await _log(onLog, '登录', '打开抖音登录页（只需一次），等待用户完成登录…');
    try {
      final ok = await _channel.invokeMethod<bool>('openDouyinLogin') ?? false;
      await _log(onLog, '登录', ok ? '用户确认已登录｜cookie 已落盘' : '用户取消了登录');
      return ok;
    } on PlatformException catch (e) {
      await _log(onLog, '失败', '登录页打不开：${e.code} ${e.message ?? '未知'}');
      return false;
    }
  }

  /// 本机是否已经登录过抖音（只判断 cookie 里有没有 sessionid，不上传任何东西）。
  /// v1.16：把原视频压一遍存进菜谱目录。
  ///
  /// 原生侧只改分辨率 / 帧率 / 码率，音频原样透传；转码失败会降级成直接拷贝，
  /// 所以这个方法只要不抛异常，`dst` 就一定有一个能播的文件。
  /// 转码要花几秒到十几秒（跟视频长度成正比），给足超时。
  Future<Map<String, dynamic>> saveVideo(
    String src,
    String dst,
    LogSink? onLog,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'saveVideo',
        <String, dynamic>{
          'src': src,
          'dst': dst,
          // 720p 长边：竖屏 720×1280 就是原分辨率，只是把 60fps 砍到 30、码率砍到 1.2M
          'maxLong': 720,
          'bitrate': 1200000,
        },
      ).timeout(const Duration(seconds: 180));
      final bytes = (res?['bytes'] as num?)?.toInt() ?? 0;
      final note = (res?['note'] ?? '').toString();
      await _log(onLog, '存视频',
          '${(bytes / 1048576).toStringAsFixed(1)}MB'
          '｜${note.isEmpty ? '已压缩' : note}'
          '｜耗时 ${sw.elapsedMilliseconds}ms');
      return res ?? <String, dynamic>{};
    } catch (e) {
      await _log(onLog, '存视频', '没存成，不影响菜谱：$e');
      return <String, dynamic>{};
    }
  }

  Future<bool> hasLogin() async {
    try {
      return await _channel.invokeMethod<bool>('hasDouyinCookie') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// 这一行是不是账号水印（而不是配方内容）。
  ///
  /// 三条同时满足才算：出现 ≥3 次、长度 ≤10、一个烹饪/食材/计量字都没有。
  /// 「麦香厨房」「小红书」「@某某」会被判成水印；
  /// 「热锅凉油」「下五花肉」「炖5分钟」因为含烹饪字或数字，一律当内容保留。
  static bool isWatermark(String line, int freq) {
    if (freq < 3) return false;
    final t = line.trim();
    if (t.length > 10) return false;
    const content =
        r'[0-9炒煮炖蒸炸煎烤焖煨焯切剁拌腌调味放加倒捞盛装火油盐糖醋酱葱姜蒜椒肉菜蛋粉面米水汤锅碗分秒勺克斤两]';
    return !RegExp(content).hasMatch(t);
  }

  /// 画面字幕是不是「已经把作者说的整段话都烧上去了」。
  ///
  /// 【v1.15 起不参与流程】换成 Paraformer 之后快了一个数量级 —— 但真机实测仍是
  /// 音频时长的 0.6~0.8 倍，不是几秒。既然每条视频都听，这个函数就退役了。
  /// 留着是因为它记录了一段踩过的坑，也还被单测当着回归基线。
  ///
  /// 【v1.14 更正】v1.13 用的是「汉字数 ≥ 160 就跳过听音频」，这个指标是**错的**，
  /// 而且错得很贵：用户做「酸甜大冷面」，182 秒的视频字幕有 238 个汉字（> 160），
  /// 于是跳过了语音；可那些字幕只是每隔几秒甩一句要点（「热锅凉油」「放点粉条」），
  /// 口播里报的配料 —— 一个梨、苹果比梨少一点、一根整的尖青椒不去根、一把香菜 ——
  /// 字幕里一个字都没有，最后菜谱只剩 8 项调料，四样配料全丢。
  ///
  /// 正确的指标是**密度**（汉字 / 视频秒数）：
  /// - 4 字/秒 以上 → 作者把整段解说都做成了字幕（快节奏口播型），可以不听；
  /// - 1~2 字/秒   → 只是每隔几秒甩一句要点，口播的信息量是字幕的三四倍，**必须听**。
  static bool subtitleCoversSpeech(String subtitle, int videoSeconds) {
    final han = subtitle.replaceAll(RegExp(r'[^\u4e00-\u9fa5]'), '').length;
    // 字幕本身就没几句，不管多长都得听
    if (han < 80) return false;
    // 不知道时长（抽帧失败等）：退回保守判断，宁多听一遍
    if (videoSeconds <= 0) return han >= 400;
    return han / videoSeconds >= 3.0;
  }

  /// 主入口：贴一条分享口令，返回「菜名 + 文案 + 字幕文字 + 一组真实画面」。
  /// [onStage] 把当前进度显示到按钮上；[onLog] 把每一步细节写进运行日志。
  Future<ReadRecipeResult> read(
    String shareText, {
    void Function(String label)? onStage,
    LogSink? onLog,
    bool skipAudio = false,
  }) async {
    final url = extractUrl(shareText);
    await _log(onLog, '读链接', '收到的分享文字 ${shareText.length} 字；提取到链接：${url.isEmpty ? '（没有）' : url}');
    if (url.isEmpty) {
      await _log(onLog, '失败', '没从输入里找到 http 链接');
      throw const DouyinReadException('没找到链接');
    }
    if (!url.contains('douyin') && !url.contains('iesdouyin')) {
      await _log(onLog, '失败', '链接不是抖音域名：$url');
      throw const DouyinReadException('目前只支持抖音的单条作品链接');
    }

    try {
      onStage?.call('正在解析链接…');
      final id = await _resolveId(url, onLog);

      // 依次试多个入口：PC 作品页 → 官方分享页 → 原始短链。
      // 以前只试第一个，一跳失败就整条链路结束；现在只要有一种入口能读到内容就继续走。
      // 分享页用**手机 UA**打开：它在手机 UA 下才把作品 SSR 进 _ROUTER_DATA，
      // 这是和 PC 页 detail 接口完全独立的一条取料路 —— PC 页被降级时靠它兜住。
      final candidates = <Map<String, Object>>[
        if (id != null)
          <String, Object>{
            'url': 'https://www.douyin.com/video/$id/',
            'mobile': false,
          },
        if (id != null)
          <String, Object>{
            'url': 'https://www.iesdouyin.com/share/video/$id/',
            'mobile': true,
          },
        <String, Object>{'url': url, 'mobile': true},
      ];
      _PageData? page;
      _PageData? textOnly;
      var captchaSeen = false;

      /// 跑一轮「直抓分享页 → 三个浏览器入口」。
      ///
      /// 抽成函数是为了 v1.11 的自动重试：抖音的风控是**偶发**的 ——
      /// 同一个链接这次弹验证、隔两秒再来就给了，让用户自己点「再试一次」
      /// 纯属把机器该干的活推给人。
      Future<_PageData?> attempt(int round) async {
        _PageData? media;
        _PageData? onlyText;

        // 第 0 条路：直抓官方分享页。成了就不必再开浏览器（省 3~10 秒）。
        if (id != null) {
          onStage?.call('正在直接读作品页…');
          final direct = await _fetchSharePageDirect(id, onLog);
          if (direct != null) {
            final p = await _parsePage(direct, onLog);
            if (p.videoUrl.isNotEmpty || p.images.isNotEmpty) {
              media = p;
              await _log(onLog, '直抓分享页', '一步就拿到素材了，不需要开浏览器');
            } else if (p.usable) {
              onlyText = p;
            }
          }
        }

        for (var i = 0; i < candidates.length; i++) {
          if (media != null) break;
          onStage?.call('正在打开作品页…（第 ${i + 1} 种入口）');
          final snap = await _fetchHtml(
            candidates[i]['url'].toString(),
            id ?? '',
            onLog,
            mobile: candidates[i]['mobile'] == true,
          );
          if (snap == null || snap.isEmpty) {
            await _log(onLog, '打开页面', '第 ${i + 1} 种入口没返回内容，换下一种');
            continue;
          }
          if (snap.captcha) captchaSeen = true;
          final parsed = await _parsePage(snap, onLog);
          // 只有「文案 + 视频」或「文案 + 图」才算真读到料。
          // 只拿到一句标题（34 字那种）不算：OCR 没素材、AI 也没配方可整理，
          // 这种结果要接着试下一个入口，别提前收工。
          final hasMedia =
              parsed.videoUrl.isNotEmpty || parsed.images.isNotEmpty;
          if (hasMedia) {
            media = parsed;
            await _log(onLog, '打开页面',
                '第 ${i + 1} 种入口拿到了${parsed.videoUrl.isNotEmpty ? '视频' : '图片'}，就用它');
            break;
          }
          if (parsed.usable && onlyText == null) onlyText = parsed;
          await _log(onLog, '打开页面',
              '第 ${i + 1} 种入口打开了（HTML ${snap.html.length} 字），'
              '但只有文案、没有视频/图，换下一种');
        }
        return media ?? onlyText;
      }

      page = await attempt(1);

      // 【v1.11】第一轮没拿到画面/视频，自动再来一轮。
      // 风控拦截常常是偶发的：隔一会儿换一次会话上下文就过了。
      // 只重试一次 —— 再多就是在跟平台硬碰，反而更容易被拉黑。
      final firstHasMedia = page != null &&
          (page.videoUrl.isNotEmpty || page.images.isNotEmpty);
      if (!firstHasMedia) {
        await _log(onLog, '自动重试',
            '第一轮没拿到画面/视频（${page == null ? '什么都没有' : '只拿到文案'}），'
            '隔 1.5 秒自动再试一轮');
        onStage?.call('没读到，自动再试一次…');
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        final second = await attempt(2);
        final secondHasMedia = second != null &&
            (second.videoUrl.isNotEmpty || second.images.isNotEmpty);
        if (secondHasMedia) {
          page = second;
          await _log(onLog, '自动重试', '第二轮拿到了画面/视频');
        } else if (second != null && page == null) {
          page = second;
          await _log(onLog, '自动重试', '第二轮仍然只有文案，但比空手强，留着');
        } else {
          await _log(onLog, '自动重试', '第二轮也没拿到，交回上层提示用户处理');
        }
      }

      // 两种入口都没拿到媒体，但至少有一份文案：先留着，后面报错时能说清楚是哪一类
      page ??= textOnly;
      if (page == null) {
        // 说清楚是「哪一类」读不到，别再笼统地说一句「读不到」。
        if (captchaSeen) {
          throw const DouyinReadException(
              '抖音在页面上弹了人机验证，作品数据没放出来（已经自动重试过一次了）。'
              '点「打开网页验证一下」，在网页里滑一下/点一下验证，回来再点一次就行');
        }
        if (!await hasLogin()) {
          throw const DouyinReadException(
              '还没登录抖音，平台不给作品数据。点「登录一次再试」，登录后就能一直贴链接读');
        }
        throw const DouyinReadException(
            '已登录但平台这次没给数据（已经自动重试过一次了）—— 可能这条作品受限'
            '（已删除 / 仅 App 内可见），或风控临时拦了。点「打开网页看一眼」，'
            '用网页确认一下这条能不能播，再回来重试');
      }

      final desc = page.desc;
      if (desc.isNotEmpty) {
        await _log(onLog, '作品文案',
            desc.substring(0, desc.length > 200 ? 200 : desc.length));
      }

      // 菜名取「#话题」之前那段，去掉平台尾巴
      String title = desc.split('#').first.trim();
      title = title.replaceAll(RegExp(r'\s*-\s*抖音.*$'), '').trim();
      final pt = page.pageTitle;
      if (title.isEmpty && pt.isNotEmpty && !pt.contains('（无 title）')) {
        title = pt;
      }
      title = title.replaceAll(RegExp(r'\s*-\s*抖音.*$'), '').trim();
      if (title.isEmpty || title.contains('在抖音记录美好生活')) title = '抖音菜谱';
      await _log(onLog, '解析页面', '拆出菜名：$title');

      // 图文作品（没有视频、只有图）：直接把作品里的图当实拍参考，不让用户自己截图
      if (page.videoUrl.isEmpty) {
        if (page.images.isEmpty) {
          // 走到这儿说明：文案拿到了，但平台没给视频、也没给封面 —— 这是风控降级，
          // 不是链接贴错。所以别让用户「换一条」，直接告诉他怎么把这一条救回来。
          final short = title.length > 18 ? '${title.substring(0, 18)}…' : title;
          throw DouyinReadException(
              '读到了标题「$short」，但视频和画面平台这次没放出来。'
              '点「打开网页验证一下」，在网页里把验证过了（或把视频播一下）再回来点一次，'
              '这一条就能读');
        }
        onStage?.call('正在取作品里的图…');
        final photos = await _downloadImages(page.images, onLog);
        if (photos.isEmpty) {
          throw const DouyinReadException('作品里的图没下载下来，检查一下网络再试');
        }

        // v1.8：图文作品的「配方」全写在图上——食材表、一步步做法、成品摆盘。
        // 以前这块直接把 subtitleText 置空，等于把最有用的信息丢了，
        // 只剩几张图给 AI 看一眼。现在每张图都过一遍 OCR，
        // 并且把图当成"帧"交给后面按步配图（图 N 就是第 N 屏）。
        onStage?.call('正在读图片上的文字…');
        final frames = <VideoFrame>[];
        for (var i = 0; i < photos.length; i++) {
          frames.add(VideoFrame(
            jpeg: photos[i],
            sec: i,
            // 图片不需要清晰度/亮度筛选：能下下来就是作者排版好的成品图
            sharp: 999,
            bright: 128,
            hash: '',
          ));
        }
        final text = await ocrFrames(
          frames,
          onLog,
          cloudOcr: CloudOcr.enabled ? CloudOcr.recognize : null,
        );

        final result = ReadRecipeResult(
          title: title,
          desc: desc,
          subtitleText: text,
          photos: photos,
          frames: frames,
          frameCount: photos.length,
        );
        await _log(onLog, '读链接结果',
            '图文作品｜菜名「$title」｜图片 ${photos.length} 张'
            '｜图上文字 ${text.length} 字');
        return result;
      }

      onStage?.call('正在下载视频…');
      // cacheKey 用作品 id：同一条视频不管是第一次读、重试、还是在另一个页面再读一次，
      // 都复用本机缓存，不再重复吃掉 60MB 流量。
      final videoPath =
          await downloadVideo(page.videoUrl, onLog, cacheKey: id ?? '');
      var keepVideo = false;

      // v1.49：同一条视频（同一作品 id）在本机反复整理时，视频有缓存但
      // 抽帧 18s + OCR 7~18s 每次重跑。命中读取缓存直接返回，秒出。
      // 缓存坏了/参数变了都当没命中，走原流程，绝不因为缓存影响正确性。
      final cached = await FrameCache.load(videoPath);
      if (cached != null && cached.result.hasContent) {
        keepVideo = true;
        await _log(onLog, '读取缓存',
            '这条视频之前抽过帧、认过字，直接复用（${cached.result.frames.length} 帧 / '
            '${cached.result.subtitleText.length} 字，省下抽帧和认字两步）');
        onStage?.call('正在读图片上的文字…');
        return cached.result;
      }

      try {
        // 【v1.13】顺序反过来了：以前先「听」再「看」，光听就要 37 秒。
        // 现在先抽帧读字幕（十来秒就够），字幕够清楚就直接跳过语音，
        // 把几十秒还给用户；字幕不行的才回头去听。
        onStage?.call('正在抽帧读字幕…');
        // 帧数由原生按视频真实时长均分（见 extractFrames 的 count 参数），
        // 这里不用再猜「每几秒一帧」。
        final frames = await extractFrames(videoPath, const <int>[], onLog);
        if (frames.isEmpty) {
          throw const DouyinReadException('这个视频抽不出画面');
        }
        // 把「每一行字幕出现在第几秒」也留下来，交给 AI 标步骤时间点用
        final subLines = <SubLine>[];
        // v1.43：抽帧和 OCR 是全链路最长的两段，以前共用一个进度文案，
        // 进度条会僵在那里十几到几十秒。拆成两个里程碑，让用户看得到在动。
        onStage?.call('正在读图片上的文字…');
        final subtitle = await ocrFrames(
          frames,
          onLog,
          outLines: subLines,
          cloudOcr: CloudOcr.enabled ? CloudOcr.recognize : null,
        );
        await _log(onLog, '字幕时间轴',
            subLines.isEmpty
                ? '（没有可用时间轴，配图退回按比例猜）'
                : '${subLines.length} 行字幕带上了秒数，'
                    '范围 ${subLines.first.sec}s ~ ${subLines.last.sec}s');

        // 【v1.43】这里以前是「不管字幕多全都听一遍」，同步 await、240 秒超时。
        // 真机日志（2026-11-15）证明：字幕 277/827/851 汉字时，听口播分别
        // 花 37 秒得 12 个错字、花 240 秒超时得 0 字、花 240 秒超时得 0 字。
        // 现在改成策略判定：字幕够密直接不等，稀疏才听，且硬限时 12 秒。
        // 口播里的用量/火候确实值钱，但不能让最慢的一步卡在必经路径上。
        var audio = '';
        final han = subtitle.replaceAll(RegExp(r'[^\u4e00-\u9fa5]'), '').length;
        if (!AsrPolicy.shouldListen(skipAudio: skipAudio, subtitleHan: han)) {
          await _log(onLog, '语音识别',
              AsrPolicy.skipReason(skipAudio: skipAudio, subtitleHan: han));
        } else {
          await _log(onLog, '语音识别', AsrPolicy.listenReason(han));
          onStage?.call('正在听视频里说了什么…');
          audio = await transcribe(videoPath, onLog);
        }

        // 筛掉黑屏 / 糊帧 / 重复画面，再从剩下的里挑进长图的实拍组
        final kept = pickUsable(frames, onLog);
        await _log(onLog, '挑图',
            '去掉黑屏、糊帧、重复画面后剩 ${kept.length} 张能用'
            '${kept.isEmpty ? ' ←← 这段视频几乎全是转场，只能不配图' : ''}');

        final picks = spread(kept, 6).map((f) => f.jpeg).toList();
        final result = ReadRecipeResult(
          title: title,
          desc: desc,
          subtitleText: subtitle,
          subtitleLines: subLines,
          audioText: audio,
          photos: picks,
          frames: kept,
          frameCount: frames.length,
          // v1.16：视频路径交出去，让上层决定「压一遍存进菜谱」还是「用完就删」。
          videoPath: videoPath,
        );
        keepVideo = true;
        // v1.49：把这一次最贵的抽帧+OCR结果存起来，下次同一条视频秒出。
        // 写缓存失败不影响本次结果（save 内部已吞掉异常）。
        await FrameCache.save(result);
        await _log(onLog, '读链接结果',
            '菜名「${result.title}」｜语音 ${result.audioText.length} 字'
            '｜画面字幕 ${result.subtitleText.length} 字'
            '｜实拍图 ${result.photos.length} 张｜总抽帧 ${result.frameCount}');
        return result;
      } finally {
        // v1.16：不再一律删。成功时保留（上层要拿它压成菜谱里能回放的视频），
        // 失败时才清理，别在临时目录里留一堆没人认领的大文件。
        if (!keepVideo) {
          try {
            final f = File(videoPath);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      }
    } on DouyinReadException catch (e) {
      await _log(onLog, '失败', '自动读取中断：${e.message}');
      rethrow;
    } catch (e, st) {
      await _log(onLog, '失败',
          '自动读取未预期异常：${e.runtimeType} $e｜堆栈首行 ${st.toString().split('\n').first}');
      rethrow;
    }
  }
}
