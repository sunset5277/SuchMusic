import 'dart:math' as math;
import 'dart:typed_data';

import 'dsp.dart';
import 'karaoke_features.dart';
import 'karaoke_model.dart';

// ---------------------------------------------------------------- 正则（与 Python 版一致）

final RegExp _cjkRe = RegExp(r'[㐀-䶿一-鿿豈-﫿]');
final RegExp _latinWordRe =
    RegExp(r"[A-Za-zÀ-ɏḀ-ỿ0-9]+(?:['’][A-Za-zÀ-ɏ]+)*");
final RegExp _vowelGroupRe =
    RegExp(r'[aeiouyæœøåäöáéíóúàèìòùâêîôûāēīōū]+', caseSensitive: false);
final RegExp _creditRe = kCreditLineRe; // 共享正则（karaoke_model.dart）
final RegExp _timeTagRe = RegExp(r'\[(\d+):(\d+(?:\.\d+)?)\]');
final RegExp _offsetRe = RegExp(r'\[offset:([+-]?\d+)\]');
final RegExp _bracketCjkRe = RegExp(r'[（(][^()（）]*[㐀-䶿一-鿿豈-﫿][^()（）]*[)）]');
final RegExp _latinCharRe = RegExp(r'[A-Za-zÀ-ɏḀ-ỿ]');
final RegExp _fullwidthRe = RegExp(r'[　-〿＀-￯]');
final RegExp _emptyParenRe = RegExp(r'[（(]\s*[)）]');
final RegExp _wsRe = RegExp(r'\s+');

bool _isCjk(String ch) => _cjkRe.hasMatch(ch);

int _syllableCount(String word) {
  final n = _vowelGroupRe.allMatches(word).length;
  return math.max(1, math.min(n, 6));
}

// ---------------------------------------------------------------- 数据结构

class AlignToken {
  String text;
  double weight;
  double start = 0.0;
  double end = 0.0;
  double confidence = 0.0;
  AlignToken(this.text, this.weight);
}

class AlignLine {
  double start;
  String text;
  List<AlignToken> tokens;
  double end = 0.0;
  AlignLine(this.start, this.text, this.tokens);
}

// ---------------------------------------------------------------- 文本处理

String cleanLineText(String input) {
  var text = input.trim();
  if (text.isEmpty) return '';
  int nCjk = _cjkRe.allMatches(text).length;
  int nLatin = _latinCharRe.allMatches(text).length;
  if (nCjk > 0 && nLatin > 0) {
    // 混排行：先删含中文的括号段（行内译文）
    text = text.replaceAllMapped(_bracketCjkRe, (_) => ' ');
    nCjk = _cjkRe.allMatches(text).length;
    nLatin = _latinCharRe.allMatches(text).length;
  }
  if (nCjk > 0 && nLatin > 0 && nLatin >= nCjk) {
    text = text.replaceAllMapped(_cjkRe, (_) => '');
    text = text.replaceAllMapped(_fullwidthRe, (_) => ' ');
    text = text.replaceAllMapped(_emptyParenRe, (_) => ' ');
  }
  return text.replaceAllMapped(_wsRe, (_) => ' ').trim();
}

List<AlignToken> tokenize(String text) {
  // 词字符（含 CJK）：歧义引号上下文判断用
  final RegExp wordCharRe = RegExp(r'[A-Za-zÀ-ɏḀ-ỿ0-9㐀-䶿一-鿿豈-﫿]');
  const closingPuncts = '，。！？、；：）】》」』…—,.!?;:)]}”’';
  const openingPuncts = '（【《「『“‘([{';

  final tokens = <AlignToken>[];
  String pendingOpen = ''; // 待挂到下一个 token 词头的开放标点
  bool quoteOpen = false; // 歧义引号配对状态（行内）
  int i = 0;
  while (i < text.length) {
    final ch = text[i];
    if (_isCjk(ch)) {
      tokens.add(AlignToken(pendingOpen + ch, 1.0));
      pendingOpen = '';
      i += 1;
      continue;
    }
    final isAsciiAlnum = ch.codeUnitAt(0) < 128 &&
        (_isAsciiLetter(ch) || (ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39));
    if (isAsciiAlnum ||
        (ch.compareTo('À') >= 0 && ch.compareTo('ɏ') <= 0) ||
        (ch.compareTo('Ḁ') >= 0 && ch.compareTo('ỿ') <= 0)) {
      final m = _latinWordRe.matchAsPrefix(text, i);
      if (m != null && m.end > i) {
        final w = m.group(0)!;
        tokens.add(AlignToken(pendingOpen + w, _syllableCount(w).toDouble()));
        pendingOpen = '';
        i = m.end;
      } else {
        i += 1;
      }
      continue;
    }
    if (ch.trim().isNotEmpty) {
      // 标点：闭合挂前一个 token，开放挂下一个 token；权重不变（计时时长不受影响）
      if (openingPuncts.contains(ch)) {
        pendingOpen += ch;
      } else if (closingPuncts.contains(ch)) {
        if (tokens.isNotEmpty) {
          tokens.last.text += ch;
        } else {
          pendingOpen += ch; // 行首闭合标点无宿主 → 挂下一个 token
        }
      } else if (ch == "'" || ch == '"') {
        // 歧义引号：词上下文优先，回退到引号配对奇偶
        final prevCh = i > 0 ? text[i - 1] : '';
        final nextCh = i + 1 < text.length ? text[i + 1] : '';
        final prevWord = prevCh.isNotEmpty && wordCharRe.hasMatch(prevCh);
        final nextWord = nextCh.isNotEmpty && wordCharRe.hasMatch(nextCh);
        bool open;
        if (prevWord && !nextWord) {
          open = false; // 词后+非词前 → 闭合（boys' / hello"）
        } else if (!prevWord && nextWord) {
          open = true; // 非词后+词前 → 开放（'hello / "你好）
        } else {
          open = !quoteOpen; // 两侧同性质 → 按配对奇偶（他说"你好"再见）
        }
        quoteOpen = open;
        if (open) {
          pendingOpen += ch;
        } else if (tokens.isNotEmpty) {
          tokens.last.text += ch;
        } else {
          pendingOpen += ch;
        }
      }
      // 其余符号（空格已在 trim 分支、未识别符号）丢弃
    }
    i += 1;
  }
  // 行尾残留的开放标点：挂回最后一个 token（整行无 token 则丢弃）
  if (pendingOpen.isNotEmpty && tokens.isNotEmpty) {
    tokens.last.text += pendingOpen;
  }
  return tokens;
}

bool _isAsciiLetter(String ch) {
  final c = ch.codeUnitAt(0);
  return (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
}

/// 解析 LRC：同一时间戳只保留第一行（其余视为翻译），过滤制作名单行。
List<AlignLine> parseLrc(String raw) {
  double offsetMs = 0.0;
  final lines = <AlignLine>[];
  final seenTimes = <double>{};
  for (var row0 in raw.split(RegExp(r'\r?\n'))) {
    final row = row0.trim();
    if (row.isEmpty) continue;
    final mOff = _offsetRe.firstMatch(row);
    if (mOff != null && mOff.start == 0) {
      offsetMs = double.parse(mOff.group(1)!);
      continue;
    }
    final tags = _timeTagRe.allMatches(row).toList();
    if (tags.isEmpty) continue;
    final text = row.replaceAll(_timeTagRe, '').trim();
    if (_creditRe.hasMatch(text)) continue; // 制作名单行
    for (final tag in tags) {
      final mm = int.parse(tag.group(1)!);
      final ss = double.parse(tag.group(2)!);
      final t = mm * 60.0 + ss - offsetMs / 1000.0;
      if (seenTimes.contains(t)) continue; // 重复时间戳（翻译行）丢弃
      seenTimes.add(t);
      final cleaned = cleanLineText(text);
      if (cleaned.isEmpty) continue;
      final tokens = tokenize(cleaned);
      if (tokens.isNotEmpty) {
        lines.add(AlignLine(math.max(0.0, t), cleaned, tokens));
      }
    }
  }
  lines.sort((a, b) => a.start.compareTo(b.start));
  return lines;
}

// ---------------------------------------------------------------- 工具

int _argmaxSlice(Float32List x, int lo, int hi) {
  // [lo, hi] 闭区间，返回首个最大值下标（numpy argmax 语义）
  double best = x[lo];
  int idx = lo;
  for (int i = lo + 1; i <= hi; i++) {
    if (x[i] > best) {
      best = x[i];
      idx = i;
    }
  }
  return idx;
}

double _medianOf(List<double> vals) {
  if (vals.isEmpty) return 0.0;
  final s = List<double>.from(vals)..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2.0;
}

/// 标记 [lo, hi] 内长度 >= minLen 的 True 连续段（就地过滤）
void _keepLongRuns(List<bool> mask, int lo, int hi, int minLen) {
  int i = lo;
  while (i <= hi) {
    if (mask[i]) {
      int j = i + 1;
      while (j <= hi && mask[j]) {
        j++;
      }
      if (j - i < minLen) {
        for (int k = i; k < j; k++) {
          mask[k] = false;
        }
      }
      i = j;
    } else {
      i++;
    }
  }
}

// ---------------------------------------------------------------- RMS-VAD 兜底

/// RMS-VAD 兜底：帧区间 [fLo, fHi) 内的布尔活动掩码
List<bool> _vocalActiveRegions(KaraokeFeatures f, int fLo, int fHi) {
  final len = fHi - fLo;
  if (len <= 0) return <bool>[];
  final seg = Float32List(len);
  for (int i = 0; i < len; i++) {
    seg[i] = f.rms[fLo + i];
  }
  final thr = kVadThrRatio * (percentile(seg, 90) + 1e-9);
  final act = List<bool>.generate(len, (i) => seg[i] > thr);
  final closed = binaryClosing1D(act, math.max(1, (kVadCloseS / kDT).round()));
  // 去碎段
  final out = List<bool>.from(closed);
  final minN = math.max(1, (kVadMinsegS / kDT).round());
  int i = 0;
  while (i < out.length) {
    if (out[i]) {
      int j = i + 1;
      while (j < out.length && out[j]) {
        j++;
      }
      if (j - i < minN) {
        for (int k = i; k < j; k++) {
          out[k] = false;
        }
      }
      i = j;
    } else {
      i++;
    }
  }
  return out;
}

// ---------------------------------------------------------------- 行锚点检测

double _sumWeights(List<AlignToken> tokens) {
  double s = 0;
  for (final t in tokens) {
    s += t.weight;
  }
  return s;
}

/// 行窗口内是否存在成段(>=STR_MIN_SEG_S)强浊音——有则行尾可用音高规则锚定
bool lineHasAnchor(KaraokeFeatures feat, double tStart, double tEnd,
    List<AlignToken> tokens) {
  final cap = kEndCapBaseS + _sumWeights(tokens) * kEndCapPerUnit;
  final fLo = feat.frame(math.max(0.0, tStart - kStartBackS));
  final fHi =
      feat.frame(math.min(math.min(feat.duration, tEnd), tStart + cap));
  if (fHi <= fLo) return false;
  final minLen = (kStrMinSegS / kDT).round();
  int run = 0;
  for (int i = fLo; i <= fHi; i++) {
    if (feat.strong[i]) {
      run++;
      if (run >= minLen) return true;
    } else {
      run = 0;
    }
  }
  return false;
}

// ---------------------------------------------------------------- 行区间精修

(double, double) refineWindow(
    KaraokeFeatures feat,
    double tStart,
    double tEnd,
    List<AlignToken> tokens,
    double budgetPerUnit) {
  final n = tokens.length;
  tEnd = math.min(tEnd, feat.duration);
  final cap = kEndCapBaseS + _sumWeights(tokens) * kEndCapPerUnit;

  // ---- 行首：标注点附近最近的浊音段起点，向左退到邻近 onset ----
  final fA = feat.frame(math.max(0.0, tStart - kStartBackS));
  final fB = feat.frame(math.min(feat.duration, tStart + kStartFwdS));
  double? t0;
  if (fB > fA) {
    // 最近的 revoice 帧
    int bestRv = -1;
    double bestDist = double.infinity;
    for (int i = fA; i <= fB; i++) {
      if (feat.revoice[i] > 0) {
        final d = (i * kDT - tStart).abs();
        if (d < bestDist) {
          bestDist = d;
          bestRv = i;
        }
      }
    }
    if (bestRv >= 0) {
      final fV = bestRv;
      final fOb = math.max(fA, fV - (kStartBackoffS / kDT).round());
      // onset 峰（覆盖声母/辅音起音）
      final oMax = _argmaxSlice(feat.onset, fOb, fV);
      if (feat.onset[oMax] > 0.10) {
        t0 = oMax * kDT - 0.01;
      } else {
        t0 = fV * kDT - 0.04;
      }
    }
  }
  if (t0 == null) {
    // 无浊音：RMS-VAD 兜底
    final act = _vocalActiveRegions(feat, fA, fB);
    t0 = tStart;
    for (int i = 0; i < act.length; i++) {
      if (act[i]) {
        t0 = (fA + i) * kDT;
        break;
      }
    }
  }
  t0 = math.min(math.max(t0!, 0.0), tEnd - 0.25);

  // ---- 行尾：响度掩码衰减 + 尾音音高连续性 ----
  final fLo = feat.frame(t0);
  final fHi = feat.frame(math.min(tEnd, t0 + cap));
  double t1 = math.min(tEnd, t0 + cap);
  if (fHi > fLo) {
    bool anyActive = false;
    int lastActiveLocal = -1;
    for (int i = fLo; i <= fHi; i++) {
      if (feat.sounding[i]) {
        anyActive = true;
        lastActiveLocal = i - fLo;
      }
    }
    if (anyActive) {
      // 强帧碎片（<0.12s）多为伴奏偶发周期段，不作人声锚点
      final strW = List<bool>.generate(fHi - fLo + 1,
          (i) => feat.strong[fLo + i]);
      _keepLongRuns(strW, 0, strW.length - 1, (kStrMinSegS / kDT).round());
      int lastStrongLocal = -1;
      for (int i = 0; i < strW.length; i++) {
        if (strW[i]) lastStrongLocal = i;
      }
      if (lastStrongLocal < 0) {
        // 整行无成段强浊音：能量掩码被伴奏维持，行尾不可信 → 时长预算兜底
        final budget = kBudgetBaseS + budgetPerUnit * _sumWeights(tokens);
        t1 = math.min(t1, t0 + budget);
      } else {
        var fLast = fLo + lastActiveLocal;
        final fS = fLo + lastStrongLocal;
        // 参考音高：最后 0.3s 强浊音帧的 f0 中位数（含无 f0 的 0 值帧）
        final refFrom = lastStrongLocal - (0.30 / kDT).round();
        final allRef = <double>[];
        for (int i = math.max(0, refFrom); i <= lastStrongLocal; i++) {
          allRef.add(feat.f0[fLo + i]);
        }
        final refF0 = _medianOf(allRef);
        if (refF0 > 0) {
          // 音高连续（±TAIL_SEMI_TOL 半音）；无 f0（气声尾巴）信任包络
          final tailOk = List<bool>.generate(fHi - fLo + 1, (i) {
            final g = fLo + i;
            final fw = feat.f0[g];
            final semiDev =
                fw > 0 ? (12.0 * math.log(math.max(fw, 1.0) / refF0) / math.ln2).abs() : 9.9;
            final envRef = feat.env[fS] * kTailEnvRatio;
            return feat.sounding[g] &&
                (semiDev <= kTailSemiTol || fw <= 0) &&
                feat.env[g] <= math.max(envRef, 1e-6);
          });
          final closedTail =
              binaryClosing1D(tailOk, math.max(1, (0.15 / kDT).round()));
          // 取包含 fS 的连通域的末端
          final c = closedTail[fS - fLo];
          int fTail;
          if (c) {
            int e = fS - fLo;
            while (e + 1 < closedTail.length && closedTail[e + 1]) {
              e++;
            }
            fTail = fLo + e;
          } else {
            fTail = fS;
          }
          fLast = math.min(
              fLast, math.min(fTail, fS + (kEndTailMaxS / kDT).round()));
        }
        t1 = fLast * kDT + kEndReleaseS;
        // 长低活动间隙切割：唱完进间奏
        final gapEnd = fLast - fLo; // [0, gapEnd]
        final minGap = (kEndGapCutS / kDT).round();
        int i = 0;
        while (i <= gapEnd) {
          if (!feat.sounding[fLo + i]) {
            int j = i + 1;
            while (j <= gapEnd && !feat.sounding[fLo + j]) {
              j++;
            }
            if (j - i >= minGap) {
              if (i * kDT > n * 0.25) {
                t1 = (fLo + i) * kDT + 0.10;
                break;
              }
            }
            i = j;
          } else {
            i++;
          }
        }
      }
    } else {
      // 无活动（低语/说唱/YIN失效）：RMS-VAD 兜底，更紧时长上限
      final act = _vocalActiveRegions(feat, fLo, fHi);
      if (act.isNotEmpty) {
        for (int i = act.length - 1; i >= 0; i--) {
          if (act[i]) {
            t1 = (fLo + i) * kDT + 0.06;
            break;
          }
        }
      }
      final nvCap = math.max(2.0, _sumWeights(tokens) * 1.2);
      t1 = math.min(t1, t0 + nvCap);
    }
  }
  t1 = math.min(math.min(t1, tEnd), feat.duration);

  // ---- 区间长度下限 ----
  final need = n * 0.10;
  if (t1 - t0 < need) {
    t1 = math.min(tEnd, t0 + need);
  }
  if (t1 - t0 < 0.25) {
    t1 = math.min(tEnd, t0 + 0.25);
    t0 = math.max(0.0, math.min(t0, t1 - 0.20));
  }
  return (t0, t1);
}

// ---------------------------------------------------------------- 动态规划

/// 在帧区间 [t0, t1] 内为 tokens 分配边界，返回 N+1 个边界帧（绝对帧号）
List<int>? dpAlign(KaraokeFeatures feat, double t0, double t1,
    List<AlignToken> tokens) {
  final n = tokens.length;
  final f0 = feat.frame(t0);
  var f1 = math.max(feat.frame(t1), f0 + 2 * n);
  f1 = math.min(f1, feat.nFrames - 1);
  final L = f1 - f0 + 1;
  if (L < 2) return null;

  final cue = feat.boundaryCue(f0, f1);
  final cuv0 = feat.cuv[f0];
  // cuvW[i] = [f0, f0+i) 内无声帧数，长度 L+1
  final cuvW = Float64List(L + 1);
  for (int i = 0; i <= L; i++) {
    cuvW[i] = feat.cuv[f0 + i] - cuv0;
  }

  final weights = Float64List(n);
  double wSum = 0;
  for (int i = 0; i < n; i++) {
    weights[i] = tokens[i].weight;
    wSum += tokens[i].weight;
  }
  final total = (L - 1).toDouble();

  final minLen = Int32List(n);
  final maxLen = Int32List(n);
  final minLenC = (kDurMinS / kDT).round();
  final maxLenC = (kDurMaxS / kDT).round();
  for (int i = 0; i < n; i++) {
    final expected = total * weights[i] / wSum;
    final maxRatio =
        i == n - 1 ? kDurMaxRatioLast : kDurMaxRatio;
    minLen[i] = math.max(minLenC, (kDurMinRatio * expected).round());
    maxLen[i] = math.min(maxLenC, (maxRatio * expected).round());
    maxLen[i] = math.max(maxLen[i], minLen[i] + 1);
  }

  const inf = double.infinity;
  final dp = Float64List((n + 1) * L)..fillRange(0, (n + 1) * L, inf);
  final ptr = Int32List((n + 1) * L)..fillRange(0, (n + 1) * L, -1);
  dp[0] = 0.0; // dp[0][0]

  for (int k = 1; k <= n; k++) {
    final ek = math.max(total * weights[k - 1] / wSum, 2.0);
    final dLo = minLen[k - 1];
    final dHi = math.min(maxLen[k - 1], L - 1);
    final lnE = math.log(ek);
    final dpPrev = k - 1;
    for (int d = dLo; d <= dHi; d++) {
      final durCost =
          kWDur * math.pow((math.log(d.toDouble()) - lnE) / kDurLnSigma, 2);
      final np_ = L - d;
      for (int p = 0; p < np_; p++) {
        final pAbs = f0 + p;
        final eAbs = pAbs + d - 1;
        // 前导无声：区间内首个浊音帧（钳到 [p, p+d]）
        var fv = feat.nextVoiced[pAbs];
        if (fv < pAbs) fv = pAbs;
        if (fv > pAbs + d) fv = pAbs + d;
        final lead = fv - pAbs;
        // 尾部无声：区间内末个浊音帧（钳到 [p-1, e]）
        var lv = feat.prevVoiced[pAbs + d - 1];
        if (lv > eAbs) lv = eAbs;
        if (lv < pAbs - 1) lv = pAbs - 1;
        final trail = eAbs - lv;
        final sil = cuvW[p + d] - cuvW[p];
        var internal = sil - lead - trail;
        if (internal < 0) internal = 0;
        final silCost =
            (kWLead * lead + kWGap * internal + kWTrail * trail) * kDT;
        double val = dp[dpPrev * L + p] + durCost + silCost;
        if (k > 1) {
          val += - kWBound * cue[p];
        }
        final col = p + d;
        if (val < dp[k * L + col]) {
          dp[k * L + col] = val;
          ptr[k * L + col] = p;
        }
      }
    }
  }

  if (!dp[n * L + (L - 1)].isFinite) return null;
  // 回溯：bounds 逆序收集后反转
  final bounds = <int>[L - 1];
  int f = L - 1;
  for (int k = n; k >= 1; k--) {
    f = ptr[k * L + f];
    if (f < 0) return null;
    bounds.add(f);
  }
  final abs = List<int>.from(bounds.reversed);
  return [for (final b in abs) f0 + b];
}

/// 把内部边界吸附到邻近最强边界线索
List<int> snapBoundaries(KaraokeFeatures feat, List<int> bounds) {
  if (bounds.length <= 2) return List<int>.from(bounds);
  final fLo = bounds[0], fHi = bounds[bounds.length - 1];
  final cue = feat.boundaryCue(fLo, fHi);
  final out = List<int>.from(bounds);
  for (int i = 1; i < bounds.length - 1; i++) {
    final lo = math.max(out[i - 1] + 2, bounds[i] - kSnapRadius);
    final hi = math.min(out[i + 1] - 2, bounds[i] + kSnapRadius);
    if (lo > hi) continue;
    // _argmaxSlice 返回 cue 数组下标（相对 fLo），需换算回绝对帧号
    out[i] = fLo + _argmaxSlice(cue, lo - fLo, hi - fLo);
  }
  return out;
}

// ---------------------------------------------------------------- 单行对齐

void alignLine(KaraokeFeatures feat, AlignLine line, double tEnd,
    [double budgetPerUnit = 0.55]) {
  final n = line.tokens.length;
  final (t0, t1) = refineWindow(feat, line.start, tEnd, line.tokens, budgetPerUnit);
  List<int>? bounds = dpAlign(feat, t0, t1, line.tokens);

  if (bounds == null) {
    // 兜底：按权重均匀分配
    final f0 = feat.frame(t0);
    final f1 = math.min(
      math.max(feat.frame(t1), feat.frame(t0) + 2 * n),
      feat.nFrames - 1,
    );
    final cum = <double>[0.0];
    for (final t in line.tokens) {
      cum.add(cum.last + t.weight);
    }
    bounds = [
      for (final c in cum) f0 + ((f1 - f0) * c / cum.last).round()
    ];
  } else {
    bounds = snapBoundaries(feat, bounds);
  }

  // 硬性钳制：边界不得越过下一行标注起点
  final fHard = (math.min(tEnd, feat.duration) / kDT).floor();
  bounds = [for (final b in bounds) math.min(b, fHard)];

  line.start = bounds[0] * kDT;
  line.end = bounds[bounds.length - 1] * kDT;
  final cue = feat.boundaryCue(bounds[0], bounds[bounds.length - 1]);
  for (int i = 0; i < n; i++) {
    final tok = line.tokens[i];
    tok.start = bounds[i] * kDT;
    tok.end = bounds[i + 1] * kDT;
    if (i == 0) {
      tok.confidence = 1.0;
    } else {
      final c = cue[bounds[i] - bounds[0]];
      tok.confidence = (math.min(1.0, 0.30 + 0.70 * c) * 1000).round() / 1000;
    }
  }

  // ---- 间隙空格 token（前字高亮在音符结束处停止，间隙归空格）----
  final newTokens = <AlignToken>[];
  for (int i = 0; i < n; i++) {
    final tok = line.tokens[i];
    final bI = (tok.start / kDT).round();
    final bN = (tok.end / kDT).round();
    double vocalEnd;
    int lastSounding = -1;
    final hi = math.min(bN, feat.nFrames);
    for (int g = bI; g < hi; g++) {
      if (feat.sounding[g]) lastSounding = g;
    }
    if (lastSounding >= 0) {
      vocalEnd = (lastSounding + 1) * kDT + 0.10;
    } else {
      vocalEnd = tok.end;
    }
    if (i < n - 1) {
      if (tok.end - vocalEnd > kGapSpaceS) {
        tok.end = vocalEnd;
        newTokens.add(tok);
        final sp = AlignToken(' ', 0.0);
        sp.start = vocalEnd;
        sp.end = bN * kDT;
        sp.confidence = 1.0;
        newTokens.add(sp);
        continue;
      }
    } else {
      // 末字：行尾收缩到音符实际结束点
      if (line.end - vocalEnd > kGapEndTrimS) {
        line.end = vocalEnd;
        tok.end = vocalEnd;
      }
    }
    newTokens.add(tok);
  }
  line.tokens = newTokens;
}

// ---------------------------------------------------------------- 全曲对齐

void alignLines(KaraokeFeatures feat, List<AlignLine> lines) {
  // 两遍对齐 + 相邻行重叠修正
  final anchors = <int>[];
  for (int i = 0; i < lines.length; i++) {
    final tEnd =
        i + 1 < lines.length ? lines[i + 1].start : feat.duration;
    if (lineHasAnchor(feat, lines[i].start, tEnd, lines[i].tokens)) {
      anchors.add(i);
      alignLine(feat, lines[i], tEnd);
    }
  }
  double perUnit = 0.55;
  if (anchors.isNotEmpty) {
    final perUnits = <double>[];
    for (final i in anchors) {
      final w = math.max(_sumWeights(lines[i].tokens), 1e-9);
      perUnits.add((lines[i].end - lines[i].start) / w);
    }
    perUnit = _medianOf(perUnits);
    perUnit = math.min(math.max(perUnit, 0.30), 1.20);
  }
  for (int i = 0; i < lines.length; i++) {
    if (anchors.contains(i)) continue;
    final tEnd =
        i + 1 < lines.length ? lines[i + 1].start : feat.duration;
    alignLine(feat, lines[i], tEnd, perUnit);
  }

  // 相邻行重叠修正：卡拉OK惯例共享边界，切在重叠区包络最弱点
  for (int i = 1; i < lines.length; i++) {
    final prev = lines[i - 1], cur = lines[i];
    if (cur.start < prev.end - 0.02 &&
        prev.tokens.isNotEmpty &&
        cur.tokens.isNotEmpty) {
      final fA = feat.frame(cur.start);
      final fB = feat.frame(prev.end);
      double boundary;
      if (fB > fA + 1) {
        // _argmaxMin 返回绝对帧号，直接换算秒
        final idx = _argmaxMin(feat.env, fA, fB);
        boundary = idx * kDT;
      } else {
        boundary = (prev.end + cur.start) / 2.0;
      }
      prev.end = boundary;
      prev.tokens.last.end = boundary;
      cur.start = boundary;
      cur.tokens.first.start = boundary;
      // 维护 token 边界单调：boundary 后移时收紧两侧 token 区间
      for (final t in cur.tokens) {
        if (t.start < boundary) t.start = boundary;
        if (t.end < t.start) t.end = t.start;
      }
      for (final t in prev.tokens) {
        if (t.end > boundary) t.end = boundary;
        if (t.start > t.end) t.start = t.end;
      }
    }
  }
}

/// [lo, hi] 闭区间内最小值下标（首个）
int _argmaxMin(Float32List x, int lo, int hi) {
  double best = x[lo];
  int idx = lo;
  for (int i = lo + 1; i <= hi; i++) {
    if (x[i] < best) {
      best = x[i];
      idx = i;
    }
  }
  return idx;
}

// ---------------------------------------------------------------- 管线入口

/// 逐字对齐管线：LRC 文本 + 22050Hz 单声道 PCM → 逐字时间戳
KaraokeSong alignKaraoke(String lrcText, Float32List pcm, String songId) {
  final lines = parseLrc(lrcText);
  if (lines.isEmpty) {
    return KaraokeSong(songId: songId, lines: const []);
  }
  final feat = KaraokeFeatures.build(pcm);
  alignLines(feat, lines);

  final outLines = <KaraokeLine>[];
  for (final l in lines) {
    final toks = <KaraokeToken>[];
    for (final t in l.tokens) {
      toks.add(KaraokeToken(
        text: t.text,
        start: (t.start * 1000).round() / 1000,
        end: (t.end * 1000).round() / 1000,
        confidence: t.confidence,
      ));
    }
    if (toks.isEmpty) continue;
    outLines.add(KaraokeLine(
      start: (l.start * 1000).round() / 1000,
      end: (l.end * 1000).round() / 1000,
      text: l.text,
      tokens: toks,
    ));
  }
  return KaraokeSong(songId: songId, lines: outLines);
}
