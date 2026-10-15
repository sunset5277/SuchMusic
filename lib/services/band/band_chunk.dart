import 'dart:convert';

import 'band_protocol.dart';

/// SuchMusic 手环通信 · 分片（header → data → end）编解码与 CRC32。
///
/// 纯函数实现，不依赖 Flutter，便于单测。帧格式与 Kotlin 端
/// `BandChunkCodec.kt` 严格一致（字段名冻结）：
///
/// ```
/// header: { tid, phase:"header", kind, total, bytes, crc32, meta }
/// data  : { tid, phase:"data", seq, txt }     // 文本
/// data  : { tid, phase:"data", seq, b64 }     // 二进制
/// end   : { tid, phase:"end", total, crc32 }
/// ```
class BandChunk {
  /// 单包字节上限（保守值，真实上限待真机验证）。
  static const int chunkMaxBytes = 900;

  /// 手环组装缓存上限，超限即回落增量模式。
  static const int assembleMaxBytes = 8192;

  static final List<int> _crcTable = _buildTable();

  static List<int> _buildTable() {
    final table = List<int>.filled(256, 0);
    for (int i = 0; i < 256; i++) {
      int c = i;
      for (int k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
      }
      table[i] = c & 0xFFFFFFFF;
    }
    return table;
  }

  /// 计算 IEEE CRC32（与 zlib 同款）。
  static int crc32(List<int> bytes) {
    int crc = 0xFFFFFFFF;
    for (final b in bytes) {
      crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  /// CRC32 的 8 位小写十六进制（协议字段 `crc32`）。
  static String crc32Hex(List<int> bytes) =>
      crc32(bytes).toRadixString(16).padLeft(8, '0');

  /// 文本载荷切分为 header/data*/end 三段的 payload 列表。
  static List<Map<String, dynamic>> splitText({
    required String tid,
    required String kind,
    required String text,
    Map<String, dynamic>? meta,
  }) {
    final bytes = utf8.encode(text);
    final crc = crc32Hex(bytes);
    final pieces = _splitOnCharBoundary(text, chunkMaxBytes);

    final frames = <Map<String, dynamic>>[];
    frames.add({
      'tid': tid,
      'phase': 'header',
      'kind': kind,
      'total': pieces.length,
      'bytes': bytes.length,
      'crc32': crc,
      'meta': ?meta,
    });
    for (var i = 0; i < pieces.length; i++) {
      frames.add({
        'tid': tid,
        'phase': 'data',
        'seq': i,
        'txt': pieces[i],
      });
    }
    frames.add({
      'tid': tid,
      'phase': 'end',
      'total': pieces.length,
      'crc32': crc,
    });
    return frames;
  }

  /// 二进制载荷切分（每片 base64 承载，CRC32 覆盖完整字节）。
  static List<Map<String, dynamic>> splitBytes({
    required String tid,
    required String kind,
    required List<int> data,
    Map<String, dynamic>? meta,
  }) {
    final crc = crc32Hex(data);
    final total =
        data.isEmpty ? 0 : ((data.length + chunkMaxBytes - 1) ~/ chunkMaxBytes);

    final frames = <Map<String, dynamic>>[];
    frames.add({
      'tid': tid,
      'phase': 'header',
      'kind': kind,
      'total': total,
      'bytes': data.length,
      'crc32': crc,
      'meta': ?meta,
    });
    for (var i = 0; i < total; i++) {
      final from = i * chunkMaxBytes;
      final to = (from + chunkMaxBytes).clamp(0, data.length);
      final slice = data.sublist(from, to);
      frames.add({
        'tid': tid,
        'phase': 'data',
        'seq': i,
        'b64': base64Encode(slice),
      });
    }
    frames.add({
      'tid': tid,
      'phase': 'end',
      'total': total,
      'crc32': crc,
    });
    return frames;
  }

  /// 按 UTF-8 字节上限切分，且不切断多字节字符。
  static List<String> _splitOnCharBoundary(String text, int maxBytes) {
    final result = <String>[];
    final buffer = StringBuffer();
    int bufferedBytes = 0;
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      final chBytes = utf8.encode(ch).length;
      if (bufferedBytes + chBytes > maxBytes && buffer.isNotEmpty) {
        result.add(buffer.toString());
        buffer.clear();
        bufferedBytes = 0;
      }
      buffer.write(ch);
      bufferedBytes += chBytes;
    }
    if (buffer.isNotEmpty) result.add(buffer.toString());
    return result;
  }

  /// 拆分一帧是否超过内联阈值（序列化后字节数）。
  static bool exceedsInline(String text) =>
      utf8.encode(text).length > chunkMaxBytes;
}

/// 组装状态。
enum ChunkStatus { pending, complete, failed }

/// 组装结果。
class ChunkResult {
  const ChunkResult.pending()
      : status = ChunkStatus.pending,
        text = null,
        missing = const <int>[],
        error = null;

  const ChunkResult.complete(String this.text)
      : status = ChunkStatus.complete,
        missing = const <int>[],
        error = null;

  const ChunkResult.failed(this.missing, this.error)
      : status = ChunkStatus.failed,
        text = null;

  final ChunkStatus status;
  final String? text;

  /// 失败时缺失的分片序号（空表示整体失败 / CRC 不符）。
  final List<int> missing;

  /// 失败原因（错误码字符串）。
  final String? error;
}

/// 分片组装器：header 记录 total/bytes/crc32 → data 按 seq 落位 →
/// end 时校验 `count == total && crc32(buf) == crc32`。
class BandChunkAssembler {
  BandChunkAssembler({this.maxBytes = BandChunk.assembleMaxBytes});

  final int maxBytes;

  String? _tid;
  int _total = 0;
  String? _crc;
  int _bytes = 0;
  bool _started = false;
  bool _oversize = false;
  final Map<int, String> _parts = <int, String>{};

  String? get tid => _tid;

  void onHeader(Map<String, dynamic> payload) {
    _tid = payload['tid'] as String?;
    _total = (payload['total'] as num?)?.toInt() ?? 0;
    _crc = payload['crc32'] as String?;
    _bytes = (payload['bytes'] as num?)?.toInt() ?? 0;
    _oversize = _bytes > maxBytes;
    _parts.clear();
    _started = true;
  }

  void onData(Map<String, dynamic> payload) {
    if (!_started) return;
    final seq = (payload['seq'] as num?)?.toInt();
    if (seq == null) return;
    _parts[seq] = payload['txt'] as String? ?? '';
  }

  ChunkResult onEnd(Map<String, dynamic> payload) {
    if (!_started) {
      return const ChunkResult.failed(<int>[], 'end before header');
    }
    if (_oversize) {
      final missing = _missing();
      _reset();
      return ChunkResult.failed(missing, BandError.tooLarge.code);
    }
    final missing = _missing();
    if (missing.isNotEmpty) {
      _reset();
      return ChunkResult.failed(missing, BandError.crc.code);
    }
    final buffer = StringBuffer();
    for (var i = 0; i < _total; i++) {
      buffer.write(_parts[i]);
    }
    final text = buffer.toString();
    final ok = BandChunk.crc32Hex(utf8.encode(text)) == _crc;
    _reset();
    return ok
        ? ChunkResult.complete(text)
        : const ChunkResult.failed(<int>[], 'E_CRC');
  }

  List<int> _missing() =>
      [for (var i = 0; i < _total; i++) if (!_parts.containsKey(i)) i];

  void _reset() {
    _parts.clear();
    _started = false;
  }
}
