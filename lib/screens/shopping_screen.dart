// 页面 8 · 买菜清单（v1.30 新增）。
//
// 两件事：从「本周菜单」里挑几道菜，再把它们的用料合并成一张能拿进超市的清单。
// 这里刻意不做「自动下单」「菜谱推荐」——买菜这件事，人只想要一张对得上的纸，
// 别的都是干扰。
import 'package:flutter/material.dart';

import '../models/recipe.dart';
import '../services/plan_service.dart';
import '../services/share_channel.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';

class ShoppingScreen extends StatefulWidget {
  const ShoppingScreen({super.key});

  @override
  State<ShoppingScreen> createState() => _ShoppingScreenState();
}

class _ShoppingScreenState extends State<ShoppingScreen> {
  final PlanService _plan = PlanService.instance;
  bool _loading = true;
  bool _hideBought = false;

  List<Recipe> _menuRecipes = const [];
  List<ShoppingItem> _items = const [];
  Set<String> _bought = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ids = await _plan.loadMenu();
    final all = await StorageService().loadRecipes();
    final menu = all.where((r) => ids.contains(r.id)).toList();
    final bought = await _plan.loadBought();
    if (!mounted) return;
    setState(() {
      _menuRecipes = menu;
      _items = PlanService.buildList(menu);
      _bought = bought;
      _loading = false;
    });
  }

  Future<void> _toggle(String key) async {
    await _plan.toggleBought(key);
    final s = Set<String>.from(_bought);
    if (!s.remove(key)) s.add(key);
    if (mounted) setState(() => _bought = s);
  }

  Future<void> _removeFromMenu(Recipe r) async {
    await _plan.removeFromMenu(r.id);
    await _load();
  }

  Future<void> _copy() async {
    final text = PlanService.asText(_items, _bought);
    if (text.isEmpty) return;
    final has = await ClipboardChannel.copy(text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(has ? '清单已复制，去微信粘贴给家人朋友' : '复制失败，长按文字自己复制'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _resetBought() async {
    await _plan.resetBought();
    if (mounted) setState(() => _bought = <String>{});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('买菜清单'),
        actions: [
          if (_items.isNotEmpty)
            IconButton(
              tooltip: '分享清单',
              icon: const Icon(Icons.ios_share),
              onPressed: _share,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _menuStrip(),
                if (_items.isEmpty) Expanded(child: _empty()) else ...[
                  _progressBar(),
                  Expanded(child: _list()),
                ],
              ],
            ),
      bottomNavigationBar: _items.isEmpty ? null : _bottomBar(),
    );
  }

  Future<void> _share() async {
    final text = PlanService.asText(_items, _bought);
    if (text.isEmpty) return;
    try {
      await ShareChannel.shareText(text, subject: '本周买菜清单');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('没调起分享：$e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  // ───────────── 本周菜单 ─────────────

  Widget _menuStrip() {
    if (_menuRecipes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
        child: Text(
          '还没有挑这周要做的菜。在菜谱页点右上角「···」，选「这周想做」，'
          '这里就会自动凑出一张采购清单。',
          style: AppText.caption,
        ),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      color: AppColors.card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.restaurant_menu,
                  size: 17, color: AppColors.primary),
              const SizedBox(width: 6),
              Text('这周想做的 ${_menuRecipes.length} 道菜',
                  style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink)),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _menuRecipes.map((r) {
              return Container(
                padding: const EdgeInsets.fromLTRB(11, 6, 5, 6),
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 130),
                      child: Text(
                        r.title.isEmpty ? '未命名' : r.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    InkWell(
                      onTap: () => _removeFromMenu(r),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: Icon(Icons.close,
                            size: 14, color: AppColors.primary),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _progressBar() {
    final done = _items.where((i) => _bought.contains(i.key)).length;
    final total = _items.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : done / total,
                minHeight: 6,
                backgroundColor: AppColors.line,
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text('$done / $total',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.subInk)),
        ],
      ),
    );
  }

  Widget _list() {
    final shown = _hideBought
        ? _items.where((i) => !_bought.contains(i.key)).toList()
        : _items;
    if (shown.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🎉', style: TextStyle(fontSize: 40)),
            const SizedBox(height: 12),
            Text('全买齐了，可以开火啦', style: AppText.bodySub),
          ],
        ),
      );
    }

    // 按组切片
    final groups = <String, List<ShoppingItem>>{};
    for (final it in shown) {
      groups.putIfAbsent(it.group, () => <ShoppingItem>[]).add(it);
    }

    final children = <Widget>[];
    for (final g in PlanService.groupOrder) {
      final list = groups[g];
      if (list == null || list.isEmpty) continue;
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 6),
        child: Row(
          children: [
            Text(g,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary,
                    letterSpacing: 0.4)),
            const SizedBox(width: 8),
            Expanded(child: Divider(color: AppColors.line, height: 1)),
          ],
        ),
      ));
      for (final it in list) {
        children.add(_row(it));
      }
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 18),
      children: children,
    );
  }

  Widget _row(ShoppingItem it) {
    final on = _bought.contains(it.key);
    return InkWell(
      onTap: () => _toggle(it.key),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 9, 18, 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 手绘感太重的勾选框不如一个圆圈干净
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: on ? AppColors.primary : Colors.transparent,
                  border: Border.all(
                    color: on ? AppColors.primary : AppColors.line,
                    width: 1.6,
                  ),
                ),
                child: on
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          it.name,
                          style: TextStyle(
                            fontSize: 16,
                            height: 1.35,
                            color: on ? AppColors.subInk : AppColors.ink,
                            decoration:
                                on ? TextDecoration.lineThrough : null,
                            decorationColor: AppColors.subInk,
                          ),
                        ),
                      ),
                      if (it.amountText.isNotEmpty) ...[
                        const SizedBox(width: 10),
                        Text(
                          it.amountText,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: on ? AppColors.subInk : AppColors.primary,
                            decoration:
                                on ? TextDecoration.lineThrough : null,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (it.fromRecipes.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        it.fromRecipes.join(' / '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🛒', style: TextStyle(fontSize: 44)),
            const SizedBox(height: 16),
            Text(
              _menuRecipes.isEmpty
                  ? '先在菜谱里挑几道这周想做的菜'
                  : '这几道菜的用料都还是空的',
              textAlign: TextAlign.center,
              style: AppText.bodySub,
            ),
            const SizedBox(height: 8),
            Text(
              _menuRecipes.isEmpty
                  ? '打开一道菜，点右上角「···」，选「这周想做」'
                  : '回菜谱里把用料补上，清单会自动更新',
              textAlign: TextAlign.center,
              style: AppText.caption,
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar() {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: BoxDecoration(
          color: AppColors.card,
          border: Border(top: BorderSide(color: AppColors.line)),
        ),
        child: Row(
          children: [
            // 隐藏已买
            InkWell(
              onTap: () => setState(() => _hideBought = !_hideBought),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      _hideBought
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 18,
                      color: AppColors.subInk,
                    ),
                    const SizedBox(width: 5),
                    Text(_hideBought ? '显示已买' : '收起已买',
                        style: TextStyle(
                            fontSize: 12.5, color: AppColors.subInk)),
                  ],
                ),
              ),
            ),
            const Spacer(),
            if (_bought.isNotEmpty)
              TextButton(
                onPressed: _resetBought,
                child: Text('全部取消',
                    style:
                        TextStyle(fontSize: 12.5, color: AppColors.subInk)),
              ),
            const SizedBox(width: 6),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              ),
              onPressed: _copy,
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('复制清单',
                  style:
                      TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}
