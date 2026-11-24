// 统一风格菜谱长图（v1.8 重排版）。
//
// 用户的原话：「菜谱显示顺序有点乱，上面是照片、下面是步骤，前期准备又混在一起，
// 做菜的时候不方便看。」所以这一版按「做饭时的视线顺序」重排：
//
//   封面大图 → 菜名 → 一句话 → 用料（主料/调料分开）→ 做法（每步配自己的画面）→ 小贴士
//
// 和旧版的三个差别：
//   1) 顶部是**封面**（视频结尾最清晰那帧），不再是 6 张平均分的小图堆在一起；
//   2) 每一张图跟着**它自己那一步**走，而不是全堆在开头；
//   3) 用料分「主料 / 调料」，做菜时抓调料不会抓错。
//
// 宽度固定 360 逻辑像素，高度自适应；预览页用 RepaintBoundary 截成 PNG。
import 'dart:io';

import 'package:flutter/material.dart';

import '../config/build_flavor.dart';
import '../models/recipe.dart';
import '../theme/app_theme.dart';
import 'step_photo.dart';

/// 用料分组：本地按名字猜，不额外调 AI（省钱、也不会编造）。
/// 只分两类就够用 —— 做菜时真正要区分的是「主菜」和「调味」。
class _IngGroup {
  final String title;
  final List<Ingredient> items;
  const _IngGroup(this.title, this.items);
}

const List<String> _seasoningKeys = <String>[
  '盐', '糖', '生抽', '老抽', '酱油', '蚝油', '料酒', '醋', '味精', '鸡精',
  '胡椒', '淀粉', '生粉', '油', '香油', '豆瓣', '甜面酱', '番茄酱', '辣椒面',
  '花椒', '八角', '桂皮', '香叶', '孜然', '五香粉', '十三香', '芝麻', '蒜粉',
];

List<_IngGroup> _groupIngredients(List<Ingredient> all) {
  final main = <Ingredient>[];
  final seasoning = <Ingredient>[];
  for (final i in all) {
    final n = i.name.trim();
    final isSeasoning = _seasoningKeys.any((k) => n.contains(k));
    (isSeasoning ? seasoning : main).add(i);
  }
  final groups = <_IngGroup>[];
  if (main.isNotEmpty) groups.add(_IngGroup('主料', main));
  if (seasoning.isNotEmpty) groups.add(_IngGroup('调料', seasoning));
  return groups;
}

class RecipeCardWidget extends StatelessWidget {
  final Recipe recipe;

  const RecipeCardWidget({super.key, required this.recipe});

  bool _fileExists(String p) => p.trim().isNotEmpty && File(p).existsSync();

  @override
  Widget build(BuildContext context) {
    final validTips = recipe.tips.where((e) => e.trim().isNotEmpty).toList();
    final cover = _fileExists(recipe.coverPath) ? recipe.coverPath : '';
    // 没有单独封面时，退回头几张实拍图里第一张还能打开的
    final fallbackCover = cover.isNotEmpty
        ? cover
        : recipe.photoPaths.firstWhere(_fileExists, orElse: () => '');

    return Container(
      width: 360,
      color: AppColors.card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (fallbackCover.isNotEmpty) _coverImage(fallbackCover),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _header(),
                if (recipe.intro.trim().isNotEmpty) ...[
                   SizedBox(height: 10),
                  Text(recipe.intro.trim(), style: AppText.bodySub),
                ],
                const SizedBox(height: 22),
                _sectionTitle('用料', Icons.shopping_basket_outlined),
                const SizedBox(height: 10),
                _ingredients(),
                if (recipe.steps.isNotEmpty) ...[
                  const SizedBox(height: 26),
                  _sectionTitle('做法', Icons.restaurant_menu_outlined),
                  const SizedBox(height: 14),
                  ..._steps(),
                ],
                if (validTips.isNotEmpty) ...[
                  const SizedBox(height: 26),
                  _sectionTitle('小贴士', Icons.lightbulb_outline),
                  const SizedBox(height: 10),
                  _tips(validTips),
                ],
                const SizedBox(height: 26),
                _footer(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 封面：满宽出血（360 x 200），底部叠一层淡渐变压住边界，图不会显得突兀。
  Widget _coverImage(String path) {
    return SizedBox(
      width: 360,
      height: 200,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.file(File(path), fit: BoxFit.cover),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 70,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    AppColors.card.withAlpha(0),
                    AppColors.card,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 5,
              height: 30,
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
             SizedBox(width: 12),
            Expanded(
              child: Text(
                recipe.title.trim().isEmpty ? '未命名菜谱' : recipe.title.trim(),
                style: AppText.title,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            _chip(recipe.tag),
            _chip('${recipe.ingredients.length} 种用料'),
            _chip('${recipe.steps.length} 步'),
          ],
        ),
      ],
    );
  }

  Widget _chip(String text) => Container(
        padding:  EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.primarySoft,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          text,
          style:  TextStyle(
            fontSize: 11,
            color: AppColors.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  Widget _sectionTitle(String text, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 20, color: AppColors.primary),
         SizedBox(width: 8),
        Text(text, style: AppText.section),
         SizedBox(width: 12),
         Expanded(
          child: Divider(color: AppColors.line, thickness: 1, height: 1),
        ),
      ],
    );
  }

  Widget _ingredients() {
    if (recipe.ingredients.isEmpty) {
      return _emptyHint('还没有用料，回上一页补一下');
    }
    final groups = _groupIngredients(recipe.ingredients);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.cream,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var g = 0; g < groups.length; g++) ...[
            if (g > 0)  SizedBox(height: 12),
            Text(
              groups[g].title,
              style:  TextStyle(
                fontSize: 12,
                color: AppColors.subInk,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 4),
            ...groups[g].items.map(_ingRow),
          ],
        ],
      ),
    );
  }

  Widget _ingRow(Ingredient i) => Padding(
        padding:  EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: Text(
                i.name.trim().isEmpty ? '—' : i.name.trim(),
                style: AppText.body,
              ),
            ),
             SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: Text(
                i.amount.trim(),
                style:  TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      );

  List<Widget> _steps() {
    final widgets = <Widget>[];
    for (var idx = 0; idx < recipe.steps.length; idx++) {
      final s = recipe.steps[idx];
      final img = _fileExists(s.photoPath) ? s.photoPath : '';
      widgets.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration:  BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${idx + 1}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                 SizedBox(width: 10),
                Expanded(
                  child: Padding(
                    padding:  EdgeInsets.only(top: 1),
                    child: Text(
                      s.text.trim().isEmpty ? '（这一步还没写）' : s.text.trim(),
                      style: AppText.body,
                    ),
                  ),
                ),
              ],
            ),
            // 这一步自己的画面：整整宽，跟着文字走，做菜时眼睛不用来回跳。
            //
            // 【v1.16 修正】原来是 320×150 配 BoxFit.cover。抖⾳/⼩红书的做菜视频
            // 全是竖屏 9:16，塞进 32:15 的横条里，cover 会横向撑满、纵向砍掉 74%，
            // 只剩中间一条窄带 —— 用户看到的正好是案板边缘、手腕、空桌面，
            // 而锅里正在发生的事被裁在上方或下方。
            // 改成 contain：整帧缩进去，一张都不裁，四周用米色底补齐。
            // 竖屏帧因此会窄一些（295×200 里约 112 宽），但"看到的是不是这一步"
            // 比"图够不够大"重要 —— 看不全可以点开看大图，看错了就是误导。
            if (img.isNotEmpty) ...[
               SizedBox(height: 10),
              // v1.27：固定高度 + 同一张图模糊铺底，长图里也不会出现一条条米色空边。
              // 长图是实时截屏，这里不做异步量尺寸（图没解码完就截会截成空白）。
              StepPhoto(
                path: img,
                fixedHeight: 200,
                radius: 10,
                softFail: true,
              ),
            ],
            if (s.tip.trim().isNotEmpty) ...[
               SizedBox(height: 8),
              Container(
                padding:  EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                     Icon(Icons.priority_high_rounded,
                        size: 15, color: AppColors.primary),
                     SizedBox(width: 6),
                    Expanded(
                      child: Text('关键点：${s.tip.trim()}', style: AppText.tip),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      );
      if (idx != recipe.steps.length - 1) {
        widgets.add(const SizedBox(height: 20));
      }
    }
    return widgets;
  }

  Widget _tips(List<String> tips) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: tips
          .map(
            (t) => Padding(
              padding:  EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('·  ', style: AppText.body),
                  Expanded(child: Text(t.trim(), style: AppText.bodySub)),
                ],
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _footer() {
    final d = recipe.createdAt;
    final date =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return Container(
      padding:  EdgeInsets.only(top: 14),
      decoration:  BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (recipe.sourceUrl.trim().isNotEmpty)
            Text(
              '来源：${recipe.sourceUrl.trim()}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption,
            ),
           SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('$kAppName · $date', style: AppText.caption),
              Text('照着做就行', style: AppText.caption),
            ],
          ),
        ],
      ),
    );
  }

  Widget _emptyHint(String text) => Container(
        padding:  EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.cream,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text, style: AppText.bodySub),
      );
}
