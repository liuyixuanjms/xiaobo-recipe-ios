// V0.14 · 运行日志服务（给「跑不通」用的黑匣子）
//
// 目的：用户真机上「不出图、不出步骤」时，不用口述，点一下导出日志发过来，
// 就能看见整条链路每一步成没成、拿到多少内容、在哪一步断的。
//
// 设计要点：
// 1) 按「次」记录：每点一次「AI 整理成菜谱」开一个会话（session），
//    读链接 → 打开页面 → 下视频 → 抽帧 → OCR → AI 整理 → 硬拦截 → 出图，
//    每一步都写一行，带时间戳和阶段标签。
// 2) **每写一行立刻落盘**：App 卡住 / 闪退时，最后一行之前的内容全在，
//    这正是「跑不通」时最需要的信息。为此把「当前会话」单独存一个小 key，
//    已结束的会话才进历史列表，避免每条日志都重写一大坨数据。
// 3) 只保留最近 8 次，避免日志无限膨胀占手机空间。
// 4) 安全：日志里绝不出现 API 密钥（自动打码），也不上传任何服务器，
//    只有用户主动点「复制 / 分享」才会离开手机。
// 5) 兼容 Dart 2.17（Flutter 3.0）：不用 record / sealed / switch 表达式。
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/brand.dart';
import '../config/build_flavor.dart';

/// 日志回调：底层服务把内部细节回吐给编排层统一记录。
/// 用 Future 是为了让调用点 await，保证日志顺序和「每条都落盘」。
typedef LogSink = Future<void> Function(String tag, String msg);

class LogService {
  LogService._();
  static final LogService instance = LogService._();

  static const String _curKey = 'run_log_current_v1';
  static const String _hisKey = 'run_log_history_v1';
  static const int maxHistory = 8;
  static const int maxLineChars = 1200;

  /// 已结束的会话，新的在前
  final List<String> _history = <String>[];
  /// 当前进行中的会话（可能为 null）
  String? _current;
  bool _loaded = false;
  DateTime? _start;

  static String pad2(int n) => n.toString().padLeft(2, '0');
  static String pad3(int n) => n.toString().padLeft(3, '0');

  static String _fmt(DateTime d) =>
      '${d.year}-${pad2(d.month)}-${pad2(d.day)} '
      '${pad2(d.hour)}:${pad2(d.minute)}:${pad2(d.second)}.${pad3(d.millisecond)}';

  static String _clock(DateTime d) =>
      '${pad2(d.hour)}:${pad2(d.minute)}:${pad2(d.second)}.${pad3(d.millisecond)}';

  /// 隐藏任何长得像密钥的东西 + 单行截断，避免日志泄露或过大。
  static String _safe(String s) {
    var out = s.replaceAllMapped(
      RegExp(r'sk-[A-Za-z0-9_\-]{8,}'),
      (_) => '[密钥已隐藏]',
    );
    out = out.replaceAllMapped(
      RegExp(r'Bearer\s+[A-Za-z0-9_\-]{8,}'),
      (_) => 'Bearer [已隐藏]',
    );
    if (out.length > maxLineChars) {
      out = '${out.substring(0, maxLineChars)} …（本行已截断）';
    }
    return out;
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final sp = await SharedPreferences.getInstance();
    _history.addAll(sp.getStringList(_hisKey) ?? <String>[]);
    _current = sp.getString(_curKey);
    _loaded = true;
  }

  static String get platformInfo =>
      '${Platform.operatingSystem} / ${Platform.operatingSystemVersion}';

  /// 开一次新会话。若上一次没正常结束（App 被杀 / 卡死），把它带标记存档。
  /// [env] 是这次运行的环境快照（版本、系统、密钥是否填了、输入概况…）。
  Future<void> startSession(String title, Map<String, String> env) async {
    await _ensureLoaded();
    if (_current != null && _current!.isNotEmpty) {
      _pushHistory('⚠️ 上一次没走完（可能中途卡住或闪退），以下是它留下的记录\n'
          '${_current!}');
    }
    _start = DateTime.now();
    final b = StringBuffer()
      ..writeln('═══════════════════════════════════════════')
      ..writeln('$kAppName · 运行日志')
      ..writeln('开始：${_fmt(_start!)}')
      ..writeln('本次操作：$title')
      ..writeln('系统：$platformInfo')
      ..writeln('构建标记：$kBuildMark')
      ..writeln(kCopyright);
    for (final e in env.entries) {
      b.writeln('${e.key}：${_safe(e.value)}');
    }
    b.writeln('───────────────────────────────────────────');
    _current = b.toString();
    await _persistCurrent(_current!);
  }

  void _pushHistory(String s) {
    _history.insert(0, s);
    if (_history.length > maxHistory) {
      _history.removeRange(maxHistory, _history.length);
    }
  }

  /// 写一行日志。
  ///
  /// 【v1.45.1】以前每写一行都把**整份日志**整体覆写进 SharedPreferences，
  /// 而字符串拼接 $current + line 本身是 O(n²)。一局上百行、每次几十 KB 写盘，
  /// 越到后面越卡界面，和用户说的「点上就点不了」叠加在一起。
  /// 现在改为：内存里用 StringBuffer 追加（O(1)），落盘节流到最多 1 秒一次，
  /// 并且页面退出 / 会话结束时强制 flush，不丢记录。
  Timer? _flushTimer;

  Future<void> log(String tag, String msg) async {
    if (_current == null) return;
    final line = '[${_clock(DateTime.now())}] [$tag] ${_safe(msg)}\n';
    _current = '$_current$line';
    await _flushThrottled();
  }

  Future<void> _flushThrottled() async {
    if (_flushTimer != null && _flushTimer!.isActive) return;
    await _persistCurrent(_current!);
    _flushTimer = Timer(const Duration(seconds: 1), () {});
  }

  /// 页面退出或关键节点调用，确保最后几行已经落盘。
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_current != null) await _persistCurrent(_current!);
  }

  /// 结束会话：写结论与总耗时，把会话从「进行中」挪进历史。
  /// 若没正常调用（App 被杀），当前会话会留在盘上，导出时会被标成「没走完」。
  Future<void> end(String result) async {
    if (_current == null) return;
    final ms = _start == null
        ? 0
        : DateTime.now().difference(_start!).inMilliseconds;
    _current = '$_current'
        '───────────────────────────────────────────\n'
        '结束：${_fmt(DateTime.now())}　总耗时 $ms ms\n'
        '结论：${_safe(result)}\n';
    _pushHistory(_current!);
    _current = null;
    _start = null;
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_curKey);
    await sp.setStringList(_hisKey, _history);
  }

  Future<void> _persistCurrent(String value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_curKey, value);
  }

  /// 供日志页展示：正在进行的排最前，后面跟历史。
  Future<List<String>> sessions() async {
    await _ensureLoaded();
    final all = <String>[];
    if (_current != null && _current!.isNotEmpty) {
      all.add('⚠️ 这一次还没走完（可能正卡住 / 中途闪退），以下是已记下的内容\n'
          '${_current!}');
    }
    all.addAll(_history);
    return all;
  }

  Future<bool> hasAny() async {
    await _ensureLoaded();
    return (_current != null && _current!.isNotEmpty) || _history.isNotEmpty;
  }

  /// 有没有「正在进行、还没结束」的会话。预览页保存长图时用来判断
  /// 是接着写同一次整理，还是单独开一份记录。
  Future<bool> hasOpenSession() async {
    await _ensureLoaded();
    return _current != null && _current!.isNotEmpty;
  }

  // ── v1.27：崩溃记录 ──────────────────────────────────────────────────
  //
  // 用户：「最近两个版本它会闪退，之前不闪退。」但老日志里只有业务步骤，
  // 崩溃那一瞬间的异常和堆栈根本没被记下来 —— 等于黑匣子只录了一半。
  // 现在把 Flutter 框架异常、Dart 未捕获异常都落盘；原生层（OOM 等）的崩溃由
  // MainActivity 写文件，启动时由 [drainNativeCrash] 搬进这里。
  static const String _crashKey = 'run_crash_v1';
  static const int maxCrashes = 6;

  /// 记一条崩溃。**任何情况下都不抛异常**（崩溃处理里再崩就彻底没线索了）。
  static Future<void> recordCrash(
    Object error,
    StackTrace? stack, {
    String where = '',
  }) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final list = sp.getStringList(_crashKey) ?? <String>[];
      final st = (stack?.toString() ?? '（没有堆栈）').split('\n');
      final head = st.take(14).join('\n');
      list.insert(
        0,
        '时间：${_fmt(DateTime.now())}\n'
        '位置：${where.isEmpty ? '未知' : where}\n'
        '类型：${error.runtimeType}\n'
        '内容：${_safe(error.toString())}\n'
        '堆栈：\n$head',
      );
      while (list.length > maxCrashes) {
        list.removeLast();
      }
      await sp.setStringList(_crashKey, list);
      // 同时写进当前会话：崩溃点和业务步骤落在同一条时间线上才好对
      final inst = LogService.instance;
      await inst._ensureLoaded();
      if (inst._current != null) {
        await inst.log('闪退', '${where.isEmpty ? '' : '$where｜'}'
            '${error.runtimeType}: ${_safe(error.toString())}');
      }
    } catch (_) {
      // 记不下来也不能再炸一次
    }
  }

  /// 原生层崩溃（Java/Kotlin 未捕获异常、OOM）会被 MainActivity 写到
  /// 私有目录的 crash_last.txt；这里读出来搬进崩溃记录并删掉。
  /// 返回是否真的捞到了一条。
  static Future<bool> drainNativeCrash() async {
    try {
      const ch = MethodChannel('com.xiaobo.recipe/share');
      final txt = await ch.invokeMethod<String>('takeCrashLog');
      if (txt == null || txt.trim().isEmpty) return false;
      final sp = await SharedPreferences.getInstance();
      final list = sp.getStringList(_crashKey) ?? <String>[];
      list.insert(0, '时间：（原生崩溃，发生在上一进程）\n'
          '位置：Android 原生层（Java/Kotlin 未捕获异常 / 内存不足）\n'
          '内容：\n${_safe(txt)}');
      while (list.length > maxCrashes) {
        list.removeLast();
      }
      await sp.setStringList(_crashKey, list);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 崩溃记录原文（导出日志时拼在最前面）。
  Future<List<String>> crashes() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getStringList(_crashKey) ?? <String>[];
  }

  Future<void> clearCrashes() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_crashKey);
  }

  /// 导出成纯文本。[all] 为 true 时带上全部历史，默认只带最近一次
  /// （默认更短，方便直接粘贴/微信发送）。
  Future<String> exportText({bool all = false}) async {
    await _ensureLoaded();
    final list = await sessions();
    final picked = all
        ? list
        : (list.isEmpty ? <String>[] : <String>[list.first]);
    final b = StringBuffer()
      ..writeln('$kAppName · 运行日志报告')
      ..writeln('导出时间：${_fmt(DateTime.now())}')
      ..writeln('系统：$platformInfo')
      ..writeln('构建标记：$kBuildMark')
      ..writeln(kCopyright)
      ..writeln('记录条数：${picked.length} 条（${all ? '全部' : '最近一次'}）')
      ..writeln('说明：只记录每一步成没成、拿到多少内容，不含任何隐私内容。')
      ..writeln('把这份全文直接发给做 App 的人即可定位问题。')
      ..writeln('');
    // v1.27：崩溃记录永远排在最前面 —— 找闪退原因时它是唯一有用的东西，
    // 藏在后面的业务步骤里就白记了。
    final crashList = await crashes();
    if (crashList.isNotEmpty) {
      b.writeln('======== 崩溃记录 ${crashList.length} 条（最近的在前）========');
      for (var i = 0; i < crashList.length; i++) {
        b.writeln('---- 崩溃 ${i + 1} ----');
        b.writeln(crashList[i]);
        b.writeln('');
      }
    }
    if (picked.isEmpty) {
      b.writeln('（暂时还没有日志。先去「新建菜谱」点一次「整理成菜谱」，再回来导出。）');
    } else {
      for (var i = 0; i < picked.length; i++) {
        b.writeln('======== 记录 ${i + 1} / ${picked.length} ========');
        b.writeln(picked[i]);
        b.writeln('');
      }
    }
    return b.toString();
  }

  Future<void> clear() async {    await _ensureLoaded();
    _history.clear();
    _current = null;
    _start = null;
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_curKey);
    await sp.remove(_hisKey);
  }
}
