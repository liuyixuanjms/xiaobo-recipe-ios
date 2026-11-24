// 出图层：把预览页里已经排好版、已挂载绘制的菜谱卡片「拍」成 PNG 存到本机。
// 用 Flutter 界面组件排版再截图，好处是：不依赖服务器、风格 100% 统一、生成完断网也能看。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'storage_service.dart';

class ImageExporter {
  /// [repaintKey] 是包住 RecipeCardWidget 的 RepaintBoundary 的 GlobalKey。
  /// 返回落盘后的 PNG 路径。
  static Future<String> capture({
    required GlobalKey repaintKey,
    required String recipeId,
  }) async {
    final ctx = repaintKey.currentContext;
    if (ctx == null) {
      throw StateError('卡片还没渲染好，稍等一下再点保存');
    }
    final boundary = ctx.findRenderObject();
    if (boundary is! RenderRepaintBoundary) {
      throw StateError('卡片没有用 RepaintBoundary 包住');
    }

    // 等这一帧画完再截。
    //
    // 【v1.7.1 修的坑】以前这里写的是 `if (boundary.debugNeedsPaint)`。
    // `debugNeedsPaint` 是 **debug 专用** getter，内部是
    // `late bool result; assert((){ result=...; }()); return result;` ——
    // release 包里 assert 被整段剥离，`result` 从未赋值，一读就抛
    // `LateInitializationError: Local 'result' has not been initialized`。
    // 表现为「点保存 → 9 毫秒后失败」，而 debug 包完全正常。
    // 所以：release 包里绝对不能碰任何 debugXxx 的 getter。
    // 等一帧画完再多给 120ms：图片解码和文字排版都完成后截，才不会截出白块。
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 120));

    // 卡片逻辑宽 360，×3 ≈ 1080px 清晰度。
    // 步骤特别多时高度会很大，自动降倍率，避免超出 GPU 纹理上限导致截图失败/空白。
    double ratio = 3.0;
    final double height = boundary.size.height;
    const double maxPixels = 6000.0;
    if (height * ratio > maxPixels) {
      ratio = maxPixels / height;
      if (ratio < 1.0) ratio = 1.0;
    }

    ui.Image image;
    try {
      image = await boundary.toImage(pixelRatio: ratio);
    } on Exception {
      // 长图超过 GPU 纹理上限时，toImage 会直接失败：降到 1 倍再试一次，
      // 宁可稍微糊一点，也不能让用户白点一次。
      image = await boundary.toImage(pixelRatio: 1.0);
    }
    final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) throw StateError('图片生成失败，再试一次');

    return StorageService().saveImage(recipeId, data.buffer.asUint8List());
  }
}
