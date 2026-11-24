// v1.13 · 备份与恢复
//
// 用户的原话：「没有备份导出功能。」
//
// 数据现状：菜谱存在 SharedPreferences，长图和步骤图存在 App 私有目录。
// 一旦卸载、换手机、清数据，全没了 —— 而整理一道菜要花 40 秒和几毛钱 token，
// 做过的菜谱是实实在在攒下来的东西，不能只活在一台手机里。
//
// 做法：所有东西打成一个 zip（菜谱数据 + 长图 + 步骤图），
// 通过系统分享发到微信 / 网盘 / 邮件；换机后选这个 zip 就能整包恢复。
//
// 为什么包里不存绝对路径：Android 每次安装的私有目录路径都可能不同，
// 存绝对路径换台手机就全指向不存在的文件。所以包内用 `files/img_1.png`
// 这种相对名，恢复时再换回本机真实路径。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/recipe.dart';
import 'storage_service.dart';

/// 导出结果：给界面显示「备份了 N 道菜、多大」。
class BackupResult {
  final String path;
  final int recipeCount;
  final int fileCount;
  final int bytes;
  const BackupResult({
    required this.path,
    required this.recipeCount,
    required this.fileCount,
    required this.bytes,
  });

  String get sizeText {
    if (bytes > 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}

class RestoreResult {
  final int added;
  final int updated;
  final int fileCount;
  final int broken;
  const RestoreResult({
    required this.added,
    required this.updated,
    required this.fileCount,
    required this.broken,
  });

  int get total => added + updated;
}

class BackupException implements Exception {
  final String message;
  const BackupException(this.message);
  @override
  String toString() => message;
}

class BackupService {
  static const int _formatVersion = 2;

  static const MethodChannel _ch = MethodChannel('com.xiaobo.recipe/share');

  /// 把备份包交给系统分享面板（微信 / 网盘 / 邮件都行）。
  static Future<void> shareBackup(String path) async {
    await _ch.invokeMethod<bool>('shareFile', <String, dynamic>{
      'path': path,
      'subject': '小波菜谱备份',
    });
  }

  /// 让用户自己挑一个备份包。返回本机临时路径；用户取消返回 null。
  static Future<String?> pickBackupFile() async {
    final p = await _ch.invokeMethod<String>('pickBackupFile');
    if (p == null || p.trim().isEmpty) return null;
    return p;
  }

  /// 导出：返回写好的 zip 文件。调用方拿路径去系统分享。
  Future<BackupResult> export() async {
    final recipes = await StorageService().loadRecipes();
    if (recipes.isEmpty) {
      throw const BackupException('现在还没有菜谱可以备份 —— 先整理出两道菜再来。');
    }

    final base = await getApplicationDocumentsDirectory();
    final archive = Archive();

    // 原路径 → 包内相对名。同一张图被多个字段引用时只存一份。
    final mapped = <String, String>{};
    var fileCount = 0;

    String packPath(String src) {
      if (src.trim().isEmpty) return '';
      final f = File(src);
      if (!f.existsSync()) return ''; // 文件已经丢了就当没有，别把空条目塞进包
      final hit = mapped[src];
      if (hit != null) return hit;
      final ext = _ext(src);
      final name = 'files/img_$fileCount$ext';
      fileCount++;
      mapped[src] = name;
      // 【v1.13】图片一律免压缩（stored）。
      // PNG / JPG 本身已经是压缩过的，再 deflate 一遍几乎压不下去 1%，
      // 却要多花十几秒 CPU 和一大块内存 —— 包里几百兆图时这个差别很致命。
      archive.addFile(
        ArchiveFile.noCompress(name, f.lengthSync(), f.readAsBytesSync()),
      );
      return name;
    }

    final out = <Map<String, dynamic>>[];
    for (final r in recipes) {
      final j = r.toJson();
      // 图片字段全部换成本包内名字
      final img = packPath(r.imagePath ?? '');
      j['imagePath'] = img.isEmpty ? null : img;
      j['coverPath'] = packPath(r.coverPath);
      j['photoPaths'] = r.photoPaths.map(packPath).where((e) => e.isNotEmpty).toList();
      final steps = <Map<String, dynamic>>[];
      for (final s in r.steps) {
        final m = s.toJson();
        m['photoPath'] = packPath(s.photoPath);
        steps.add(m);
      }
      j['steps'] = steps;
      out.add(j);
    }

    final manifest = <String, dynamic>{
      'format': _formatVersion,
      'app': '小波菜谱',
      'exportedAt': DateTime.now().toIso8601String(),
      'count': out.length,
      'recipes': out,
    };
    final jsonBytes = utf8.encode(const JsonEncoder.withIndent(' ').convert(manifest));
    archive.addFile(ArchiveFile('recipes.json', jsonBytes.length, jsonBytes));

    final bytes = ZipEncoder().encode(archive);
    if (bytes == null || bytes.isEmpty) {
      throw const BackupException('打包失败（压缩器没返回内容）');
    }

    final stamp = _stamp(DateTime.now());
    final dir = Directory('${(await getTemporaryDirectory()).path}/backup');
    if (!await dir.exists()) await dir.create(recursive: true);
    final outFile = File('${dir.path}/小波菜谱备份_$stamp.zip');
    await outFile.writeAsBytes(bytes, flush: true);

    // base 只用来确认私有目录还在，避免在异常的存储状态下写包
    if (!await base.exists()) {
      throw const BackupException('存储目录不可用，先重启一下手机再试');
    }

    return BackupResult(
      path: outFile.path,
      recipeCount: out.length,
      fileCount: fileCount,
      bytes: bytes.length,
    );
  }

  /// 导入：读 zip，把图片落到本机，再把菜谱合并进列表（同 id 覆盖）。
  Future<RestoreResult> restoreFrom(String zipPath) async {
    final f = File(zipPath);
    if (!await f.exists()) {
      throw const BackupException('这个文件找不到，可能已经被清理了，重新选一次');
    }
    final bytes = await f.readAsBytes();
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw const BackupException('这不是一个有效的小波菜谱备份包（解压失败）');
    }

    ArchiveFile? manifestFile;
    for (final a in archive) {
      if (a.name == 'recipes.json') {
        manifestFile = a;
        break;
      }
    }
    if (manifestFile == null) {
      throw const BackupException('这个包是别的东西，里面没有 recipes.json');
    }

    Map<String, dynamic> manifest;
    try {
      final text = utf8.decode(manifestFile.content as List<int>, allowMalformed: true);
      manifest = Map<String, dynamic>.from(jsonDecode(text) as Map);
    } catch (e) {
      throw const BackupException('备份包里的菜谱数据坏了，读不出来');
    }

    // 1) 先把包里的图片全部落到本机目录，记下「包内名 → 本机绝对路径」
    final imgDir = Directory('${(await getApplicationDocumentsDirectory()).path}/recipe_cards');
    if (!await imgDir.exists()) await imgDir.create(recursive: true);
    final landed = <String, String>{};
    for (final a in archive) {
      if (!a.isFile || !a.name.startsWith('files/')) continue;
      final name = a.name.substring('files/'.length);
      if (name.isEmpty) continue;
      try {
        final target = File('${imgDir.path}/r_$name');
        await target.writeAsBytes(a.content as List<int>, flush: true);
        landed[a.name] = target.path;
      } catch (_) {
        // 单张图写失败不影响整包恢复
      }
    }

    String unpackPath(String? packed) {
      if (packed == null || packed.trim().isEmpty) return '';
      return landed[packed.trim()] ?? '';
    }

    // 2) 再拼回菜谱。路径换成本机的，图片没落地的就留空（长图会留白，不会崩）
    final rawList = manifest['recipes'];
    if (rawList is! List) {
      throw const BackupException('备份包结构不对（recipes 不是列表）');
    }
    final existing = await StorageService().loadRecipes();
    final existingIds = existing.map((e) => e.id).toSet();
    final storage = StorageService();

    var added = 0, updated = 0, broken = 0;
    for (final item in rawList) {
      if (item is! Map) {
        broken++;
        continue;
      }
      final m = Map<String, dynamic>.from(item);
      try {
        m['imagePath'] = unpackPath(m['imagePath'] as String?);
        m['coverPath'] = unpackPath(m['coverPath'] as String?);
        final ph = m['photoPaths'];
        if (ph is List) {
          m['photoPaths'] =
              ph.map((e) => unpackPath(e?.toString())).where((e) => e.isNotEmpty).toList();
        }
        final steps = m['steps'];
        if (steps is List) {
          final fixed = <Map<String, dynamic>>[];
          for (final s in steps) {
            if (s is! Map) continue;
            final sm = Map<String, dynamic>.from(s);
            sm['photoPath'] = unpackPath(sm['photoPath'] as String?);
            fixed.add(sm);
          }
          m['steps'] = fixed;
        }
        // 空路径写成 null 更干净，fromJson 里按「没有图」处理
        if ((m['imagePath']?.toString() ?? '').isEmpty) m['imagePath'] = null;

        final r = Recipe.fromJson(m);
        if (r.id.trim().isEmpty) {
          broken++;
          continue;
        }
        await storage.saveRecipe(r);
        if (existingIds.contains(r.id)) {
          updated++;
        } else {
          added++;
        }
      } catch (_) {
        broken++;
      }
    }

    if (added == 0 && updated == 0) {
      throw const BackupException('包里没有一条能用的菜谱');
    }
    return RestoreResult(
      added: added,
      updated: updated,
      fileCount: landed.length,
      broken: broken,
    );
  }

  static String _ext(String p) {
    final i = p.lastIndexOf('.');
    if (i < 0 || i < p.length - 6) return '.png';
    return p.substring(i).toLowerCase();
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}';
  }
}

/// 给 UI 用的：异常里带的都是人话，直接显示。
String backupErrorText(Object e) {
  if (e is BackupException) return e.message;
  return '出了点意外：$e';
}

/// 校验一下「用户选的这个文件」是不是 zip（有些手机选择器会返回 0 字节）。
bool looksLikeZip(Uint8List head) =>
    head.length >= 4 && head[0] == 0x50 && head[1] == 0x4B;
