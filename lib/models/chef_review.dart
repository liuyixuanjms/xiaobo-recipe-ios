// 厨师质检流水线的数据结构。
// V0.9 新增：把「一次出结果」升级为「规划 → 整理 → 评审 → 修订」，
// 每一步的产物都要能被 UI 展示出来，让用户看得见「检查了什么、改了什么」。
// 注意：保持 Dart 2.17 兼容，不用 record / pattern / sealed 等 Dart 3 语法。
import 'recipe.dart';

/// 流水线进度回调：给 UI 显示「第几步 / 共几步 / 正在做什么」。
/// 单独定义成 typedef，页面层不用认识 service 内部。
typedef OnStage = void Function(String label, int step, int total);

/// 审稿厨师挑出的一条问题。
class ReviewIssue {
  final String level; // 严重 / 提醒
  final String where; // 问题位置，如「用料第 3 项」「步骤 5」
  final String problem; // 具体问题
  final String fix; // 建议怎么改

  ReviewIssue({
    this.level = '提醒',
    this.where = '',
    this.problem = '',
    this.fix = '',
  });

  /// 容错解析：模型可能用 severity / issue / suggestion 之类的别名。
  static ReviewIssue fromJson(Map<String, dynamic> j) => ReviewIssue(
        level: (j['level'] ?? j['severity'] ?? '提醒').toString(),
        where: (j['where'] ?? j['location'] ?? j['位置'] ?? '').toString(),
        problem: (j['problem'] ?? j['issue'] ?? j['问题'] ?? '').toString(),
        fix: (j['fix'] ?? j['suggestion'] ?? j['建议'] ?? '').toString(),
      );
}

/// 给用户看的质检报告（校对页顶部那张卡片的数据源）。
class ChefReviewReport {
  String planSummary = ''; // ① 厨师规划：这道菜是什么路子
  List<String> stages = <String>[]; // ① 建议的烹饪阶段划分
  List<ReviewIssue> issues = <ReviewIssue>[]; // ③ 审稿挑出的问题
  List<String> localFlags = <String>[]; // 本地硬校验抓到的硬伤（不花 API 钱）
  List<String> changes = <String>[]; // ④ 实际改了什么
  List<String> remainingRisks = <String>[]; // 仍需人工确认的点
  bool reviewDone = false; // 评审 + 修订是否完整跑完
  String note = ''; // 一句话状态说明

  int get issueCount => issues.length;
  bool get hasHardProblem =>
      localFlags.isNotEmpty || issues.any((e) => e.level.contains('严重'));

  /// 把某个 JSON 字段稳妥地转成字符串列表。
  static List<String> strList(dynamic v) {
    if (v is! List) return <String>[];
    return v.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
  }

  static List<ReviewIssue> parseIssues(Map<String, dynamic> m) {
    final raw = m['issues'] ?? m['problems'] ?? m['问题清单'];
    if (raw is! List) return <ReviewIssue>[];
    return raw
        .map((e) => e is Map
            ? ReviewIssue.fromJson(Map<String, dynamic>.from(e))
            : ReviewIssue(problem: e.toString()))
        .where((e) => e.problem.isNotEmpty)
        .toList();
  }

  static List<String> parseStages(Map<String, dynamic> m) {
    final raw = m['stages'] ?? m['phases'] ?? m['阶段'];
    if (raw is! List) return <String>[];
    return strList(raw);
  }
}

/// 智能整理的最终产物：修订后的菜谱 + 质检报告。
class SmartOrganizeResult {
  final Recipe recipe;
  final ChefReviewReport report;

  SmartOrganizeResult({required this.recipe, required this.report});
}
