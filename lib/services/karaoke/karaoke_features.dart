import 'dart:math' as math;
import 'dart:typed_data';

import 'dsp.dart';

// ---------------------------------------------------------------- 常量参数（与 V3 算法一致）

const double kSR = 22050; // 重采样率
const int kNFFT = 2048; // STFT 窗长
const int kHOP = 256; // 帧移
const double kDT = kHOP / kSR;

const int kHPSSKernelT = 31;
const int kHPSSKernelF = 31;

const double kVocalLo = 150.0;
const double kVocalHi = 5500.0;

const int kYinWin = 2048;
const double kYinFmin = 80.0;
const double kYinFmax = 1000.0;
const double kYinThr = 0.09620758544742632;
const double kYinMedThr = 0.20115352656191218;
const double kYinWeakThr = 0.3006914417097795;
const double kYinBpLo = 100.0;
const double kYinBpHi = 1200.0;

const double kVoiceCloseS = 0.06962929677369945;
const double kVoiceMinrunS = 0.06974223633552672;
const double kVoiceEnergyGate = 0.019252875629857225;
const double kWeakEnergyGate = 0.04726539495064121;

const double kStartBackS = 0.29353010424262765;
const double kStartFwdS = 0.4;
const double kStartBackoffS = 0.1502154120140806;
const double kEndReleaseS = 0.12263937616096456;
const double kEndGapCutS = 0.7197824522694474;
const double kEndCapBaseS = 1.236194490808558;
const double kEndCapPerUnit = 0.46024735228490615;
const double kEndTailMaxS = 4.3544474924243985;
const double kGapSpaceS = 0.5841242616167385;
const double kGapEndTrimS = 0.19785727832555985;

const double kWBound = 1.3838696057388635;
const double kWLead = 1.0290263528850172;
const double kWGap = 0.6123554329790188;
const double kWTrail = 0.07845897695025411;
const double kWDur = 0.14406973997881584;
const double kDurLnSigma = 1.043961591358318;
const double kDurMinRatio = 0.5;
const double kDurMaxRatio = 6.056058696751039;
const double kDurMaxRatioLast = 4.327249995717804;
const double kDurMinS = 0.04;
const double kDurMaxS = 6.0;
const double kCueRevOnset = 0.9039484071821502;
const double kCuePjump = 1.0;
const double kCueRise = 0.7148583211380275;
const double kCueNote = 0.4265574086819161;
const int kSnapRadius = 7;

const int kFluxMed = 43;
const double kMedGapS = 0.9298305542091392;
const double kMedMinSegS = 0.10;
const double kActWinS = 1.2867651370421844;
const double kActRatio = 0.11537137651142966;
const double kActFloor = 0.0159605219196049;
const double kActCloseS = 0.06;
const double kSndWinS = 3.706911223379634;
const double kSndRatio = 0.08658920259185778;
const double kSndFloor = 0.013575785962712505;
const double kSndCloseS = 0.10;
const double kActDilS = 0.130539263916847;
const double kPjWinS = 0.09881497287806841;
const double kPjGuardS = 0.015;
const double kPjClip = 3.0;

const double kCueSoft = 0.15492566854814263;
const double kCueAccomp = 0.277988473022156;
const double kStrMinSegS = 0.06;
const double kTailSemiTol = 1.7892027182453172;
const double kTailEnvRatio = 1.2649515522179253;
const double kBudgetBaseS = 1.4642819731558854;

const double kVadThrRatio = 0.16;
const double kVadCloseS = 0.18;
const double kVadMinsegS = 0.10;

int _bandLoBin() {
  final binHz = kSR / 2 / (kNFFT ~/ 2);
  return (kVocalLo / binHz).ceil();
}

int _bandHiBin() {
  final binHz = kSR / 2 / (kNFFT ~/ 2);
  return (kVocalHi / binHz).floor();
}

/// STFT 保留的频带 bin 数（人声带 + HPSS 频向窗半径）
int keepBins() {
  final binHz = kSR / 2 / (kNFFT ~/ 2);
  final hiBin = (kVocalHi / binHz).floor() + kHPSSKernelF ~/ 2;
  return math.min(kNFFT ~/ 2 + 1, hiBin + 1);
}

/// 全曲一次性特征：onset 包络、人声带 RMS、浊音/基频及其派生线索。
class KaraokeFeatures {
  final int nFrames;
  final double duration;

  final Float32List onset; // 起始强度（p99 归一化）
  final Float32List rms; // 人声带 RMS（p99 归一化）
  final Float32List env; // 平滑能量包络（≈80ms 窗）
  final List<bool> voiced;
  final List<bool> strong;
  final List<bool> active;
  final List<bool> sounding;
  final Float32List f0;
  final Int64List nextVoiced;
  final Int64List prevVoiced;
  final Float64List cuv; // 无声帧累积和（前置 0），以声活度为准
  final Float32List revoice;
  final Float32List pjump;
  final Float32List rise;
  final Float32List noteEdge;
  final Float32List activeDil;

  const KaraokeFeatures._(
    this.nFrames,
    this.duration,
    this.onset,
    this.rms,
    this.env,
    this.voiced,
    this.strong,
    this.active,
    this.sounding,
    this.f0,
    this.nextVoiced,
    this.prevVoiced,
    this.cuv,
    this.revoice,
    this.pjump,
    this.rise,
    this.noteEdge,
    this.activeDil,
  );

  int frame(double t) => (t / kDT).round().clamp(0, nFrames - 1);

  /// 窗口 [f0, f1] 内的边界线索融合：onset / 重新起音 / 音高跳变 / 上升沿 / 音符边界
  Float32List boundaryCue(int f0, int f1) {
    final len = f1 - f0 + 1;
    final out = Float32List(math.max(0, len));
    if (len <= 0) return out;
    for (int i = 0; i < len; i++) {
      final g = f0 + i;
      // onset：软压缩 + 伴奏段打折
      double on = onset[g] / (onset[g] + kCueSoft);
      on = on * (kCueAccomp + (1.0 - kCueAccomp) * activeDil[g]);
      final rv = revoice[g] * kCueRevOnset;
      final pj = pjump[g] * kCuePjump;
      final ri0 = rise[g];
      final ri = ri0 / (ri0 + kCueSoft) * kCueRise;
      final ne = noteEdge[g] * kCueNote;
      double m = on;
      if (rv > m) m = rv;
      if (pj > m) m = pj;
      if (ri > m) m = ri;
      if (ne > m) m = ne;
      out[i] = m;
    }
    return out;
  }

  // ------------------------------------------------------------ 构建

  /// y: 22050Hz 单声道 PCM。STFT+HPSS 分块流式计算以控制内存。
  static KaraokeFeatures build(Float32List yInput) {
    final n = yInput.length;
    final duration = n / kSR;
    // scipy stft boundary='zeros'：两侧各补 NFFT/2，padded=True 增量
    // (-(N + NFFT) % HOP) % N = 0（2048 % 256 == 0），故帧数 = floor(N/HOP) + 1
    final nFrames = n ~/ kHOP + 1;

    // ============ 阶段 1：STFT + HPSS → onset / rms ============
    final (onset, rmsNorm) = _computeSpectralFeatures(yInput, nFrames);

    // ============ 阶段 2：YIN 基频跟踪（带通预滤波后） ============
    final secs = designButterBandpass(kYinBpLo, kYinBpHi, kSR);
    final yb = sosFiltFilt(secs, yInput);

    final (f0, vmin) = _yinTrack(yb, nFrames, rmsNorm);

    // ============ 阶段 3：滞后双阈值浊音判决 ============
    final strong = List<bool>.filled(nFrames, false);
    final medium = List<bool>.filled(nFrames, false);
    final weak = List<bool>.filled(nFrames, false);
    for (int i = 0; i < nFrames; i++) {
      final r = rmsNorm[i];
      if (r > kVoiceEnergyGate) {
        strong[i] = vmin[i] < kYinThr;
        medium[i] = vmin[i] < kYinMedThr;
      }
      weak[i] = r > kWeakEnergyGate && vmin[i] < kYinWeakThr;
    }

    // 浊音段 = 含强帧的弱连通域，或与保留段相邻的中档弱连通域（链式扩展）
    final voiced = List<bool>.filled(nFrames, false);
    {
      final runs = labelRuns(weak);
      final keep = List<bool>.filled(runs.length, false);
      final medOk = List<bool>.filled(runs.length, false);
      for (int r = 0; r < runs.length; r++) {
        final s = runs[r][0], e = runs[r][1]; // [s, e)
        bool hs = false, hm = false;
        for (int i = s; i < e; i++) {
          if (strong[i]) hs = true;
          if (medium[i]) hm = true;
        }
        keep[r] = hs;
        medOk[r] = hm && (e - s) >= (kMedMinSegS / kDT).round();
      }
      final gapMax = (kMedGapS / kDT).round();
      int lastKeepEnd = -1 << 30;
      for (int r = 0; r < runs.length; r++) {
        if (keep[r]) {
          lastKeepEnd = runs[r][1];
        } else if (medOk[r] && runs[r][0] - lastKeepEnd <= gapMax) {
          keep[r] = true;
          lastKeepEnd = runs[r][1];
        }
      }
      int nextKeepStart = 1 << 30;
      for (int r = runs.length - 1; r >= 0; r--) {
        if (keep[r]) {
          nextKeepStart = runs[r][0];
        } else if (medOk[r] && nextKeepStart - runs[r][1] <= gapMax) {
          keep[r] = true;
          nextKeepStart = runs[r][0];
        }
      }
      for (int r = 0; r < runs.length; r++) {
        if (keep[r]) {
          for (int i = runs[r][0]; i < runs[r][1]; i++) {
            voiced[i] = true;
          }
        }
      }
    }

    // 浊音段整形：补小洞、去碎段
    {
      final closed = binaryClosing1D(voiced, (kVoiceCloseS / kDT).round());
      voiced.fillRange(0, nFrames, false);
      final minRun = (kVoiceMinrunS / kDT).round();
      for (final r in labelRuns(closed)) {
        if (r[1] - r[0] >= minRun) {
          for (int i = r[0]; i < r[1]; i++) {
            voiced[i] = true;
          }
        }
      }
    }

    // ============ 阶段 4：声活度 / 响度掩码 / 派生线索 ============
    final env = uniformFilter1D(rmsNorm, 7);

    final active = List<bool>.filled(nFrames, false);
    {
      final wA = (kActWinS / kDT).round();
      final roll = maxFilter1DScipy(env, wA + 1, -(wA ~/ 2));
      for (int i = 0; i < nFrames; i++) {
        active[i] =
            voiced[i] && env[i] > math.max(kActRatio * roll[i], kActFloor);
      }
      final closed = binaryClosing1D(active, math.max(1, (kActCloseS / kDT).round()));
      active.setAll(0, closed);
    }

    final sounding = List<bool>.filled(nFrames, false);
    {
      final wS = (kSndWinS / kDT).round();
      final roll3 = maxFilter1DScipy(env, wS + 1, -(wS ~/ 2));
      for (int i = 0; i < nFrames; i++) {
        sounding[i] =
            active[i] || env[i] > math.max(kSndRatio * roll3[i], kSndFloor);
      }
      final closed = binaryClosing1D(sounding, math.max(1, (kSndCloseS / kDT).round()));
      sounding.setAll(0, closed);
    }

    final nextVoiced = Int64List(nFrames);
    final prevVoiced = Int64List(nFrames);
    {
      int nx = nFrames;
      for (int i = nFrames - 1; i >= 0; i--) {
        if (active[i]) nx = i;
        nextVoiced[i] = nx;
      }
      int pv = -1;
      for (int i = 0; i < nFrames; i++) {
        if (active[i]) pv = i;
        prevVoiced[i] = pv;
      }
    }

    final cuv = Float64List(nFrames + 1);
    for (int i = 0; i < nFrames; i++) {
      cuv[i + 1] = cuv[i] + (active[i] ? 0.0 : 1.0);
    }

    final revoice = Float32List(nFrames);
    for (int i = 1; i < nFrames; i++) {
      if (active[i] && !active[i - 1]) revoice[i] = 1.0;
    }

    // 音高跳变：双侧均值阶跃（半音）
    final pjump = Float32List(nFrames);
    {
      final W = (kPjWinS / kDT).round();
      final G = (kPjGuardS / kDT).round();
      final csL = Float64List(nFrames + 1);
      final csC = Float64List(nFrames + 1);
      for (int i = 0; i < nFrames; i++) {
        final vm = f0[i] > 0;
        csL[i + 1] =
            csL[i] + (vm ? math.log(math.max(f0[i], 1.0)) / math.ln2 : 0.0);
        csC[i + 1] = csC[i] + (vm ? 1.0 : 0.0);
      }
      for (int i = 0; i < nFrames; i++) {
        final b0 = (i - W).clamp(0, nFrames);
        final b1 = (i - G).clamp(0, nFrames);
        final a0 = (i + G + 1).clamp(0, nFrames);
        final a1 = (i + W + 1).clamp(0, nFrames);
        final cntB = csC[b1] - csC[b0];
        final cntA = csC[a1] - csC[a0];
        if (cntB >= 3 && cntA >= 3) {
          final mb = (csL[b1] - csL[b0]) / cntB;
          final ma = (csL[a1] - csL[a0]) / cntA;
          pjump[i] = ((ma - mb).abs() * 12.0).clamp(0.0, kPjClip) / kPjClip;
        }
      }
    }

    // 包络上升沿
    final rise = Float32List(nFrames);
    {
      final raw = Float32List(nFrames);
      for (int i = 1; i < nFrames; i++) {
        raw[i] = math.max(0.0, env[i] - env[i - 1]);
      }
      final p99 = percentile(raw, 99) + 1e-9;
      for (int i = 0; i < nFrames; i++) {
        rise[i] = raw[i] / p99;
      }
    }

    // f0 音符分段边界（连音换字）
    final noteEdge = Float32List(nFrames);
    {
      final masked = Float32List(nFrames);
      for (int i = 0; i < nFrames; i++) {
        masked[i] = voiced[i] ? f0[i] : 0.0;
      }
      final f0m = medianFilter1D(masked, 5);
      final semi = Int32List(nFrames);
      final vpos = List<bool>.filled(nFrames, false);
      for (int i = 0; i < nFrames; i++) {
        vpos[i] = f0m[i] > 0;
        if (vpos[i]) {
          semi[i] = (12.0 * math.log(f0m[i] / 55.0) / math.ln2).round();
        }
      }
      final edge = List<bool>.filled(nFrames, false);
      for (int i = 1; i < nFrames; i++) {
        edge[i] = vpos[i] && vpos[i - 1] && semi[i] != semi[i - 1];
      }
      // 新音高需向后持续 >=3 帧，否则视为量化抖动；末两帧 persist 恒为真
      for (int i = 0; i < nFrames - 2; i++) {
        if (!(semi[i] == semi[i + 1] && semi[i] == semi[i + 2])) {
          edge[i] = false;
        }
      }
      for (int i = 0; i < nFrames; i++) {
        if (edge[i]) {
          for (int k = math.max(0, i - 1);
              k <= math.min(nFrames - 1, i + 1);
              k++) {
            noteEdge[k] = 1.0;
          }
        }
      }
    }

    final activeDil = Float32List(nFrames);
    {
      final dil =
          binaryDilation1D(active, math.max(1, (kActDilS / kDT).round()));
      for (int i = 0; i < nFrames; i++) {
        activeDil[i] = dil[i] ? 1.0 : 0.0;
      }
    }

    return KaraokeFeatures._(
      nFrames,
      duration,
      onset,
      rmsNorm,
      env,
      voiced,
      strong,
      active,
      sounding,
      f0,
      nextVoiced,
      prevVoiced,
      cuv,
      revoice,
      pjump,
      rise,
      noteEdge,
      activeDil,
    );
  }

  // ============ STFT + HPSS 分块流式 ============
  static (Float32List, Float32List) _computeSpectralFeatures(
      Float32List y, int nFrames) {
    final nBins = keepBins();
    final bandLo = _bandLoBin();
    final bandHi = _bandHiBin();
    const halfF = kHPSSKernelF ~/ 2; // 15

    // 周期 hann 窗（scipy get_window('hann', N) 默认 sym=False）
    final win = Float32List(kNFFT);
    double winSum = 0;
    for (int i = 0; i < kNFFT; i++) {
      win[i] = 0.5 * (1 - math.cos(2 * math.pi * i / kNFFT));
      winSum += win[i];
    }
    final stftScale = 1.0 / winSum; // scipy stft scaling='spectrum'

    final fft = FFT(kNFFT);
    final reBuf = Float64List(kNFFT);
    final imBuf = Float64List(kNFFT);

    final fluxRaw = Float32List(nFrames);
    final rmsAcc = Float32List(nFrames);

    const blockFrames = 2048;
    const frontHalo = kHPSSKernelT ~/ 2 + 1; // 16：含 prevLog 初始化帧
    const backHalo = kHPSSKernelT ~/ 2; // 15
    final localLen = blockFrames + frontHalo + backHalo;

    final magBlock = Float32List(localLen * nBins); // [t*nBins + b]
    final medPBlock = Float32List(localLen * nBins);
    final medHRow = Float32List(localLen);
    final medPCol = Float64List(kHPSSKernelF);
    final stftRow = Float32List(nBins);

    void computeStftFrame(int g, int localSlot) {
      final base = g * kHOP - (kNFFT ~/ 2);
      for (int k = 0; k < kNFFT; k++) {
        final idx = base + k;
        reBuf[k] = (idx >= 0 && idx < y.length) ? y[idx] * win[k] : 0.0;
        imBuf[k] = 0.0;
      }
      fft.transform(reBuf, imBuf);
      for (int b = 0; b < nBins; b++) {
        stftRow[b] =
            math.sqrt(reBuf[b] * reBuf[b] + imBuf[b] * imBuf[b]) * stftScale;
      }
      final off = localSlot * nBins;
      for (int b = 0; b < nBins; b++) {
        magBlock[off + b] = stftRow[b];
      }
    }

    for (int bStart = 0; bStart < nFrames; bStart += blockFrames) {
      final bEnd = math.min(bStart + blockFrames, nFrames);
      final coreLen = bEnd - bStart;
      final blockFirst = bStart - frontHalo;
      final localFrames = coreLen + frontHalo + backHalo;

      // 1) STFT 帧（全局越界帧按 reflect 取，槽位内容即反射语义）
      for (int t = 0; t < localFrames; t++) {
        computeStftFrame(reflectIdx(blockFirst + t, nFrames), t);
      }

      // 2) 频向中值 med_p（每帧沿 bin 滑动，窗口 31，bin<0 反射）
      for (int t = 0; t < localFrames; t++) {
        final off = t * nBins;
        int len = 0;
        for (int k = -halfF; k <= halfF; k++) {
          medPCol[len++] = magBlock[off + reflectIdx(k, nBins)];
        }
        _sortSmall(medPCol, len);
        medPBlock[off] = medPCol[halfF];
        for (int b = 0; b < bandHi; b++) {
          _removeSorted(medPCol, len, magBlock[off + reflectIdx(b - halfF, nBins)]);
          _insertSorted(
              medPCol, len - 1, magBlock[off + reflectIdx(b + halfF + 1, nBins)]);
          medPBlock[off + b + 1] = medPCol[halfF];
        }
      }

      // 3) 逐 bin 时间向中值 med_h + harm 累积（flux / rms）
      for (int b = 0; b <= bandHi; b++) {
        _medHRowForBin(magBlock, medHRow, localFrames, b, nBins, frontHalo);

        if (b < bandLo) continue;
        double pl = double.nan;
        for (int t = frontHalo - 1; t < frontHalo + coreLen; t++) {
          final g = blockFirst + t;
          if (g >= nFrames) break;
          final off = t * nBins;
          final mv = magBlock[off + b];
          final mh = medHRow[t];
          final mp = medPBlock[off + b];
          final harm = mv * mh / (mh + mp + 1e-10);
          final logh = math.log(1.0 + 1.0e4 * harm);
          if (pl.isNaN) {
            pl = logh; // g == bStart-1：仅初始化 prevLog
            continue;
          }
          final diff = logh - pl;
          pl = logh;
          if (g < bStart) continue;
          if (diff > 0) fluxRaw[g] += diff;
          rmsAcc[g] += harm * harm;
        }
      }
    }

    // flux：中值滤波去基线 + 截断 + p99 归一化
    final fluxMed = medianFilter1D(fluxRaw, kFluxMed);
    final flux = Float32List(nFrames);
    for (int i = 0; i < nFrames; i++) {
      flux[i] = math.max(0.0, fluxRaw[i] - fluxMed[i]);
    }
    final fluxP99 = percentile(flux, 99) + 1e-9;
    final onset = Float32List(nFrames);
    for (int i = 0; i < nFrames; i++) {
      onset[i] = flux[i] / fluxP99;
    }

    // rms：sqrt(Σ band harm² / 总 bin 数)（带外为 0 的均值），再 p99 归一化
    final rmsRaw = Float32List(nFrames);
    final invBins = 1.0 / (kNFFT ~/ 2 + 1);
    for (int i = 0; i < nFrames; i++) {
      rmsRaw[i] = math.sqrt(rmsAcc[i] * invBins + 1e-12);
    }
    final rmsP99 = percentile(rmsRaw, 99) + 1e-9;
    final rmsNorm = Float32List(nFrames);
    for (int i = 0; i < nFrames; i++) {
      rmsNorm[i] = rmsRaw[i] / rmsP99;
    }
    return (onset, rmsNorm);
  }

  /// 对 bin b 计算局部帧范围 [frontHalo-1, localFrames) 的时间向中值。
  /// 窗口 ±15；核心帧窗口完全落在块内（含 front halo），越界槽位即反射帧。
  static void _medHRowForBin(Float32List magBlock, Float32List medHRow,
      int localFrames, int b, int nBins, int frontHalo) {
    const halfT = kHPSSKernelT ~/ 2; // 15
    final startT = frontHalo - 1;
    final win = Float64List(kHPSSKernelT);
    int len = 0;
    for (int k = -halfT; k <= halfT; k++) {
      win[len++] = magBlock[(startT + k) * nBins + b];
    }
    _sortSmall(win, len);
    medHRow[startT] = win[halfT];
    for (int t = startT + 1; t < localFrames; t++) {
      final inT = t + halfT;
      if (inT >= localFrames) break; // 超出块尾的帧不会被核心累计使用
      _removeSorted(win, len, magBlock[(t - 1 - halfT) * nBins + b]);
      _insertSorted(win, len - 1, magBlock[inT * nBins + b]);
      medHRow[t] = win[halfT];
    }
  }

  // ============ YIN 基频跟踪 ============
  /// 返回 (f0, vmin)。近静音帧（rms ≤ 阈值）直接跳过（vmin=1, f0=0），
  /// 该类帧不可能通过任何能量门限，对浊音判决结果与全量计算等价。
  static (Float32List, Float32List) _yinTrack(
      Float32List yb, int nFrames, Float32List rmsNorm) {
    final sr = kSR;
    final tauMin = math.max(2, (sr / kYinFmax).floor());
    final tauMax = (sr / kYinFmin).floor();
    final nfft = 1 << ((2 * kYinWin - 1).bitLength); // 4096
    final pad = kYinWin ~/ 2;

    // yp：前置 pad 零 + y + 后置 pad+HOP 零（保证末帧窗口完整）
    final yp = Float32List(yb.length + pad * 2 + kHOP);
    yp.setRange(pad, pad + yb.length, yb);

    final fft = FFT(nfft);
    final re = Float64List(nfft);
    final im = Float64List(nfft);
    final cs = Float64List(kYinWin + 1);
    final winBuf = Float64List(kYinWin);

    final f0 = Float32List(nFrames);
    final vmin = Float32List(nFrames);

    for (int f = 0; f < nFrames; f++) {
      if (rmsNorm[f] <= 0.019) {
        vmin[f] = 1.0;
        f0[f] = 0.0;
        continue;
      }
      final base = f * kHOP;
      double mean = 0;
      for (int k = 0; k < kYinWin; k++) {
        final v = yp[base + k].toDouble();
        winBuf[k] = v;
        mean += v;
      }
      mean /= kYinWin;
      for (int k = 0; k < kYinWin; k++) {
        winBuf[k] -= mean;
        re[k] = winBuf[k];
        im[k] = 0.0;
      }
      for (int k = kYinWin; k < nfft; k++) {
        re[k] = 0.0;
        im[k] = 0.0;
      }
      fft.transform(re, im);
      for (int k = 0; k < nfft; k++) {
        final p = re[k] * re[k] + im[k] * im[k];
        re[k] = p;
        im[k] = 0.0;
      }
      fft.transform(re, im, inverse: true);
      // re[tau] = 自相关 ac[tau]

      // 累积能量 cs[j] = Σ_{k<j} x[k]²
      cs[0] = 0.0;
      for (int k = 0; k < kYinWin; k++) {
        cs[k + 1] = cs[k] + winBuf[k] * winBuf[k];
      }
      // 差分函数 d(tau) = cs[win-tau] + cs[win] - cs[tau] - 2*ac[tau]
      final csWin = cs[kYinWin];
      double cdf = 0.0;
      bool has = false;
      int tauRel = 0;
      double bestV = double.infinity;
      int argminRel = 0;
      int tau = 0;
      for (tau = 0; tau <= tauMax; tau++) {
        double dv;
        if (tau == 0) {
          dv = 0.0;
        } else {
          dv = math.max(
              0.0, cs[kYinWin - tau] + csWin - cs[tau] - 2.0 * re[tau]);
        }
        if (tau >= 1) {
          cdf += dv;
        }
        if (tau == 0) {
          continue; // cmnd[0] = 1
        }
        final cmnd = dv * tau / math.max(cdf, 1e-12);
        if (tau >= tauMin) {
          if (cmnd < bestV) {
            bestV = cmnd;
            argminRel = tau - tauMin;
          }
          if (!has && cmnd < kYinThr) {
            has = true;
            tauRel = tau - tauMin;
          }
        }
        // 保存 cmnd 供抛物线插值使用（存回 re 数组复用空间）
        im[tau] = cmnd;
      }
      im[0] = 1.0; // cmnd[0]

      final tSel = (has ? tauRel : argminRel) + tauMin;
      final v = im[tSel];
      vmin[f] = v;
      final ok = has && v < kYinWeakThr;
      if (!ok) {
        f0[f] = 0.0;
        continue;
      }
      // 抛物线插值
      final tc = tSel.clamp(tauMin + 1, tauMax - 1);
      final y1 = im[tc - 1], y2 = im[tc], y3 = im[tc + 1];
      final denom = y1 - 2.0 * y2 + y3;
      double shift = 0.0;
      if (denom.abs() > 1e-9) {
        shift = (0.5 * (y1 - y3) / math.max(denom, 1e-9)).clamp(-1.0, 1.0);
      }
      final tauF = tc + shift;
      f0[f] = sr / math.max(tauF, 1.0);
    }
    return (f0, vmin);
  }
}

// ---------------------------------------------------------------- 小工具

void _sortSmall(Float64List a, int len) {
  for (int i = 1; i < len; i++) {
    final v = a[i];
    int j = i - 1;
    while (j >= 0 && a[j] > v) {
      a[j + 1] = a[j];
      j--;
    }
    a[j + 1] = v;
  }
}

void _removeSorted(Float64List a, int len, double v) {
  int lo = 0, hi = len - 1, pos = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (a[mid] == v) {
      pos = mid;
      break;
    } else if (a[mid] < v) {
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  if (pos < 0) {
    for (int i = 0; i < len; i++) {
      if (a[i] == v) {
        pos = i;
        break;
      }
    }
    if (pos < 0) return;
  }
  for (int i = pos; i < len - 1; i++) {
    a[i] = a[i + 1];
  }
}

void _insertSorted(Float64List a, int len, double v) {
  int i = len - 1;
  while (i >= 0 && a[i] > v) {
    a[i + 1] = a[i];
    i--;
  }
  a[i + 1] = v;
}
