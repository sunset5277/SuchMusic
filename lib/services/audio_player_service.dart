import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song_model.dart';
import 'music_api_service.dart';

enum PlayerState { idle, loading, playing, paused, error }

enum PlayMode { loop, single, shuffle }

class LyricLine {
  final Duration timestamp;
  final String text;

  const LyricLine({required this.timestamp, required this.text});
}

class AudioPlayerService {
  static final AudioPlayerService _instance = AudioPlayerService._internal();
  factory AudioPlayerService() => _instance;

  static final Map<String, Uint8List> _coverCache = {};
  static final Map<String, String> _coverFileCache = {};
  static Uint8List? _lastCoverBytes;
  static final Dio _coverDio = Dio();

  static Uint8List? cachedCover(String url) => _coverCache[url];
  static Uint8List? get lastCoverBytes => _lastCoverBytes;

  static String? coverFileUri(String url) => _coverFileCache[url];

  static Future<void> preFetchCover(String url) async {
    if (_coverCache.containsKey(url)) return;
    try {
      // 压缩到 500px 加载（原图可达数 MB），缓存键仍用原始 URL
      final response = await _coverDio.get(
        '${url.split('?').first}?param=500y500',
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'Referer': 'https://music.163.com',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
          },
        ),
      );
      if (response.statusCode == 200 && response.data != null) {
        final bytes = response.data as Uint8List;
        _coverCache[url] = bytes;
        _lastCoverBytes = bytes;

        // 保存到本地文件，用于通知栏封面显示
        try {
          final dir = await getApplicationDocumentsDirectory();
          final coverDir = Directory('${dir.path}/covers');
          if (!await coverDir.exists()) {
            await coverDir.create(recursive: true);
          }
          final fileName = Uri.parse(url).pathSegments.last;
          final file = File('${coverDir.path}/$fileName');
          if (!await file.exists()) {
            await file.writeAsBytes(bytes);
          }
          _coverFileCache[url] = file.path;
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 清理封面缓存：内存映射 + 通知栏封面文件 + Flutter 图片缓存。
  /// 不清理登录数据（user_cache.json）。
  /// 返回 (清理条目数, 释放字节数)。
  static Future<(int, int)> clearCoverCache() async {
    var count = _coverCache.length;
    var bytes = 0;
    for (final data in _coverCache.values) {
      bytes += data.length;
    }
    _coverCache.clear();
    _coverFileCache.clear();

    // 通知栏封面文件（磁盘）
    try {
      final dir = await getApplicationDocumentsDirectory();
      final coverDir = Directory('${dir.path}/covers');
      if (await coverDir.exists()) {
        await for (final entity in coverDir.list()) {
          if (entity is File) {
            bytes += await entity.length();
            count += 1;
            await entity.delete();
          }
        }
      }
    } catch (_) {}

    // Flutter 图片缓存（Image 组件解码后的位图）
    bytes += PaintingBinding.instance.imageCache.currentSizeBytes;
    count += PaintingBinding.instance.imageCache.currentSize;
    PaintingBinding.instance.imageCache.clear();

    return (count, bytes);
  }

  AudioPlayerService._internal() {
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        return;
      }
      if (state.processingState == ProcessingState.loading ||
          state.processingState == ProcessingState.buffering) {
        _updateState(PlayerState.loading);
      } else if (state.playing) {
        _updateState(PlayerState.playing);
      } else if (state.processingState == ProcessingState.ready) {
        _updateState(PlayerState.paused);
      } else {
        _updateState(PlayerState.idle);
      }
    });

    _player.processingStateStream.listen((state) async {
      if (state == ProcessingState.completed) {
        if (_isFmMode) {
          await _fetchAndPlayFm();
          return;
        }
        if (_usingConcatenatingSource) {
          if (_playMode == PlayMode.loop) {
            _currentIndex = 0;
            _currentSong = _playlist.isNotEmpty ? _playlist[0] : null;
            _currentSongController.add(_currentSong);
            await _player.seek(Duration.zero);
            await _player.play();
          } else if (_playMode == PlayMode.single && _currentSong != null) {
            await _player.seek(Duration.zero);
            await _player.play();
          } else {
            _updateState(PlayerState.idle);
          }
          return;
        }
        if (_playMode == PlayMode.single && _currentSong != null) {
          await play(_currentSong!);
        } else if (_playlist.isNotEmpty && _currentIndex >= 0) {
          _playHistory.add(_currentIndex);
          if (_playMode == PlayMode.shuffle) {
            _currentIndex = _nextShuffleIndex();
          } else {
            _currentIndex = (_currentIndex + 1) % _playlist.length;
          }
          _savePlaylist();
          await play(_playlist[_currentIndex]);
        } else {
          _updateState(PlayerState.idle);
        }
      }
    });

    _player.currentIndexStream.listen((index) {
      if (index != null && index >= 0 && index < _playlist.length) {
        _currentIndex = index;
        _currentSong = _playlist[index];
        _currentSongController.add(_currentSong);
        if (_currentSong!.coverUrl != null &&
            _currentSong!.coverUrl!.isNotEmpty) {
          preFetchCover(_currentSong!.coverUrl!);
        }
        _fetchLyrics(_currentSong!.id);
        _savePlaylist();
      }
    });

    _player.positionStream.listen((pos) {
      _position = pos;
      _positionController.add(pos);
      _updateCurrentLyric(pos);
    });

    _player.durationStream.listen((dur) {
      _duration = dur ?? Duration.zero;
      _durationController.add(dur ?? Duration.zero);
    });
  }

  static const _playlistFileName = 'playlist.json';

  Future<void> init() async {
    // 启动时应用"与其他应用同时播放"设置
    try {
      final prefs = await SharedPreferences.getInstance();
      await applyMixWithOthers(prefs.getBool('allowMixWithOthers') ?? false);
    } catch (_) {}
    await _loadPlaylist();
  }

  /// 应用"与其他应用同时播放"设置
  /// true: 混音模式（iOS mixWithOthers；Android 用 mayDuck 抢占，其他应用只降音量不停止）
  /// false: 默认独占音频焦点（其他应用会暂停）
  static Future<void> applyMixWithOthers(bool allow) async {
    try {
      final session = await AudioSession.instance;
      if (allow) {
        await session.configure(const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playback,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.mixWithOthers,
          androidAudioFocusGainType:
              AndroidAudioFocusGainType.gainTransientMayDuck,
        ));
      } else {
        await session.configure(const AudioSessionConfiguration.music());
      }
    } catch (_) {}
  }

  Future<void> _loadPlaylist() async {
    try {
      final file = await _getPlaylistFile();
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString());
      if (json is Map<String, dynamic>) {
        final list = json['playlist'] as List<dynamic>? ?? [];
        _playlist = list
            .map((e) => SongModel.fromStorage(e as Map<String, dynamic>))
            .toList();
        _currentIndex = json['currentIndex'] as int? ?? -1;
        if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
          _currentSong = _playlist[_currentIndex];
          _currentSongController.add(_currentSong);
        }
        _playlistController.add(_playlist);
      }
    } catch (_) {}
  }

  Future<void> _savePlaylist() async {
    try {
      final file = await _getPlaylistFile();
      final data = {
        'playlist': _playlist.map((s) => s.toJson()).toList(),
        'currentIndex': _currentIndex,
      };
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  Future<File> _getPlaylistFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_playlistFileName');
  }

  final AudioPlayer _player = AudioPlayer();

  PlayerState _state = PlayerState.idle;
  SongModel? _currentSong;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  List<LyricLine> _lyrics = [];
  String _currentLyric = '';

  List<SongModel> _playlist = [];
  int _currentIndex = -1;
  PlayMode _playMode = PlayMode.loop;
  final Random _random = Random();
  List<int> _shuffleQueue = [];
  int _shuffleQueuePos = 0;
  final List<int> _playHistory = [];

  PlayerState get state => _state;
  SongModel? get currentSong => _currentSong;
  bool get isPlaying => _state == PlayerState.playing;
  Duration get position => _position;
  Duration get duration => _duration;
  String get currentLyric => _currentLyric;
  List<LyricLine> get lyrics => List.unmodifiable(_lyrics);
  int get currentLyricIndex {
    if (_lyrics.isEmpty) return -1;
    for (int i = _lyrics.length - 1; i >= 0; i--) {
      if (_position >= _lyrics[i].timestamp) return i;
    }
    return -1;
  }
  List<SongModel> get playlist => List.unmodifiable(_playlist);
  int get currentIndex => _currentIndex;
  PlayMode get playMode => _playMode;

  bool _isFmMode = false;
  bool get isFmMode => _isFmMode;

  bool _usingConcatenatingSource = false;

  final StreamController<bool> _fmModeController =
      StreamController<bool>.broadcast();
  Stream<bool> get onFmModeChanged => _fmModeController.stream;

  final StreamController<PlayerState> _stateController =
      StreamController<PlayerState>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationController =
      StreamController<Duration>.broadcast();
  final StreamController<String> _lyricController =
      StreamController<String>.broadcast();
  final StreamController<List<LyricLine>> _lyricsController =
      StreamController<List<LyricLine>>.broadcast();
  final StreamController<List<SongModel>> _playlistController =
      StreamController<List<SongModel>>.broadcast();
  final StreamController<SongModel?> _currentSongController =
      StreamController<SongModel?>.broadcast();
  final StreamController<PlayMode> _playModeController =
      StreamController<PlayMode>.broadcast();

  Stream<PlayerState> get onStateChanged => _stateController.stream;
  Stream<Duration> get onPositionChanged => _positionController.stream;
  Stream<Duration> get onDurationChanged => _durationController.stream;
  Stream<String> get onLyricChanged => _lyricController.stream;
  Stream<List<LyricLine>> get onLyricsChanged => _lyricsController.stream;
  Stream<List<SongModel>> get onPlaylistChanged => _playlistController.stream;
  Stream<SongModel?> get onCurrentSongChanged => _currentSongController.stream;
  Stream<PlayMode> get onPlayModeChanged => _playModeController.stream;

  void _updateState(PlayerState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
    }
  }

  List<LyricLine> _parseLrc(String lrcText) {
    final lines = lrcText.split('\n');
    final result = <LyricLine>[];
    final regExp = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');

    for (final line in lines) {
      final match = regExp.firstMatch(line.trim());
      if (match != null) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        var millisStr = match.group(3)!;
        if (millisStr.length == 2) millisStr += '0';
        final millis = int.parse(millisStr);
        final text = match.group(4)?.trim() ?? '';
        if (text.isNotEmpty) {
          result.add(LyricLine(
            timestamp: Duration(
                minutes: minutes, seconds: seconds, milliseconds: millis),
            text: text,
          ));
        }
      }
    }

    result.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return result;
  }

  void _updateCurrentLyric(Duration position) {
    if (_lyrics.isEmpty) return;

    String newLyric = '';
    for (int i = _lyrics.length - 1; i >= 0; i--) {
      if (position >= _lyrics[i].timestamp) {
        newLyric = _lyrics[i].text;
        break;
      }
    }

    if (newLyric != _currentLyric) {
      _currentLyric = newLyric;
      _lyricController.add(_currentLyric);
    }
  }

  Future<void> _fetchLyrics(String songId) async {
    _lyrics = [];
    _currentLyric = '';
    _lyricController.add('');
    _lyricsController.add([]);

    final lrcText = await MusicApiService().getLyrics(songId);
    if (lrcText != null && lrcText.isNotEmpty) {
      _lyrics = _parseLrc(lrcText);
      _lyricsController.add(List.unmodifiable(_lyrics));
      _updateCurrentLyric(_position);
    }
  }

  Future<bool> play(SongModel song, {bool exitFm = true}) async {
    _usingConcatenatingSource = false;
    try {
      if (exitFm && _isFmMode) {
        await exitFmMode();
      }
      _updateState(PlayerState.loading);
      _currentSong = song;
      _currentSongController.add(_currentSong);

      if (song.coverUrl != null && song.coverUrl!.isNotEmpty) {
        preFetchCover(song.coverUrl!);
      }

      await _player.stop();

      _fetchLyrics(song.id);

      final url = await MusicApiService().getSongUrl(song.id);
      if (url == null) {
        _updateState(PlayerState.error);
        return false;
      }

      await _player
          .setAudioSource(
            AudioSource.uri(Uri.parse(url)),
          )
          .timeout(const Duration(seconds: 15));

      await _player.play();

      if (song.coverUrl == null || song.coverUrl!.isEmpty) {
        final detail = await MusicApiService().getSongDetail(song.id);
        if (detail != null && detail.coverUrl != null) {
          _currentSong = detail;
          _currentSongController.add(_currentSong);
          preFetchCover(detail.coverUrl!);
          if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
            _playlist[_currentIndex] = detail;
            _playlistController.add(_playlist);
            _savePlaylist();
          }
        }
      }

      return true;
    } on TimeoutException {
      _updateState(PlayerState.error);
      return false;
    } catch (e) {
      _updateState(PlayerState.error);
      return false;
    }
  }

  Future<void> pause() async {
    await _player.pause();
  }

  Future<void> resume() async {
    await _player.play();
  }

  Future<void> togglePlayPause() async {
    if (_state == PlayerState.playing) {
      await pause();
    } else if (_state == PlayerState.paused) {
      await resume();
    } else if (_currentSong != null) {
      await play(_currentSong!);
    }
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  Future<void> stop() async {
    await _player.stop();
    _currentSong = null;
    _currentSongController.add(null);
    _lyrics = [];
    _currentLyric = '';
    _lyricController.add('');
    _lyricsController.add([]);
    _updateState(PlayerState.idle);
  }

  Future<bool> playAndAdd(SongModel song) async {
    if (_isFmMode) {
      await exitFmMode();
    }
    final existingIndex = _playlist.indexWhere((s) => s.id == song.id);
    if (existingIndex >= 0) {
      if (_currentIndex >= 0 && existingIndex != _currentIndex) {
        _playHistory.add(_currentIndex);
      }
      _currentIndex = existingIndex;
    } else {
      if (_currentIndex >= 0) {
        _playHistory.add(_currentIndex);
      }
      _playlist.insert(0, song);
      _currentIndex = 0;
      _playlistController.add(_playlist);
    }
    _savePlaylist();
    return play(song);
  }

  void addToPlaylist(SongModel song) {
    if (_playlist.indexWhere((s) => s.id == song.id) >= 0) return;
    _playlist.insert(0, song);
    _playlistController.add(_playlist);
    _savePlaylist();
  }

  Future<void> playSongs(List<SongModel> songs) async {
    if (songs.isEmpty) return;
    _usingConcatenatingSource = true;
    if (_isFmMode) {
      await exitFmMode();
    }

    _playlist.clear();
    _playlist.addAll(songs);
    _currentIndex = 0;
    _playlistController.add(_playlist);

    _updateState(PlayerState.loading);
    _currentSong = songs[0];
    _currentSongController.add(_currentSong);

    if (songs[0].coverUrl != null && songs[0].coverUrl!.isNotEmpty) {
      preFetchCover(songs[0].coverUrl!);
    }

    await _player.stop();

    _fetchLyrics(songs[0].id);

    final sources = <AudioSource>[];
    for (final song in songs) {
      final url = await MusicApiService().getSongUrl(song.id);
      if (url != null) {
        sources.add(AudioSource.uri(Uri.parse(url)));
      }
    }

    if (sources.isEmpty) {
      _updateState(PlayerState.error);
      return;
    }

    await _player
        .setAudioSource(ConcatenatingAudioSource(children: sources))
        .timeout(const Duration(seconds: 15));

    await _player.play();
    _savePlaylist();
  }

  void togglePlayMode() {
    switch (_playMode) {
      case PlayMode.loop:
        _playMode = PlayMode.single;
        break;
      case PlayMode.single:
        _playMode = PlayMode.shuffle;
        _generateShuffleQueue();
        break;
      case PlayMode.shuffle:
        _playMode = PlayMode.loop;
        break;
    }
    _playModeController.add(_playMode);
  }

  /// 直接设置播放模式（与循环式 [togglePlayMode] 相对）。
  /// 供手环「播放模式页」使用：由外部指定目标模式，避免多次循环触发。
  /// 副作用与 [togglePlayMode] 保持一致（切到乱序时重置乱序队列）。
  void setPlayMode(PlayMode mode) {
    if (_playMode == mode) return;
    _playMode = mode;
    if (_playMode == PlayMode.shuffle) {
      _generateShuffleQueue();
    }
    _playModeController.add(_playMode);
  }

  void _generateShuffleQueue() {
    if (_playlist.isEmpty) return;
    _shuffleQueue = List.generate(_playlist.length, (i) => i);
    for (int i = _shuffleQueue.length - 1; i > 0; i--) {
      final j = _random.nextInt(i + 1);
      final tmp = _shuffleQueue[i];
      _shuffleQueue[i] = _shuffleQueue[j];
      _shuffleQueue[j] = tmp;
    }
    final currentInQueue = _shuffleQueue.indexOf(_currentIndex);
    if (currentInQueue >= 0) {
      _shuffleQueue.removeAt(currentInQueue);
      _shuffleQueue.insert(0, _currentIndex);
    }
    _shuffleQueuePos = 0;
  }

  int _nextShuffleIndex() {
    if (_shuffleQueue.isEmpty || _playlist.isEmpty) {
      _generateShuffleQueue();
    }
    _shuffleQueuePos++;
    if (_shuffleQueuePos >= _shuffleQueue.length) {
      _generateShuffleQueue();
      _shuffleQueuePos = 1;
    }
    return _shuffleQueue[_shuffleQueuePos];
  }

  Future<void> playNext() async {
    if (_isFmMode) {
      await _fetchAndPlayFm();
      return;
    }
    if (_playlist.isEmpty || _currentIndex < 0) return;

    if (_usingConcatenatingSource && _playMode != PlayMode.shuffle) {
      await _player.seekToNext();
      return;
    }

    _playHistory.add(_currentIndex);
    if (_playMode == PlayMode.shuffle) {
      _currentIndex = _nextShuffleIndex();
    } else {
      _currentIndex = (_currentIndex + 1) % _playlist.length;
    }
    _savePlaylist();
    await play(_playlist[_currentIndex]);
  }

  Future<void> playPrevious() async {
    if (_isFmMode) return;
    if (_playlist.isEmpty || _currentIndex < 0) return;

    if (_usingConcatenatingSource && _playMode != PlayMode.shuffle) {
      await _player.seekToPrevious();
      return;
    }

    if (_playHistory.isNotEmpty) {
      _currentIndex = _playHistory.removeLast();
    } else if (_playMode == PlayMode.shuffle) {
      _playHistory.add(_currentIndex);
      _currentIndex = _nextShuffleIndex();
    } else {
      _currentIndex =
          (_currentIndex - 1 + _playlist.length) % _playlist.length;
    }
    _savePlaylist();
    await play(_playlist[_currentIndex]);
  }

  Future<void> playAtIndex(int index) async {
    if (_playlist.isEmpty || index < 0 || index >= _playlist.length) return;

    if (_usingConcatenatingSource) {
      await _player.seek(Duration.zero, index: index);
      return;
    }

    if (_currentIndex >= 0 && index != _currentIndex) {
      _playHistory.add(_currentIndex);
    }
    _currentIndex = index;
    _savePlaylist();
    await play(_playlist[_currentIndex]);
  }

  Future<void> removeFromPlaylist(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    _playlist.removeAt(index);
    if (_currentIndex == index) {
      if (_playlist.isEmpty) {
        _currentIndex = -1;
        await stop();
      } else {
        _currentIndex = index.clamp(0, _playlist.length - 1);
        await play(_playlist[_currentIndex]);
      }
    } else if (_currentIndex > index) {
      _currentIndex--;
    }
    _playlistController.add(_playlist);
    _savePlaylist();
  }

  Future<void> clearPlaylist() async {
    if (_playlist.isEmpty && !_isFmMode) return;
    _usingConcatenatingSource = false;
    if (_isFmMode) {
      _isFmMode = false;
      _fmModeController.add(false);
    }
    _playlist.clear();
    _currentIndex = -1;
    await stop();
    _playlistController.add(_playlist);
    _savePlaylist();
  }

  /// [startSong] 指定从某首歌开始 FM（如首页卡片封面歌），
  /// 为空时走默认逻辑重新拉取 FM 队列
  Future<void> enterFmMode({SongModel? startSong}) async {
    _isFmMode = true;
    _fmModeController.add(true);
    _playlist.clear();
    _currentIndex = -1;
    _playHistory.clear();
    _playlistController.add(_playlist);
    if (startSong != null) {
      _playlist.add(startSong);
      _currentIndex = 0;
      _playlistController.add(_playlist);
      await play(startSong, exitFm: false);
      return;
    }
    await _fetchAndPlayFm();
  }

  Future<void> _fetchAndPlayFm() async {
    final songs = await MusicApiService().userRadio();
    if (songs.isEmpty) {
      _updateState(PlayerState.error);
      return;
    }
    _playlist.clear();
    _playlist.add(songs.first);
    _currentIndex = 0;
    _playlistController.add(_playlist);
    await play(songs.first, exitFm: false);
  }

  Future<void> exitFmMode() async {
    _isFmMode = false;
    _fmModeController.add(false);
    _playlist.clear();
    _currentIndex = -1;
    _playHistory.clear();
    await stop();
    _playlistController.add(_playlist);
    _savePlaylist();
  }

  Future<void> fmTrash() async {
    final songId = _currentSong?.id;
    if (songId != null) {
      MusicApiService().userRadioTrash(songId);
    }
    await _fetchAndPlayFm();
  }

  void dispose() {
    _player.dispose();
    _stateController.close();
    _positionController.close();
    _durationController.close();
    _lyricController.close();
    _lyricsController.close();
    _playlistController.close();
    _currentSongController.close();
    _playModeController.close();
  }
}