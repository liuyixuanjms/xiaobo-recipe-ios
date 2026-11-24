// 首页卡片的尺寸换算（v1.43.2）——纯函数，方便写测试。
//
// 【为什么单独抽出来】
// 首页缩略图以前放在 Expanded 里，格子高由 GridView 的 childAspectRatio=0.72
// 拍死，图片区被撑得又高又长。缩略图用的是导出的**长图 PNG**（顶部写着菜名、
// 分类标签、「用料」），于是长图里那套字被裁进缩略图，卡片下方又放了一遍
// 菜名和「家常菜 · N 步」——一张卡两套标题、两套元信息，看着特别冗杂。
//
// 现在让图片区的宽高比等于长图封面的宽高比（360:200）。这样：
//   · 用独立实拍封面时：照片正好铺满，不变形；
//   · 退回长图时：BoxFit.cover 按宽度缩放，容器高度对应的正好是源图顶部
//     200 像素，也就是纯封面那一段，长图里的文字自然被裁在下面。
// 格子总高 = 封面高 + 文字区高，动态算，不同屏宽都不会留白或溢出。
class HomeCardLayout {
  const HomeCardLayout._();

  static const double pagePadding = 16;
  static const double spacing = 12;
  static const int columns = 2;

  /// 长图封面是 360×200 满宽出血（见 recipe_card.dart 的 _coverImage）。
  static const double coverAspect = 360 / 200;

  /// 卡片下方文字区的固定高度：菜名一行 + 元信息一行 + 内边距。
  static const double textHeight = 56;

  static double cardWidth(double gridWidth) =>
      (gridWidth - pagePadding * 2 - spacing * (columns - 1)) / columns;

  static double coverHeight(double gridWidth) =>
      cardWidth(gridWidth) / coverAspect;

  /// GridView 的 childAspectRatio。宽度异常时退回一个安全值，不崩布局。
  static double aspectRatio(double gridWidth) {
    final w = cardWidth(gridWidth);
    if (w <= 0) return 0.72;
    final h = coverHeight(gridWidth) + textHeight;
    return h <= 0 ? 0.72 : w / h;
  }
}
