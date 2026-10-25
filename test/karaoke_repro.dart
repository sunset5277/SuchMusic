// 复现逐字对齐 isolate 内 RangeError 的测试脚本（纯 Dart，PC 上直接跑）
// 用法: dart run test/karaoke_repro.dart
// ignore_for_file: avoid_print
import 'package:such_music/services/karaoke/karaoke_align.dart';
import 'dart:math';
import 'dart:typed_data';

Float32List makePcm(double seconds, {int sr = 22050}) {
  final n = (seconds * sr).toInt();
  final pcm = Float32List(n);
  for (int i = 0; i < n; i++) {
    final t = i / sr;
    // 模拟人声：220Hz 基频 + 谐波，随时间幅度调制（每 0.5s 有起伏）
    final amp = 0.5 + 0.4 * sin(2 * pi * t / 0.5);
    pcm[i] = amp *
        (0.6 * sin(2 * pi * 220 * t) +
            0.3 * sin(2 * pi * 440 * t) +
            0.1 * sin(2 * pi * 880 * t));
  }
  return pcm;
}

void runCase(String name, double seconds, String lrc) {
  try {
    final song = alignKaraoke(lrc, makePcm(seconds), 'test_$name');
    print('[$name] OK: ${song.lines.length} lines');
    for (final l in song.lines) {
      print('  ${l.start.toStringAsFixed(2)}-${l.end.toStringAsFixed(2)}: '
          '${l.tokens.map((t) => '${t.text}@${t.start.toStringAsFixed(2)}').join(' ')}');
    }
  } catch (e) {
    print('[$name] FAILED: $e');
    rethrow; // 保留完整堆栈
  }
}

void main() {
  const shortLrc = '[00:00.50]测试一下逐字歌词\n'
      '[00:02.00]第二行歌词内容\n'
      '[00:04.00]最后一行结束啦';
  runCase('short-6s', 6.0, shortLrc);
  runCase('normal-30s', 30.0, shortLrc);
  runCase('one-line', 6.0, '[00:01.00]只有一行');
  runCase('long-line', 6.0, '[00:00.50]这一行有很多很多的字用来测试动态规划对齐的边界情况处理是否正确');
  runCase('edge-timing', 6.0, '[00:05.50]接近结尾的行\n[00:05.90]更接近结尾');
  print('ALL PASS');
}
