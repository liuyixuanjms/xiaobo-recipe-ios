// 页面 4 · 长图预览：先看一眼排版，点「保存」才把卡片截成 PNG 落盘。
// 用一个真实的、已挂载绘制的 RepaintBoundary 截图，比「离屏自动生成」可靠得多，
// 也顺带给了用户一次「看一眼再存」的机会。
//
// v1.30：手绘皮肤整套下线。它当年是为了模仿另一种菜谱风格，实际用下来发现：
// 一是慢（一张长图要逐张重画水彩），二是存两份图占空间，三是用户根本没在用。
// 现在只有一套干净版，这一页也就回到最简单的一件事：看一眼，存下来。
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/recipe.dart';
import '../services/app_info.dart';
import '../services/image_exporter.dart';
import '../services/log_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/recipe_card.dart';

class PreviewScreen extends StatefulWidget {
  final Recipe recipe;

  const PreviewScreen({super.key, required this.recipe});

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  final GlobalKey _cardKey = GlobalKey();
  bool _saving = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    // 截图那一刻图片必须已经解码完，否则会截出空白块
    WidgetsBinding.instance.addPostFrameCallback((_) => _warm());
  }

  Future<void> _warm() async {
    final r = widget.recipe;
    final paths = <String>[
      if (r.coverPath.trim().isNotEmpty) r.coverPath,
      for (final s in r.steps)
        if (s.photoPath.trim().isNotEmpty) s.photoPath,
    ];
    for (final p in paths) {
      if (!File(p).existsSync()) continue;
      try {
        await precacheImage(FileImage(File(p)), context);
      } catch (_) {
        // 单张预热失败不阻塞，最多那张截出来是空的
      }
    }
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final logs = LogService.instance;
    final r0 = widget.recipe;
    try {
      // 若不是从新建页一路过来的（比如从已有菜谱单独重存），也给它一份记录
      if (!await logs.hasOpenSession()) {
        await logs.startSession('单独保存长图', <String, String>{
          'App 版本': AppInfo.version,
          '系统': LogService.platformInfo,
          '菜名': r0.title,
        });
      }
      await logs.log(
          '出图',
          '开始截长图｜菜名「${r0.title}」'
          '｜用料 ${r0.ingredients.length} 项｜步骤 ${r0.steps.length} 步'
          '｜实拍图 ${r0.photoPaths.length} 张');
      final path = await ImageExporter.capture(
        repaintKey: _cardKey,
        recipeId: widget.recipe.id,
      );
      final r = widget.recipe;
      r.imagePath = path;
      await StorageService().saveRecipe(r);
      await logs.log('出图', 'PNG 已生成并落盘｜$path');
      await logs.end(
          '✅ 成功：长图已生成并保存，用料 ${r.ingredients.length} 项 / ${r.steps.length} 步 / ${r.photoPaths.length} 张实拍图');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('存好啦，回到首页就能看到'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      // 回到首页并刷新（首页 push 新建页时挂的 then 会重新读列表）
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e, st) {
      await logs.log('失败',
          '生成长图异常：${e.runtimeType} $e｜堆栈 ${st.toString().split('\n').first}');
      await logs.end('❌ 生成长图失败：$e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('没存成，再点一次试试：$e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('看一眼再存')),
      body: SingleChildScrollView(
        // 卡片固定 360 逻辑宽；小屏机型若左右有点溢出，可把这里 padding 调到 0
        // 或把 RecipeCardWidget 的 width 调小，不影响内容完整性。
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 110),
        child: Center(
          child: RepaintBoundary(
            key: _cardKey,
            child: RecipeCardWidget(recipe: widget.recipe),
          ),
        ),
      ),
      bottomSheet: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _ready ? '上面就是存下来的样子，可以直接截图发朋友圈' : '正在把图片准备好…',
                style: AppText.caption,
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.favorite_border),
                  label: Text(
                    _saving ? '正在生成…' : '存进我的菜谱',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
