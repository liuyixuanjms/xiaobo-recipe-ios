// v1.11 · 小红书（图文 / 视频）贴链接自动读
//
// 和抖音是同一个思路，但**取料方式完全不同**，别照抄抖音：
//   抖音：数据在页面自己发的接口里 → 必须开 WebView 截接口；
//   小红书：数据在服务端渲染的 `window.__INITIAL_STATE__` 里 →
//          一个 http 请求就拿到全量 JSON，**不用开浏览器、不用登录**。
//
// 【2026-11-11 实测记录（务必先读）】
//  1) 桌面 UA 访问笔记页 → 302 到 /login，什么也拿不到。
//  2) 手机 UA + `/discovery/item/<id>` + 带 `xsec_token` → HTTP 200，
//     83KB 页面，`__INITIAL_STATE__.noteData.data.noteData` 里是全量数据：
//     title / desc / imageList / video / user / tagList。
//  3) **不带 xsec_token 一定 302 走人**。token 只能从分享短链的 302 Location 里拿，
//     所以「跟跳转」是这条路的第一步，不是可选项。
//  4) 图片直链 `sns-webpic-qc.xhscdn.com/...!h5_1080jpg` 可直接下载（1080×1440）。
//  5) 短链形如 `xhslink.cn/o/xxx`、`xhslink.com/a/xxx`；
//     跳转后 Location 里自带 `type=normal|video`，能直接分清图文还是视频。
//
// 【边界，不许说满】
//  - token 有时效，用户贴很久以前复制的链接可能失效 → 提示重新复制；
//  - 未登录能看到的内容，登录墙后面的（私密、仅粉丝）读不到 → 如实说；
//  - 视频笔记的 `video.media.stream` 字段结构随版本会变，这里做了多层兜底
//    并在日志里打印实际字段，跑不通时照日志补就行。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'asr_policy.dart';
import 'douyin_reader.dart';
import 'log_service.dart';
import 'xhs_parser.dart';

// XhsNote 在 parser 里定义（纯 Dart，能单独拿真实页面验证），这里转出去，
// 让调用方只 import 这一个文件就够。
export 'xhs_parser.dart' show XhsNote;

/// 一个「解析好了的」小红书链接：带 token 的完整地址 + 笔记 id + 类型。
class XhsLink {
  final String url;
  final String noteId;
  final String type; // normal / video / ''
  final bool hasToken;

  const XhsLink({
    required this.url,
    required this.noteId,
    this.type = '',
    this.hasToken = false,
  });

  @override
  String toString() =>
      'id=$noteId｜type=${type.isEmpty ? '未知' : type}｜凭证=${hasToken ? '有' : '没有'}｜$url';
}

class XhsReadException implements Exception {
  final String message;
  const XhsReadException(this.message);
  @override
  String toString() => message;
}

class XhsReader {
  static const MethodChannel _channel =
      MethodChannel('com.xiaobo.recipe/share');

  /// 小红书只认手机身份。桌面 UA 一律 302 到登录页（实测）。
  static const String mobileUa =
      'Mozilla/5.0 (Linux; Android 12; SM-G991B) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  static const String referer = 'https://www.xiaohongshu.com/';

  static final RegExp _urlReg = RegExp(
    r'https?://[^\s，,。;；\]\)\}）]+',
    caseSensitive: false,
  );

  /// 笔记 id：24 位十六进制（`6abfaf91000000001802fa15`）。
  /// 三种路径都见过：/discovery/item/、/explore/、/item/。
  static final RegExp _noteIdReg =
      RegExp(r'/(?:discovery/item|explore|item)/([0-9a-fA-F]{16,32})');

  static const String _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static Future<void> _log(LogSink? onLog, String tag, String msg) async {
    if (onLog != null) await onLog(tag, msg);
  }

  /// 从「78 芮子初发布了一篇小红书笔记，快来看吧！… http://xhslink.com/a/xxx …」
  /// 这类口令里挑出链接。链接可能不带 http://，由调用方补全。
  static String extractUrl(String raw) {
    final m = _urlReg.firstMatch(raw);
    return m == null ? '' : raw.substring(m.start, m.end).trim();
  }

  static bool looksLikeXhs(String s) {
    final u = s.toLowerCase();
    return u.contains('xhslink.com') ||
        u.contains('xhslink.cn') ||
        u.contains('xiaohongshu.com');
  }

  static String? _pickId(String s) {
    return _noteIdReg.firstMatch(s)?.group(1);
  }

  static String _tokenOf(Uri u) {
    final t = u.queryParameters['xsec_token'] ?? '';
    return t.trim();
  }

  static String _typeOf(Uri u) {
    final t = (u.queryParameters['type'] ?? '').trim().toLowerCase();
    return (t == 'video' || t == 'normal') ? t : '';
  }

  // ---------------------------------------------------------------------------
  // 第一步：跟短链跳转，拿到「带 token 的真正地址」
  // ---------------------------------------------------------------------------

  /// 小红书最容易踩的坑就在这一步：**token 只在 302 的 Location 里**，
  /// 少了它后面一定 302 到登录页。所以这里逐跳跟，并且把每一跳都写进日志。
  Future<XhsLink> resolve(String rawUrl, LogSink? onLog) async {
    var url = rawUrl.trim();
    while (url.endsWith('。') || url.endsWith('.') || url.endsWith(',')) {
      url = url.substring(0, url.length - 1);
    }
    await _log(onLog, '小红书', '收到的链接：$url');

    var cur = Uri.parse(url);
    var id = _pickId(url) ?? '';
    var type = _typeOf(cur);
    var token = _tokenOf(cur);

    // 链接本身就是完整的（用户从网页地址栏复制的），直接可用
    if (id.isNotEmpty && token.isNotEmpty) {
      await _log(onLog, '小红书',
          '链接里已经带了笔记 id 和访问凭证，不用跳转｜id=$id');
      return XhsLink(url: url, noteId: id, type: type, hasToken: true);
    }
    if (id.isNotEmpty && token.isEmpty) {
      await _log(onLog, '小红书',
          '链接里有笔记 id 但没有 xsec_token —— 这种多半读不到，先试一次');
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12)
      ..findProxy = HttpClient.findProxyFromEnvironment;
    try {
      for (var hop = 1; hop <= 6; hop++) {
        HttpClientResponse resp;
        HttpClientRequest req;
        try {
          req = await client
              .getUrl(cur)
              .timeout(const Duration(seconds: 12));
          // 关键：不自动跟跳转，自己读 Location，才能把 token 一起拿走
          req.followRedirects = false;
          req.headers.set(HttpHeaders.userAgentHeader, mobileUa);
          req.headers.set(HttpHeaders.acceptLanguageHeader, 'zh-CN,zh;q=0.9');
          resp = await req.close().timeout(const Duration(seconds: 12));
        } on Exception catch (e) {
          await _log(onLog, '小红书',
              '第 $hop 跳请求失败：${e.runtimeType} —— 短链可能已过期');
          break;
        }

        final loc = resp.headers.value(HttpHeaders.locationHeader);
        await _log(onLog, '小红书',
            '第 $hop 跳｜HTTP ${resp.statusCode}｜${shortUrl(cur.toString())}'
            ' → ${loc == null ? '（不再跳转）' : shortUrl(normUri(loc, cur))}');

        if (loc == null || loc.isEmpty) {
          // 到终点了。可能已经是笔记页（此时把正文里的 id 抠出来），
          // 也可能是「链接失效」的首页。
          final body = await resp.transform(utf8.decoder).join();
          id = id.isEmpty ? (_pickId(body) ?? '') : id;
          await _log(onLog, '小红书',
              '落地页正文 ${body.length} 字｜${id.isEmpty ? '没扫到笔记 id' : '扫到 id=$id'}');
          break;
        }

        final next = normUri(loc, cur);
        cur = Uri.parse(next);
        id = id.isEmpty ? (_pickId(next) ?? '') : id;
        final t2 = _typeOf(cur);
        if (t2.isNotEmpty) type = t2;
        final tk = _tokenOf(cur);
        if (tk.isNotEmpty) token = tk;

        // 已经拿到「id + token」就没必要再跟
        if (id.isNotEmpty && token.isNotEmpty) break;
      }
    } finally {
      client.close(force: true);
    }

    // 最后的兜底：只拿到 id、没 token，也拼一个地址去试（有些老笔记不校验）
    final finalUrl = (id.isNotEmpty && token.isEmpty)
        ? 'https://www.xiaohongshu.com/discovery/item/$id'
        : cur.toString();

    await _log(onLog, '小红书',
        '解析结果：id=${id.isEmpty ? '（没有）' : id}｜'
        '类型=${type.isEmpty ? '未知' : type}｜'
        '凭证=${token.isEmpty ? '❌ 没有（八成读不到）' : '有'}');

    if (id.isEmpty) {
      throw const XhsReadException(
          '这条链接里没解析出笔记。请回到小红书，点笔记右上角「分享 → 复制链接」，'
          '把复制出来的整段原样贴进来');
    }
    return XhsLink(url: finalUrl, noteId: id, type: type, hasToken: token.isNotEmpty);
  }

  /// 相对 Location → 绝对地址；顺手把协议补成 https（图片、页面都要求）。
  static String normUri(String loc, Uri base) {
    try {
      return base.resolve(loc).toString();
    } catch (_) {
      return loc;
    }
  }

  /// 日志里只留域名 + 路径，别把一长串 token 写进日志（用户要发给别人看）。
  static String shortUrl(String u) {
    try {
      final x = Uri.parse(u);
      final p = x.path.length > 40 ? '${x.path.substring(0, 40)}…' : x.path;
      return '${x.host}$p';
    } catch (_) {
      return u.length > 60 ? '${u.substring(0, 60)}…' : u;
    }
  }

  // ---------------------------------------------------------------------------
  // 第二步：取笔记数据（先 http 直读，失败再开浏览器）
  // ---------------------------------------------------------------------------

  /// 直接用手机身份抓 `/discovery/item/<id>`。成功的话几百毫秒就回来。
  ///
  /// 为什么强制走 discovery/item：`/explore/<id>` 在手机 UA 下会 302 到别处，
  /// discovery/item 才是真正 SSR 出数据的那条路径（实测）。
  Future<XhsNote?> fetchByHttp(XhsLink link, LogSink? onLog) async {
    final q = <String, String>{
      'xsec_source': 'app_share',
      ...Uri.parse(link.url).queryParameters,
    };
    final uri = Uri.https(
      'www.xiaohongshu.com',
      '/discovery/item/${link.noteId}',
      q,
    );
    await _log(onLog, '小红书', '直读笔记页：${shortUrl(uri.toString())}');
    final sw = Stopwatch()..start();
    try {
      final resp = await http.get(uri, headers: <String, String>{
        'User-Agent': mobileUa,
        'Referer': referer,
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
      }).timeout(const Duration(seconds: 20));

      final html = utf8.decode(resp.bodyBytes, allowMalformed: true);
      await _log(onLog, '小红书',
          'HTTP ${resp.statusCode}｜正文 ${html.length} 字'
          '｜带内嵌数据 ${html.contains('__INITIAL_STATE__') ? '是' : '否'}'
          '｜耗时 ${sw.elapsedMilliseconds}ms');

      if (resp.statusCode != 200) {
        await _log(onLog, '小红书',
            '不是 200，多半被要求登录或链接已失效；下一步改开浏览器');
        return null;
      }
      final note = XhsParser.parseHtml(html, link.noteId, onLog);
      if (note != null) return note;

      if (html.length < 4000) {
        await _log(onLog, '小红书',
            '正文只有 ${html.length} 字，基本是跳转壳/空壳，改开浏览器试');
      }
      return null;
    } on Exception catch (e) {
      await _log(onLog, '小红书', '直读失败：${e.runtimeType}，改开浏览器试');
      return null;
    }
  }

  /// 兜底：让原生 WebView（手机 UA，带本机 cookie）打开笔记页，
  /// 把 `window.__INITIAL_STATE__` 整个 stringify 回来。
  ///
  /// 什么时候用得上：链接被要求登录、或者 http 直读拿到的只是骨架页。
  Future<XhsNote?> fetchByWebView(XhsLink link, LogSink? onLog) async {
    await _log(onLog, '小红书', '开手机内嵌浏览器打开笔记页（兜底通道）');
    final sw = Stopwatch()..start();
    try {
      final dynamic raw = await _channel.invokeMethod<dynamic>(
        'fetchXhsPage',
        <String, dynamic>{
          'url': link.url,
          'id': link.noteId,
          'mobile': true,
        },
      );
      if (raw == null) {
        await _log(onLog, '小红书', '浏览器没返回内容');
        return null;
      }
      Map<String, dynamic> m = <String, dynamic>{};
      if (raw is Map) m = Map<String, dynamic>.from(raw);
      final trace = (m['trace'] ?? '').toString();
      if (trace.isNotEmpty) {
        await _log(onLog, '小红书', '浏览器轨迹：$trace');
      }
      final state = (m['state'] ?? '').toString();
      final html = (m['html'] ?? '').toString();
      await _log(onLog, '小红书',
          '浏览器回来了｜页面数据 ${state.length} 字｜HTML ${html.length} 字'
          '｜最终地址 ${shortUrl((m['finalUrl'] ?? '').toString())}'
          '｜耗时 ${sw.elapsedMilliseconds}ms');

      // 优先用浏览器直接 stringify 出来的 state（比从 HTML 里抠更可靠）
      if (state.length > 200) {
        final note = XhsParser.parseState(state, link.noteId, onLog);
        if (note != null) return note;
      }
      return XhsParser.parseHtml(html, link.noteId, onLog);
    } on PlatformException catch (e) {
      await _log(onLog, '小红书', '浏览器调用报错：${e.code} ${e.message ?? ''}');
      return null;
    } on Exception catch (e) {
      await _log(onLog, '小红书', '浏览器通道异常：${e.runtimeType}');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // 第三步：把笔记变成「能交给 AI 的材料」
  // ---------------------------------------------------------------------------

  Future<List<Uint8List>> _downloadImages(
      List<String> urls, LogSink? onLog) async {
    final out = <Uint8List>[];
    final seen = <String>{};
    for (final u in urls) {
      if (out.length >= 10) break;
      // 同一张图会有多种规格（!h5_1080jpg / !style_xxx），按 fileId 去重
      final key = u.split('!').first.split('?').first;
      if (!seen.add(key)) continue;
      try {
        final resp = await http.get(
          Uri.parse(u),
          headers: <String, String>{
            'User-Agent': mobileUa,
            'Referer': referer,
          },
        ).timeout(const Duration(seconds: 30));
        if (resp.statusCode == 200 && resp.bodyBytes.length > 2048) {
          out.add(resp.bodyBytes);
        } else {
          await _log(onLog, '取图',
              '单张没下来（HTTP ${resp.statusCode}，${resp.bodyBytes.length} 字节），跳过');
        }
      } on Exception catch (e) {
        await _log(onLog, '取图', '单张失败（跳过）：${e.runtimeType}');
      }
    }
    await _log(onLog, '取图', '候选 ${urls.length} 张｜成功下载 ${out.length} 张');
    return out;
  }

  /// 去掉小红书的话题标签：`#家常饺子[话题]#`、`#下饭菜`、`#在家做美食[话题]#`。
  ///
  /// 为什么要删：视频笔记的「正文」经常只有一个标题 + 四五个话题（实测 45 字里
  /// 35 个字都是标签），拿去当菜名会变成「茴香猪肉馅饺子鲜嫩多汁。#家常」，
  /// 拿去给 AI 也只是噪音。删掉之后才剩下真正的信息。
  static String stripTags(String s) {
    var t = s
        .replaceAll(RegExp(r'#[^#\s\[\]]{1,30}\[话题\]#'), ' ')
        .replaceAll(RegExp(r'#\S{1,30}'), ' ')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .trim();
    // 只删标签会把句子尾巴留成「，」或「。」，收个尾
    t = t.replaceAll(RegExp(r'[，,、\s]+$'), '');
    return t.trim();
  }

  /// 主入口：贴一条小红书分享口令，返回和抖音同一套结构，
  /// 上层 UI 一行都不用改。
  Future<ReadRecipeResult> read(
    String shareText, {
    void Function(String label)? onStage,
    LogSink? onLog,
    bool skipAudio = false,
  }) async {
    final url = extractUrl(shareText);
    await _log(onLog, '小红书',
        '收到的分享文字 ${shareText.length} 字｜提取到链接：${url.isEmpty ? '（没有）' : url}');
    if (url.isEmpty) {
      throw const XhsReadException('没找到链接');
    }
    if (!looksLikeXhs(url)) {
      throw const XhsReadException('这不是小红书链接');
    }

    final DouyinReader media = DouyinReader(); // 下载/抽帧/OCR/听写复用同一套

    try {
      onStage?.call('正在解析小红书链接…');
      final link = await resolve(url, onLog);

      onStage?.call('正在读这条笔记…');
      XhsNote? note = await fetchByHttp(link, onLog);
      if (note == null || (!note.hasMedia && !note.hasText)) {
        onStage?.call('正在用浏览器打开笔记…');
        note = await fetchByWebView(link, onLog);
      }
      if (note == null || (!note.hasMedia && !note.hasText)) {
        if (!link.hasToken) {
          throw const XhsReadException(
              '这条链接里缺一段「访问凭证」，平台直接把我挡回登录页了。\n'
              '请回到小红书，打开这条笔记 → 右上角「分享」→「复制链接」，'
              '把复制出来的整段重新贴进来（别手动删改）。');
        }
        throw const XhsReadException(
            '笔记页面打开了，但平台没给内容 —— 可能这条已删除、设成私密、'
            '或只对登录用户可见。换一条公开的试试。');
      }

      // v1.12：先剥话题标签。视频笔记的正文往往就是「一句标题 + 五个话题」，
      // 不剥的话菜名会被截成「茴香猪肉馅饺子鲜嫩多汁。#家常」。
      final cleanDesc = stripTags(note.desc);
      final cleanTitle = stripTags(note.title);

      // 菜名：优先笔记标题；没有标题就把正文第一行拿来当菜名
      var title = cleanTitle.trim();
      if (title.isEmpty) {
        final first = cleanDesc
            .split('\n')
            .map((e) => e.trim())
            .firstWhere((e) => e.isNotEmpty, orElse: () => '');
        // 取到第一个句号/感叹号/问号为止，别把整段简介都塞进标题
        final cut = first.split(RegExp(r'[。！!？?，,]')).first.trim();
        title = cut.length > 18 ? cut.substring(0, 18) : cut;
      }
      await _log(onLog, '小红书',
          '菜名取「$title」｜正文 ${cleanDesc.length} 字（剥标签前 ${note.desc.length} 字）'
          '｜作者 ${note.author}');

      final hasVideo = note.videoUrl.trim().isNotEmpty;

      // ---------- 视频笔记：下视频 → 听 → 抽帧 → 读字幕 ----------
      if (hasVideo) {
        onStage?.call('正在下载视频…');
        final path = await media.downloadVideo(
          note.videoUrl,
          onLog,
          referer: referer,
        );
        var keepVideo = false;
        try {
          // v1.13：先抽帧读字幕，字幕够清楚就跳过语音（Vosk 很慢，37 秒可能只出 4 个字）
          onStage?.call('正在抽帧读字幕…');
          final frames = await media.extractFrames(path, const <int>[], onLog);
          if (frames.isEmpty) {
            throw const XhsReadException('这个视频抽不出画面，可能视频地址已失效');
          }
          final subLines = <SubLine>[];
          onStage?.call('正在读图片上的文字…');
          final subtitle = await media.ocrFrames(frames, onLog, outLines: subLines);
          await _log(onLog, '字幕时间轴',
              subLines.isEmpty
                  ? '（没有可用时间轴，配图退回按比例猜）'
                  : '${subLines.length} 行字幕带上了秒数，'
                      '范围 ${subLines.first.sec}s ~ ${subLines.last.sec}s');

          var audio = '';
          final han = subtitle.replaceAll(RegExp(r'[^\u4e00-\u9fa5]'), '').length;
          // v1.43：和抖音那条路统一策略 —— 字幕够密就不等口播。
          // 真机日志里这一步曾两次跑满 240 秒超时、0 产出。
          if (!AsrPolicy.shouldListen(skipAudio: skipAudio, subtitleHan: han)) {
            await _log(onLog, '语音识别',
                AsrPolicy.skipReason(skipAudio: skipAudio, subtitleHan: han));
          } else {
            await _log(onLog, '语音识别', AsrPolicy.listenReason(han));
            onStage?.call('正在听视频里说了什么…');
            audio = await media.transcribe(path, onLog);
          }

          final kept = media.pickUsable(frames, onLog);
          await _log(onLog, '挑图',
              '去掉黑屏、糊帧、重复画面后剩 ${kept.length} 张能用');
          final picks = DouyinReader.spread(kept, 6).map((f) => f.jpeg).toList();

          final result = ReadRecipeResult(
            title: title,
            desc: cleanDesc,
            subtitleText: subtitle,
            subtitleLines: subLines,
            audioText: audio,
            photos: picks,
            frames: kept,
            frameCount: frames.length,
            // v1.16：视频路径交出去，上层决定存还是删
            videoPath: path,
          );
          keepVideo = true;
          await _log(onLog, '读链接结果',
              '小红书视频｜菜名「$title」｜语音 ${audio.length} 字'
              '｜画面字幕 ${subtitle.length} 字｜实拍图 ${picks.length} 张');
          return result;
        } finally {
          // v1.16：成功时保留视频（上层要压进菜谱），失败才清理
          if (!keepVideo) {
            try {
              final f = File(path);
              if (await f.exists()) await f.delete();
            } catch (_) {}
          }
        }
      }

      // ---------- 图文笔记：下图片 → 读图上的字 ----------
      List<Uint8List> photos = const <Uint8List>[];
      if (note.images.isNotEmpty) {
        onStage?.call('正在取笔记里的图…');
        photos = await _downloadImages(note.images, onLog);
      }

      var ocr = '';
      final frames = <VideoFrame>[];
      if (photos.isNotEmpty) {
        onStage?.call('正在读图片上的文字…');
        for (var i = 0; i < photos.length; i++) {
          frames.add(VideoFrame(
            jpeg: photos[i],
            sec: i,
            // 图片不用做清晰度筛选：本身就是作者排好版的成品图
            sharp: 999,
            bright: 128,
            hash: '',
          ));
        }
        // 图文不传 outLines：图片没有「第几秒」，硬塞时间轴会把 AI 带偏
        ocr = await media.ocrFrames(frames, onLog);
      }

      if (photos.isEmpty && cleanDesc.length < 12) {
        throw const XhsReadException(
            '这条笔记里没有图、也没有文字说明，读不出菜谱。换一条试试。');
      }

      final result = ReadRecipeResult(
        title: title,
        desc: cleanDesc,
        subtitleText: ocr,
        photos: photos,
        frames: frames,
        frameCount: photos.length,
      );
      await _log(onLog, '读链接结果',
          '小红书图文｜菜名「$title」｜图片 ${photos.length} 张'
          '｜正文 ${cleanDesc.length} 字｜图上文字 ${ocr.length} 字'
          '${photos.isEmpty ? '（纯文字笔记，靠正文整理）' : ''}');
      return result;
    } on XhsReadException catch (e) {
      await _log(onLog, '失败', '小红书读取中断：${e.message}');
      rethrow;
    } catch (e, st) {
      await _log(onLog, '失败',
          '小红书未预期异常：${e.runtimeType} $e｜堆栈首行 ${st.toString().split('\n').first}');
      rethrow;
    }
  }

  /// 给「打开网页验证」用的地址（小红书几乎用不上，但界面要统一）。
  static String deskTopUrl(String noteId) =>
      noteId.isEmpty ? 'https://www.xiaohongshu.com/' : 'https://www.xiaohongshu.com/discovery/item/$noteId';

  static const String desktopUa = _desktopUa;
}
