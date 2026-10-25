import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'karaoke/karaoke_align.dart';
import 'karaoke/karaoke_model.dart';
import 'karaoke/dsp.dart';
import 'music_api_service.dart';

enum KaraokeStatus { idle, downloading, decoding, aligning, ready, failed }

class KaraokeState {
  final String songId;
  final KaraokeStatus status;
  final double progress; // 0~1（仅下载阶段有效）
  final String? error;

  const KaraokeState(this.songId, this.status,
      {this.progress = 0, this.error});
}

/// 端上逐字歌词服务：下载音频 → 原生解码 → isolate 内跑对齐算法 → 缓存 JSON。
class KaraokeService {
  static final KaraokeService _instance = KaraokeService._internal();
  factory KaraokeService() => _instance;
  KaraokeService._internal();

  static const MethodChannel _channel = MethodChannel('such_music/karaoke');
  final Dio _dio = Dio();

  // 内存缓存：songId → 逐字数据
  final Map<String, KaraokeSong> _cache = {};
  // 正在计算中的 songId
  String? _runningSongId;
  // 最新期望计算的 songId（切歌时覆盖，实现"最新优先"）
  String? _desiredSongId;
  // 各 songId 的当前状态
  final Map<String, KaraokeState> _states = {};
  final StreamController<KaraokeState> _stateController =
      StreamController<KaraokeState>.broadcast();
  // 失败过的 songId（本次会话内不再重试）
  final Set<String> _failed = {};

  Stream<KaraokeState> get onStateChanged => _stateController.stream;

  KaraokeSong? cachedKaraoke(String songId) => _cache[songId];

  KaraokeState? stateOf(String songId) => _states[songId];

  Directory? _cacheDir;
  bool _initialized = false;

  Future<void> _ensureDir() async {
    if (_initialized && _cacheDir != null) return;
    final docs = await getApplicationDocumentsDirectory();
    _cacheDir = Directory('${docs.path}/karaoke');
    if (!await _cacheDir!.exists()) {
      await _cacheDir!.create(recursive: true);
    }
    _initialized = true;
  }

  File _cacheFile(String songId) => File('${_cacheDir!.path}/$songId.json');

  /// 请求某首歌的逐字数据。命中缓存立即返回；否则后台计算。
  /// 返回值：缓存命中时返回数据，否则 null（监听 onStateChanged 获取结果）。
  Future<KaraokeSong?> request(String songId, String lrcText) async {
    if (songId.isEmpty || lrcText.trim().isEmpty) return null;
    final hit = _cache[songId];
    if (hit != null) return hit;

    await _ensureDir();
    // 磁盘缓存
    if (await _cacheFile(songId).exists()) {
      try {
        final json = jsonDecode(await _cacheFile(songId).readAsString());
        final song = KaraokeSong.fromJson(json);
        if (song.lines.isNotEmpty) {
          _cache[songId] = song;
          _setState(KaraokeState(songId, KaraokeStatus.ready));
          return song;
        }
      } catch (_) {
        // 缓存损坏则删除重算
        try {
          await _cacheFile(songId).delete();
        } catch (_) {}
      }
    }

    if (_failed.contains(songId)) return null;
    // 已在计算
    if (_runningSongId == songId) return null;

    _desiredSongId = songId;
    _pump();
    return null;
  }

  void _setState(KaraokeState s) {
    _states[s.songId] = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  /// 计算调度器：空闲时启动，始终计算最新期望的歌曲
  Future<void> _pump() async {
    if (_runningSongId != null) return;
    final songId = _desiredSongId;
    if (songId == null || _cache.containsKey(songId)) {
      _desiredSongId = null;
      return;
    }
    _runningSongId = songId;
    try {
      await _compute(songId);
    } finally {
      _runningSongId = null;
      // 期间切了歌 → 继续
      if (_desiredSongId != null && _desiredSongId != songId) {
        _pump();
      } else {
        _desiredSongId = null;
      }
    }
  }

  Future<void> _compute(String songId) async {
    File? downloaded; // 下载的临时文件，解码后删除（本地源文件绝不删）
    try {
      // ---- 1/2. 取音频：本地歌直接用源文件，在线歌取链接后下载 ----
      final localPath = _localAudioPaths.remove(songId);
      final File audioFile;
      if (localPath != null) {
        _setState(KaraokeState(songId, KaraokeStatus.decoding));
        audioFile = File(localPath);
      } else {
        // 拿播放链接（320k 足够对齐用，避免下载 FLAC）
        String? url = await MusicApiService().getSongUrl(songId, br: 320000);
        url ??= await MusicApiService().getSongUrl(songId);
        if (url == null) throw Exception('无可用音频链接');

        // 下载（必须带 Referer/UA 头，否则网易 CDN 返回错误内容）
        _setState(KaraokeState(songId, KaraokeStatus.downloading));
        final tmpDir = Directory('${_cacheDir!.path}/tmp');
        if (!await tmpDir.exists()) await tmpDir.create(recursive: true);
        final ext = _extOf(url);
        final f = File('${tmpDir.path}/$songId.$ext');
        await _dio.download(url, f.path,
            options: Options(headers: {
              'Referer': 'https://music.163.com',
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            }), onReceiveProgress: (c, t) {
          if (t > 0) {
            _setState(KaraokeState(songId, KaraokeStatus.downloading,
                progress: (c / t).clamp(0.0, 1.0)));
          }
        });
        downloaded = f;
        audioFile = f;

        // 校验文件是音频（防止 CDN 返回错误页浪费解码）
        final head = await audioFile.openRead(0, 16).fold<List<int>>(
            <int>[], (a, b) => a..addAll(b));
        _validateAudioFile(head, url);
      }

      // ---- 3. 原生解码 → f32le 单声道 PCM ----
      _setState(KaraokeState(songId, KaraokeStatus.decoding));
      final decoded = await _channel
          .invokeMethod('decodeAudio', {'path': audioFile.path});
      final pcmPath = decoded['path'] as String;
      final sampleRate = decoded['sampleRate'] as int;
      if (downloaded != null) {
        try {
          await downloaded.delete();
        } catch (_) {}
      }

      // ---- 4. isolate 内重采样 + 特征 + 对齐 ----
      _setState(KaraokeState(songId, KaraokeStatus.aligning));
      final lrcText = _lrcFor(songId);
      if (lrcText == null) throw Exception('歌词缺失');
      final raw = await File(pcmPath).readAsBytes();
      try {
        await File(pcmPath).delete();
      } catch (_) {}
      // offsetInBytes 必须 4 字节对齐才能零拷贝建 Float32List 视图，否则先拷贝
      final Float32List rawPcm;
      if (raw.offsetInBytes % 4 == 0) {
        rawPcm = raw.buffer
            .asFloat32List(raw.offsetInBytes, raw.lengthInBytes ~/ 4);
      } else {
        final tmp = Uint8List.fromList(raw);
        rawPcm = tmp.buffer.asFloat32List(0, tmp.lengthInBytes ~/ 4);
      }

      // ---- 4. isolate 内重采样 + 特征 + 对齐 ----
      // 注意：必须用 Isolate.spawn + 显式纯数据消息，不能用 Isolate.run 闭包。
      // Isolate.run 的闭包会沿 context 链捕获 _compute 作用域里的其他闭包
      // （如 Dio 的 onReceiveProgress 捕获的 this），连带出 rxdart
      // BehaviorSubject 等不可发送对象导致崩溃。
      final song = await _runAlignIsolate(_AlignRequest(
        songId: songId,
        lrcText: lrcText,
        rawPcm: rawPcm,
        sampleRate: sampleRate,
      ));

      if (song.lines.isEmpty) throw Exception('歌词未解析到有效行');

      // ---- 5. 缓存 ----
      _cache[songId] = song;
      try {
        await _cacheFile(songId)
            .writeAsString(jsonEncode(song.toJson()), flush: true);
      } catch (_) {}
      _setState(KaraokeState(songId, KaraokeStatus.ready));
      debugPrint('🎤 逐字对齐完成: $songId (${song.lines.length} 行)');
    } catch (e) {
      _failed.add(songId);
      _setState(KaraokeState(songId, KaraokeStatus.failed, error: '$e'));
      debugPrint('❌ 逐字对齐失败: $songId -> $e');
    }
  }

  // 歌词文本由调用方暂存（避免重复请求）
  final Map<String, String> _lrcTexts = {};
  void attachLyrics(String songId, String lrcText) {
    _lrcTexts[songId] = lrcText;
    if (_lrcTexts.length > 50) {
      _lrcTexts.remove(_lrcTexts.keys.first);
    }
  }

  String? _lrcFor(String songId) => _lrcTexts[songId];

  // 本地歌曲的音频文件路径暂存（songId → path），计算时取出
  final Map<String, String> _localAudioPaths = {};

  /// 本地歌曲逐字对齐：音频直接用本地文件，跳过在线取址与下载
  Future<KaraokeSong?> requestLocal(
      String songId, String lrcText, String audioPath) async {
    if (songId.isEmpty || lrcText.trim().isEmpty) return null;
    if (!File(audioPath).existsSync()) return null;
    attachLyrics(songId, lrcText);
    final hit = _cache[songId];
    if (hit != null) return hit;

    await _ensureDir();
    // 磁盘缓存
    if (await _cacheFile(songId).exists()) {
      try {
        final json = jsonDecode(await _cacheFile(songId).readAsString());
        final song = KaraokeSong.fromJson(json);
        if (song.lines.isNotEmpty) {
          _cache[songId] = song;
          _setState(KaraokeState(songId, KaraokeStatus.ready));
          return song;
        }
      } catch (_) {
        // 缓存损坏则删除重算
        try {
          await _cacheFile(songId).delete();
        } catch (_) {}
      }
    }

    if (_failed.contains(songId)) return null;
    // 已在计算
    if (_runningSongId == songId) return null;

    if (_localAudioPaths.length > 50) {
      _localAudioPaths.remove(_localAudioPaths.keys.first);
    }
    _localAudioPaths[songId] = audioPath;
    _desiredSongId = songId;
    _pump();
    return null;
  }

  String _extOf(String url) {
    final path = Uri.parse(url).path.toLowerCase();
    if (path.endsWith('.flac')) return 'flac';
    if (path.endsWith('.ape')) return 'ape';
    if (path.endsWith('.wav')) return 'wav';
    if (path.endsWith('.m4a')) return 'm4a';
    return 'mp3';
  }

  /// 按魔数校验下载内容是音频容器；否则抛出带线索的错误（含内容头部 hex 与 host）
  void _validateAudioFile(List<int> head, String url) {
    String hex = head.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    bool ok = false;
    if (head.length >= 4) {
      // ID3 (mp3 带标签)
      if (head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) ok = true;
      // MPEG 帧同步 (0xFFEx)
      if (head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) ok = true;
      // fLaC
      if (head[0] == 0x66 && head[1] == 0x4C && head[2] == 0x61 && head[3] == 0x43) {
        ok = true;
      }
      // OggS
      if (head[0] == 0x4F && head[1] == 0x67 && head[2] == 0x67 && head[3] == 0x53) {
        ok = true;
      }
      // RIFF (wav)
      if (head[0] == 0x52 && head[1] == 0x49 && head[2] == 0x46 && head[3] == 0x46) {
        ok = true;
      }
      // MAC (ape)
      if (head[0] == 0x4D && head[1] == 0x41 && head[2] == 0x43 && head[3] == 0x20) {
        ok = true;
      }
      // ftyp (m4a/mp4，偏移 4)
      if (head.length >= 8 &&
          head[4] == 0x66 && head[5] == 0x74 &&
          head[6] == 0x79 && head[7] == 0x70) {
        ok = true;
      }
    }
    if (!ok) {
      throw Exception('下载内容不是音频 (head=$hex, host=${Uri.parse(url).host})');
    }
  }

  /// 清空逐字缓存（供设置页清理缓存调用），返回删除的文件数
  static Future<int> clearCache() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/karaoke');
      var count = 0;
      if (await dir.exists()) {
        await for (final e in dir.list(recursive: true)) {
          if (e is File) {
            count++;
            await e.delete();
          }
        }
      }
      _instance._cache.clear();
      _instance._failed.clear();
      return count;
    } catch (_) {
      return 0;
    }
  }
}

/// isolate 对齐请求（纯数据，全部可跨 isolate 发送）
class _AlignRequest {
  final String songId;
  final String lrcText;
  final Float32List rawPcm;
  final int sampleRate;
  const _AlignRequest({
    required this.songId,
    required this.lrcText,
    required this.rawPcm,
    required this.sampleRate,
  });
}

/// 启动对齐 isolate：显式消息传递，杜绝闭包 context 隐式捕获。
Future<KaraokeSong> _runAlignIsolate(_AlignRequest req) async {
  final port = ReceivePort();
  Isolate? isolate;
  try {
    isolate = await Isolate.spawn(_alignIsolateEntry, [port.sendPort, req]);
    final result = await port.first;
    if (result is KaraokeSong) return result;
    throw Exception('逐字对齐 isolate 失败: $result');
  } finally {
    isolate?.kill(priority: Isolate.immediate);
    port.close();
  }
}

/// isolate 顶层入口：重采样 → 特征 → 对齐。保证任何路径都回发一条消息。
void _alignIsolateEntry(List message) {
  final SendPort reply = message[0] as SendPort;
  final req = message[1] as _AlignRequest;
  try {
    final pcm = resampleToSR(req.rawPcm, req.sampleRate, 22050);
    reply.send(alignKaraoke(req.lrcText, pcm, req.songId));
  } catch (e) {
    reply.send('$e');
  }
}
