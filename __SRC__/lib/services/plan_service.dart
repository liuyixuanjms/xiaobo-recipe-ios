// 本周菜单 + 买菜清单（v1.30 新增）。
//
// 用户的设想原话：「想加一个每周集中采购或者买菜时候需要买什么的功能，
// 能把存下来的菜加到将要做菜单里面。」
//
// 所以需要两层数据：
//   1) 菜单：哪几道菜这周打算做 —— 只存菜谱 id，菜谱本身还是那份数据，不复制。
//   2) 勾选：清单上哪几样已经买到 —— 只存在本机，纯 UI 状态，不进菜谱。
//
// 合并规则值得说明：同一个「蒜」，三道菜各写 3 瓣 / 2 头 / 适量，合并成一行
// 把三种用量都列出来，而不是相加 —— 因为单位不统一，硬加会算出「5 头蒜」这种
// 没法照着买的东西。宁可多列一个，也不要给一个错的数。
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/recipe.dart';

/// 清单上的一行
class ShoppingItem {
  /// 归一化后的名字，勾选状态拿它当 key（跨重启稳定）
  final String key;
  final String name;
  /// 各道菜写的用量，去重后按出现顺序；可能为空（原文没写用量）
  final List<String> amounts;
  /// 哪几道菜要用它 —— 买多了的时候能反查是不是漏了菜
  final List<String> fromRecipes;
  final String group;

  const ShoppingItem({
    required this.key,
    required this.name,
    required this.amounts,
    required this.fromRecipes,
    required this.group,
  });

  String get amountText => amounts.join(' + ');
}

class PlanService {
  PlanService._();
  static final PlanService instance = PlanService._();

  static const String _kMenu = 'plan_menu_ids_v1';
  static const String _kBought = 'plan_bought_keys_v1';

  /// 菜单变化时通知（首页购物袋角标、详情页按钮状态都听它）
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  SharedPreferences? _prefs;

  Future<SharedPreferences> _p() async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<Set<String>> loadMenu() async {
    final p = await _p();
    return (p.getStringList(_kMenu) ?? const <String>[]).toSet();
  }

  Future<bool> inMenu(String recipeId) async =>
      (await loadMenu()).contains(recipeId);

  /// 加进本周菜单 / 拿出来。返回操作后「是否在菜单里」。
  Future<bool> toggleMenu(String recipeId) async {
    final p = await _p();
    final ids = (p.getStringList(_kMenu) ?? const <String>[]).toList();
    final has = ids.remove(recipeId);
    if (!has) ids.add(recipeId);
    await p.setStringList(_kMenu, ids);
    if (!has) {
      // 新加的菜：把它的勾选状态清干净，避免复用上次同名的勾
      await _pruneBought(ids);
    }
    revision.value++;
    return !has;
  }

  Future<void> removeFromMenu(String recipeId) async {
    final p = await _p();
    final ids = (p.getStringList(_kMenu) ?? const <String>[]).toList()
      ..remove(recipeId);
    await p.setStringList(_kMenu, ids);
    await _pruneBought(ids);
    revision.value++;
  }

  Future<void> clearMenu() async {
    final p = await _p();
    await p.remove(_kMenu);
    await p.remove(_kBought);
    revision.value++;
  }

  Future<Set<String>> loadBought() async {
    final p = await _p();
    return (p.getStringList(_kBought) ?? const <String>[]).toSet();
  }

  Future<void> toggleBought(String key) async {
    final p = await _p();
    final s = (p.getStringList(_kBought) ?? const <String>[]).toList();
    if (!s.remove(key)) s.add(key);
    await p.setStringList(_kBought, s);
  }

  /// 全部取消勾选（下次采购重新开始）
  Future<void> resetBought() async {
    final p = await _p();
    await p.remove(_kBought);
  }

  /// 菜单变了以后，把已经不在清单上的食材勾选状态清掉
  Future<void> _pruneBought(List<String> menuIds) async {
    final p = await _p();
    final bought = p.getStringList(_kBought);
    if (bought == null || bought.isEmpty) return;
    // 这里没有菜谱实体，无法精确重算，索性只在新加菜时全清一次 ——
    // 加菜意味着菜单变了，旧的「已买」勾不再可信。
    await p.remove(_kBought);
  }

  // ───────────────────────── 分类 ─────────────────────────

  /// 食谱按超市动线分组，而不是按「主料/辅料/调料」。
  /// 理由：这个清单是拿在超市里走的东西，按生鲜区 → 肉档 → 水产 → 干货
  /// 的顺序排，比按菜谱逻辑排有用得多。
  static const List<String> groupOrder = [
    '蔬菜水果',
    '肉蛋',
    '水产',
    '主食豆制品',
    '调料干货',
    '其他',
  ];

  static const List<String> _veg = [
    '菜', '葱', '姜', '蒜', '椒', '瓜', '茄', '豆角', '笋', '菇', '萝卜', '藕',
    '芹', '韭', '菠菜', '生菜', '番茄', '土豆', '山药', '玉米', '洋葱', '西兰花',
    '香菜', '香葱', '小米辣', '青椒', '红椒', '彩椒', '莲藕', '南瓜', '冬瓜',
    '黄瓜', '西红柿', '苹果', '柠檬', '橙', '莓', '香蕉', '牛油果', '梨', '葡萄',
  ];
  static const List<String> _meat = [
    '猪', '牛', '羊', '鸡', '鸭', '鹅', '肉', '排骨', '培根', '火腿', '香肠',
    '蛋', '鹌鹑', '午餐肉', '腊肠', '里脊', '五花', '鸡翅', '鸡腿', '鸡胸',
  ];
  static const List<String> _sea = [
    '虾', '鱼', '蟹', '贝', '蛤', '鱿', '墨鱼', '花甲', '蛏', '扇贝', '海参',
    '鲍', '海带', '紫菜', '虾仁', '蚝豉', '蛎',
  ];
  static const List<String> _staple = [
    '米', '面', '粉', '馒头', '年糕', '豆腐', '豆皮', '腐竹', '米线', '面包',
    '粉丝', '意面', '馄饨', '饺子', '汤圆', '燕麦', '吐司',
  ];
  static const List<String> _season = [
    '油', '盐', '糖', '酱', '醋', '酒', '胡椒', '花椒', '八角', '桂皮', '香叶',
    '味精', '鸡精', '淀粉', '生粉', '蚝油', '豆瓣', '蜂蜜', '芝士', '黄油',
    '孜然', '咖喱', '五香', '十三香', '芥末', '沙拉', '番茄酱', '芝麻', '干辣椒',
    '豆豉', '腐乳', '泡打粉', '酵母', '香油', '辣椒面', '椒盐', '黑胡椒',
    // 生抽 / 老抽 不带「油」也不带「酱」，单靠上面那串认不出来，
    // 会被归到「其他」去 —— 超市里翻半天找不到酱油，这条必须单独列。
    '生抽', '老抽', '豉油', '鱼露', '蒸鱼',
  ];

  static String groupOf(String name) {
    final n = name.replaceAll(RegExp(r'\s+'), '');
    if (n.isEmpty) return '其他';
    // 先判调料：像「蒜蓉辣酱」这种既像蔬菜又像调料的名字，带「酱/油/粉」
    // 的应该进调料区，所以调料优先，但要排除「面粉」「米粉」这类主食。
    final isFlour = n.contains('面粉') || n.contains('米粉') || n.contains('糯米粉');
    if (!isFlour) {
      for (final w in _season) {
        if (n.contains(w)) return '调料干货';
      }
    }
    for (final w in _sea) {
      if (n.contains(w)) return '水产';
    }
    for (final w in _meat) {
      if (n.contains(w)) return '肉蛋';
    }
    // 蔬菜要排在主食前面。踩过一次坑：「小米辣」里有「米」，
    // 先判主食就把一整袋小米辣塞进米面区去了。
    for (final w in _veg) {
      if (n.contains(w)) return '蔬菜水果';
    }
    for (final w in _staple) {
      if (n.contains(w)) return '主食豆制品';
    }
    return '其他';
  }

  // ───────────────────────── 合并成清单 ─────────────────────────

  /// 把菜单里的菜谱用料合并成一张有顺序、去重的采购清单。
  static List<ShoppingItem> buildList(List<Recipe> recipes) {
    final nameOf = <String, String>{}; // key -> 首次出现的原始名
    final amountsOf = <String, List<String>>{};
    final fromOf = <String, List<String>>{};
    final order = <String>[];

    for (final r in recipes) {
      for (final ing in r.ingredients) {
        final raw = ing.name.trim();
        if (raw.isEmpty) continue;
        final key = _norm(raw);
        if (!nameOf.containsKey(key)) {
          nameOf[key] = raw;
          amountsOf[key] = <String>[];
          fromOf[key] = <String>[];
          order.add(key);
        }
        final amt = ing.amount.trim();
        if (amt.isNotEmpty && !amountsOf[key]!.contains(amt)) {
          amountsOf[key]!.add(amt);
        }
        final t = r.title.trim();
        if (t.isNotEmpty && !fromOf[key]!.contains(t)) fromOf[key]!.add(t);
      }
    }

    final items = <ShoppingItem>[];
    for (final key in order) {
      final name = nameOf[key]!;
      items.add(ShoppingItem(
        key: key,
        name: name,
        amounts: amountsOf[key]!,
        fromRecipes: fromOf[key]!,
        group: groupOf(name),
      ));
    }

    // 按超市动线排；同组内按名字排，便于扫一眼找
    items.sort((a, b) {
      final ga = groupOrder.indexOf(a.group);
      final gb = groupOrder.indexOf(b.group);
      if (ga != gb) return ga.compareTo(gb);
      return a.name.compareTo(b.name);
    });
    return items;
  }

  /// 归一化：去空白、去「适量」这类后缀噪音，保证「小米辣」和「小米辣 」
  /// 是同一行，「大蒜」「蒜」暂时不合并（可能是不同东西，宁多不少）。
  static String _norm(String s) => s
      .replaceAll(RegExp(r'[\s　]+'), '')
      .replaceAll(RegExp(r'[（(].*?[)）]'), '')
      .toLowerCase();

  /// 复制到微信 / 备忘录用的纯文本
  static String asText(List<ShoppingItem> items, Set<String> bought) {
    if (items.isEmpty) return '';
    final buf = StringBuffer('【本周买菜清单】\n');
    String? last;
    for (final it in items) {
      if (it.group != last) {
        buf.writeln('');
        buf.writeln('· ${it.group}');
        last = it.group;
      }
      final tick = bought.contains(it.key) ? '✓' : '□';
      final amt = it.amountText.isEmpty ? '' : '  ${it.amountText}';
      buf.writeln('$tick ${it.name}$amt');
    }
    return buf.toString().trimRight();
  }

  /// 调试/备份用
  static String encodeSet(Set<String> s) => jsonEncode(s.toList());

  static Set<String> decodeSet(String? s) {
    if (s == null || s.isEmpty) return <String>{};
    try {
      final l = jsonDecode(s);
      if (l is List) return l.map((e) => e.toString()).toSet();
    } catch (_) {}
    return <String>{};
  }
}
