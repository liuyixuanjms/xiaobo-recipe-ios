// 菜谱数据模型：AI 整理出来的结构化结果、校对页编辑结果、长图渲染，全部用这一个类。
// V1 存成本机 JSON 字符串，不引数据库。
// V0.12：新增 photoPaths —— 用户带进来的实景截图/视频帧，会成组排进长图。
import 'dart:convert';

class Ingredient {
  String name; // 食材名
  String amount; // 用量（含单位），原文没写就留空，禁止 AI 编造

  Ingredient({this.name = '', this.amount = ''});

  Map<String, dynamic> toJson() => {'name': name, 'amount': amount};

  static Ingredient fromJson(Map<String, dynamic> j) => Ingredient(
        name: (j['name'] ?? '').toString(),
        amount: (j['amount'] ?? '').toString(),
      );
}

class StepItem {
  String text; // 这一步做什么
  String tip; // 这一步的关键点：火候 / 状态 / 时间 / 手法
  /// v1.8：这一步对应的实拍图（本机路径）。空字符串表示这一步没配上图，
  /// 长图和「一步步做」页会留出文字位，而不是硬塞一张不相干的画面。
  String photoPath;

  /// v1.10：这一步大致发生在视频第几秒。
  ///
  /// AI 拿到的字幕是**带时间戳**的（「[12] 先把蒜苔切段」），所以它能直接把
  /// 每一步「指」到某一句字幕上。配图就从这里取时间，而不是靠步骤文字跟
  /// 帧字幕算相似度去猜 —— 步骤是模型改写过的措辞，猜出来经常错位。
  /// -1 表示模型没标（或标注越界被丢弃），这时才退回按比例+相似度匹配。
  int atSec;

  StepItem({
    this.text = '',
    this.tip = '',
    this.photoPath = '',
    this.atSec = -1,
  });

  Map<String, dynamic> toJson() =>
      {'text': text, 'tip': tip, 'photoPath': photoPath, 'atSec': atSec};

  static StepItem fromJson(Map<String, dynamic> j) => StepItem(
        text: (j['text'] ?? '').toString(),
        tip: (j['tip'] ?? '').toString(),
        photoPath: (j['photoPath'] ?? '').toString(),
        atSec: int.tryParse('${j['atSec'] ?? '-1'}') ?? -1,
      );
}

class Recipe {
  // 「重新整理」时会保留同一个 id，覆盖同一张长图，不产生重复记录
  String id;
  String title;
  String intro;
  String tag; // 分类标签：家常菜 / 汤 / 烘焙 ...
  String sourceUrl; // 出处链接，仅作备注，不自动抓取
  List<Ingredient> ingredients;
  List<StepItem> steps;
  List<String> tips;
  DateTime createdAt;
  String? imagePath; // 生成好的长图 PNG 在 App 私有目录里的路径

  /// 【已废弃】v1.8 时的长图皮肤：'clean' 清爽版 / 'hand' 手绘纸感版。
  /// v1.30 起手绘整套下线，不再写入、不再渲染。字段保留只是为了老存档
  /// 反序列化时不吃到未知字段而报错，将来可以安全删掉。
  String style;

  /// v1.8：成品封面图（本机路径）。取视频结尾最清晰的一帧，当长图头图用。
  String coverPath;

  /// 实景图片（用户从视频里截的画面 / 图文原图），落盘后的本机路径。
  /// 长图渲染时会成组插到「用料」上方；App 只读本机文件，不依赖原链接。
  List<String> photoPaths;

  /// v1.16：原视频在本机的位置。
  ///
  /// 用户的原话：「能不能把这个视频也放到菜谱里？能来回拖动、能播放、能自动循环，
  /// 我做饭的时候能看到原样。」—— 做饭时最想看的其实是"人家那个手法"，
  /// 截图只能定格，视频才看得出手是往哪边翻的。
  ///
  /// 空字符串 = 没有视频（图文笔记、或者存的太失败）。
  /// 视频一律压在 720p / 1.2Mbps 左右，三分钟约 25MB，不至于把手机塞满。
  String videoPath;

  Recipe({
    required this.id,
    this.title = '',
    this.intro = '',
    this.tag = '家常菜',
    this.sourceUrl = '',
    List<Ingredient>? ingredients,
    List<StepItem>? steps,
    List<String>? tips,
    DateTime? createdAt,
    this.imagePath,
    this.style = 'clean',
    this.coverPath = '',
    this.videoPath = '',
    List<String>? photoPaths,
  })  : ingredients = ingredients ?? [],
        steps = steps ?? [],
        tips = tips ?? [],
        photoPaths = photoPaths ?? [],
        createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'intro': intro,
        'tag': tag,
        'sourceUrl': sourceUrl,
        'ingredients': ingredients.map((e) => e.toJson()).toList(),
        'steps': steps.map((e) => e.toJson()).toList(),
        'tips': tips,
        'createdAt': createdAt.toIso8601String(),
        'imagePath': imagePath,
        'style': style,
        'coverPath': coverPath,
        'photoPaths': photoPaths,
        'videoPath': videoPath,
      };

  static Recipe fromJson(Map<String, dynamic> j) => Recipe(
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        intro: (j['intro'] ?? '').toString(),
        tag: (j['tag'] ?? '家常菜').toString(),
        sourceUrl: (j['sourceUrl'] ?? '').toString(),
        ingredients: ((j['ingredients'] as List?) ?? [])
            .map((e) => Ingredient.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        steps: ((j['steps'] as List?) ?? [])
            .map((e) => StepItem.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        tips: ((j['tips'] as List?) ?? []).map((e) => e.toString()).toList(),
        createdAt: DateTime.tryParse((j['createdAt'] ?? '').toString()) ?? DateTime.now(),
        imagePath: j['imagePath']?.toString(),
        style: (j['style'] ?? 'clean').toString(),
        coverPath: (j['coverPath'] ?? '').toString(),
        // 老版本数据没有这个字段，按空列表处理，保证旧存档照样能打开
        photoPaths: ((j['photoPaths'] as List?) ?? [])
            .map((e) => e.toString())
            .toList(),
        // 老版本数据没有这个字段，按空字符串处理，旧存档照样能打开
        videoPath: (j['videoPath'] ?? '').toString(),
      );

  String encode() => jsonEncode(toJson());

  static Recipe decode(String s) => fromJson(Map<String, dynamic>.from(jsonDecode(s) as Map));

  /// 深拷贝：校对页改动前先复制一份，避免直接改到列表缓存里的对象
  Recipe copy() => Recipe.decode(encode());

  /// 把 DeepSeek 返回的宽松 JSON 转成 Recipe。
  /// 做了容错：字段可能缺失、可能用了 quantity / 用量 之类的别名、可能返回字符串而非对象。
  static Recipe fromAiJson(
    Map<String, dynamic> j, {
    required String id,
    required String sourceUrl,
  }) {
    List<Map<String, dynamic>> asMapList(dynamic v) {
      if (v is! List) return <Map<String, dynamic>>[];
      return v
          .map((e) => e is Map
              ? Map<String, dynamic>.from(e)
              : <String, dynamic>{'name': e.toString()})
          .toList();
    }

    return Recipe(
      id: id,
      title: (j['title'] ?? '未命名菜谱').toString(),
      intro: (j['intro'] ?? '').toString(),
      sourceUrl: sourceUrl,
      ingredients: asMapList(j['ingredients'])
          .map((m) => Ingredient(
                name: (m['name'] ?? m['食材'] ?? '').toString(),
                amount: (m['amount'] ?? m['quantity'] ?? m['用量'] ?? '').toString(),
              ))
          .toList(),
      steps: asMapList(j['steps'])
          .map((m) {
            // at：这一步对应的字幕秒数。模型可能给 int、字符串、null 或者干脆不写，
            // 一律走这个宽松解析，解析不出来就当 -1（退回按比例匹配）。
            final rawAt = m['at'] ?? m['sec'] ?? m['秒'] ?? -1;
            final at = rawAt is int
                ? rawAt
                : (int.tryParse('$rawAt'.trim()) ?? -1);
            return StepItem(
              text: (m['text'] ?? m['desc'] ?? m['做法'] ?? '').toString(),
              tip: (m['tip'] ?? m['key'] ?? m['关键点'] ?? '').toString(),
              atSec: at < 0 ? -1 : at,
            );
          })
          .toList(),
      tips: ((j['tips'] as List?) ?? []).map((e) => e.toString()).toList(),
    );
  }
}
