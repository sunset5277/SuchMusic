import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_player_service.dart';
import 'karaoke/karaoke_model.dart';

/// 桌面悬浮歌词：原生 TYPE_APPLICATION_OVERLAY 悬浮窗。
/// 有逐字数据时推送当前句 token 时间表 + 播放位置，由原生自绘 View
/// 按时钟外推逐字填充；无逐字数据时回退整句文本推送。
class FloatingLyricService {
  FloatingLyricService._internal();
  static final FloatingLyricService _instance = FloatingLyricService._internal();
  factory FloatingLyricService() => _instance;

  static const _channel =
      MethodChannel('com.such.music.such_music/floating_lyric');

  void _log(String msg) {
    if (kDebugMode) debugPrint('[悬浮歌词] $msg');
  }

  bool _running = false;
  // 会话代际：每次 start 自增，供 300ms 兜底重发定时器识别自己是否
  // 已被新一次 start 取代（防止旧定时器误发）
  int _sessionGen = 0;
  String _lastText = '';
  StreamSubscription<String>? _lyricSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<KaraokeSong?>? _karaokeSub;

  // 卡拉OK模式状态
  bool _karaokeActive = false; // 当前歌是否有逐字数据
  int _lastLineIndex = -2; // -2 = 未初始化
  Duration _lastPos = Duration.zero;

  /// 悬浮窗是否开启中
  bool get isRunning => _running;

  Future<bool> canDrawOverlays() async =>
      await _channel.invokeMethod('canDrawOverlays') == true;

  /// 跳转系统设置申请"显示在其他应用上层"权限，用户返回后需重新检查
  Future<void> requestOverlayPermission() =>
      _channel.invokeMethod('requestOverlayPermission');

  /// 开启悬浮歌词。歌词内容随 AudioPlayerService 流自动推送。
  Future<void> start() async {
    if (_running) return;
    _running = true;
    final gen = ++_sessionGen;
    _lastLineIndex = -2;
    _karaokeActive = false;
    _lastPos = AudioPlayerService().position;
    _lastText = AudioPlayerService().currentLyric;
    _log('start: text="$_lastText" karaoke=${AudioPlayerService().karaoke != null} '
        'pos=${_lastPos.inMilliseconds}ms playing=${AudioPlayerService().isPlaying}');
    await _channel.invokeMethod('showFloatingLyric', {'text': _lastText});
    // 同步锁定状态：服务每次重建后原生 locked 重置为 false，而 Dart
    // 单例的 locked 跨开关保留，需重新推送（dispatch 保证服务未就绪时暂存回放）
    await _channel.invokeMethod('setFloatingLyricLocked', {'locked': locked});
    // 同步对齐方式（同理：服务重建后原生重置；与原生存档一致时 setAlign 内部 no-op）
    await loadAlign();
    await _channel.invokeMethod('setFloatingLyricAlign', {'align': align});

    final audio = AudioPlayerService();
    _lyricSub?.cancel();
    _lyricSub = audio.onLyricChanged.listen(_onLyric);
    _posSub?.cancel();
    _posSub = audio.onPositionChanged.listen(_onPosition);
    _karaokeSub?.cancel();
    _karaokeSub = audio.onKaraokeChanged.listen(_onKaraokeChanged);
    // 当前已有逐字数据的话立即进入卡拉OK模式
    _onKaraokeChanged(audio.karaoke);

    // 注意：这里不监听原生的 onFloatingLyricClosed。悬浮窗已无 ✕ 按钮，
    // 唯一关闭入口是 Dart 的 stop()（状态本就已同步）。若监听 stopService
    // 的异步 onDestroy，上一次开关遗留的迟到通知会被本次 start 安装的
    // 新 handler 接住并误判为"当前会话被关闭"（gen 校验对被替换后的
    // handler 无效），导致 _running 错误置 false → 图标重置 + 推送中断。
    // 系统杀死服务属罕见情况：图标可能与实际短暂不一致，再点一次自愈。

    // 兜底：原生服务创建是异步的，若首帧推送在其就绪前到达会丢失，
    // 延迟强制重发一次当前行/文本，确保悬浮窗不卡在初始一句
    Future.delayed(const Duration(milliseconds: 300), () {
      if (!_running || gen != _sessionGen) return;
      _log('兜底重发: karaokeActive=$_karaokeActive pos=${_lastPos.inMilliseconds}ms');
      _lastLineIndex = -2;
      if (_karaokeActive) {
        _syncLine(_lastPos);
      } else {
        _lastText = '';
        _pushText(AudioPlayerService().currentLyric);
      }
    });
  }

  /// 关闭悬浮歌词
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _log('stop');
    await _teardownSubs();
    _channel.setMethodCallHandler(null);
    await _channel.invokeMethod('hideFloatingLyric');
  }

  Future<void> _teardownSubs() async {
    await _lyricSub?.cancel();
    _lyricSub = null;
    await _posSub?.cancel();
    _posSub = null;
    await _karaokeSub?.cancel();
    _karaokeSub = null;
  }

  /// 运行状态变化回调（预留：悬浮窗关闭按钮已移除，目前无触发方）
  final _closedListeners = <void Function()>[];
  void addClosedListener(void Function() cb) => _closedListeners.add(cb);
  void removeClosedListener(void Function() cb) => _closedListeners.remove(cb);

  /// 歌词锁定（锁定后悬浮窗触摸穿透、不可拖动/点击）
  bool locked = false;
  Future<void> setLocked(bool value) async {
    locked = value;
    if (_running) {
      await _channel.invokeMethod('setFloatingLyricLocked', {'locked': value});
    }
  }

  // ------------------------------------------------------------- 对齐方式

  /// 对齐方式：left / center / right（屏幕水平锚定）
  String align = 'center';
  static const _alignPrefKey = 'floatingLyricAlign';

  /// 从本地读取对齐方式（app 冷启动后字段为默认值，需先加载）
  Future<void> loadAlign() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      align = prefs.getString(_alignPrefKey) ?? 'center';
    } catch (_) {}
  }

  /// 切换对齐方式：持久化 + 运行中实时推送给原生
  Future<void> setAlign(String v) async {
    align = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_alignPrefKey, v);
    } catch (_) {}
    if (_running) {
      await _channel.invokeMethod('setFloatingLyricAlign', {'align': v});
    }
  }

  // ---------------------------------------------------------------- 回退模式

  void _onLyric(String text) {
    if (!_running) return;
    if (_karaokeActive) return; // 卡拉OK模式下由原生自绘，不推整句
    _pushText(text);
  }

  void _pushText(String text) {
    final t = text.isEmpty ? '  ♪  ' : text;
    if (t == _lastText) return;
    _lastText = t;
    _channel.invokeMethod('updateFloatingLyric', {'text': t});
  }

  // ---------------------------------------------------------------- 卡拉OK

  void _onKaraokeChanged(KaraokeSong? song) {
    if (!_running) return;
    _karaokeActive = song != null && song.lines.isNotEmpty;
    _lastLineIndex = -2;
    _log('逐字数据变化: active=$_karaokeActive');
    if (!_karaokeActive) {
      _channel.invokeMethod('clearKaraoke');
      _pushText(AudioPlayerService().currentLyric);
    } else {
      _syncLine(_lastPos);
    }
  }

  void _onPosition(Duration pos) {
    if (!_running) return;
    _lastPos = pos;
    _channel.invokeMethod('syncPosition',
        {'positionMs': pos.inMilliseconds, 'playing': AudioPlayerService().isPlaying});
    if (_karaokeActive) _syncLine(pos);
  }

  /// 检测当前句索引变化，变化则推送整句 token 结构给原生
  void _syncLine(Duration pos) {
    final song = AudioPlayerService().karaoke;
    if (song == null || song.lines.isEmpty) return;
    final t = pos.inMilliseconds / 1000.0;
    final idx = _lineIndexAt(song, t);
    if (idx == _lastLineIndex) return;
    _lastLineIndex = idx;
    _log('推卡拉OK行 idx=$idx pos=${pos.inMilliseconds}ms');
    if (idx < 0) {
      // 前奏/间奏：清空填充，显示音符占位
      _channel.invokeMethod('setKaraokeLine', {
        'tokens': <Map<String, dynamic>>[],
        'text': '  ♪  ',
        'lineEndMs': -1,
      });
      return;
    }
    final line = song.lines[idx];
    _channel.invokeMethod('setKaraokeLine', {
      'tokens': [
        for (final tk in line.tokens)
          {'t': tk.text, 's': (tk.start * 1000).round(), 'e': (tk.end * 1000).round()}
      ],
      'text': line.text,
      'lineEndMs': (line.end * 1000).round(),
    });
  }

  /// 行区间定位：l.start <= t < l.end；否则 -1
  static int _lineIndexAt(KaraokeSong song, double t) {
    final lines = song.lines;
    // 歌词按时间有序，线性扫描足够
    for (int i = 0; i < lines.length; i++) {
      final l = lines[i];
      if (t < l.start) return -1;
      if (t < l.end) return i;
    }
    return -1;
  }
}
