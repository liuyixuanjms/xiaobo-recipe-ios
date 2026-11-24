/// 把「标题党」洗成真正的菜名。
///
/// 素材里的标题常常长这样：
///   蒜苔炒肉怎么做吃隔夜的味道，超级入味巨下饭！
///   【暖灶食光】2分钟学会下酒神器酱油㸆鸭子
///   5分钟学会糖醋排骨，零失败
///
/// 做法不是「砍掉尾巴」，而是**把口水词当分隔符切块**，
/// 每块都是菜名候选，最后给每个候选打分，挑最像菜名的那块。
/// 因为菜名既可能在口水词前面（蒜苔炒肉｜怎么做），
/// 也可能在后面（2分钟学会｜糖醋排骨），单纯截断必然有一半是错的。
///
/// 【v1.43 重要修正】话题标签才是作者亲手写下的菜名，以前被当垃圾删掉了。
///
/// 真实日志（2026-11-15）里三条视频：
///   作品文案 3分钟教你学会东北老式鸡蛋酱… #鸡蛋酱 #美食教程
///     → 旧版输出「不会炸酱」，用户手改成「鸡蛋酱」
///   作品文案 低成本在家实现牛排自由… #自制牛排 #煎牛排
///     → 旧版输出「低成本」，用户手改成「自制牛排」
///   作品文案 东北四大炖菜之一… #排骨炖豆角
///     → 旧版输出「东北四大炖菜之一」，用户手改成「排骨炖豆角-段小段」
///
/// 根因在两处：douyin_reader 用 desc.split('#').first 把话题整段砍掉，
/// 本文件第一步又用正则删一次 #话题。最可靠的信号被丢光，
/// 只剩标题党长句交给打分器瞎切，自然切出「低成本」「不会炸酱」。
/// 现在改为：先读话题标签，命中就直接用；没有话题才回退到老的分块打分。
class TitleFixer {
  /// 出现在菜名里就一定不是菜名的词。它们会变成切块的分隔符。
  static const _chatter = <String>[
    // 教程类
    '怎么做', '咋做', '如何做', '怎样做', '这样做', '做法', '教程', '配方',
    '零失败', '保姆级', '一看就会', '看一遍', '教你', '学会', '学会了', '搞定',
    // 夸赞类
    '巨下饭', '超下饭', '下饭菜', '下饭', '下酒神器', '下酒菜',
    '超级入味', '超入味', '入味', '太香了', '真香', '香迷糊',
    '绝了', '好吃到', '舔盘', '光盘', '馋哭', '太好吃', '好吃',
    '秒光', '抢着吃', '上桌', '出锅', '味道',
    // 引导类
    '收藏', '必学', '必看', '安排', '分享', '挑战', '试试', '原来', '才知道',
    '在家', '简单', '快手', '秘制', '隔夜', '吃隔夜',
  ];

  /// 话题标签里的活动 / 营销词：整条命中就不可能是菜名。
  /// 注意这里只放「绝对不是菜」的，别误伤「#下饭菜谱」这类边界情况；
  /// 真正的硬门槛是下面的「必须带食材字或烹饪字」。
  static const _tagBlacklist = <String>[
    '上热门', '热门', '创作灵感', '记录真实生活', '生活的烟火气息',
    '抖音', '宠爱季', '集结', '出招', '主播', '同城', '推荐',
    '原创', '日常', '挑战', '流量', '涨粉', '美食教程', '家常菜',
    '下饭神器', '下饭菜', '美食分享', '菜谱', '做饭', '厨房',
    '我要上', '我要', '各路', '新主播', '趣味', '生活',
  ];

  /// 烹饪字：出现在一个词里，它是菜名的可能性就高很多。
  static const _cookChars = '炒烧炖煮蒸煎炸拌焖煲烤酱卤爆熘烩汆涮腌焗㸆';

  /// 食材字：同上。
  static const _foodChars = '肉蛋鱼鸡鸭鹅菜豆瓜菇虾蟹藕笋椒葱蒜姜排豆腐米面粉薯茄萝';

  /// 句子里常见但不属于菜名的虚词，只在首尾去掉。
  static const _filler = '的了啊呀呢吗吧这就都很最超巨太真是个才又也那这';

  /// 从完整素材里挑菜名。
  ///
  /// [source] 传完整文案（作品 description、字幕全文都行），里面通常带 #话题。
  /// [confident] 为 false 表示「没找到像菜名的东西」，调用方应让用户自己填，
  /// 不要把标题党长句原样端上去 —— 那正是用户骂「出来的都不是菜名」的原因。
  static TitlePick pick(String raw, {String source = ''}) {
    final origin = raw.trim();
    final pool = source.isEmpty ? origin : '$origin\n$source';

    // ① 话题标签优先：作者亲手标的菜名，比从口水话里猜可靠得多。
    final fromTag = _pickFromTags(_tagsOf(pool), pool);
    if (fromTag != null) return fromTag;

    if (origin.isEmpty) return const TitlePick('', false, '空');

    // ② 老办法：口水词切块打分。fix 会返回 origin 表示洗不出来。
    final cleaned = fix(origin);
    if (cleaned != origin && looksLikeDish(cleaned)) {
      return TitlePick(cleaned, true, '文案切块');
    }

    // ③ 原文本身就短得像菜名，直接认下（例如用户手动输的「番茄炒蛋」）。
    if (looksLikeDish(origin) && !_hasChatter(origin)) {
      return TitlePick(origin, true, '原文');
    }

    // ④ 没把握。返回空，交给调用方兜底，绝不把整句标题党当菜名。
    return const TitlePick('', false, '没找到像菜名的候选');
  }

  /// 给外部判断一段文字像不像菜名。
  ///
  /// 除了「带食材/烹饪字」，还要挡住「东北四大炖菜之一」「不会炸酱」这类
  /// 带食材字却根本不是名字的说法 —— 它们正是旧版输出的假菜名。
  static bool looksLikeDish(String s) {
    final t = s.trim();
    if (t.length < 2 || t.length > 10) return false;
    if (RegExp(r'[a-zA-Z0-9]').hasMatch(t)) return false;
    if (RegExp(r'[\n，,。！!？?、；;]').hasMatch(t)) return false;
    if (RegExp(r'[之其这那么不为以想把被也很最超真太就都还而到]').hasMatch(t)) {
      return false;
    }
    for (final w in _nonDishMarkers) {
      if (t.contains(w)) return false;
    }
    var cook = 0;
    var food = 0;
    for (final ch in t.split('')) {
      if (_cookChars.contains(ch)) cook++;
      if (_foodChars.contains(ch)) food++;
    }
    return cook + food > 0;
  }

  /// 出现在一段文字里，它就一定是在讲别的，不是在报菜名。
  static const _nonDishMarkers = <String>[
    '之一', '四大', '大全', '合集', '盘点', '排行', '低成本', '自由',
    '不只是', '不止', '原来', '其实', '学会', '教你', '分钟', '剪辑',
  ];

  /// 老接口，保持原行为不变（现有调用方和回归测试都依赖它）。
  /// 新代码请用 [pick]，它能读话题标签。
  static String fix(String raw) {
    final origin = raw.trim();
    if (origin.isEmpty) return origin;

    // 1. 砍掉明显不属于菜名的东西
    var t = origin
        .replaceAll(RegExp(r'https?://\S+'), ' ')
        .replaceAll(RegExp(r'#[^\s#]+'), ' ') // #话题
        .replaceAll(RegExp(r'@[^\s@]+'), ' ') // @作者
        .replaceAll(RegExp(r'\d+(?:\.\d+)?\s*复制打开抖音[^，。]*'), ' ')
        .replaceAll(RegExp(r'复制打开抖音[^，。]*'), ' ')
        .replaceAll(RegExp(r'[【\[（(][^】\]）)]*[】\]）)]'), ' ') // 【栏目名】
        .replaceAll(RegExp(r'[\u2600-\u27BF\uD83C-\uDBFF\uDC00-\uDFFF]'), ' '); // 表情

    // 2. 口水词一律换成切块符
    for (final w in _chatter) {
      t = t.replaceAll(w, '|');
    }

    // 3. 按标点 / 空白 / 切块符切开
    final parts = t
        .split(RegExp(r'[，,。！!？?、~～｜|:：;；/\\\s]+'))
        .map(_trimFiller)
        .where((e) => e.isNotEmpty)
        .toList();

    // 4. 逐个打分，挑最像菜名的
    String? best;
    var bestScore = -999;
    for (final p in parts) {
      // 「5 分钟」「3 步」「1 个技巧」这种不是菜名
      final cleaned = p
          .replaceAll(RegExp(r'\d+\s*(分钟|分|秒|步|招|个技巧|种|道|款)'), '')
          .trim();
      if (_cnLength(cleaned) < 2) continue;
      final s = _score(cleaned);
      if (s > bestScore) {
        bestScore = s;
        best = cleaned;
      }
    }

    // 洗不出来就原样返回：宁可留着让你看到，也不要凭空造一个菜名
    if (best == null || bestScore <= 0) return origin;

    var out = best;
    if (out.length > 12) out = out.substring(0, 12);
    return out.trim();
  }

  /// 从一段文字里抓 #话题。抖音的话题以空白 / 标点 / 另一个 # 结尾。
  static List<String> _tagsOf(String text) {
    final out = <String>[];
    for (final m in RegExp(r'#([^#\s,，。！!?？、；;\n]+)').allMatches(text)) {
      final tag = (m.group(1) ?? '').trim();
      if (tag.isNotEmpty && !out.contains(tag)) out.add(tag);
    }
    return out;
  }

  /// 在话题标签里挑菜名。
  ///
  /// 硬门槛：必须带食材字或烹饪字，长度 2~10，不含数字英文，不命中营销黑名单。
  /// **第一个通过门槛的标签就是主菜名**：作者标话题时习惯把菜名放最前面，
  /// 后面跟的是做法、活动、泛标签。只有当后面的候选明显更像菜名（高 8 分以上）
  /// 才替换，避免「#自制牛排 #煎牛排」被后者抢走。
  static TitlePick? _pickFromTags(List<String> tags, String body) {
    String? best;
    var bestScore = -999;
    for (var i = 0; i < tags.length && i < 30; i++) {
      final tag = _trimFiller(tags[i]
          .replaceAll(
              RegExp(r'[\u2600-\u27BF\uD83C-\uDBFF\uDC00-\uDFFF]'), '')
          .trim());
      if (tag.length < 2 || tag.length > 10) continue;
      if (RegExp(r'[a-zA-Z0-9]').hasMatch(tag)) continue;
      if (_tagBlacklist.any((w) => tag.contains(w))) continue;
      if (!looksLikeDish(tag)) continue;

      var sc = _score(tag) + 12;
      // 标签里的食材在正文里真的出现过，再确认一次
      if (_appearsInBody(tag, body)) sc += 3;
      if (best == null || sc > bestScore + 8) {
        bestScore = sc;
        best = tag;
      }
    }
    return best == null ? null : TitlePick(best, true, '话题标签');
  }

  static bool _appearsInBody(String tag, String body) {
    for (final ch in tag.split('')) {
      if ((_foodChars.contains(ch) || _cookChars.contains(ch)) &&
          body.contains(ch)) {
        return true;
      }
    }
    return false;
  }

  static bool _hasChatter(String s) => _chatter.any((w) => s.contains(w));

  /// 去掉首尾的虚词和标点残留
  static String _trimFiller(String s) {
    var r = s.trim();
    var changed = true;
    while (changed && r.isNotEmpty) {
      changed = false;
      if (_filler.contains(r[0])) {
        r = r.substring(1);
        changed = true;
      }
      if (r.isNotEmpty && _filler.contains(r[r.length - 1])) {
        r = r.substring(0, r.length - 1);
        changed = true;
      }
    }
    return r.trim();
  }

  static int _cnLength(String s) =>
      s.replaceAll(RegExp(r'[^\u3400-\u4dbf\u4e00-\u9fa5a-zA-Z]'), '').length;

  /// 像菜名就打正分：字数适中、带烹饪字、带食材字；
  /// 带数字/英文、夹虚词、太长，都扣分。
  static int _score(String s) {
    final n = s.length;
    var sc = 0;
    if (n >= 2 && n <= 6) {
      sc += 3;
    } else if (n <= 8) {
      sc += 2;
    } else {
      sc -= (n - 8) * 2;
    }

    var cook = 0;
    var food = 0;
    for (final ch in s.split('')) {
      if (_cookChars.contains(ch)) cook++;
      if (_foodChars.contains(ch)) food++;
    }
    sc += cook * 4 + food * 3;

    // 【v1.40】没有任何食材字、也没有任何烹饪字的一段，基本不可能是菜名 ——
    // 它是「这一口要命了」「一吃一个不吱声」「太香了」这类夸词。
    if (cook == 0 && food == 0) {
      sc -= 8;
    } else {
      // 反过来，带料的要给一个明确的确认分，稳稳压过短夸词
      sc += 5;
    }

    if (RegExp(r'[a-zA-Z0-9]').hasMatch(s)) sc -= 4;
    if (RegExp(r'[的了啊呀呢吗吧]').hasMatch(s)) sc -= 5;
    return sc;
  }
}

/// 一次菜名挑选的结果。[confident] 为 false 时 [title] 为空，
/// 调用方应提示用户自己填，而不是把整句标题党端上去。
class TitlePick {
  final String title;
  final bool confident;
  final String reason;
  const TitlePick(this.title, this.confident, this.reason);

  @override
  String toString() => 'TitlePick($title, $confident, $reason)';
}
