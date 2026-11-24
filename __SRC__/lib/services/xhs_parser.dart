// 小红书页面数据解析（纯 Dart，不依赖 Flutter）。
//
// 单独拆出来只为一件事：**能用 `dart run` 拿真实页面验证**。
// 放在 reader 里就得连带 MethodChannel 一起 import，跑不起来也就验不了。
//
// 数据结构（2026-11-11 实测）：
//   window.__INITIAL_STATE__.noteData.data.noteData = {
//     noteId, type: 'normal'|'video', title, desc,
//     imageList: [{ url, infoList: [{imageScene, url}] }],
//     video: { media: { stream: { h264: [{ masterUrl, backupUrls }] } } },
//     user: { nickName }, tagList, time
//   }
import 'dart:convert';

/// 一条小红书笔记的全部原始材料。
class XhsNote {
  final String noteId;
  final String type; // 'normal'（图文）/ 'video'
  final String title;
  final String desc;
  final String author;
  final List<String> images;
  final String videoUrl;
  final String finalUrl;

  const XhsNote({
    this.noteId = '',
    this.type = '',
    this.title = '',
    this.desc = '',
    this.author = '',
    this.images = const <String>[],
    this.videoUrl = '',
    this.finalUrl = '',
  });

  bool get hasMedia => images.isNotEmpty || videoUrl.isNotEmpty;
  bool get hasText => desc.trim().isNotEmpty || title.trim().isNotEmpty;

  @override
  String toString() => 'XhsNote($noteId, $type, 图 ${images.length}, '
      '视频 ${videoUrl.isEmpty ? '无' : '有'}, 正文 ${desc.length} 字)';
}

/// 解析回调：把中间过程说给日志听。和 LogSink 同签名，但不依赖它。
typedef XhsLog = void Function(String tag, String msg);

class XhsParser {
  /// 从整页 HTML 里抠 `__INITIAL_STATE__` 再解析。
  static XhsNote? parseHtml(String html, String wantId, [XhsLog? log]) {
    if (html.isEmpty) return null;
    final i = html.indexOf('__INITIAL_STATE__');
    if (i < 0) {
      log?.call('小红书', '页面里没有 __INITIAL_STATE__（可能被要求登录）');
      return null;
    }
    final brace = html.indexOf('{', i);
    if (brace < 0) return null;
    final jsonText = balancedJson(html, brace);
    if (jsonText.isEmpty) {
      log?.call('小红书', '__INITIAL_STATE__ 找到了但括号没闭合');
      return null;
    }
    return parseState(jsonText, wantId, log);
  }

  /// 解析 state JSON → 笔记。字段名给足兜底，平台改版时不至于全废。
  static XhsNote? parseState(String jsonText, String wantId, [XhsLog? log]) {
    dynamic root;
    try {
      root = jsonDecode(jsonText);
    } on Exception {
      // 小红书的 state 里偶尔出现 JS 的裸 `undefined`，标准 JSON 解不动。
      //
      // 只替换「结构位置」的 undefined（紧跟 : , [ 之后、后面是 , } ]），
      // 不能用 `\bundefined\b` 一把梭 —— 那样会把正文里出现的
      // 「含 undefined 的说明」也改成 null，等于悄悄篡改用户内容。
      try {
        root = jsonDecode(jsonText.replaceAllMapped(
          RegExp(r'([:,\[])\s*undefined(?=\s*[,}\]])'),
          (m) => '${m.group(1)}null',
        ));
      } on Exception catch (e) {
        log?.call('小红书', '内嵌数据解不动：${e.runtimeType}');
        return null;
      }
    }
    if (root is! Map) {
      log?.call('小红书', '内嵌数据不是对象');
      return null;
    }

    Map? note;
    // ① 当前版本：noteData.data.noteData
    final nd = root['noteData'];
    if (nd is Map) {
      final data = nd['data'];
      if (data is Map) {
        final n = data['noteData'];
        if (n is Map) note = n;
        if (note == null) {
          final err = data['errorNoteData'];
          if (err is Map) {
            final msg = (err['title'] ?? err['desc'] ?? '').toString();
            if (msg.isNotEmpty) {
              log?.call('小红书',
                  '平台返回的说明：${msg.length > 60 ? '${msg.substring(0, 60)}…' : msg}');
            }
          }
        }
      }
    }
    // ② 老版本：note.noteDetailMap{<id>: {note: {...}}}
    if (note == null) {
      final n = root['note'];
      if (n is Map) {
        final m = n['noteDetailMap'];
        if (m is Map) {
          final hit = m[wantId];
          if (hit is Map && hit['note'] is Map) {
            note = hit['note'] as Map;
          } else {
            for (final v in m.values) {
              if (v is Map && v['note'] is Map) {
                note = v['note'] as Map;
                break;
              }
            }
          }
        }
      }
    }
    // ③ 兜底：全树找「带 noteId 又有 imageList/video/desc」的那个对象
    if (note == null) {
      walk(root, (Map m) {
        if (note != null) return;
        final id = (m['noteId'] ?? '').toString();
        if (id.isEmpty) return;
        if (wantId.isNotEmpty && id != wantId) return;
        if (m.containsKey('imageList') ||
            m.containsKey('video') ||
            m.containsKey('desc')) {
          note = m;
        }
      });
    }

    final Map? found = note;
    if (found == null) {
      log?.call('小红书', '数据里没找到笔记对象（可能被要求登录 / 笔记已删）');
      return null;
    }

    final gotId = (found['noteId'] ?? '').toString();
    if (wantId.isNotEmpty && gotId.isNotEmpty && gotId != wantId) {
      log?.call('小红书', '拿到的是别的笔记（$gotId ≠ $wantId），丢掉');
      return null;
    }

    final images = imageUrls(found);
    final videoUrl = videoUrlOf(found);
    final title = (found['title'] ?? '').toString().trim();
    final desc = (found['desc'] ?? '').toString().trim();
    final user = found['user'];
    final author = user is Map ? (user['nickName'] ?? '').toString() : '';
    final type = (found['type'] ?? '').toString();

    log?.call(
        '小红书',
        '笔记解出来了｜类型=${type.isEmpty ? '未知' : type}｜标题 ${title.length} 字'
        '｜正文 ${desc.length} 字｜图片 ${images.length} 张'
        '｜视频 ${videoUrl.isEmpty ? '没有' : '有'}｜作者 $author');

    if (videoUrl.isEmpty) {
      final v = found['video'];
      if (v is Map) {
        log?.call('小红书', 'video 里的字段：${v.keys.take(12).join(' / ')}');
        final media = v['media'];
        if (media is Map) {
          final stream = media['stream'];
          if (stream is Map) {
            log?.call('小红书',
                'video.media.stream 里的字段：${stream.keys.take(8).join(' / ')}');
          }
        }
      }
    }

    return XhsNote(
      noteId: gotId,
      type: type,
      title: title,
      desc: desc,
      author: author,
      images: images,
      videoUrl: videoUrl,
    );
  }

  /// 图片地址：优先 `imageList[].url`（1080 宽），其次 infoList 里挑最大的。
  static List<String> imageUrls(Map note) {
    final out = <String>[];
    final list = note['imageList'];
    if (list is List) {
      for (final item in list) {
        if (item is! Map) continue;
        var u = (item['url'] ?? item['urlDefault'] ?? '').toString();
        if (u.isEmpty) u = _bestInInfoList(item['infoList']);
        if (u.isEmpty) u = _firstHttp(item);
        u = httpsify(u);
        if (u.isNotEmpty && !out.contains(u)) out.add(u);
      }
    }
    // 视频笔记只有封面：也算一张，不然长图没图可排
    final cov = note['cover'];
    if (out.isEmpty && cov is Map) {
      final u = httpsify((cov['urlDefault'] ?? cov['url'] ?? '').toString());
      if (u.isNotEmpty) out.add(u);
    }
    return out;
  }

  static String _bestInInfoList(dynamic infoList) {
    if (infoList is! List) return '';
    for (final i in infoList) {
      if (i is Map && (i['imageScene'] ?? '').toString() == 'H5_DTL') {
        final u = (i['url'] ?? '').toString();
        if (u.isNotEmpty) return u;
      }
    }
    for (final i in infoList) {
      if (i is Map) {
        final u = (i['url'] ?? '').toString();
        if (u.isNotEmpty) return u;
      }
    }
    return '';
  }

  /// 视频地址：按已知结构取，取不到就全树扫 mp4 / masterUrl。
  static String videoUrlOf(Map note) {
    final v = note['video'];
    if (v is Map) {
      final media = v['media'];
      if (media is Map) {
        final stream = media['stream'];
        if (stream is Map) {
          for (final codec in <String>['h264', 'h265', 'av1']) {
            final arr = stream[codec];
            if (arr is! List) continue;
            for (final item in arr) {
              if (item is! Map) continue;
              final u = httpsify((item['masterUrl'] ?? '').toString());
              if (u.isNotEmpty) return u;
              final backups = item['backupUrls'];
              if (backups is List) {
                for (final b in backups) {
                  final bu = httpsify(b.toString());
                  if (bu.isNotEmpty) return bu;
                }
              }
            }
          }
        }
      }
      for (final k in <String>['url', 'videoUrl', 'masterUrl']) {
        final u = httpsify((v[k] ?? '').toString());
        if (u.isNotEmpty) return u;
      }
      final consumer = v['consumer'];
      if (consumer is Map) {
        final u = httpsify((consumer['originVideoKey'] ?? '').toString());
        if (u.contains('http')) return u;
      }
    }
    // 全树兜底：像视频的 http 地址
    String? hit;
    walk(note, (Map m) {
      if (hit != null) return;
      for (final k in <String>['masterUrl', 'backupUrls', 'url']) {
        final val = m[k];
        if (val is String && looksVideo(val)) {
          hit = val;
          return;
        }
        if (val is List) {
          for (final x in val) {
            if (x is String && looksVideo(x)) {
              hit = x;
              return;
            }
          }
        }
      }
    });
    return httpsify(hit ?? '');
  }

  static final RegExp _vish = RegExp(
      r'\.mp4|/video/|xhscdn\.com/.*video|sns-video',
      caseSensitive: false);

  static bool looksVideo(String u) => u.startsWith('http') && _vish.hasMatch(u);

  static String _firstHttp(dynamic node) {
    String? best;
    walk(node, (Map m) {
      if (best != null) return;
      for (final v in m.values) {
        if (v is String && v.startsWith('http') && _isImage(v)) {
          best = v;
          return;
        }
      }
    });
    return best ?? '';
  }

  static bool _isImage(String u) {
    final l = u.toLowerCase();
    return l.contains('.jpg') ||
        l.contains('.jpeg') ||
        l.contains('.png') ||
        l.contains('.webp') ||
        l.contains('xhscdn.com');
  }

  static String httpsify(String u) {
    final t = u.trim();
    if (t.startsWith('http://')) return 'https://${t.substring(7)}';
    return t;
  }

  /// 遍历所有 Map 节点（深度上限 12，防止异常深的数据把栈吃光）。
  static void walk(dynamic node, void Function(Map) visit, [int depth = 0]) {
    if (depth > 12) return;
    if (node is Map) {
      visit(node);
      for (final v in node.values) {
        walk(v, visit, depth + 1);
      }
    } else if (node is List) {
      for (final v in node) {
        walk(v, visit, depth + 1);
      }
    }
  }

  /// 从 [start] 的 `{` 开始按括号配对切一段完整 JSON。
  /// 用正则切到 `</script>` 会被字符串里的 `}` 提前截断。
  static String balancedJson(String s, int start) {
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
}
