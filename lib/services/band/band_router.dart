import 'dart:async';
import 'dart:convert';

import '../../models/song_model.dart';
import '../audio_player_service.dart';
import 'band_chunk.dart';
import 'band_player_port.dart';
import 'band_protocol.dart';

/// SuchMusic 手环通信 · 手机侧路由。
///
/// 职责：
/// - `req` → 落地到 [BandPlayerPort]（真实上游播放服务），返回 `res`/`err`；
/// - [BandPlayerPort] 的状态流 → 协议 `evt`（进度事件按 **≤1 次/秒** 节流）；
/// - 大载荷（搜索/歌词/封面）超阈值时走 `xfer.chunk` 分片；
/// - 对 `req.id` 做 **LRU(64) 幂等去重**：重复命令只生效一次，直接回放缓存响应。
///
/// 本类不依赖任何 Flutter Widget / 通道，便于用 mock [BandPlayerPort] 单测。
class BandRouter {
  BandRouter({
    required this.port,
    required this.send,
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 播放端抽象（上游实现：`AudioPlayerServiceBandPort`）。
  final BandPlayerPort port;

  /// 手机 → 手环 的信封出口。
  final void Function(BandEnvelope env) send;

  /// 时钟（ms），可注入以便单测。
  final int Function() _clock;

  final BandIdGenerator _ids = BandIdGenerator(origin: 'p');
  final LruCache<String, BandEnvelope> _dedupe = LruCache<String, BandEnvelope>(64);
  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];

  /// 最近一次进度事件时间（用于 1Hz 节流）。
  int? _lastProgressAt;

  /// 未完成的分片传输：tid → 帧 payload 列表（用于 `xfer.nack` 重发）。
  final Map<String, List<Map<String, dynamic>>> _transfers =
      <String, List<Map<String, dynamic>>>{};
  int _chunkSeq = 0;

  int _sessionVersion = kBandProtoVersion;
  List<String> _sessionCaps = const <String>[];

  int get sessionVersion => _sessionVersion;
  List<String> get sessionCaps => List.unmodifiable(_sessionCaps);

  /// 握手完成后写入会话版本与能力。
  void setSession({required int version, required List<String> caps}) {
    _sessionVersion = version;
    _sessionCaps = List.unmodifiable(caps);
  }

  /// 订阅上游播放服务的状态流并转成协议事件。
  void attach() {
    _subs.add(port.onStateChanged.listen((s) {
      pushEvent('player.state', {
        'state': playerStateToWire(s),
        'playing': s == PlayerState.playing,
      });
    }));
    _subs.add(port.onCurrentSongChanged.listen((song) {
      pushEvent('player.song', {'song': songToDto(song)});
      _emitProgress(force: true); // 切歌立即补发进度
    }));
    _subs.add(port.onPositionChanged.listen((_) => _emitProgress()));
    _subs.add(port.onDurationChanged.listen((_) => _emitProgress()));
    _subs.add(port.onPlayModeChanged.listen((m) {
      pushEvent('player.mode', {'mode': playModeToWire(m)});
    }));
    _subs.add(port.onPlaylistChanged.listen((list) {
      pushEvent('player.queue', {
        'count': list.length,
        'currentIndex': port.currentIndex,
      });
    }));
    _subs.add(port.onLyricChanged.listen(_emitLyricLine));
    _subs.add(port.onLyricsChanged.listen((lines) {
      pushEvent('lyric.meta', {
        'songId': port.currentSong?.id ?? '',
        'has': lines.isNotEmpty,
        'count': lines.length,
      });
    }));
  }

  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  // ----- 事件 -----

  /// 发送一个事件信封（若无该能力则不发）。
  void pushEvent(String event, Map<String, dynamic> payload) {
    final cap = eventCap(event);
    if (cap != null && _sessionCaps.isNotEmpty && !_sessionCaps.contains(cap)) {
      return; // 对端未协商到该能力，不发送
    }
    send(BandEnvelope.evt(
      id: _ids.next(),
      event: event,
      payload: payload,
      ts: _clock(),
    ));
  }

  void _emitProgress({bool force = false}) {
    final now = _clock();
    if (!force && _lastProgressAt != null && now - _lastProgressAt! < 1000) {
      return;
    }
    _lastProgressAt = now;
    pushEvent('player.progress', {
      'positionMs': port.position.inMilliseconds,
      'durationMs': port.duration.inMilliseconds,
      'ts': now,
    });
  }

  void _emitLyricLine(String text) {
    final index = port.currentLyricIndex;
    final lines = port.lyrics;
    final t = (index >= 0 && index < lines.length)
        ? lines[index].timestamp.inMilliseconds
        : 0;
    pushEvent('lyric.line', {
      'songId': port.currentSong?.id ?? '',
      'index': index,
      'text': text,
      't': t,
    });
  }

  // ----- 请求 -----

  /// 处理一个 `req`，返回 `res`/`err`。重复 `req.id` 直接回放缓存。
  Future<BandEnvelope> handleRequest(BandEnvelope req) async {
    final id = req.id;
    if (id != null) {
      final cached = _dedupe.get(id);
      if (cached != null) {
        return cached; // 幂等：不重复执行
      }
    }
    BandEnvelope response;
    try {
      response = await _dispatch(req);
    } catch (e) {
      response = BandEnvelope.err(
        id: id,
        code: BandError.internal,
        message: '$e',
      );
    }
    if (id != null) {
      _dedupe.put(id, response);
    }
    return response;
  }

  Future<BandEnvelope> _dispatch(BandEnvelope req) async {
    final id = req.id;
    final method = req.method ?? '';
    final cap = methodCap(method);
    if (cap != null && _sessionCaps.isNotEmpty && !_sessionCaps.contains(cap)) {
      return BandEnvelope.err(
        id: id,
        code: BandError.unsupported,
        message: 'capability missing',
        missing: cap,
      );
    }

    switch (method) {
      case 'state.get':
        return BandEnvelope.res(id: id, payload: snapshot());

      case 'song.info':
        return BandEnvelope.res(id: id, payload: {'song': songToDto(port.currentSong)});

      case 'playback.play':
        if (port.currentSong == null) {
          await port.togglePlayPause();
        } else {
          await port.resume();
        }
        return BandEnvelope.res(id: id, payload: {'state': playerStateToWire(port.state)});

      case 'playback.pause':
        await port.pause();
        return BandEnvelope.res(id: id, payload: {'state': playerStateToWire(port.state)});

      case 'playback.toggle':
        await port.togglePlayPause();
        return BandEnvelope.res(id: id, payload: {'state': playerStateToWire(port.state)});

      case 'playback.next':
        if (port.playlist.isEmpty) {
          return BandEnvelope.err(id: id, code: BandError.empty, message: 'queue empty');
        }
        await port.playNext();
        return BandEnvelope.res(id: id, payload: {'song': songToDto(port.currentSong)});

      case 'playback.prev':
        if (port.playlist.isEmpty) {
          return BandEnvelope.err(id: id, code: BandError.empty, message: 'queue empty');
        }
        await port.playPrevious();
        return BandEnvelope.res(id: id, payload: {'song': songToDto(port.currentSong)});

      case 'playback.seek':
        final ms = (req.payload['positionMs'] as num?)?.toInt();
        if (ms == null) {
          return BandEnvelope.err(id: id, code: BandError.badReq, message: 'positionMs required');
        }
        await port.seek(ms);
        _emitProgress(force: true); // seek 立即补发
        return BandEnvelope.res(id: id, payload: {'positionMs': ms});

      case 'playback.setMode':
        final mode = req.payload['mode'] as String?;
        if (mode == null || !const ['loop', 'single', 'shuffle'].contains(mode)) {
          return BandEnvelope.err(id: id, code: BandError.badReq, message: 'invalid mode');
        }
        await port.setMode(mode);
        return BandEnvelope.res(id: id, payload: {'mode': mode});

      case 'playback.setVolume':
        // 上游原版无独立音量控制（Phase 2）
        return BandEnvelope.err(
          id: id,
          code: BandError.unsupported,
          message: 'volume not supported',
          missing: BandCaps.volume,
        );

      case 'queue.play':
        final index = (req.payload['index'] as num?)?.toInt();
        if (index == null) {
          return BandEnvelope.err(id: id, code: BandError.badReq, message: 'index required');
        }
        if (index < 0 || index >= port.playlist.length) {
          return BandEnvelope.err(id: id, code: BandError.notFound, message: 'index out of range');
        }
        await port.playAtIndex(index);
        return BandEnvelope.res(id: id, payload: {'song': songToDto(port.currentSong)});

      case 'queue.clear':
        await port.clearPlaylist();
        return BandEnvelope.res(id: id, payload: {'ok': true});

      case 'search.song':
        final keyword = (req.payload['keyword'] as String?)?.trim() ?? '';
        final limit = (req.payload['limit'] as num?)?.toInt() ?? 10;
        if (keyword.isEmpty) {
          return BandEnvelope.err(id: id, code: BandError.badReq, message: 'keyword required');
        }
        final results = await port.search(keyword, limit);
        return _payloadOrChunk(id: id, kind: 'search_result', data: {
          'query': keyword,
          'total': results.length,
          'results': results.map(songToDto).toList(),
        });

      case 'search.suggest':
        final keyword = (req.payload['keyword'] as String?)?.trim() ?? '';
        final limit = (req.payload['limit'] as num?)?.toInt() ?? 6;
        if (keyword.isEmpty) {
          return BandEnvelope.err(id: id, code: BandError.badReq, message: 'keyword required');
        }
        final items = await port.searchSuggest(keyword);
        return BandEnvelope.res(id: id, payload: {'items': items.take(limit).toList()});

      case 'search.hot':
        final items = await port.hotSearch();
        return BandEnvelope.res(id: id, payload: {'items': items});

      case 'lyric.window':
        return _lyricWindow(req);

      case 'cover.get':
        return _cover(req);

      case 'xfer.nack':
        return _handleNack(req);

      default:
        return BandEnvelope.err(
          id: id,
          code: BandError.unsupported,
          message: 'unknown method: $method',
        );
    }
  }

  /// `lyric.window`：返回当前行附近窗口 ≤ before+after+1 行。
  BandEnvelope _lyricWindow(BandEnvelope req) {
    final id = req.id;
    final songId = req.payload['songId'] as String? ?? port.currentSong?.id ?? '';
    final lines = port.lyrics;
    if (lines.isEmpty) {
      return BandEnvelope.res(id: id, payload: {'songId': songId, 'start': 0, 'lines': []});
    }
    final indexRaw = (req.payload['index'] as num?)?.toInt();
    final index = (indexRaw == null || indexRaw < 0)
        ? port.currentLyricIndex.clamp(0, lines.length - 1)
        : indexRaw.clamp(0, lines.length - 1);
    final before = (req.payload['before'] as num?)?.toInt() ?? 3;
    final after = (req.payload['after'] as num?)?.toInt() ?? 8;
    final start = (index - before).clamp(0, lines.length - 1);
    final end = (index + after).clamp(0, lines.length - 1);
    final slice = lines.sublist(start, end + 1).map((l) {
      return {'t': l.timestamp.inMilliseconds, 'text': l.text};
    }).toList();
    final data = <String, dynamic>{
      'songId': songId,
      'start': start,
      'lines': slice,
    };
    return _payloadOrChunk(id: id, kind: 'lyric_window', data: data);
  }

  /// `cover.get`：返回当前（或指定）歌曲封面二进制分片。
  BandEnvelope _cover(BandEnvelope req) {
    final id = req.id;
    final songId = req.payload['songId'] as String? ?? port.currentSong?.id;
    final url = port.currentSong?.coverUrl;
    if (url == null || url.isEmpty) {
      return BandEnvelope.err(id: id, code: BandError.notFound, message: 'no cover');
    }
    final bytes = port.coverBytes(url);
    if (bytes == null) {
      return BandEnvelope.err(id: id, code: BandError.notFound, message: 'cover not cached');
    }
    final frames = BandChunk.splitBytes(
      tid: _nextTid(),
      kind: 'cover',
      data: bytes,
      meta: {'songId': songId},
    );
    return _emitChunked(id: id, frames: frames);
  }

  /// `xfer.nack{tid,seq}`：重发指定分片。
  BandEnvelope _handleNack(BandEnvelope req) {
    final id = req.id;
    final tid = req.payload['tid'] as String?;
    final seq = (req.payload['seq'] as num?)?.toInt();
    final frames = tid == null ? null : _transfers[tid];
    if (frames == null) {
      return BandEnvelope.res(id: id, payload: {'ok': true});
    }
    // frames[0] = header；其后为 data 帧，第 seq 号 data 位于 index seq+1
    final target = (seq != null && seq >= 0 && seq + 1 < frames.length)
        ? frames[seq + 1]
        : null;
    if (target != null) {
      pushEvent('xfer.chunk', target);
    }
    return BandEnvelope.res(id: id, payload: {'ok': true});
  }

  /// 小载荷内联返回；超阈值则发分片并返回 `__chunked` 摘要。
  BandEnvelope _payloadOrChunk({
    required String? id,
    required String kind,
    required Map<String, dynamic> data,
  }) {
    final json = jsonEncode(data);
    if (!BandChunk.exceedsInline(json)) {
      return BandEnvelope.res(id: id, payload: data);
    }
    final frames = BandChunk.splitText(tid: _nextTid(), kind: kind, text: json);
    return _emitChunked(id: id, frames: frames);
  }

  BandEnvelope _emitChunked({
    required String? id,
    required List<Map<String, dynamic>> frames,
  }) {
    final header = frames.first;
    final tid = header['tid'] as String;
    _transfers[tid] = frames;
    for (final f in frames) {
      pushEvent('xfer.chunk', f);
    }
    return BandEnvelope.res(id: id, payload: {
      '__chunked': true,
      'tid': tid,
      'total': header['total'],
      'bytes': header['bytes'],
      'crc32': header['crc32'],
    });
  }

  String _nextTid() => 't-${(_chunkSeq++).toString().padLeft(4, '0')}';

  /// 全量状态快照（`state.get` 出参）。
  Map<String, dynamic> snapshot() {
    final lines = port.lyrics;
    return {
      'state': playerStateToWire(port.state),
      'playing': port.isPlaying,
      'song': songToDto(port.currentSong),
      'positionMs': port.position.inMilliseconds,
      'durationMs': port.duration.inMilliseconds,
      'mode': playModeToWire(port.playMode),
      // 上游原版无独立音量控制，恒为 0；volume 能力已声明缺失
      'volume': 0,
      'queue': {
        'count': port.playlist.length,
        'currentIndex': port.currentIndex,
      },
      'lyric': {'has': lines.isNotEmpty, 'count': lines.length},
      'ts': _clock(),
    };
  }
}

/// 歌曲 → 协议 `song` DTO。
///
/// 字段差异（上游原版 vs 概念版）：上游 `SongModel` **没有** `source` 字段（仅网易云音源），
/// 也无 `hash/albumId/localUri`。故 `source` 恒为 `"netease"`，`durationMs` 直接取
/// `duration`（上游单位为毫秒）。
Map<String, dynamic> songToDto(SongModel? song) {
  if (song == null) return <String, dynamic>{};
  return <String, dynamic>{
    'id': song.id,
    'name': song.name,
    'artist': song.artist,
    'album': song.album,
    'durationMs': song.duration ?? 0,
    'source': 'netease',
    'hasCover': song.coverUrl != null && song.coverUrl!.isNotEmpty,
  };
}
