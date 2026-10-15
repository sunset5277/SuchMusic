import 'dart:typed_data';

import '../../models/song_model.dart';
import '../audio_player_service.dart';
import '../music_api_service.dart';

/// 播放模式 `PlayMode` ↔ 协议字符串 的一一映射（冻结）。
String playModeToWire(PlayMode mode) {
  switch (mode) {
    case PlayMode.loop:
      return 'loop';
    case PlayMode.single:
      return 'single';
    case PlayMode.shuffle:
      return 'shuffle';
  }
}

/// 协议字符串 → `PlayMode`，未知值回退 `loop`。
PlayMode wireToPlayMode(String? wire) {
  switch (wire) {
    case 'single':
      return PlayMode.single;
    case 'shuffle':
      return PlayMode.shuffle;
    case 'loop':
    default:
      return PlayMode.loop;
  }
}

/// 玩家状态 → 协议字符串（`{idle,loading,playing,paused,error}`）。
String playerStateToWire(PlayerState state) => state.name;

/// 手环命令落地所需的「播放端抽象」。
///
/// 设计文档 §4.4 要求：跨端统一抽象 `BandPlayerPort`，概念版与上游原版各提供一份实现，
/// [BandRouter] 只依赖本接口 → 同一协议、两种后端。上游原版实现见
/// [AudioPlayerServiceBandPort]。
abstract class BandPlayerPort {
  PlayerState get state;
  SongModel? get currentSong;
  bool get isPlaying;
  Duration get position;
  Duration get duration;
  PlayMode get playMode;
  List<SongModel> get playlist;
  int get currentIndex;
  List<LyricLine> get lyrics;
  int get currentLyricIndex;

  Future<void> resume();
  Future<void> pause();
  Future<void> togglePlayPause();
  Future<void> playNext();
  Future<void> playPrevious();
  Future<void> seek(int positionMs);

  /// 直接设置播放模式（对应协议 `playback.setMode`）。
  Future<void> setMode(String wireMode);

  Future<void> playAtIndex(int index);
  Future<void> clearPlaylist();

  Future<List<SongModel>> search(String keyword, int limit);
  Future<List<String>> searchSuggest(String keyword);
  Future<List<String>> hotSearch();

  /// 已缓存的封面字节（可能为 null）。
  Uint8List? coverBytes(String url);

  Stream<PlayerState> get onStateChanged;
  Stream<SongModel?> get onCurrentSongChanged;
  Stream<Duration> get onPositionChanged;
  Stream<Duration> get onDurationChanged;
  Stream<PlayMode> get onPlayModeChanged;
  Stream<List<SongModel>> get onPlaylistChanged;
  Stream<String> get onLyricChanged;
  Stream<List<LyricLine>> get onLyricsChanged;
}

/// 上游原版适配器：把 [AudioPlayerService] / [MusicApiService] 的真实接口
/// 适配到 [BandPlayerPort]。
///
/// 关键映射（上游实际接口，非概念版）：
/// - 播控：`resume / pause / togglePlayPause / playNext / playPrevious / seek /
///   playAtIndex / clearPlaylist`（同名直接转发）。
/// - 播放模式：上游仅有循环式 `togglePlayMode()`，缺少「直接设定」的方法；
///   本 PR 为 `AudioPlayerService` **新增** `setPlayMode(PlayMode)`（最小改动）。
/// - 搜索：上游无 `SourceManager`/`hotSearch`，而是
///   `MusicApiService().search / searchSuggest / getHotSearchKeys`。
/// - 歌词：读 `AudioPlayerService().lyrics` + `currentLyricIndex`。
/// - 单例：上游 `AudioPlayerService()` 为工厂单例，直接复用（与 handler 同源）。
class AudioPlayerServiceBandPort implements BandPlayerPort {
  final AudioPlayerService _service = AudioPlayerService();
  final MusicApiService _api = MusicApiService();

  @override
  PlayerState get state => _service.state;

  @override
  SongModel? get currentSong => _service.currentSong;

  @override
  bool get isPlaying => _service.isPlaying;

  @override
  Duration get position => _service.position;

  @override
  Duration get duration => _service.duration;

  @override
  PlayMode get playMode => _service.playMode;

  @override
  List<SongModel> get playlist => _service.playlist;

  @override
  int get currentIndex => _service.currentIndex;

  @override
  List<LyricLine> get lyrics => _service.lyrics;

  @override
  int get currentLyricIndex => _service.currentLyricIndex;

  @override
  Future<void> resume() => _service.resume();

  @override
  Future<void> pause() => _service.pause();

  @override
  Future<void> togglePlayPause() => _service.togglePlayPause();

  @override
  Future<void> playNext() => _service.playNext();

  @override
  Future<void> playPrevious() => _service.playPrevious();

  @override
  Future<void> seek(int positionMs) =>
      _service.seek(Duration(milliseconds: positionMs));

  @override
  Future<void> setMode(String wireMode) async {
    _service.setPlayMode(wireToPlayMode(wireMode));
  }

  @override
  Future<void> playAtIndex(int index) => _service.playAtIndex(index);

  @override
  Future<void> clearPlaylist() => _service.clearPlaylist();

  @override
  Future<List<SongModel>> search(String keyword, int limit) =>
      _api.search(keyword, limit: limit);

  @override
  Future<List<String>> searchSuggest(String keyword) =>
      _api.searchSuggest(keyword);

  @override
  Future<List<String>> hotSearch() => _api.getHotSearchKeys();

  @override
  Uint8List? coverBytes(String url) => AudioPlayerService.cachedCover(url);

  @override
  Stream<PlayerState> get onStateChanged => _service.onStateChanged;

  @override
  Stream<SongModel?> get onCurrentSongChanged => _service.onCurrentSongChanged;

  @override
  Stream<Duration> get onPositionChanged => _service.onPositionChanged;

  @override
  Stream<Duration> get onDurationChanged => _service.onDurationChanged;

  @override
  Stream<PlayMode> get onPlayModeChanged => _service.onPlayModeChanged;

  @override
  Stream<List<SongModel>> get onPlaylistChanged => _service.onPlaylistChanged;

  @override
  Stream<String> get onLyricChanged => _service.onLyricChanged;

  @override
  Stream<List<LyricLine>> get onLyricsChanged => _service.onLyricsChanged;
}
