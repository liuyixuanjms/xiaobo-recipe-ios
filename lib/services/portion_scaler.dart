// 份量换算（v1.23）：按人数把用料里的数字用量等比缩放。
//
// 设计原则（很重要，别改坏）：
//   1. 只动「带数字的用量」：如 300g、3 个、5–10g、0.5 勺。
//   2. 没有数字的定性描述一律原样保留 —— "适量" "少许" "比梨少一点"
//      "1 把"（把是模糊量，但带 1 就缩放成 2 把，这个可以）、"老抽一点点"。
//      绝不能把"比梨少一点"这种相对量算成具体数字，会做咸/做淡。
//   3. 范围（5–10g）两端都缩放；连字符支持 - – — ~ 到。
//   4. 数字后面紧跟的单位/后缀整段保留，只换数字本身。
//   5. 缩放后整数优先，小数最多 1 位，去掉无意义的 .0。
//
// 这是纯函数，不依赖 Flutter，方便单测。
class PortionResult {
  final String text;
  final bool scaled; // 是否真的改了数字
  const PortionResult(this.text, this.scaled);
}

class PortionScaler {
  /// 把一段用量按 factor 缩放。factor=1 原样返回。
  static PortionResult scale(String amount, double factor) {
    final src = amount.trim();
    if (src.isEmpty || (factor - 1.0).abs() < 1e-9) {
      return PortionResult(src, false);
    }
    // 匹配首个数（含小数），后面可选范围第二个数。
    // 例："300g" / "3 个" / "5–10g" / "0.5 勺" / "约 650 克" / "生抽 25g"
    // 注意：\s* 只在「范围连接符」两侧才消费，不能吞掉数字与单位之间的空格
    // （否则 "3 个" 会变成 "3个"，中文显示难看）。
    final m = RegExp(r'(-?\d+(?:\.\d+)?)(?:\s*[–—~-]\s*(\d+(?:\.\d+)?))?')
        .firstMatch(src);
    if (m == null) {
      // 没有数字：适量 / 少许 / 比梨少一点 —— 原样，交给用户自己拿捏
      return PortionResult(src, false);
    }

    final first = double.tryParse(m.group(1) ?? '');
    if (first == null) return PortionResult(src, false);

    final newFirst = _fmt(first * factor);
    final secondStr = m.group(2);
    String replacement;
    if (secondStr != null) {
      final second = double.tryParse(secondStr);
      replacement = second == null
          ? newFirst
          : '$newFirst–${_fmt(second * factor)}';
    } else {
      replacement = newFirst;
    }

    final out = src.substring(0, m.start) + replacement + src.substring(m.end);
    // 结果没变化视为没缩放（例如 factor 让整数仍相同）
    return PortionResult(out, out != src);
  }

  /// 格式化：整数不带小数点；小数保留最多 1 位，去掉 .0。
  static String _fmt(double v) {
    // 四舍五入到 1 位
    final r = (v * 10).roundToDouble() / 10;
    if ((r - r.roundToDouble()).abs() < 1e-9) return r.round().toString();
    // 去掉末尾 0（如 4.50 -> 4.5）
    return r.toStringAsFixed(1).replaceAll(RegExp(r'0$'), '');
  }
}
