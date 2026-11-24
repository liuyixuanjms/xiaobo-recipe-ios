/// 口播识别（ASR）到底值不值得等、最多等多久。
///
/// 【v1.43 为什么要有这个文件】
/// 2026-11-15 用户导出的真机日志，三次运行：
///   51 秒视频：听口播 37.1 秒，只得到 12 个汉字，还全是错字；
///             而画面字幕已有 277 汉字。
///   324 秒视频：听口播 240 秒超时，0 字；画面字幕 851 汉字。
///   427 秒视频：听口播 240 秒超时，0 字；画面字幕 827 汉字。
/// 旧代码在 douyin_reader 里写死「不管字幕多全都听一遍」，
/// 而且是 `await transcribe(...)` 同步卡在主流程上，内部超时 240 秒。
/// 也就是说：字幕已经足够时，用户还要白等 0~4 分钟，换回一堆错字或什么都没有。
///
/// 结论不是「语音没用」——字幕稀疏时口播里的用量、火候确实值钱。
/// 结论是「不能把最慢、最不确定的一步放在必经路径上」：
///   ① 字幕够密就直接不等；
///   ② 真要听，给一个硬预算，超时立刻放弃、字幕结果照出；
///   ③ 全程用纯函数判定，改规则不用装包、跑一条测试就知道。
class AsrPolicy {
  const AsrPolicy._();

  /// 画面字幕达到这个汉字数，就认为信息已经够用，不再等口播。
  ///
  /// 取 120 的依据：日志里最密的三条是 277 / 827 / 851 字，
  /// 而字幕稀疏到需要口播兜底的样例通常在几十字以内。
  /// 留一倍余量，宁可多跳一次，也不要让用户为 12 个错字等 37 秒。
  static const int denseSubtitleHan = 120;

  /// 真要听时的硬预算（秒）。原来是 240 秒，两次直接跑满超时。
  /// 12 秒足够覆盖短视频的口播，长视频本来也听不完，不如交给字幕。
  static const int budgetSeconds = 12;

  /// 是否值得在这一条视频上听口播。
  static bool shouldListen({
    required bool skipAudio,
    required int subtitleHan,
  }) =>
      !skipAudio && subtitleHan < denseSubtitleHan;

  /// 跳过原因，直接写进运行日志，别让用户猜为什么少了这一步。
  static String skipReason({
    required bool skipAudio,
    required int subtitleHan,
  }) {
    if (skipAudio) {
      return '快速整理：按你的选择跳过口播，省掉全链路最慢的一步；'
          '只靠画面字幕，用量、火候可能缺';
    }
    return '画面字幕已有 $subtitleHan 汉字（≥$denseSubtitleHan），信息足够；'
        '跳过口播识别。这一步在本机 CPU 上要跑音频时长的 0.6~0.8 倍，'
        '实测在字幕充足时几乎换不回新内容（51 秒片子花 37 秒只得到 12 个错字，'
        '长片两次跑满 240 秒超时、0 字）';
  }

  /// 决定要听时写进日志的说明。
  static String listenReason(int subtitleHan) =>
      '画面字幕只有 $subtitleHan 汉字（<$denseSubtitleHan），'
      '靠口播补用量和火候；硬限时 $budgetSeconds 秒，'
      '到点放弃、直接拿字幕出结果，不让用户干等';
}
