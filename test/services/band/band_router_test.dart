import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/services/audio_player_service.dart';
import 'package:such_music/services/band/band_player_port.dart';
import 'package:such_music/services/band/band_protocol.dart';
import 'package:such_music/services/band/band_router.dart';

/// 用 mock 端口驱动 [BandRouter]，验证协议逻辑与「命令落地」的映射关系，
/// 不触碰真实播放服务。
class MockPort implements BandPlayerPort {
  @override
  PlayerState state = PlayerState.paused;
  @override
  SongModel? currentSong;
  @override
  bool isPlaying = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration duration = Duration.zero;
  @override
  PlayMode playMode = PlayMode.loop;
  @override
  List<SongModel> playlist = <SongModel>[];
  @override
  int currentIndex = -1;
  @override
  List<LyricLine> lyrics = <LyricLine>[];
  @override
  int currentLyricIndex = -1;

  int nextCalls = 0;
  int prevCalls = 0;
  int playAtCalls = 0;
  int resumeCalls = 0;
  int pauseCalls = 0;
  int toggleCalls = 0;
  int seekCalls = 0;
  int clearCalls = 0;
  final List<String> setModes = <String>[];

  List<SongModel> searchResult = <SongModel>[];
  List<String> hotResult = <String>[];
  List<String> suggestResult = <String>[];

  @override
  Future<void> resume() async => resumeCalls++;

  @override
  Future<void> pause() async => pauseCalls++;

  @override
  Future<void> togglePlayPause() async => toggleCalls++;

  @override
  Future<void> playNext() async {
    nextCalls++;
    if (playlist.isNotEmpty && currentIndex >= 0) {
      currentIndex = (currentIndex + 1) % playlist.length;
      currentSong = playlist[currentIndex];
    }
  }

  @override
  Future<void> playPrevious() async => prevCalls++;

  @override
  Future<void> seek(int positionMs) async {
    seekCalls++;
    position = Duration(milliseconds: positionMs);
  }

  @override
  Future<void> setMode(String wireMode) async {
    setModes.add(wireMode);
    playMode = wireToPlayMode(wireMode);
  }

  @override
  Future<void> playAtIndex(int index) async {
    playAtCalls++;
    currentIndex = index;
    if (index >= 0 && index < playlist.length) currentSong = playlist[index];
  }

  @override
  Future<void> clearPlaylist() async {
    clearCalls++;
    playlist = <SongModel>[];
    currentIndex = -1;
    currentSong = null;
  }

  @override
  Future<List<SongModel>> search(String keyword, int limit) async =>
      searchResult.take(limit).toList();

  @override
  Future<List<String>> searchSuggest(String keyword) async => suggestResult;

  @override
  Future<List<String>> hotSearch() async => hotResult;

  @override
  Uint8List? coverBytes(String url) => null;

  @override
  Stream<PlayerState> get onStateChanged => const Stream<PlayerState>.empty();

  @override
  Stream<SongModel?> get onCurrentSongChanged =>
      const Stream<SongModel?>.empty();

  @override
  Stream<Duration> get onPositionChanged => const Stream<Duration>.empty();

  @override
  Stream<Duration> get onDurationChanged => const Stream<Duration>.empty();

  @override
  Stream<PlayMode> get onPlayModeChanged => const Stream<PlayMode>.empty();

  @override
  Stream<List<SongModel>> get onPlaylistChanged =>
      const Stream<List<SongModel>>.empty();

  @override
  Stream<String> get onLyricChanged => const Stream<String>.empty();

  @override
  Stream<List<LyricLine>> get onLyricsChanged =>
      const Stream<List<LyricLine>>.empty();
}

SongModel _song(String id, {String? name}) => SongModel(
      id: id,
      name: name ?? 'song-$id',
      artist: 'artist',
      album: 'album',
      duration: 180000,
    );

void main() {
  late MockPort port;
  late List<BandEnvelope> sent;
  late BandRouter router;

  setUp(() {
    port = MockPort();
    sent = <BandEnvelope>[];
    router = BandRouter(port: port, send: sent.add, clock: () => 1000);
  });

  BandEnvelope req(String id, String method, [Map<String, dynamic>? p]) =>
      BandEnvelope.req(id: id, method: method, payload: p);

  group('幂等去重（同一 req.id 只生效一次）', () {
    test('重复 playback.next 只切一次歌', () async {
      port.playlist = [_song('1'), _song('2'), _song('3')];
      port.currentIndex = 0;
      port.currentSong = port.playlist[0];

      final r1 = await router.handleRequest(req('p-aaaa-0001', 'playback.next'));
      final r2 = await router.handleRequest(req('p-aaaa-0001', 'playback.next'));
      final r3 = await router.handleRequest(req('p-aaaa-0001', 'playback.next'));

      expect(port.nextCalls, 1, reason: '重复 id 不应重复执行');
      expect(r1.encode(), r2.encode());
      expect(r2.encode(), r3.encode());

      // 不同 id 才再次生效
      await router.handleRequest(req('p-aaaa-0002', 'playback.next'));
      expect(port.nextCalls, 2);
    });

    test('LRU 容量 64：第 65 个不同 id 会挤出最旧的', () async {
      port.playlist = [_song('1'), _song('2')];
      port.currentIndex = 0;
      for (var i = 0; i < 65; i++) {
        await router.handleRequest(
          req('p-aaaa-${i.toString().padLeft(4, '0')}', 'playback.seek',
              {'positionMs': i}),
        );
      }
      // 第 0 个 id 已被挤出：再次发送会重新执行
      final before = port.seekCalls;
      await router.handleRequest(
          req('p-aaaa-0000', 'playback.seek', {'positionMs': 0}));
      expect(port.seekCalls, before + 1);
    });
  });

  group('播控映射', () {
    test('playback.setMode → port.setMode + PlayMode 映射', () async {
      final res = await router.handleRequest(
          req('p-bbbb-0001', 'playback.setMode', {'mode': 'single'}));
      expect(res.type, BandType.res);
      expect(res.payload['mode'], 'single');
      expect(port.setModes, ['single']);
      expect(port.playMode, PlayMode.single);
    });

    test('非法 mode → E_BADREQ 且不下发', () async {
      final res = await router.handleRequest(
          req('p-bbbb-0002', 'playback.setMode', {'mode': 'nonsense'}));
      expect(res.type, BandType.err);
      expect(res.payload['code'], 'E_BADREQ');
      expect(port.setModes, isEmpty);
    });

    test('playback.seek → seek(Duration)', () async {
      final res = await router.handleRequest(
          req('p-bbbb-0003', 'playback.seek', {'positionMs': 42000}));
      expect(res.payload['positionMs'], 42000);
      expect(port.seekCalls, 1);
      expect(port.position.inMilliseconds, 42000);
    });

    test('playback.play 无歌时走 toggle，有歌时走 resume', () async {
      await router.handleRequest(req('p-bbbb-0004', 'playback.play'));
      expect(port.toggleCalls, 1);
      expect(port.resumeCalls, 0);

      port.currentSong = _song('9');
      await router.handleRequest(req('p-bbbb-0005', 'playback.play'));
      expect(port.resumeCalls, 1);
    });

    test('queue.play 越界 → E_NOT_FOUND', () async {
      port.playlist = [_song('1')];
      final res = await router.handleRequest(
          req('p-bbbb-0006', 'queue.play', {'index': 5}));
      expect(res.type, BandType.err);
      expect(res.payload['code'], 'E_NOT_FOUND');
      expect(port.playAtCalls, 0);
    });

    test('playback.next 空队列 → E_EMPTY', () async {
      final res = await router.handleRequest(req('p-bbbb-0007', 'playback.next'));
      expect(res.payload['code'], 'E_EMPTY');
    });

    test('playback.setVolume → E_UNSUPPORTED（上游无音量能力）', () async {
      final res = await router.handleRequest(
          req('p-bbbb-0008', 'playback.setVolume', {'volume': 50}));
      expect(res.payload['code'], 'E_UNSUPPORTED');
      expect(res.payload['missing'], BandCaps.volume);
    });

    test('未知方法 → E_UNSUPPORTED', () async {
      final res = await router.handleRequest(req('p-bbbb-0009', 'no.such'));
      expect(res.payload['code'], 'E_UNSUPPORTED');
    });
  });

  group('能力门控', () {
    test('未协商到 search 能力 → search.song E_UNSUPPORTED', () async {
      router.setSession(version: 1, caps: [BandCaps.playback]);
      final res = await router.handleRequest(
          req('p-cccc-0001', 'search.song', {'keyword': 'x'}));
      expect(res.payload['code'], 'E_UNSUPPORTED');
      expect(res.payload['missing'], BandCaps.search);
    });

    test('协商到 search 能力 → 正常返回', () async {
      router.setSession(version: 1, caps: [BandCaps.search]);
      port.searchResult = [_song('1')];
      final res = await router.handleRequest(
          req('p-cccc-0002', 'search.song', {'keyword': 'x'}));
      expect(res.type, BandType.res);
      expect((res.payload['results'] as List).length, 1);
    });
  });

  group('状态快照', () {
    test('state.get 字段与冻结结构一致', () async {
      port.playlist = [_song('1'), _song('2')];
      port.currentIndex = 1;
      port.currentSong = port.playlist[1];
      port.playMode = PlayMode.shuffle;
      port.position = const Duration(seconds: 42);
      port.duration = const Duration(seconds: 269);
      port.lyrics = [const LyricLine(timestamp: Duration.zero, text: 'a')];

      final res = await router.handleRequest(req('p-dddd-0001', 'state.get'));
      final p = res.payload;
      expect(p['state'], 'paused');
      expect(p['mode'], 'shuffle');
      expect(p['positionMs'], 42000);
      expect(p['durationMs'], 269000);
      expect((p['song'] as Map)['source'], 'netease');
      expect((p['queue'] as Map)['count'], 2);
      expect((p['queue'] as Map)['currentIndex'], 1);
      expect((p['lyric'] as Map)['has'], isTrue);
      expect(p['ts'], 1000);
    });

    test('song DTO 的 durationMs 取毫秒', () async {
      port.currentSong = _song('42', name: '晴天');
      final res = await router.handleRequest(req('p-dddd-0002', 'song.info'));
      final song = res.payload['song'] as Map;
      expect(song['name'], '晴天');
      expect(song['durationMs'], 180000);
      expect(song['source'], 'netease');
    });
  });

  group('大载荷分片', () {
    test('小结果内联返回', () async {
      router.setSession(version: 1, caps: [BandCaps.search]);
      port.searchResult = [_song('1')];
      final res = await router.handleRequest(
          req('p-eeee-0001', 'search.song', {'keyword': 'x', 'limit': 10}));
      expect(res.payload.containsKey('__chunked'), isFalse);
      expect(res.payload['results'], isA<List>());
      expect(sent.where((e) => e.event == 'xfer.chunk'), isEmpty);
    });

    test('大结果走 xfer.chunk 分片并返回 __chunked 摘要', () async {
      // 需同时协商到 search 与 transfer 能力，分片事件才会下发
      router.setSession(
          version: 1, caps: [BandCaps.search, BandCaps.transfer]);
      port.searchResult = [
        for (var i = 0; i < 40; i++) _song('$i', name: '很长的歌曲名称-$i'),
      ];
      final res = await router.handleRequest(
          req('p-eeee-0002', 'search.song', {'keyword': 'x', 'limit': 40}));
      expect(res.payload['__chunked'], isTrue);
      expect(res.payload['tid'], isA<String>());
      expect(res.payload['crc32'], isA<String>());

      final chunks =
          sent.where((e) => e.event == 'xfer.chunk').toList();
      expect(chunks.length, greaterThan(1));
      expect(chunks.first.payload['phase'], 'header');
      expect(chunks.last.payload['phase'], 'end');
    });
  });

  group('歌词窗口', () {
    test('lyric.window 按 index/before/after 切片', () async {
      port.lyrics = [
        for (var i = 0; i < 20; i++)
          LyricLine(timestamp: Duration(milliseconds: i * 1000), text: 'line$i'),
      ];
      port.currentLyricIndex = 5;
      final res = await router.handleRequest(req('p-ffff-0001', 'lyric.window',
          {'songId': 's1', 'index': 5, 'before': 1, 'after': 2}));
      final lines = res.payload['lines'] as List;
      expect(res.payload['start'], 4);
      expect(lines.length, 4); // 4..7
      expect((lines.first as Map)['text'], 'line4');
    });
  });
}
