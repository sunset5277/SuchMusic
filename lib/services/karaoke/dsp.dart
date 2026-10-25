import 'dart:math' as math;
import 'dart:typed_data';

// ---------------------------------------------------------------- FFT

/// 迭代基-2 FFT（就地变换），预计算旋转因子与位反转表。
class FFT {
  final int n;
  final Float64List _cos;
  final Float64List _sin;
  final Uint32List _rev;

  FFT(this.n)
      : _cos = Float64List(n ~/ 2),
        _sin = Float64List(n ~/ 2),
        _rev = Uint32List(n) {
    if ((n & (n - 1)) != 0 || n < 2) {
      throw ArgumentError('FFT size must be a power of 2, got $n');
    }
    for (int i = 0; i < n ~/ 2; i++) {
      final a = -2.0 * math.pi * i / n;
      _cos[i] = math.cos(a);
      _sin[i] = math.sin(a);
    }
    int bits = 0;
    while ((1 << bits) < n) {
      bits++;
    }
    for (int i = 0; i < n; i++) {
      int r = 0;
      for (int b = 0; b < bits; b++) {
        if ((i & (1 << b)) != 0) r |= 1 << (bits - 1 - b);
      }
      _rev[i] = r;
    }
  }

  /// inverse=true 时执行逆变换（含 1/n 归一化）。
  void transform(Float64List re, Float64List im, {bool inverse = false}) {
    for (int i = 0; i < n; i++) {
      final j = _rev[i];
      if (j > i) {
        double t = re[i];
        re[i] = re[j];
        re[j] = t;
        t = im[i];
        im[i] = im[j];
        im[j] = t;
      }
    }
    for (int size = 2; size <= n; size <<= 1) {
      final half = size >> 1;
      final step = n ~/ size;
      for (int i = 0; i < n; i += size) {
        for (int j = i, k = 0; j < i + half; j++, k += step) {
          final c = _cos[k];
          final s = inverse ? -_sin[k] : _sin[k];
          final tre = re[j + half] * c - im[j + half] * s;
          final tim = re[j + half] * s + im[j + half] * c;
          re[j + half] = re[j] - tre;
          im[j + half] = im[j] - tim;
          re[j] += tre;
          im[j] += tim;
        }
      }
    }
    if (inverse) {
      final inv = 1.0 / n;
      for (int i = 0; i < n; i++) {
        re[i] *= inv;
        im[i] *= inv;
      }
    }
  }
}

// ---------------------------------------------------------------- 统计

/// 线性插值百分位（与 numpy.percentile 默认 linear 法一致）。
double percentile(Float32List x, double q) {
  final n = x.length;
  if (n == 0) return 0.0;
  final sorted = Float32List.fromList(x);
  sorted.sort();
  final pos = (n - 1) * q / 100.0;
  final lo = pos.floor();
  final hi = pos.ceil();
  if (lo == hi) return sorted[lo];
  final frac = pos - lo;
  return sorted[lo] * (1 - frac) + sorted[hi] * frac;
}

double medianOf(List<double> vals) {
  if (vals.isEmpty) return 0.0;
  final s = List<double>.from(vals)..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2.0;
}

double medianOfF32(Float32List vals) {
  if (vals.isEmpty) return 0.0;
  final s = Float32List.fromList(vals)..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2.0;
}

// ---------------------------------------------------------------- scipy 反射索引

/// scipy mode='reflect'（对称延拓）：-1->0, -2->1, n->n-1, n+1->n-2
int reflectIdx(int i, int n) {
  if (n == 1) return 0;
  while (i < 0 || i >= n) {
    if (i < 0) i = -i - 1;
    if (i >= n) i = 2 * n - i - 1;
  }
  return i;
}

// ---------------------------------------------------------------- 一维滤波

/// 一维中值滤波（scipy ndimage.median_filter, mode='reflect'）。
/// 滑动有序窗口实现，window 为奇数时最准确，偶数窗口取左偏中心。
Float32List medianFilter1D(Float32List x, int window) {
  final n = x.length;
  final out = Float32List(n);
  if (n == 0) return out;
  if (window <= 1) {
    out.setAll(0, x);
    return out;
  }
  final half = window ~/ 2;
  final win = Float64List(window);
  int winLen = 0;
  // 初始窗口 [0-half, 0+half]
  for (int k = -half; k <= half; k++) {
    win[winLen++] = x[reflectIdx(k, n)];
  }
  _sortSmall(win, winLen);
  out[0] = win[half];
  for (int i = 1; i < n; i++) {
    final outIdx = reflectIdx(i - 1 - half, n);
    final inIdx = reflectIdx(i + half, n);
    _removeSorted(win, winLen, x[outIdx]);
    winLen--;
    _insertSorted(win, winLen, x[inIdx]);
    winLen++;
    out[i] = win[half];
  }
  return out;
}

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
  // 二分查找任一相等位置后线性收缩（浮点等值在此窗口语义下安全）
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
    // 理论不发生（窗口内容与移出值一致）；兜底线性查找
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

/// 一维滑动均值（scipy uniform_filter1d, mode='reflect'）。
Float32List uniformFilter1D(Float32List x, int size) {
  final n = x.length;
  final out = Float32List(n);
  if (n == 0 || size <= 1) {
    if (n > 0) out.setAll(0, x);
    return out;
  }
  double sum = 0;
  final half = size ~/ 2;
  for (int k = -half; k <= size - 1 - half; k++) {
    sum += x[reflectIdx(k, n)];
  }
  out[0] = sum / size;
  for (int i = 1; i < n; i++) {
    sum += x[reflectIdx(i + size - 1 - half, n)] -
        x[reflectIdx(i - 1 - half, n)];
    out[i] = sum / size;
  }
  return out;
}

/// 前向滑动最大值：out[i] = max(x[i..i+w-1])，越界按 'nearest' 钳制。
/// 对应 scipy maximum_filter1d(size=w+1, origin=-(w//2), mode='nearest')。
Float32List forwardMaxFilter1D(Float32List x, int w) {
  final n = x.length;
  final out = Float32List(n);
  if (n == 0) return out;
  if (w <= 0) {
    out.setAll(0, x);
    return out;
  }
  for (int i = 0; i < n; i++) {
    double m = x[i];
    final end = math.min(i + w, n - 1);
    for (int j = i + 1; j <= end; j++) {
      if (x[j] > m) m = x[j];
    }
    out[i] = m;
  }
  return out;
}

/// scipy maximum_filter1d(size, origin, mode='nearest') 的 1D 等价实现。
/// 窗口 [i - size~/2 - origin, i + size-1 - size~/2 - origin]，越界钳制。
Float32List maxFilter1DScipy(Float32List x, int size, int origin) {
  final n = x.length;
  final out = Float32List(n);
  if (n == 0) return out;
  final start0 = size ~/ 2 + origin; // i - start0 为窗口起点
  for (int i = 0; i < n; i++) {
    int lo = i - start0;
    int hi = lo + size - 1;
    if (lo < 0) lo = 0;
    if (hi > n - 1) hi = n - 1;
    double m = x[lo];
    for (int j = lo + 1; j <= hi; j++) {
      if (x[j] > m) m = x[j];
    }
    out[i] = m;
  }
  return out;
}

// ---------------------------------------------------------------- 二值形态学

/// 一维二值膨胀（scipy.ndimage.binary_dilation, structure=ones(n), origin=0）。
/// 窗口 [i - n~/2, i + (n-1)~/2]，越界视为 False（border_value=0）。
List<bool> binaryDilation1D(List<bool> a, int n) {
  final len = a.length;
  final out = List<bool>.filled(len, false);
  if (n <= 1) {
    for (int i = 0; i < len; i++) {
      out[i] = a[i];
    }
    return out;
  }
  final hL = n ~/ 2, hR = (n - 1) ~/ 2;
  for (int i = 0; i < len; i++) {
    bool v = false;
    final lo = math.max(0, i - hL), hi = math.min(len - 1, i + hR);
    for (int j = lo; j <= hi; j++) {
      if (a[j]) {
        v = true;
        break;
      }
    }
    out[i] = v;
  }
  return out;
}

/// 一维二值腐蚀（scipy.ndimage.binary_erosion, border_value=0）。
List<bool> binaryErosion1D(List<bool> a, int n) {
  final len = a.length;
  final out = List<bool>.filled(len, false);
  if (n <= 1) {
    for (int i = 0; i < len; i++) {
      out[i] = a[i];
    }
    return out;
  }
  final hL = n ~/ 2, hR = (n - 1) ~/ 2;
  for (int i = 0; i < len; i++) {
    bool v = true;
    final lo = math.max(0, i - hL), hi = math.min(len - 1, i + hR);
    for (int j = lo; j <= hi; j++) {
      if (!a[j]) {
        v = false;
        break;
      }
    }
    // 越界视为 False：窗口未完全覆盖时必为 False
    if (i - hL < 0 || i + hR > len - 1) v = false;
    out[i] = v;
  }
  return out;
}

/// 一维二值闭运算（补小洞，scipy.ndimage.binary_closing border_value=0）。
List<bool> binaryClosing1D(List<bool> a, int n) {
  return binaryErosion1D(binaryDilation1D(a, n), n);
}

/// 一维连通域（True 连续段），返回 [start, end) 区间列表。
List<List<int>> labelRuns(List<bool> mask) {
  final runs = <List<int>>[];
  int i = 0;
  final len = mask.length;
  while (i < len) {
    if (mask[i]) {
      int j = i + 1;
      while (j < len && mask[j]) {
        j++;
      }
      runs.add([i, j]);
      i = j;
    } else {
      i++;
    }
  }
  return runs;
}

// ---------------------------------------------------------------- 重采样

/// 窗口化 sinc 重采样（32 抽头 Hann 窗，抗混叠）。
/// 目标采样率固定 22050；srIn == SR 时直接返回副本。
Float32List resampleToSR(Float32List x, int srIn, int srOut) {
  if (srIn == srOut) return Float32List.fromList(x);
  final ratio = srIn / srOut; // 每个输出样本对应的输入步长
  final nOut = (x.length / ratio).floor();
  final out = Float32List(math.max(0, nOut));
  if (nOut == 0) return out;
  const taps = 16; // 单侧抽头数
  // 归一化截止（相对输入采样率）：目标奈奎斯特的 0.9
  final cutoff = 0.5 * math.min(srIn, srOut) / srIn * 0.9;
  final scale = cutoff;
  for (int i = 0; i < nOut; i++) {
    final p = i * ratio;
    final i0 = p.floor();
    final frac = p - i0;
    double acc = 0.0;
    for (int k = -taps + 1; k <= taps; k++) {
      final idx = i0 + k;
      if (idx < 0 || idx >= x.length) continue;
      final d = frac - k; // 距离目标点（单位：输入样本）
      if (d == 0) {
        acc += x[idx];
        continue;
      }
      if (d.abs() > taps) continue;
      // sinc(cutoff * d) * hann(d / taps)
      final t = d / taps;
      final w = 0.5 * (1 + math.cos(math.pi * t));
      acc += x[idx] *
          w *
          math.sin(math.pi * cutoff * d) / (math.pi * cutoff * d);
    }
    out[i] = acc * scale;
  }
  return out;
}

// ---------------------------------------------------------------- Butterworth 带通 + 零相位滤波

class Biquad {
  double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
}

/// 设计 4 阶（8 极点）Butterworth 带通，返回 4 个二阶节（与
/// scipy.signal.butter(4, [lo, hi], btype='band', fs=sr, output='sos') 等效）。
List<Biquad> designButterBandpass(double lo, double hi, double sr) {
  // 双线性预扭曲（T=1）
  final wl = math.tan(math.pi * lo / sr);
  final wh = math.tan(math.pi * hi / sr);
  final w0sq = wl * wh;
  final bw = wh - wl;
  // 4 阶 Butterworth 模拟低通原型极点（单位圆左半）
  const n = 4;
  // 对每个原型极点 p 做低通->带通变换: s^2 - bw*p*s + w0^2 = 0
  final zPoles = <Complex>[];
  for (int k = 0; k < n; k++) {
    final phi = math.pi * (2 * k + n + 1) / (2 * n);
    final p = Complex(math.cos(phi), math.sin(phi)); // Re < 0
    final b = p.times(bw);
    final disc = (b * b).minus(Complex(4 * w0sq, 0));
    final sq = disc.sqrt();
    zPoles.add(b.plus(sq).times(0.5));
    zPoles.add(b.minus(sq).times(0.5));
  }
  // 双线性变换 z = (1 + s/2) / (1 - s/2)，零点为 z=1 与 z=-1
  final sections = <Biquad>[];
  final used = List<bool>.filled(zPoles.length, false);
  for (int i = 0; i < zPoles.length; i++) {
    if (used[i]) continue;
    // 找共轭配对
    int partner = -1;
    for (int j = i + 1; j < zPoles.length; j++) {
      if (!used[j] &&
          (zPoles[i].re - zPoles[j].re).abs() < 1e-9 &&
          (zPoles[i].im + zPoles[j].im).abs() < 1e-9) {
        partner = j;
        break;
      }
    }
    if (partner < 0) partner = i;
    used[i] = true;
    used[partner] = true;
    final p1 = zPoles[i], p2 = zPoles[partner];
    final z1 = Complex(1 + p1.re / 2, p1.im / 2) / (Complex(1 - p1.re / 2, -p1.im / 2));
    final z2 = Complex(1 + p2.re / 2, p2.im / 2) / (Complex(1 - p2.re / 2, -p2.im / 2));
    final bq = Biquad();
    // 分子: (1 - z^-2)；分母: (1 - p1 z^-1)(1 - p2 z^-1)
    bq.a1 = -(z1.re + z2.re);
    bq.a2 = z1.re * z2.re - z1.im * z2.im; // z1*z2 的实部（共轭对 => |z1|^2）
    bq.b0 = 1;
    bq.b1 = 0;
    bq.b2 = -1;
    sections.add(bq);
  }
  // 归一化通带中心增益为 1
  final wCenter = math.pi * math.sqrt(lo * hi) / sr;
  final gain = _biquadChainGain(sections, wCenter);
  final g = gain.abs() < 1e-12 ? 1.0 : 1.0 / gain.abs();
  for (final s in sections) {
    s.b0 *= g;
    s.b2 *= g;
  }
  return sections;
}

double _biquadChainGain(List<Biquad> secs, double w) {
  double mag = 1.0;
  final c1 = math.cos(w), s1 = math.sin(w);
  final c2 = math.cos(2 * w), s2 = math.sin(2 * w);
  for (final q in secs) {
    // H(z) 在 z=e^{jw}
    final nr = q.b0 + q.b1 * c1 + q.b2 * c2;
    final ni = -(q.b1 * s1 + q.b2 * s2);
    final dr = 1.0 + q.a1 * c1 + q.a2 * c2;
    final di = -(q.a1 * s1 + q.a2 * s2);
    final dm = dr * dr + di * di;
    mag *= math.sqrt((nr * nr + ni * ni) / (dm < 1e-30 ? 1e-30 : dm));
  }
  return mag;
}

/// 直接 I 型 biquad 级联滤波（就地返回新数组）。
Float32List _sosFilt(List<Biquad> secs, Float32List x) {
  final y = Float32List(x.length);
  for (final q in secs) {
    double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    for (int i = 0; i < x.length; i++) {
      final xn = x[i];
      final yn = q.b0 * xn + q.b1 * x1 + q.b2 * x2 - q.a1 * y1 - q.a2 * y2;
      x2 = x1;
      x1 = xn;
      y2 = y1;
      y1 = yn;
      y[i] = yn;
    }
    // 级联：后续节以本节输出为输入
    for (int i = 0; i < y.length; i++) {
      x[i] = y[i];
    }
  }
  return y;
}

/// 零相位 sosfiltfilt（奇延拓 padding，前后向各滤一次）。
Float32List sosFiltFilt(List<Biquad> secs, Float32List x) {
  const padLen = 27;
  final n = x.length;
  final pad = math.min(padLen, n - 1);
  final ext = Float32List(n + 2 * pad);
  // odd 延拓
  for (int i = 0; i < pad; i++) {
    ext[i] = 2 * x[0] - x[pad - i];
    ext[n + pad + i] = 2 * x[n - 1] - x[n - 2 - i];
  }
  for (int i = 0; i < n; i++) {
    ext[pad + i] = x[i];
  }
  var y = _sosFilt(secs, ext);
  // 反转再滤一次
  final rev = Float32List(y.length);
  for (int i = 0; i < y.length; i++) {
    rev[i] = y[y.length - 1 - i];
  }
  y = _sosFilt(secs, rev);
  final out = Float32List(n);
  for (int i = 0; i < n; i++) {
    out[i] = y[y.length - 1 - (pad + i)];
  }
  return out;
}

// ---------------------------------------------------------------- 复数

class Complex {
  final double re, im;
  const Complex(this.re, this.im);
  Complex operator +(Complex o) => Complex(re + o.re, im + o.im);
  Complex operator -(Complex o) => Complex(re - o.re, im - o.im);
  Complex operator *(Complex o) =>
      Complex(re * o.re - im * o.im, re * o.im + im * o.re);
  Complex times(double f) => Complex(re * f, im * f);
  Complex plus(Complex o) => Complex(re + o.re, im + o.im);
  Complex minus(Complex o) => Complex(re - o.re, im - o.im);
  Complex operator /(Complex o) {
    final d = o.re * o.re + o.im * o.im;
    return Complex((re * o.re + im * o.im) / d, (im * o.re - re * o.im) / d);
  }

  Complex sqrt() {
    final r = math.sqrt(re * re + im * im);
    final m = math.sqrt(math.max(0.0, (r + re) / 2));
    double n = math.sqrt(math.max(0.0, (r - re) / 2));
    if (im < 0) n = -n;
    return Complex(m, n);
  }
}
