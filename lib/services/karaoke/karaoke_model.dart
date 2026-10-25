/// 制作名单行（歌手/作曲等）正则：对齐管线用它剔除，展示层用它从 LRC 补回
final RegExp kCreditLineRe = RegExp(
    r'(歌手|作曲|作词|编曲|混音|母带|制作人|监制|音乐设计|采样|小提琴|和声|伴唱|'
    r'吉他|贝斯|鼓|键盘|出品|企划|OP|SP|词|曲)\s*[:：]');

/// 逐字歌词数据模型（由端上音频对齐算法生成，结构与 V3 算法 JSON 输出一致）
class KaraokeToken {
  final String text;
  final double start; // 秒
  final double end; // 秒
  final double confidence;

  const KaraokeToken({
    required this.text,
    required this.start,
    required this.end,
    required this.confidence,
  });

  /// 间隙空格 token（不参与高亮填充，仅占位）
  bool get isSpace => text.trim().isEmpty;

  factory KaraokeToken.fromJson(Map<String, dynamic> j) => KaraokeToken(
        text: j['text'] as String? ?? '',
        start: (j['start'] as num?)?.toDouble() ?? 0.0,
        end: (j['end'] as num?)?.toDouble() ?? 0.0,
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0.0,
      );

  Map<String, dynamic> toJson() => {
        'text': text,
        'start': start,
        'end': end,
        'confidence': confidence,
      };
}

class KaraokeLine {
  final double start; // 秒
  final double end; // 秒
  final String text;
  final List<KaraokeToken> tokens;

  const KaraokeLine({
    required this.start,
    required this.end,
    required this.text,
    required this.tokens,
  });

  factory KaraokeLine.fromJson(Map<String, dynamic> j) => KaraokeLine(
        start: (j['start'] as num?)?.toDouble() ?? 0.0,
        end: (j['end'] as num?)?.toDouble() ?? 0.0,
        text: j['text'] as String? ?? '',
        tokens: ((j['tokens'] as List?) ?? const [])
            .map((t) => KaraokeToken.fromJson(t as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        'text': text,
        'tokens': tokens.map((t) => t.toJson()).toList(),
      };
}

class KaraokeSong {
  final String songId;
  final List<KaraokeLine> lines;

  const KaraokeSong({required this.songId, required this.lines});

  /// 定位时间 t 所在行（返回最后一个 start <= t 的行下标，-1 表示尚未开始）
  int lineIndexAt(double t) {
    int lo = 0, hi = lines.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].start <= t) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  factory KaraokeSong.fromJson(Map<String, dynamic> j) => KaraokeSong(
        songId: j['songId'] as String? ?? '',
        lines: ((j['lines'] as List?) ?? const [])
            .map((l) => KaraokeLine.fromJson(l as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'songId': songId,
        'lines': lines.map((l) => l.toJson()).toList(),
      };
}
