import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 本地音频内嵌封面提取器（纯 Dart 解析文件头）：
/// - mp3：ID3v2.2 PIC / ID3v2.3-2.4 APIC 帧
/// - flac：PICTURE metadata block（type 6）
/// - m4a/mp4：moov→udta→meta→ilst→covr→data atom 链
/// - ogg/opus/wav 等无内嵌封面或暂不支持，返回 null（UI 显示默认占位）
/// 结果按路径缓存（含无封面的负缓存），重复刷新/滚动零开销
class AudioCoverExtractor {
  // 缓存上限保护：超限整体清空（封面解析只在浏览到的行触发，正常到不了）
  static const _maxCache = 500;
  static final Map<String, Uint8List?> _cache = {};

  static Future<Uint8List?> extract(String path) async {
    final hit = _cache[path];
    if (_cache.containsKey(path)) return hit;
    final cover = await _extract(path);
    if (_cache.length >= _maxCache) _cache.clear();
    _cache[path] = cover;
    return cover;
  }

  static Future<Uint8List?> _extract(String path) async {
    RandomAccessFile raf;
    try {
      raf = await File(path).open();
    } catch (_) {
      return null;
    }
    try {
      final head = await raf.read(12);
      if (head.length < 12) return null;
      if (head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) {
        // 'ID3' — mp3
        return await _extractId3(raf, head);
      }
      if (head[0] == 0x66 && head[1] == 0x4C && head[2] == 0x61 &&
          head[3] == 0x43) {
        // 'fLaC'
        return await _extractFlac(raf);
      }
      if (head[4] == 0x66 && head[5] == 0x74 && head[6] == 0x79 &&
          head[7] == 0x70) {
        // 偏移 4 处为 'ftyp' — mp4/m4a
        return await _extractMp4(raf);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      try {
        await raf.close();
      } catch (_) {}
    }
  }

  // ---------- ID3v2 ----------

  /// 读整个 ID3 tag 后在内存中逐帧找 frameIds 中的第一个帧，返回其 body
  static Future<Uint8List?> _findId3Frame(
      RandomAccessFile raf, Uint8List head, Set<String> frameIds) async {
    final major = head[3];
    final flags = head[5];
    final tagSize = _syncsafe(head, 6); // 不含 10 字节头
    if (tagSize < 20 || tagSize > 10 * 1024 * 1024) return null;
    // head 读了 12 字节，ID3 tag 实际从 offset 10 开始，重新定位
    await raf.setPosition(10);
    final tag = await raf.read(tagSize);
    var pos = 0;
    // 扩展头：跳过（v2.3 长度字段非 syncsafe，v2.4 为 syncsafe）
    if ((flags & 0x40) != 0 && pos + 4 <= tag.length) {
      final extSize =
          major >= 4 ? _syncsafe(tag, pos) : _u32be(tag, pos) + 4;
      pos += extSize;
    }
    final idLen = major <= 2 ? 3 : 4;
    final sizeLen = major <= 2 ? 3 : 4;
    while (pos + idLen + sizeLen <= tag.length) {
      final frameId = latin1.decode(tag.sublist(pos, pos + idLen),
          allowInvalid: true);
      if (frameId == '\x00\x00\x00') break; // padding
      int frameSize;
      if (major <= 2) {
        frameSize = _u24be(tag, pos + idLen);
      } else if (major == 4) {
        frameSize = _syncsafe(tag, pos + idLen);
      } else {
        frameSize = _u32be(tag, pos + idLen);
      }
      final headerLen = idLen + sizeLen + (major <= 2 ? 0 : 2);
      final bodyStart = pos + headerLen;
      if (frameSize <= 0 || bodyStart + frameSize > tag.length) break;
      if (frameIds.contains(frameId)) {
        return Uint8List.sublistView(tag, bodyStart, bodyStart + frameSize);
      }
      pos = bodyStart + frameSize;
    }
    return null;
  }

  /// 内嵌封面：mp3 走 APIC/PIC 帧
  static Future<Uint8List?> _extractId3(
      RandomAccessFile raf, Uint8List head) async {
    final body =
        await _findId3Frame(raf, head, {'APIC', 'PIC'});
    if (body == null) return null;
    final isV22 = head[3] <= 2;
    return _parseApic(body, isV22);
  }

  /// 内嵌歌词：mp3 走 USLT/ULT 帧
  static Future<String?> _extractId3Lyrics(
      RandomAccessFile raf, Uint8List head) async {
    final body = await _findId3Frame(raf, head, {'USLT', 'ULT'});
    if (body == null) return null;
    return _parseUslt(body);
  }

  /// 内嵌歌词提取：优先同名 .lrc 文件，其次 mp3 内嵌 USLT/ULT 帧
  /// （flac/m4a 的歌词 tag 较少见，暂不解析）
  static final RegExp _lrcTimeRe = RegExp(r'\[\d{1,3}:\d{1,2}');
  static final Map<String, String?> _lyricsCache = {};

  static Future<String?> extractLyrics(String path) async {
    if (_lyricsCache.containsKey(path)) return _lyricsCache[path];
    String? lrc;
    try {
      // 1. 同名 .lrc 文件（内容最标准）
      final dot = path.lastIndexOf('.');
      final base = dot > path.lastIndexOf('/') ? path.substring(0, dot) : path;
      final lrcFile = File('$base.lrc');
      if (await lrcFile.exists()) {
        final text = await lrcFile.readAsString();
        if (_lrcTimeRe.hasMatch(text)) lrc = text;
      }
      // 2. mp3 内嵌歌词
      lrc ??= await _extractEmbeddedLyrics(path);
    } catch (_) {
      lrc = null;
    }
    if (_lyricsCache.length >= _maxCache) _lyricsCache.clear();
    _lyricsCache[path] = lrc;
    return lrc;
  }

  static Future<String?> _extractEmbeddedLyrics(String path) async {
    RandomAccessFile raf;
    try {
      raf = await File(path).open();
    } catch (_) {
      return null;
    }
    try {
      final head = await raf.read(12);
      if (head.length < 12) return null;
      if (head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) {
        return await _extractId3Lyrics(raf, head);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      try {
        await raf.close();
      } catch (_) {}
    }
  }

  /// USLT/ULT body：enc(1) + lang(3) + desc(null结尾) + 文本。
  /// 实际文件普遍不规范（常见省略 lang、UTF-16 BOM 位置诡异），
  /// 因此不做逐字段解析，直接在 body 里搜索 LRC 时间轴起始标记，
  /// 从标记处解码到帧尾（LRC 时间轴后的内容按对应编码解码）。
  static String? _parseUslt(Uint8List body) {
    if (body.length < 8) return null;
    final encoding = body[0];
    int textStart = -1;
    bool utf16 = false;
    if (encoding == 1 || encoding == 2) {
      utf16 = true;
      // UTF-16：找 BOM+'['（FF FE 5B）或裸 '['（5B 00）
      for (var i = 1; i + 2 < body.length; i++) {
        if (body[i] == 0xFF && body[i + 1] == 0xFE && body[i + 2] == 0x5B) {
          textStart = i;
          break;
        }
        if (body[i] == 0x5B && body[i + 1] == 0x00) {
          textStart = i;
          break;
        }
      }
    } else {
      // latin1/UTF-8：找 '['（5B）
      textStart = body.indexOf(0x5B, 1);
    }
    if (textStart < 0) return null;
    String text;
    try {
      if (utf16) {
        text = utf16Decode(body.sublist(textStart));
      } else {
        text = utf8.decode(body.sublist(textStart), allowMalformed: true);
      }
    } catch (_) {
      return null;
    }
    return _lrcTimeRe.hasMatch(text) ? text : null;
  }

  /// UTF-16 解码（自动识别 BOM，无 BOM 按 LE 处理）
  static String utf16Decode(Uint8List bytes) {
    var start = 0;
    var littleEndian = true;
    if (bytes.length >= 2) {
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        littleEndian = true;
        start = 2;
      } else if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        littleEndian = false;
        start = 2;
      }
    }
    final buffer = StringBuffer();
    for (var i = start; i + 1 < bytes.length; i += 2) {
      final unit = littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1];
      if (unit == 0x0000) break; // 终止符
      buffer.writeCharCode(unit);
    }
    return buffer.toString();
  }

  /// APIC/PIC body：encoding(1) + mime(null结尾，v2.2 为 3 字节格式码)
  /// + picType(1) + description(null结尾，按编码) + 图片数据
  static Uint8List? _parseApic(Uint8List body, bool isV22) {
    if (body.isEmpty) return null;
    final encoding = body[0];
    var p = 1;
    String mime;
    if (isV22) {
      // v2.2 PIC：3 字节格式码 'JPG'/'PNG'
      if (p + 3 > body.length) return null;
      final fmt = latin1.decode(body.sublist(p, p + 3), allowInvalid: true);
      mime = fmt == 'PNG' ? 'image/png' : 'image/jpeg';
      p += 3;
    } else {
      // v2.3/2.4：null 结尾的 mime 字符串
      final mimeEnd = body.indexOf(0x00, p);
      if (mimeEnd < 0) return null;
      mime = latin1.decode(body.sublist(p, mimeEnd), allowInvalid: true);
      p = mimeEnd + 1;
    }
    if (p >= body.length) return null;
    p += 1; // picType（不区分封面类型，取第一个图片帧）
    // 跳过 description（按编码找 null 终止符）
    if (encoding == 1 || encoding == 2) {
      // UTF-16：找 0x00 0x00，且与奇偶对齐
      while (p + 1 < body.length) {
        if (body[p] == 0x00 && body[p + 1] == 0x00) {
          p += 2;
          break;
        }
        p += 1;
      }
    } else {
      final descEnd = body.indexOf(0x00, p);
      p = descEnd < 0 ? body.length : descEnd + 1;
    }
    if (p >= body.length) return null;
    final data = Uint8List.sublistView(body, p);
    if (data.length < 100) return null; // 过小基本是坏数据
    // 仅接受真实图片 mime；'-->'（链接）不支持
    if (mime.contains('jpeg') || mime.contains('jpg')) return data;
    if (mime.contains('png')) return data;
    if (mime.contains('webp')) return data;
    if (mime.contains('bmp')) return data;
    // 编码探测兜底：jpeg/p Magic
    if (_looksLikeImage(data)) return data;
    return null;
  }

  // ---------- FLAC ----------

  static Future<Uint8List?> _extractFlac(RandomAccessFile raf) async {
    var pos = 4; // 跳过 'fLaC'
    while (true) {
      await raf.setPosition(pos);
      final header = await raf.read(4);
      if (header.length < 4) return null;
      final isLast = (header[0] & 0x80) != 0;
      final blockType = header[0] & 0x7F;
      final blockLen = (header[1] << 16) | (header[2] << 8) | header[3];
      if (blockType == 6) {
        // PICTURE block
        final body = await raf.read(blockLen);
        if (body.length < blockLen) return null;
        return _parseFlacPicture(body);
      }
      if (isLast || blockLen > 16 * 1024 * 1024) return null;
      pos += 4 + blockLen;
    }
  }

  /// PICTURE body：type(4)+mimeLen(4)+mime+descLen(4)+desc+
  /// width/height/depth/colors(各4)+dataLen(4)+data
  static Uint8List? _parseFlacPicture(Uint8List body) {
    var p = 4; // 跳过 picture type
    if (p + 4 > body.length) return null;
    final mimeLen = _u32be(body, p);
    p += 4;
    if (p + mimeLen > body.length) return null;
    p += mimeLen;
    if (p + 4 > body.length) return null;
    final descLen = _u32be(body, p);
    p += 4 + descLen;
    if (p + 20 > body.length) return null;
    final dataLen = _u32be(body, p + 16);
    p += 20;
    if (dataLen <= 0 || p + dataLen > body.length) return null;
    return Uint8List.sublistView(body, p, p + dataLen);
  }

  // ---------- MP4 / M4A ----------

  static Future<Uint8List?> _extractMp4(RandomAccessFile raf) async {
    final fileSize = await raf.length();
    var pos = 0;
    while (pos + 8 <= fileSize) {
      await raf.setPosition(pos);
      final header = await raf.read(8);
      if (header.length < 8) return null;
      final rawSize = _u32be(header, 0);
      final type = latin1.decode(header.sublist(4, 8), allowInvalid: true);
      var headerLen = 8;
      var boxSize = rawSize;
      if (rawSize == 1) {
        final ext = await raf.read(8);
        if (ext.length < 8) return null;
        boxSize = _u64be(ext, 0);
        headerLen = 16;
      } else if (rawSize == 0) {
        boxSize = fileSize - pos;
      }
      if (boxSize < headerLen) return null;
      if (type == 'moov') {
        final moov = await raf.read(boxSize - headerLen);
        return _findCovr(moov);
      }
      pos += boxSize;
    }
    return null;
  }

  /// 在 moov 内按 moov→udta→meta→ilst→covr 找链路，最后读 covr 里的 data atom
  static Uint8List? _findCovr(Uint8List moov) {
    var udta = _atomRange(moov, 0, moov.length, 'udta');
    udta ??= _atomRange(moov, 0, moov.length, 'meta'); // 少数文件无 udta
    if (udta == null) return null;
    var meta = _atomRange(moov, udta[0], udta[1], 'meta');
    meta ??= udta;
    // meta 是 full box 时 payload 前有 4 字节 version/flags
    var ilst = _atomRange(moov, meta[0], meta[1], 'ilst');
    if (ilst == null) {
      if (meta[1] - meta[0] < 4) return null;
      ilst = _atomRange(moov, meta[0] + 4, meta[1], 'ilst');
    }
    if (ilst == null) return null;
    final covr = _atomRange(moov, ilst[0], ilst[1], 'covr');
    if (covr == null) return null;
    final data = _atomRange(moov, covr[0], covr[1], 'data');
    if (data == null) return null;
    // data atom payload：version/flags(4) + locale(4) + 内容
    final start = data[0] + 8;
    final end = data[1];
    if (end - start < 100 || end > moov.length) return null;
    return Uint8List.sublistView(moov, start, end);
  }

  /// 在 [start,end) 内找 type 指定的原子，返回 [payloadStart, payloadEnd)
  static List<int>? _atomRange(Uint8List data, int start, int end, String type) {
    var pos = start;
    final t = latin1.encode(type);
    while (pos + 8 <= end) {
      final boxSize = _u32be(data, pos);
      var headerLen = 8;
      var realSize = boxSize;
      if (boxSize == 1) {
        if (pos + 16 > end) return null;
        realSize = _u64be(data, pos + 8);
        headerLen = 16;
      } else if (boxSize == 0) {
        realSize = end - pos;
      }
      if (realSize < headerLen || pos + realSize > end) return null;
      if (data[pos + 4] == t[0] &&
          data[pos + 5] == t[1] &&
          data[pos + 6] == t[2] &&
          data[pos + 7] == t[3]) {
        return [pos + headerLen, pos + realSize];
      }
      pos += realSize;
    }
    return null;
  }

  // ---------- 工具 ----------

  static bool _looksLikeImage(Uint8List d) {
    if (d.length < 12) return false;
    // JPEG: FF D8 FF；PNG: 89 50 4E 47；BMP: 'BM'；WEBP: 'RIFF'...'WEBP'
    if (d[0] == 0xFF && d[1] == 0xD8 && d[2] == 0xFF) return true;
    if (d[0] == 0x89 && d[1] == 0x50 && d[2] == 0x4E && d[3] == 0x47) {
      return true;
    }
    if (d[0] == 0x42 && d[1] == 0x4D) return true;
    if (d[0] == 0x52 && d[1] == 0x49 && d[8] == 0x57 && d[9] == 0x45) {
      return true;
    }
    return false;
  }

  static int _u32be(Uint8List b, int p) =>
      (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];

  static int _u24be(Uint8List b, int p) =>
      (b[p] << 16) | (b[p + 1] << 8) | b[p + 2];

  static int _u64be(Uint8List b, int p) {
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | b[p + i];
    }
    return v;
  }

  static int _syncsafe(Uint8List b, int p) =>
      (b[p] << 21) | (b[p + 1] << 14) | (b[p + 2] << 7) | b[p + 3];
}
