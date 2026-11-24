// 厨师复核报告卡片：把四步流水线「检查了什么、改了什么、还要你确认什么」摆到校对页顶部。
// 用户明确要「有一个检查它的步骤，然后修改」——这个卡片就是那一步的可视化，不做黑箱。
// 可折叠，默认展开摘要，不占太多地方。
import 'package:flutter/material.dart';

import '../models/chef_review.dart';
import '../theme/app_theme.dart';

class ChefReviewCard extends StatefulWidget {
  final ChefReviewReport report;
  const ChefReviewCard({super.key, required this.report});

  @override
  State<ChefReviewCard> createState() => _ChefReviewCardState();
}

class _ChefReviewCardState extends State<ChefReviewCard> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    final totalProblems = r.issueCount + r.localFlags.length;
    final bool clean = totalProblems == 0 && r.reviewDone;

    return Container(
      margin:  EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding:  EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: [
                  Icon(
                    clean ? Icons.verified_outlined : Icons.restaurant_menu,
                    color: clean ? AppColors.done : AppColors.primary,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                         Text(
                          '厨师复核报告',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: AppColors.ink),
                        ),
                         SizedBox(height: 2),
                        Text(
                          clean
                              ? '规划 → 整理 → 复核 → 修订，检查通过'
                              : '先规划做法、再整理、逐条挑错、按意见修订',
                          style:  TextStyle(
                              fontSize: 12, color: AppColors.subInk),
                        ),
                      ],
                    ),
                  ),
                  _countBadge(totalProblems),
                   SizedBox(width: 4),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      color: AppColors.subInk, size: 20),
                ],
              ),
            ),
          ),
          if (_expanded) _body(r, clean, totalProblems),
        ],
      ),
    );
  }

  Widget _countBadge(int n) {
    final ok = n == 0;
    return Container(
      padding:  EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: ok ? AppColors.primarySoft : Color(0xFFFBEEDF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        ok ? '无问题' : '发现 $n 处',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: ok ? AppColors.primary : Color(0xFFB5763A),
        ),
      ),
    );
  }

  Widget _body(ChefReviewReport r, bool clean, int totalProblems) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1),
          const SizedBox(height: 12),
          if (r.planSummary.trim().isNotEmpty) ...[
            // v1.16：这里原来叫「厨师规划」，但 AI 现在不规划做法了 ——
            // 它只负责核对「作者说了什么、整理时掉了什么」，叫「规划」会让人以为
            // 那一堆缺项是 AI 建议你加的配料。
            _line(Icons.fact_check_outlined, '核对过素材', r.planSummary.trim()),
            if (r.stages.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 30, top: 4),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: r.stages
                      .map((s) => Container(
                            padding:  EdgeInsets.symmetric(
                                horizontal: 9, vertical: 3),
                            decoration: BoxDecoration(
                              color: AppColors.primarySoft,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(s,
                                style:  TextStyle(
                                    fontSize: 11, color: AppColors.primary)),
                          ))
                      .toList(),
                ),
              ),
             SizedBox(height: 10),
          ],
          if (r.localFlags.isNotEmpty) ...[
            _subTitle(Icons.rule, '本地规则拦下的硬伤', AppColors.danger),
            ...r.localFlags.map((f) => _bullet(f, AppColors.danger)),
            const SizedBox(height: 8),
          ],
          if (r.issues.isNotEmpty) ...[
            _subTitle(Icons.rate_review_outlined, '厨师挑出的问题',
                 Color(0xFFB5763A)),
            ...r.issues.map((i) => _issue(i)),
             SizedBox(height: 8),
          ],
          if (r.changes.isNotEmpty) ...[
            _subTitle(Icons.edit_outlined, '已按意见修订', AppColors.done),
            ...r.changes.map((c) => _bullet(c, AppColors.done)),
             SizedBox(height: 8),
          ],
          if (r.remainingRisks.isNotEmpty) ...[
            _subTitle(Icons.help_outline, '仍需你自己核对', AppColors.subInk),
            ...r.remainingRisks.map((x) => _bullet(x, AppColors.subInk)),
             SizedBox(height: 8),
          ],
          if (r.note.trim().isNotEmpty)
            Padding(
              padding:  EdgeInsets.only(top: 2),
              child: Text(r.note.trim(),
                  style:  TextStyle(
                      fontSize: 12, color: AppColors.subInk, height: 1.5)),
            ),
          if (clean)
             Text('没发现编造用量或混入无关内容，下面的草稿可以放心校对。',
                style: TextStyle(fontSize: 12, color: AppColors.subInk, height: 1.5)),
           SizedBox(height: 6),
           Text(
            '提醒：自动复核不等于百分百准确，用量这一栏最后还是要你自己扫一眼再生成图。',
            style: TextStyle(fontSize: 11, color: AppColors.subInk, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _line(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: AppColors.primary),
         SizedBox(width: 8),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: TextStyle(fontSize: 13, color: AppColors.ink, height: 1.5),
              children: [
                TextSpan(
                  text: '$label　',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                TextSpan(text: value),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _subTitle(IconData icon, String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(text,
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }

  Widget _bullet(String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(left: 21, bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('· ', style: TextStyle(color: color, fontSize: 13)),
          Expanded(
            child: Text(text.replaceFirst(RegExp(r'^【[^】]*】'), ''),
                style:  TextStyle(
                    fontSize: 12.5, color: AppColors.ink, height: 1.5)),
          ),
        ],
      ),
    );
  }

  Widget _issue(ReviewIssue i) {
    final serious = i.level.contains('严重');
    return Padding(
      padding: const EdgeInsets.only(left: 21, bottom: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 3),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: serious ? const Color(0xFFFBE4DE) : const Color(0xFFFBEEDF),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(serious ? '严重' : '提醒',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: serious ? AppColors.danger : Color(0xFFB5763A))),
              ),
               SizedBox(width: 7),
              Expanded(
                child: Text(
                  '${i.where.isEmpty ? '' : '${i.where}：'}${i.problem}',
                  style:  TextStyle(
                      fontSize: 12.5, color: AppColors.ink, height: 1.45),
                ),
              ),
            ],
          ),
          if (i.fix.trim().isNotEmpty)
            Padding(
              padding:  EdgeInsets.only(left: 2, top: 2),
              child: Text('→ 建议：${i.fix.trim()}',
                  style:  TextStyle(
                      fontSize: 11.5, color: AppColors.subInk, height: 1.4)),
            ),
        ],
      ),
    );
  }
}
