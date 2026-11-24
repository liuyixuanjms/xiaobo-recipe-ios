// 本地存储层：菜谱结构化数据存在 SharedPreferences，生成的长图 PNG 存在 App 私有目录。
// V1 不引数据库、不联网同步。注意：卸载 App 或换手机数据会丢，V2 会补「导出备份」。
// V0.12：新增 savePhotos —— 把用户带进来的实景截图整组落盘，长图渲染时读本机文件。
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/recipe.dart';

class StorageService {
  static const String _listKey = 'recipes_v1';
  static const String _imageDir = 'recipe_cards';
  static const String _photoDir = 'recipe_photos';

  Future<Directory> _imagesDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_imageDir');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _photosDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_photoDir');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<List<Recipe>> loadRecipes() async {
    final sp = await SharedPreferences.getInstance();
    final list = sp.getStringList(_listKey) ?? <String>[];
    final result = <Recipe>[];
    for (final s in list) {
      try {
        result.add(Recipe.decode(s));
      } catch (_) {
        // 跳过单条坏数据，不让一条脏记录导致整个列表打不开
      }
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  /// 按 id 新增或覆盖保存
  Future<void> saveRecipe(Recipe r) async {
    final sp = await SharedPreferences.getInstance();
    final list = sp.getStringList(_listKey) ?? <String>[];
    final idx = list.indexWhere((s) {
      try {
        return Recipe.decode(s).id == r.id;
      } catch (_) {
        return false;
      }
    });
    if (idx >= 0) {
      list[idx] = r.encode();
    } else {
      list.add(r.encode());
    }
    await sp.setStringList(_listKey, list);
  }

  Future<void> deleteRecipe(String id, {String? imagePath}) async {
    final sp = await SharedPreferences.getInstance();
    final list = sp.getStringList(_listKey) ?? <String>[];
    list.removeWhere((s) {
      try {
        return Recipe.decode(s).id == id;
      } catch (_) {
        return false;
      }
    });
    await sp.setStringList(_listKey, list);
    if (imagePath != null) {
      try {
        final f = File(imagePath);
        if (await f.exists()) await f.delete();
      } catch (_) {
        // 删图失败不影响删记录
      }
    }
    // 顺手清掉这道菜的实景组图（按 id 前缀）
    try {
      final dir = await _photosDir();
      if (await dir.exists()) {
        final files = dir.listSync();
        for (final f in files) {
          if (f is File && f.path.contains('${id}_photo_')) {
            await f.delete();
          }
        }
      }
    } catch (_) {}
    // v1.16：视频可能有几十兆，删菜谱时必须一起删，不然手机里会慢慢堆满孤儿文件
    await deleteVideo(id);
  }

  Future<void> clearAll() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_listKey);
    try {
      final dir = await _imagesDir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    try {
      final dir = await _photosDir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  Future<String> saveImage(String recipeId, Uint8List bytes) async {
    final dir = await _imagesDir();
    final file = File('${dir.path}/$recipeId.png');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// 把一组实景图落盘，返回本机路径列表。
  /// 文件名带 id 前缀，重新整理/覆盖时同名覆盖，不产生一堆垃圾文件。
  Future<List<String>> savePhotos(
    String recipeId,
    List<Uint8List> photos, {
    String tag = 'photo',
  }) async {
    if (photos.isEmpty) return <String>[];
    final dir = await _photosDir();
    final paths = <String>[];
    for (var i = 0; i < photos.length; i++) {
      if (photos[i].isEmpty) {
        paths.add('');
        continue;
      }
      final file = File('${dir.path}/${recipeId}_${tag}_$i.jpg');
      await file.writeAsBytes(photos[i], flush: true);
      paths.add(file.path);
    }
    return paths;
  }

  /// v1.16：原视频的落盘位置。
  /// 和长图放同一层，文件名带 id，重新生成时同名覆盖，不会攒出一堆垃圾。
  Future<File> videoFile(String recipeId) async {
    final dir = await _imagesDir();
    return File('${dir.path}/${recipeId}_video.mp4');
  }

  /// 删掉某道菜的视频（重整理、删除菜谱时用）。
  Future<void> deleteVideo(String recipeId) async {
    try {
      final f = await videoFile(recipeId);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 这道菜的视频占了多少空间（备份、显示用）。
  Future<int> videoBytes(String recipeId) async {
    try {
      final f = await videoFile(recipeId);
      if (await f.exists()) return await f.length();
    } catch (_) {}
    return 0;
  }
}
