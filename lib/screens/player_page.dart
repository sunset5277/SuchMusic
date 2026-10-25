import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../models/song_model.dart';
import '../services/audio_player_service.dart';
import '../services/floating_lyric_service.dart';
import '../services/karaoke/karaoke_model.dart';
import '../services/music_api_service.dart';
import '../widgets/design_dialog.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => PlayerPageState();
}

/// State 类公开：悬浮歌词设置面板可从设置页直接调用（PlayerPageState.showFloatingLyricSettings）
class PlayerPageState extends State<PlayerPage> {
  final AudioPlayerService _audioPlayer = AudioPlayerService();
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<SongModel?>? _currentSongSub;
  StreamSubscription<PlayMode>? _playModeSub;
  StreamSubscription<bool>? _fmModeSub;
  bool _isFmMode = false;
  final ValueNotifier<PlayMode> _playModeNotifier = ValueNotifier<PlayMode>(
    PlayMode.loop,
  );
  bool _isPlaying = false;
  bool _coverCollapsed = false;
  // 大封面拖动手势：原始位移用于方向判定（含竖直方向的上滑暂停），
  // 跟手反馈仅水平方向；松手切歌时跟手位移作为出场动画起点继续滑出
  Offset _coverPanDelta = Offset.zero;
  Offset _coverDragOffset = Offset.zero;
  bool _coverDragging = false;
  Offset? _coverDragExitBegin;
  // 拖动切歌后的冻结：封面停在松手位置不回弹，出场/入场动画通过
  // _coverDragExitBegin 补偿轨迹，300ms 后外层位移才瞬时归零（两帧衔接无缝）
  bool _coverFrozen = false;
  Timer? _coverSnapTimer;
  Timer? _coverExitTimer;
  // 大封面切歌滑动方向：1 下一首（左滑出、右侧入），-1 上一曲，0 无动画
  int _coverSlideDir = 0;
  int _lastCoverIndex = -1;
  String? _currentCoverUrl;
  Uint8List? _coverBytes;
  String? _fetchingUrl;
  // 歌词页沉浸模式：10 秒无操作隐藏播控按钮，进度条下沉到屏幕底部上方 32px
  bool _controlsHidden = false;
  Timer? _idleTimer;
  // 桌面悬浮歌词开关状态（悬浮窗独立于页面生命周期，离开播放页仍显示）
  bool _floatingLyricOn = false;
  void Function()? _floatingClosedCb;

  bool get _isImmersive => _coverCollapsed && _controlsHidden;

  @override
  void initState() {
    super.initState();
    _isPlaying = _audioPlayer.isPlaying;
    _playModeNotifier.value = _audioPlayer.playMode;
    _isFmMode = _audioPlayer.isFmMode;
    _loadCover();
    // 悬浮歌词可能已在运行（页面重开），同步按钮状态
    _floatingLyricOn = FloatingLyricService().isRunning;
    // 用户直接点悬浮窗上的 ✕ 关闭时，同步按钮状态
    _floatingClosedCb = () {
      if (mounted) setState(() => _floatingLyricOn = false);
    };
    FloatingLyricService().addClosedListener(_floatingClosedCb!);

    _stateSub = _audioPlayer.onStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state == PlayerState.playing;
        });
      }
    });

    _currentSongSub = _audioPlayer.onCurrentSongChanged.listen((song) {
      if (!mounted) return;
      // 依据播放列表索引变化判定切歌方向，驱动大封面滑动动画
      final idx = _audioPlayer.currentIndex;
      final switched =
          idx >= 0 && _lastCoverIndex >= 0 && idx != _lastCoverIndex;
      if (switched) {
        final len = _audioPlayer.playlist.length;
        if (_lastCoverIndex == len - 1 && idx == 0) {
          _coverSlideDir = 1; // 末尾回环到开头，视为下一首
        } else if (_lastCoverIndex == 0 && idx == len - 1) {
          _coverSlideDir = -1; // 开头回环到末尾，视为上一曲
        } else {
          _coverSlideDir = idx > _lastCoverIndex ? 1 : -1;
        }
      } else {
        _coverSlideDir = 0;
      }
      _lastCoverIndex = idx;
      setState(() {
        if (_coverFrozen) {
          if (switched) {
            // 拖动切歌：出场动画随本次 setState 启动（子组件 key 换成新歌 id）。
            // 外层跟手位移此时仍生效，出场/入场轨迹已按它补偿，300ms 后
            // （旧封面滑出、新封面仍在屏幕外）再把外层位移瞬时归零
            _coverSnapTimer?.cancel();
            _coverSnapTimer = Timer(const Duration(milliseconds: 300), () {
              if (mounted) setState(() => _coverDragOffset = Offset.zero);
            });
            // 出场动画结束后解除冻结、清除轨迹补偿
            _coverExitTimer?.cancel();
            _coverExitTimer = Timer(const Duration(milliseconds: 650), () {
              if (mounted) {
                setState(() {
                  _coverFrozen = false;
                  _coverDragExitBegin = null;
                });
              }
            });
          } else {
            // 未真正切歌（重播当前歌）：解除冻结，250ms 回弹归位
            _coverFrozen = false;
            _coverDragOffset = Offset.zero;
            _coverDragExitBegin = null;
          }
        }
        if (song != null) {
          // 切歌时保留上一首封面继续显示，新封面加载完成后再替换
          _loadCover();
        } else {
          // 完全无歌曲时才清空封面，显示占位图
          _currentCoverUrl = null;
          _coverBytes = null;
          _fetchingUrl = null;
        }
      });
    });

    _playModeSub = _audioPlayer.onPlayModeChanged.listen((mode) {
      if (mounted) {
        _playModeNotifier.value = mode;
      }
    });

    _fmModeSub = _audioPlayer.onFmModeChanged.listen((isFm) {
      if (mounted) {
        setState(() {
          _isFmMode = isFm;
        });
      }
    });
  }

  void _loadCover() {
    final song = _audioPlayer.currentSong;
    if (song?.coverUrl == null) {
      // 新歌没有封面：保留上一首封面继续显示，不退回占位图
      _fetchingUrl = null;
      return;
    }
    final newUrl = song!.coverUrl!;
    if (newUrl == _currentCoverUrl && _coverBytes != null) return;
    _currentCoverUrl = newUrl;
    final cached = AudioPlayerService.cachedCover(_currentCoverUrl!);
    if (cached != null) {
      _coverBytes = cached;
      _fetchingUrl = null;
    } else if (_fetchingUrl != newUrl) {
      _fetchingUrl = newUrl;
      _fetchCover(_currentCoverUrl!);
    }
  }

  Future<void> _fetchCover(String url) async {
    await AudioPlayerService.preFetchCover(url);
    if (!mounted) return;
    if (_currentCoverUrl != url) return; // 已切到其他歌，丢弃过期结果
    final bytes = AudioPlayerService.cachedCover(url);
    if (bytes != null) {
      setState(() {
        _coverBytes = bytes;
        _fetchingUrl = null;
      });
    } else {
      if (_fetchingUrl == url) {
        _fetchingUrl = null;
      }
    }
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _coverSnapTimer?.cancel();
    _coverExitTimer?.cancel();
    _stateSub?.cancel();
    _currentSongSub?.cancel();
    _playModeSub?.cancel();
    _fmModeSub?.cancel();
    _playModeNotifier.dispose();
    if (_floatingClosedCb != null) {
      FloatingLyricService().removeClosedListener(_floatingClosedCb!);
    }
    super.dispose();
  }

  // 沉浸模式倒计时：10 秒无操作后隐藏播控
  void _restartIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: 10), () {
      if (mounted && _coverCollapsed && !_controlsHidden) {
        setState(() => _controlsHidden = true);
      }
    });
  }

  // 用户触摸页面：立即恢复播控显示并重新计时
  void _handleUserInteract() {
    if (!_coverCollapsed) return;
    if (_controlsHidden) {
      setState(() => _controlsHidden = false);
    }
    _restartIdleTimer();
  }

  @override
  Widget build(BuildContext context) {
    // 深色页面：系统栏用浅色图标，避免 ColorOS 手势条自动垫浅色背景
    final viewPadBottom = MediaQuery.of(context).padding.bottom;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        // 全页触摸监听：任意点击恢复播控显示并重置沉浸模式倒计时
        body: Listener(
          onPointerDown: (_) => _handleUserInteract(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildBlurredBackground(),
              SafeArea(
                child: Column(
                  children: [
                    _buildTopBar(),
                    const SizedBox(height: 34),
                    _buildCoverAndSongInfo(),
                    // 大歌词区域：出现时上移淡入，收起时下移淡出（与封面动画同步 200ms）
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        switchInCurve: Curves.easeInOut,
                        switchOutCurve: Curves.easeInOut,
                        transitionBuilder: (child, animation) {
                          final slide = Tween<Offset>(
                            begin: const Offset(0, 0.04),
                            end: Offset.zero,
                          ).animate(animation);
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: slide,
                              child: child,
                            ),
                          );
                        },
                        child: _coverCollapsed
                            ? FullLyricDisplay(
                                key: const ValueKey('lyrics'),
                                // 沉浸模式下点击歌词仅恢复播控显示，不跳转进度
                                tapToSeek: !_isImmersive,
                              )
                            : const SizedBox.expand(
                                key: ValueKey('lyrics_empty'),
                              ),
                      ),
                    ),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      switchInCurve: Curves.easeInOut,
                      switchOutCurve: Curves.easeInOut,
                      transitionBuilder: (child, animation) =>
                          FadeTransition(opacity: animation, child: child),
                      child: _coverCollapsed
                          ? const SizedBox(
                              width: double.infinity,
                              key: ValueKey('song_info_empty'),
                            )
                          : Column(
                              key: const ValueKey('song_info_visible'),
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(left: 25),
                                  child: _buildSongInfo(collapsed: false),
                                ),
                                const SizedBox(height: 18),
                              ],
                            ),
                    ),
                    // 进度条：歌词页沉浸模式下向下移动，与底部间距动画配合停在屏幕底部上方 32px
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeInOut,
                      transform: Matrix4.translationValues(
                        0,
                        _isImmersive ? 0 : -12,
                        0,
                      ),
                      child: const ProgressBar(),
                    ),
                    const SizedBox(height: 0),
                    // 播控按钮：沉浸模式下滑动下沉 + 逐渐淡出；
                    // 占位高度同步收缩为 0，让大歌词显示空间向下扩展
                    SizedBox(
                      width: double.infinity,
                      child: Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.topCenter,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeInOut,
                            height: _isImmersive ? 0 : 144,
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 0,
                            child: IgnorePointer(
                              ignoring: _isImmersive,
                              child: AnimatedOpacity(
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeInOut,
                                opacity: _isImmersive ? 0.0 : 1.0,
                                child: AnimatedSlide(
                                  duration: const Duration(milliseconds: 200),
                                  curve: Curves.easeInOut,
                                  offset: _isImmersive
                                      ? const Offset(0, 0.9)
                                      : Offset.zero,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Transform.translate(
                                        offset: const Offset(0, -24),
                                        child: _buildControls(),
                                      ),
                                      const SizedBox(height: 4),
                                      // 第二行按钮：上移 18px 靠近播控，整体 75% 不透明度
                                      Transform.translate(
                                        offset: const Offset(0, -18),
                                        child: Opacity(
                                          opacity: 0.75,
                                          child: _buildExtraActionsRow(),
                                        ),
                                      ),
                                      const SizedBox(height: 40),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 沉浸模式：进度条距屏幕底部 32px（扣除底部安全区内边距）
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeInOut,
                      height: _isImmersive
                          ? (32.0 - viewPadBottom).clamp(0.0, 32.0).toDouble()
                          : 0.0,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBlurredBackground() {
    final defaultBg = Stack(
      fit: StackFit.expand,
      children: [
        Container(
          color: const Color(0xFF1A1A2E),
          child: Image.asset(
            'assets/images/Such_Music_Logo.png',
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
          ),
        ),
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(color: Colors.black.withValues(alpha: 0.4)),
        ),
      ],
    );
    if (_coverBytes == null) return defaultBg;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 背景图交叉淡入淡出：消除切歌时新图到达瞬间的硬切闪跳
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 500),
          switchInCurve: Curves.easeInOut,
          switchOutCurve: Curves.easeInOut,
          child: Image.memory(
            _coverBytes!,
            key: ValueKey(_currentCoverUrl),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
          ),
        ),
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(color: Colors.black.withValues(alpha: 0.4)),
        ),
      ],
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 16, top: 4, bottom: 4),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Row(
              children: [
                SvgPicture.asset(
                  'assets/images/svg/Down.svg',
                  width: 22,
                  height: 22,
                  colorFilter: const ColorFilter.mode(
                    Colors.white,
                    BlendMode.srcIn,
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  '返回',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
              ],
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildCoverAndSongInfo() {
    final screenWidth = MediaQuery.of(context).size.width;
    final coverSize = screenWidth - 50;
    const collapsedSize = 70.0;
    final collapsedHeight = collapsedSize + 8.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      width: coverSize,
      height: _coverCollapsed ? collapsedHeight : coverSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 4.0,
            left: collapsedSize + 12.0,
            right: 0,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              opacity: _coverCollapsed ? 1.0 : 0.0,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                // 与小封面同步：上移浮现
                offset: _coverCollapsed ? Offset.zero : const Offset(0, 0.4),
                child: _buildSongInfo(collapsed: true),
              ),
            ),
          ),
          // 大封面：收起时下移淡出
          Positioned(
            top: -8.0,
            left: 0,
            child: IgnorePointer(
              ignoring: _coverCollapsed,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                opacity: _coverCollapsed ? 0.0 : 1.0,
                child: AnimatedSlide(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  offset: _coverCollapsed ? const Offset(0, 0.3) : Offset.zero,
                  child: GestureDetector(
                    // 收起封面进入歌词页：开始沉浸模式倒计时
                    onTap: () {
                      setState(() => _coverCollapsed = true);
                      _restartIdleTimer();
                    },
                    // 封面手势：左滑下一首、右滑上一首、上滑暂停/恢复
                    onPanStart: _handleCoverPanStart,
                    onPanUpdate: _handleCoverPanUpdate,
                    onPanEnd: _handleCoverPanEnd,
                    // 拖动跟手：拖动中瞬时跟随；切歌冻结期不回弹（停在松手位置）；
                    // 其余情况 250ms 缓动归位
                    child: AnimatedSlide(
                      duration: _coverDragging
                          ? const Duration(milliseconds: 1)
                          : _coverFrozen
                          ? Duration.zero
                          : const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                      offset: Offset(
                        _coverDragOffset.dx / coverSize,
                        _coverDragOffset.dy / coverSize,
                      ),
                      child: AnimatedSwitcher(
                        // 前半段旧封面滑出屏幕，后半段新封面才滑入。
                        // 不用 switchIn/OutCurve：CurvedAnimation 在端点
                        // （t=0/1）会跳过曲线返回原始值，导致出场第一帧
                        // 旧封面瞬移到屏幕外闪一下；改为在 transitionBuilder
                        // 里用原始 animation.value 自行分段计算，端点确定
                        duration: const Duration(milliseconds: 600),
                        // 不裁剪，让旧封面滑出屏幕、新封面从屏幕边缘滑入
                        layoutBuilder:
                            (
                              Widget? currentChild,
                              List<Widget> previousChildren,
                            ) {
                              return Stack(
                                clipBehavior: Clip.none,
                                alignment: Alignment.center,
                                children: [...previousChildren, ?currentChild],
                              );
                            },
                        transitionBuilder:
                            (Widget child, Animation<double> animation) {
                              // 以封面宽度为单位的位移比例：屏幕宽+封面宽，
                              // 保证封面无论起点在哪都完全滑出屏幕
                              final frac =
                                  (screenWidth + coverSize) / coverSize;
                              // 无方向时默认按下一首处理
                              final dir = _coverSlideDir == 0
                                  ? 1
                                  : _coverSlideDir;
                              // 拖动切歌补偿：冻结期间外层跟手位移仍生效，出/入
                              // 位移各减去该量，300ms 外层归零后总位置保持连续
                              final comp = _coverDragExitBegin == null
                                  ? Offset.zero
                                  : Offset(
                                      _coverDragExitBegin!.dx / coverSize,
                                      _coverDragExitBegin!.dy / coverSize,
                                    );
                              // 子组件按歌曲 id 区分，动画不等封面下载立即开始
                              final incoming =
                                  child.key ==
                                  ValueKey(_audioPlayer.currentSong?.id);
                              // 下一首：入场从右侧、出场向左；上一曲反之
                              final enterBegin = dir > 0
                                  ? Offset(frac - comp.dx, -comp.dy)
                                  : Offset(-frac - comp.dx, -comp.dy);
                              final exitEnd = dir > 0
                                  ? Offset(-frac - comp.dx, -comp.dy)
                                  : Offset(frac - comp.dx, -comp.dy);
                              return AnimatedBuilder(
                                animation: animation,
                                builder: (context, _) {
                                  final t = animation.value;
                                  final double v;
                                  final Offset begin;
                                  if (incoming) {
                                    // 入场 t: 0→1，前半段停在屏幕外，后半段滑入
                                    v = Curves.easeOutCubic.transform(
                                      ((t - 0.5) * 2).clamp(0.0, 1.0),
                                    );
                                    begin = enterBegin;
                                  } else {
                                    // 出场 t: 1→0，前半段从原位滑出，后半段停在屏幕外
                                    v = Curves.easeInCubic.transform(
                                      ((1.0 - t) * 2).clamp(0.0, 1.0),
                                    );
                                    begin = Offset.zero;
                                  }
                                  return FractionalTranslation(
                                    translation: Offset.lerp(
                                      begin,
                                      incoming ? Offset.zero : exitEnd,
                                      v,
                                    )!,
                                    child: child,
                                  );
                                },
                              );
                            },
                        child: Container(
                          key: ValueKey(_audioPlayer.currentSong?.id),
                          width: coverSize,
                          height: coverSize,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.4),
                                blurRadius: 30,
                                spreadRadius: 20,
                                offset: const Offset(0, 5),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: _coverImage(coverSize),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 小封面：收起时上移浮现
          Positioned(
            top: -8.0,
            left: 0,
            child: IgnorePointer(
              ignoring: !_coverCollapsed,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                opacity: _coverCollapsed ? 1.0 : 0.0,
                child: AnimatedSlide(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  offset: _coverCollapsed ? Offset.zero : const Offset(0, 0.4),
                  child: GestureDetector(
                    // 展开封面退出歌词页：取消沉浸模式，立即恢复播控
                    onTap: () {
                      setState(() => _coverCollapsed = false);
                      _controlsHidden = false;
                      _idleTimer?.cancel();
                    },
                    child: Container(
                      width: collapsedSize,
                      height: collapsedSize,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: _coverImage(collapsedSize),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 大封面拖动手势：跟手移动，左滑下一首、右滑上一首、上滑暂停/恢复
  /// 距离超过 60px 或松手速度超过 250px/s 即触发，取分量更大的轴判定方向
  void _handleCoverPanStart(DragStartDetails details) {
    // 新一次拖动：清掉上一轮冻结/定时器/补偿
    _coverSnapTimer?.cancel();
    _coverExitTimer?.cancel();
    setState(() {
      _coverDragging = true;
      _coverFrozen = false;
      _coverDragExitBegin = null;
      _coverPanDelta = Offset.zero;
      _coverDragOffset = Offset.zero;
    });
  }

  void _handleCoverPanUpdate(DragUpdateDetails details) {
    setState(() {
      _coverPanDelta += details.delta;
      // 跟手反馈只保留水平方向，竖直拖动封面不动
      _coverDragOffset += Offset(details.delta.dx, 0);
    });
  }

  void _handleCoverPanEnd(DragEndDetails details) {
    final v = details.velocity.pixelsPerSecond;
    final d = _coverPanDelta;
    final dx = d.dx.abs() >= 60 || v.dx.abs() >= 250 ? d.dx : 0.0;
    final dy = d.dy.abs() >= 60 || v.dy.abs() >= 250 ? d.dy : 0.0;

    if (dx != 0 && dx.abs() >= dy.abs()) {
      // 横向拖动切歌：封面冻结在松手位置（不回弹），等切歌回调启动
      // 出场动画；出场/入场轨迹由 _coverDragExitBegin 补偿，300ms 后
      // 外层位移瞬时归零，全程无跳变地从松手位置滑出
      setState(() {
        _coverDragging = false;
        _coverFrozen = true;
        _coverDragExitBegin = _coverDragOffset;
        _coverSlideDir = dx < 0 ? 1 : -1;
      });
      if (dx < 0) {
        _audioPlayer.playNext();
      } else {
        _audioPlayer.playPrevious();
      }
      // 兜底：切歌回调迟迟不来（如重播当前歌），解除冻结回弹归位
      _coverSnapTimer?.cancel();
      _coverSnapTimer = Timer(const Duration(milliseconds: 800), () {
        if (mounted) {
          setState(() {
            _coverFrozen = false;
            _coverDragOffset = Offset.zero;
            _coverDragExitBegin = null;
          });
        }
      });
    } else {
      // 上滑暂停/恢复，或未达阈值：封面回弹归位
      if (dy < 0 && dy.abs() > dx.abs()) {
        _audioPlayer.togglePlayPause();
      }
      setState(() {
        _coverDragging = false;
        _coverDragOffset = Offset.zero;
      });
    }
  }

  /// 封面图片（大小共用同一份字节缓存）
  Widget _coverImage(double size) {
    // 封面图交叉淡入淡出：新图加载完成瞬间不硬切（滑入中先显示旧图）
    return _coverBytes != null
        ? AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeOut,
            child: Image.memory(
              _coverBytes!,
              key: ValueKey(_currentCoverUrl),
              width: size,
              height: size,
              fit: BoxFit.cover,
            ),
          )
        : _buildDefaultCover(size);
  }

  Widget _buildDefaultCover(double size) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: size,
        height: size,
        color: const Color(0xFF1A1A2E),
        child: Image.asset(
          'assets/images/Such_Music_Logo.png',
          width: size,
          height: size,
          fit: BoxFit.contain,
        ),
      ),
    );
  }

  Widget _buildSongInfo({required bool collapsed}) {
    final song = _audioPlayer.currentSong;

    if (song == null) {
      return SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '暂无播放歌曲',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '快去挑一首喜欢的歌吧',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: Colors.white70),
            ),
          ],
        ),
      );
    }

    final child = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            // 红心按钮：仅展开态显示（歌曲名/歌手右侧）
            if (!collapsed) _LikeButton(songId: song.id),
          ],
        ),
        if (!collapsed) ...[const SizedBox(height: 8), const LyricDisplay()],
      ],
    );
    return child;
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 25),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (_isFmMode)
            Opacity(
              opacity: 0.3,
              child: SvgPicture.asset(
                'assets/images/svg/Play_cycle.svg',
                width: 24,
                height: 24,
                colorFilter: const ColorFilter.mode(
                  Colors.white,
                  BlendMode.srcIn,
                ),
              ),
            )
          else
            GestureDetector(
              onTap: () => _audioPlayer.togglePlayMode(),
              child: ValueListenableBuilder<PlayMode>(
                valueListenable: _playModeNotifier,
                builder: (_, mode, _) {
                  final icon = switch (mode) {
                    PlayMode.loop => 'assets/images/svg/Play_cycle.svg',
                    PlayMode.single => 'assets/images/svg/play-once.svg',
                    PlayMode.shuffle => 'assets/images/svg/shuffle-one.svg',
                  };
                  return SvgPicture.asset(
                    icon,
                    width: 24,
                    height: 24,
                    colorFilter: const ColorFilter.mode(
                      Colors.white,
                      BlendMode.srcIn,
                    ),
                  );
                },
              ),
            ),
          GestureDetector(
            onTap: _isFmMode ? null : () => _audioPlayer.playPrevious(),
            child: Opacity(
              opacity: _isFmMode ? 0.3 : 1.0,
              child: SvgPicture.asset(
                'assets/images/svg/Previous.svg',
                width: 32,
                height: 32,
                colorFilter: const ColorFilter.mode(
                  Colors.white,
                  BlendMode.srcIn,
                ),
              ),
            ),
          ),
          Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(shape: BoxShape.circle),
            child: IconButton(
              onPressed: () => _audioPlayer.togglePlayPause(),
              icon: _isPlaying
                  ? SvgPicture.asset(
                      'assets/images/svg/Pause.svg',
                      width: 48,
                      height: 48,
                      colorFilter: const ColorFilter.mode(
                        Colors.white,
                        BlendMode.srcIn,
                      ),
                    )
                  : SvgPicture.asset(
                      'assets/images/svg/Play.svg',
                      width: 48,
                      height: 48,
                      colorFilter: const ColorFilter.mode(
                        Colors.white,
                        BlendMode.srcIn,
                      ),
                    ),
            ),
          ),
          GestureDetector(
            onTap: () => _audioPlayer.playNext(),
            child: SvgPicture.asset(
              'assets/images/svg/Next.svg',
              width: 32,
              height: 32,
              colorFilter: const ColorFilter.mode(
                Colors.white,
                BlendMode.srcIn,
              ),
            ),
          ),
          if (_isFmMode)
            GestureDetector(
              onTap: () => _audioPlayer.fmTrash(),
              child: SvgPicture.asset(
                'assets/images/svg/thumb_down.svg',
                width: 28,
                height: 28,
                colorFilter: const ColorFilter.mode(
                  Colors.white,
                  BlendMode.srcIn,
                ),
              ),
            )
          else
            GestureDetector(
              onTap: () => _showPlaylistSheet(context),
              child: SvgPicture.asset(
                'assets/images/svg/Playlist_Alternate.svg',
                width: 24,
                height: 24,
                colorFilter: const ColorFilter.mode(
                  Colors.white,
                  BlendMode.srcIn,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 播控下方附加按钮行：左侧悬浮歌词图标开关，右侧三个点菜单
  Widget _buildExtraActionsRow() {
    final on = _floatingLyricOn;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 25),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          GestureDetector(
            onTap: _toggleFloatingLyric,
            onLongPress: () =>
                PlayerPageState.showFloatingLyricSettings(context),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SizedBox(
                width: 24,
                height: 24,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // "词"字图标
                    Center(
                      child: Text(
                        '词',
                        style: TextStyle(
                          fontSize: 19,
                          height: 1,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    // 开启时右下角 ON 角标
                    if (on)
                      Positioned(
                        right: -3,
                        bottom: -2,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 0.5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'ON',
                            style: TextStyle(
                              fontSize: 6.5,
                              height: 1.1,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF333333),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          GestureDetector(
            onTap: _showMoreMenu,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SvgPicture.asset(
                'assets/images/svg/more.svg',
                width: 21,
                height: 21,
                colorFilter: const ColorFilter.mode(
                  Colors.white,
                  BlendMode.srcIn,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 悬浮歌词设置页（长按"词"图标或设置页打开）：歌词锁定开关、对齐方式滑块
  static Future<void> showFloatingLyricSettings(BuildContext context) async {
    final svc = FloatingLyricService();
    await svc.loadAlign();
    if (!context.mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(15)),
      ),
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setSheetState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 14),
              Text(
                '悬浮歌词设置',
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF333333),
                ),
              ),
              const SizedBox(height: 8),
              // 歌词锁定
              GestureDetector(
                onTap: () async {
                  final v = !svc.locked;
                  await svc.setLocked(v);
                  setSheetState(() {});
                },
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 15,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.lock_outline,
                        size: 20,
                        color: const Color(0xFF333333),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '歌词锁定',
                          style: TextStyle(
                            fontSize: 16,
                            color: const Color(0xFF333333),
                          ),
                        ),
                      ),
                      _buildMiniSwitch(svc.locked),
                    ],
                  ),
                ),
              ),
              // 对齐方式（左/居中/右，三档滑块，滑动或点击切换）
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 15,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.format_align_center,
                      size: 20,
                      color: const Color(0xFF333333),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        '对齐方式',
                        style: TextStyle(
                          fontSize: 16,
                          color: Color(0xFF333333),
                        ),
                      ),
                    ),
                    _buildAlignSlider(svc.align, (v) async {
                      await svc.setAlign(v);
                      setSheetState(() {});
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  /// 对齐方式三档滑块（左/居中/右）：点击对应档位或横向拖动切换，
  /// 白色滑块在浅灰胶囊轨道上滑动指示当前档位
  static Widget _buildAlignSlider(
    String current,
    ValueChanged<String> onChanged,
  ) {
    const values = ['left', 'center', 'right'];
    const labels = ['左', '居中', '右'];
    final idx = values.indexOf(current).clamp(0, 2);
    const trackW = 150.0;
    const trackH = 30.0;
    int idxFromDx(double dx) => ((dx / trackW) * 3).floor().clamp(0, 2);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) => onChanged(values[idxFromDx(d.localPosition.dx)]),
      onHorizontalDragUpdate: (d) =>
          onChanged(values[idxFromDx(d.localPosition.dx)]),
      child: Container(
        width: trackW,
        height: trackH,
        decoration: BoxDecoration(
          color: const Color(0xFFF1F2F4),
          borderRadius: BorderRadius.circular(trackH / 2),
        ),
        child: Stack(
          children: [
            // 白色滑块（跟随当前档位在三个位置间平滑移动）
            AnimatedAlign(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              alignment: Alignment(idx - 1, 0), // 0=左 1=中 2=右 → -1/0/+1
              child: Container(
                width: trackW / 3,
                height: trackH,
                margin: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(trackH / 2 - 2),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 4,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
            // 三档文字（选中项深色，未选中灰色）
            Row(
              children: [
                for (var i = 0; i < 3; i++)
                  Expanded(
                    child: Center(
                      child: Text(
                        labels[i],
                        style: TextStyle(
                          fontSize: 12.5,
                          color: i == idx
                              ? const Color(0xFF333333)
                              : const Color(0xFF999999),
                          fontWeight: i == idx
                              ? FontWeight.w500
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 小号设计风开关（与设置页开关同款样式，缩至 47×27）
  static Widget _buildMiniSwitch(bool value) {
    const s = 0.8;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      width: 53 * s + 6,
      height: 25 * s + 6,
      padding: EdgeInsets.all(4 * s),
      decoration: BoxDecoration(
        color: value ? const Color(0xFF2F84FE) : const Color(0xFFC4C4C4),
        borderRadius: BorderRadius.circular(84),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 23 * s,
          height: 23 * s,
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  /// 三个点菜单
  void _showMoreMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(15)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            Text(
              '更多',
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF333333),
              ),
            ),
            const SizedBox(height: 8),
            // 音效设置：点击进入二级菜单
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                Navigator.pop(ctx);
                _showSoundEffectSheet();
              },
              child: Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Text(
                      '音效',
                      style: TextStyle(fontSize: 16, color: Color(0xFF333333)),
                    ),
                    const Spacer(),
                    Text(
                      _audioPlayer.soundEffect.name,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF999999),
                      ),
                    ),
                    const SizedBox(width: 6),
                    SvgPicture.asset(
                      'assets/images/svg/Chevron Right.svg',
                      width: 14,
                      height: 14,
                      colorFilter: const ColorFilter.mode(
                        Color(0xFFCCCCCC),
                        BlendMode.srcIn,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 悬浮歌词设置：打开歌词锁定/对齐方式面板
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                Navigator.pop(ctx);
                PlayerPageState.showFloatingLyricSettings(context);
              },
              child: Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: const Row(
                  children: [
                    Text(
                      '悬浮歌词设置',
                      style: TextStyle(fontSize: 16, color: Color(0xFF333333)),
                    ),
                    Spacer(),
                    Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: Color(0xFFCCCCCC),
                    ),
                  ],
                ),
              ),
            ),
            // 逐字歌词设置：点击进入二级菜单
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                Navigator.pop(ctx);
                _showKaraokeSettingsSheet();
              },
              child: Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Text(
                      '逐字歌词',
                      style: TextStyle(fontSize: 16, color: Color(0xFF333333)),
                    ),
                    const Spacer(),
                    Text(
                      _audioPlayer.karaokeEnabled ? '开启' : '关闭',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF999999),
                      ),
                    ),
                    const SizedBox(width: 6),
                    SvgPicture.asset(
                      'assets/images/svg/Chevron Right.svg',
                      width: 14,
                      height: 14,
                      colorFilter: const ColorFilter.mode(
                        Color(0xFFCCCCCC),
                        BlendMode.srcIn,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  /// 逐字歌词二级菜单：开关逐字歌词、提前缓存下一首逐字歌词
  void _showKaraokeSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(15)),
      ),
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 14),
                const Center(
                  child: Text(
                    '逐字歌词',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF333333),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // 开关逐字歌词
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () async {
                    final v = !_audioPlayer.karaokeEnabled;
                    await _audioPlayer.setKaraokeEnabled(v);
                    if (ctx.mounted) setSheetState(() {});
                  },
                  child: Container(
                    height: 52,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        const Text(
                          '打开或关闭逐字歌词',
                          style: TextStyle(
                            fontSize: 16,
                            color: Color(0xFF333333),
                          ),
                        ),
                        const Spacer(),
                        _buildMiniSwitch(_audioPlayer.karaokeEnabled),
                      ],
                    ),
                  ),
                ),
                // 提前下一首缓存逐字歌词
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () async {
                    final v = !_audioPlayer.karaokePrecacheEnabled;
                    final msg =
                        await _audioPlayer.setKaraokePrecacheEnabled(v);
                    if (!mounted) return;
                    if (v && msg != null) {
                      DesignToast.show(context, msg);
                    }
                    setSheetState(() {});
                  },
                  child: Container(
                    height: 52,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        const Text(
                          '提前下一首缓存逐字歌词',
                          style: TextStyle(
                            fontSize: 16,
                            color: Color(0xFF333333),
                          ),
                        ),
                        const Spacer(),
                        _buildMiniSwitch(_audioPlayer.karaokePrecacheEnabled),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 音效二级菜单：PEQ 参数均衡器（10 段虚设 UI，相邻两段映射底层五段均衡器）。
  /// 预设为虚设增益值，点选即时生效可试听；滑杆拖动后按"自定义"生效
  void _showSoundEffectSheet() {
    final current = _audioPlayer.soundEffect;
    final List<double> gains = current.gains != null
        ? List<double>.of(current.gains!)
        : List<double>.filled(10, 0.0);
    String selected = current.name;
    const freqLabels = [
      '31Hz',
      '62Hz',
      '125Hz',
      '250Hz',
      '500Hz',
      '1kHz',
      '2kHz',
      '4kHz',
      '8kHz',
      '16kHz',
    ];
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(15)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 14),
                const Center(
                  child: Text(
                    '音效',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF333333),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // 预设 chips
                SizedBox(
                  height: 32,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: kSoundEffectPresets.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (ctx, i) {
                      final p = kSoundEffectPresets[i];
                      final sel = p.name == selected;
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () async {
                          await _audioPlayer.setSoundEffect(p);
                          if (!ctx.mounted) return;
                          setSheetState(() {
                            selected = p.name;
                            for (var j = 0; j < gains.length; j++) {
                              gains[j] = j < (p.gains?.length ?? 0)
                                  ? p.gains![j]
                                  : 0.0;
                            }
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: sel
                                ? const Color(0xFF2F84FE)
                                : const Color(0xFFF5F5F5),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            p.name,
                            style: TextStyle(
                              fontSize: 13,
                              color: sel
                                  ? Colors.white
                                  : const Color(0xFF333333),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 20),
                // PEQ 五段竖向滑杆
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 216,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: const [
                            Text(
                              '+15',
                              style: TextStyle(
                                fontSize: 10,
                                color: Color(0xFF999999),
                              ),
                            ),
                            Text(
                              '0',
                              style: TextStyle(
                                fontSize: 10,
                                color: Color(0xFF999999),
                              ),
                            ),
                            Text(
                              '-15',
                              style: TextStyle(
                                fontSize: 10,
                                color: Color(0xFF999999),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 4,
                            activeTrackColor: const Color(0xFF2F84FE),
                            inactiveTrackColor: const Color(0xFFE8E8E8),
                            thumbColor: const Color(0xFF2F84FE),
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 10,
                            ),
                          ),
                          child: Row(
                            children: List.generate(10, (i) {
                              return Expanded(
                                child: Column(
                                  children: [
                                    SizedBox(
                                      height: 200,
                                      child: RotatedBox(
                                        quarterTurns: 3,
                                        child: Slider(
                                          value: gains[i].clamp(-15.0, 15.0),
                                          min: -15,
                                          max: 15,
                                          onChanged: (v) =>
                                              setSheetState(() => gains[i] = v),
                                          onChangeEnd: (v) {
                                            setSheetState(
                                              () => selected = '自定义',
                                            );
                                            _audioPlayer.setSoundEffect(
                                              SoundEffectPreset(
                                                '自定义',
                                                List<double>.of(gains),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                    Text(
                                      freqLabels[i],
                                      maxLines: 1,
                                      overflow: TextOverflow.clip,
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Color(0xFF999999),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    // 当前段增益值（dB），拖动实时刷新
                                    Text(
                                      gains[i].round() > 0
                                          ? '+${gains[i].round()}'
                                          : '${gains[i].round()}',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: gains[i].round() == 0
                                            ? const Color(0xFF999999)
                                            : const Color(0xFF2F84FE),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 开关桌面悬浮歌词；无悬浮窗权限时先跳系统设置申请
  Future<void> _toggleFloatingLyric() async {
    final svc = FloatingLyricService();
    if (svc.isRunning) {
      // 乐观更新：点击立即反馈，不等平台调用返回
      if (mounted) setState(() => _floatingLyricOn = false);
      await svc.stop();
      return;
    }
    if (mounted) setState(() => _floatingLyricOn = true);
    if (await svc.canDrawOverlays()) {
      try {
        await svc.start();
      } catch (_) {
        if (mounted) setState(() => _floatingLyricOn = false);
      }
    } else {
      if (mounted) setState(() => _floatingLyricOn = false);
      // 跳转系统设置授权，返回后用户再点一次按钮即可开启
      await svc.requestOverlayPermission();
      if (mounted) {
        DesignToast.show(context, '请允许"显示在其他应用上层"后再点一次');
      }
    }
  }

  void _showPlaylistSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final playlist = _audioPlayer.playlist;
            final currentIndex = _audioPlayer.currentIndex;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '播放列表 (${playlist.length})',
                        style: const TextStyle(
                          color: Colors.black87,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Row(
                        children: [
                          if (playlist.isNotEmpty)
                            GestureDetector(
                              onTap: () async {
                                await _audioPlayer.clearPlaylist();
                                if (!ctx.mounted) return;
                                setSheetState(() {});
                              },
                              child: const Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                child: Text(
                                  '清空',
                                  style: TextStyle(
                                    color: Colors.red,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),
                          GestureDetector(
                            onTap: () => Navigator.pop(ctx),
                            child: const Icon(
                              Icons.close,
                              color: Colors.black54,
                              size: 22,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Color(0xFFEEEEEE)),
                Expanded(
                  child: playlist.isEmpty
                      ? const Center(
                          child: Text(
                            '播放列表为空',
                            style: TextStyle(color: Colors.black38),
                          ),
                        )
                      : ListView.builder(
                          itemCount: playlist.length,
                          itemBuilder: (ctx, index) {
                            final song = playlist[index];
                            final isCurrent = index == currentIndex;
                            return ListTile(
                              leading: isCurrent
                                  ? const Icon(
                                      Icons.equalizer,
                                      color: Color(0xFF2F84FE),
                                      size: 22,
                                    )
                                  : Text(
                                      '${index + 1}',
                                      style: TextStyle(
                                        color: Colors.black38,
                                        fontSize: 14,
                                      ),
                                    ),
                              title: Text(
                                song.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: isCurrent
                                      ? const Color(0xFF2F84FE)
                                      : Colors.black87,
                                  fontSize: 14,
                                  fontWeight: isCurrent
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                ),
                              ),
                              subtitle: Text(
                                song.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.black38,
                                  fontSize: 12,
                                ),
                              ),
                              trailing: GestureDetector(
                                onTap: () async {
                                  await _audioPlayer.removeFromPlaylist(index);
                                  if (!ctx.mounted) return;
                                  setSheetState(() {});
                                },
                                child: const Padding(
                                  padding: EdgeInsets.all(6),
                                  child: Icon(
                                    Icons.close,
                                    color: Colors.black38,
                                    size: 18,
                                  ),
                                ),
                              ),
                              onTap: () async {
                                await _audioPlayer.playAtIndex(index);
                                if (!ctx.mounted) return;
                                setSheetState(() {});
                              },
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class ProgressBar extends StatefulWidget {
  const ProgressBar({super.key});

  @override
  State<ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<ProgressBar> {
  final AudioPlayerService _audioPlayer = AudioPlayerService();
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isSeeking = false;

  @override
  void initState() {
    super.initState();
    _position = _audioPlayer.position;
    _duration = _audioPlayer.duration;
    _positionSub = _audioPlayer.onPositionChanged.listen((pos) {
      if (mounted && !_isSeeking) {
        setState(() {
          _position = pos;
        });
      }
    });
    _durationSub = _audioPlayer.onDurationChanged.listen((dur) {
      if (mounted) {
        setState(() {
          _duration = dur;
        });
      }
    });
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final barWidth = screenWidth - 50;
    final progress = _duration.inMilliseconds > 0
        ? _position.inMilliseconds / _duration.inMilliseconds
        : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 25),
      child: Column(
        children: [
          SizedBox(
            width: barWidth,
            height: 20,
            child: GestureDetector(
              onTapUp: (details) {
                final pos = (details.localPosition.dx / barWidth).clamp(
                  0.0,
                  1.0,
                );
                final seekPos = Duration(
                  milliseconds: (pos * _duration.inMilliseconds).round(),
                );
                setState(() {
                  _position = seekPos;
                });
                _audioPlayer.seek(seekPos);
              },
              onHorizontalDragUpdate: (details) {
                setState(() {
                  _isSeeking = true;
                  final pos = (details.localPosition.dx / barWidth).clamp(
                    0.0,
                    1.0,
                  );
                  _position = Duration(
                    milliseconds: (pos * _duration.inMilliseconds).round(),
                  );
                });
              },
              onHorizontalDragEnd: (_) {
                _isSeeking = false;
                _audioPlayer.seek(_position);
              },
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    width: barWidth,
                    height: 5,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2.5),
                      color: Colors.white24,
                    ),
                  ),
                  Container(
                    width: barWidth * progress.clamp(0.0, 1.0),
                    height: 5,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2.5),
                      color: Colors.white,
                    ),
                  ),
                  Positioned(
                    left: barWidth * progress.clamp(0.0, 1.0) - 5,
                    top: 5,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: barWidth,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDuration(_position),
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                Text(
                  _formatDuration(_duration),
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class LyricDisplay extends StatefulWidget {
  const LyricDisplay({super.key});

  @override
  State<LyricDisplay> createState() => _LyricDisplayState();
}

class _LyricDisplayState extends State<LyricDisplay> {
  final AudioPlayerService _audioPlayer = AudioPlayerService();
  StreamSubscription<String>? _lyricSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<KaraokeSong?>? _karaokeSub;
  String _currentLyric = '';
  // 逐字卡拉OK（就绪后小歌词与大歌词同款逐字填充）
  KaraokeSong? _karaoke;
  int _karaokeIndex = -1;
  final ValueNotifier<double> _karaokeTick = ValueNotifier(0.0);

  @override
  void initState() {
    super.initState();
    _currentLyric = _audioPlayer.currentLyric;
    _karaoke = _audioPlayer.karaoke;
    _lyricSub = _audioPlayer.onLyricChanged.listen((lyric) {
      if (mounted) {
        setState(() {
          _currentLyric = lyric;
        });
      }
    });
    _karaokeSub = _audioPlayer.onKaraokeChanged.listen((k) {
      if (!mounted) return;
      setState(() {
        _karaoke = k;
        _karaokeIndex = -1;
      });
      _syncKaraokeIndex();
    });
    _positionSub = _audioPlayer.onPositionChanged.listen((pos) {
      if (!mounted) return;
      _karaokeTick.value = pos.inMilliseconds / 1000.0;
      _syncKaraokeIndex();
    });
  }

  void _syncKaraokeIndex() {
    if (_karaoke == null || _karaoke!.lines.isEmpty) return;
    final newIndex = _karaoke!.lineIndexAt(_karaokeTick.value);
    if (newIndex != _karaokeIndex) {
      setState(() => _karaokeIndex = newIndex);
    }
  }

  @override
  void dispose() {
    _lyricSub?.cancel();
    _positionSub?.cancel();
    _karaokeSub?.cancel();
    _karaokeTick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 24,
      width: double.infinity,
      child: _LineRoller(
        child:
            (_karaoke != null &&
                _karaoke!.lines.isNotEmpty &&
                _karaokeIndex >= 0)
            ? FittedBox(
                key: ValueKey<int>(_karaokeIndex),
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: _KaraokeActiveLine(
                  line: _karaoke!.lines[_karaokeIndex],
                  tick: _karaokeTick,
                  fontSize: 16,
                ),
              )
            : _MarqueeText(
                _currentLyric,
                key: ValueKey<String>(_currentLyric),
                style: const TextStyle(fontSize: 16, color: Colors.white54),
              ),
      ),
    );
  }
}

/// 单行滚轮：换行时旧行向上滚出、新行从下方滚入，方向恒定向上（与大歌词一致）。
/// AnimatedSwitcher 的退场是入场动画倒放（旧行会向下退回），做不出单向滚轮。
class _LineRoller extends StatefulWidget {
  final Widget child;
  const _LineRoller({required this.child});

  @override
  State<_LineRoller> createState() => _LineRollerState();
}

class _LineRollerState extends State<_LineRoller>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  Widget? _prev;

  @override
  void initState() {
    super.initState();
    _ctrl =
        AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 350),
          )
          ..addListener(() {
            if (mounted) setState(() {});
          })
          ..addStatusListener((s) {
            if (s == AnimationStatus.completed && mounted) {
              setState(() => _prev = null);
            }
          });
  }

  @override
  void didUpdateWidget(covariant _LineRoller old) {
    super.didUpdateWidget(old);
    if (widget.child.key != null && widget.child.key != old.child.key) {
      _prev = old.child;
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Curves.easeInOut.transform(_ctrl.value);
    final animating = _prev != null && t < 1.0;
    return LayoutBuilder(
      builder: (context, c) {
        final h = c.maxHeight;
        return ClipRect(
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.centerLeft,
            children: [
              if (animating) ...[
                Positioned(
                  left: 0,
                  right: 0,
                  top: -t * h,
                  child: Opacity(opacity: 1 - t, child: _prev),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: (1 - t) * h,
                  child: Opacity(opacity: t, child: widget.child),
                ),
              ] else
                widget.child,
            ],
          ),
        );
      },
    );
  }
}

/// 红心按钮：显示当前歌红心状态，点击红心/取消红心（乐观更新，失败回滚）
class _LikeButton extends StatefulWidget {
  final String songId;
  const _LikeButton({required this.songId});

  @override
  State<_LikeButton> createState() => _LikeButtonState();
}

class _LikeButtonState extends State<_LikeButton> {
  final MusicApiService _api = MusicApiService();
  bool? _override; // 点击后的乐观状态，接口确认后清空回退到缓存值
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 首次需要时懒加载红心列表（登录状态下）
    _api.ensureLikelist().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant _LikeButton old) {
    super.didUpdateWidget(old);
    if (old.songId != widget.songId) {
      _override = null;
      _busy = false;
    }
  }

  bool get _liked => _override ?? _api.isLiked(widget.songId);

  Future<void> _toggle() async {
    if (_busy) return;
    final uid = _api.cachedUserId;
    if (uid == null || uid.isEmpty) {
      DesignToast.show(context, '登录后才能收藏歌曲');
      return;
    }
    final next = !_liked;
    setState(() {
      _override = next;
      _busy = true;
    });
    final ok = await _api.likeSong(widget.songId, next);
    if (!mounted) return;
    setState(() {
      _override = null; // 成功则缓存已同步，失败则回滚
      _busy = false;
    });
    if (!ok) DesignToast.show(context, '操作失败，请稍后再试');
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _toggle,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 25, 8),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          transitionBuilder: (child, anim) => ScaleTransition(
            scale: Tween(begin: 0.6, end: 1.0).animate(anim),
            child: child,
          ),
          child: SvgPicture.asset(
            // 已红心用实心爱心，未红心用描边空心爱心
            _liked
                ? 'assets/images/svg/heart_filled.svg'
                : 'assets/images/svg/heart.svg',
            key: ValueKey<bool>(_liked),
            width: 22,
            height: 22,
            colorFilter: ColorFilter.mode(
              _liked ? const Color(0xFFEC4141) : Colors.white60,
              BlendMode.srcIn,
            ),
          ),
        ),
      ),
    );
  }
}

/// 单行跑马灯文字：宽度足够时静止；溢出时横向循环滚动（开头停留 1s 便于阅读）。
/// 换行文本时自动重置回开头。不引入第三方 marquee 依赖。
class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _MarqueeText(this.text, {super.key, required this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  static const double _speed = 30; // px/s
  static const double _gap = 48; // 循环接缝间距
  static const int _leadPauseMs = 1000; // 开头停留时长

  late final Ticker _ticker;
  double _offset = 0;
  double _textW = 0;
  double _maxW = 0;
  Duration? _lastElapsed;
  int _sinceResetMs = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didUpdateWidget(covariant _MarqueeText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _offset = 0;
      _sinceResetMs = 0;
    }
  }

  void _onTick(Duration elapsed) {
    final dt = _lastElapsed == null
        ? 0.0
        : (elapsed - _lastElapsed!).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    if (dt <= 0 || _textW <= _maxW + 0.5) return; // 无溢出不需要滚动
    _sinceResetMs += (dt * 1000).round();
    if (_sinceResetMs < _leadPauseMs) return;
    setState(() {
      _offset += _speed * dt;
      if (_offset >= _textW + _gap) _offset -= _textW + _gap;
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    _textW = tp.width;

    return LayoutBuilder(
      builder: (context, c) {
        _maxW = c.maxWidth;
        if (_textW <= _maxW + 0.5) {
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }
        return ClipRect(
          child: SizedBox(
            width: c.maxWidth,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.centerLeft,
              children: [
                Positioned(
                  left: -_offset,
                  child: Text(widget.text, style: widget.style),
                ),
                Positioned(
                  left: -_offset + _textW + _gap,
                  child: Text(widget.text, style: widget.style),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 逐字模式显示项：逐字行或从 LRC 补回的制作名单行
class _KaraokeDisplayItem {
  final KaraokeLine? line; // null = 制作名单行
  final LyricLine? credit;
  final int? karaokeIdx; // 对应逐字行下标
  const _KaraokeDisplayItem.line(this.line, this.karaokeIdx) : credit = null;
  const _KaraokeDisplayItem.credit(this.credit)
    : line = null,
      karaokeIdx = null;
}

class FullLyricDisplay extends StatefulWidget {
  final bool tapToSeek;
  const FullLyricDisplay({super.key, this.tapToSeek = true});

  @override
  State<FullLyricDisplay> createState() => _FullLyricDisplayState();
}

class _FullLyricDisplayState extends State<FullLyricDisplay> {
  final AudioPlayerService _audioPlayer = AudioPlayerService();
  StreamSubscription<String>? _lyricSub;
  StreamSubscription<List<LyricLine>>? _lyricsSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<KaraokeSong?>? _karaokeSub;
  List<LyricLine> _lyrics = [];
  int _currentIndex = -1;
  // 逐字卡拉OK数据（就绪后自动切换显示模式）
  KaraokeSong? _karaoke;
  int _karaokeIndex = -1;
  // 逐字模式显示列表：逐字行 + 从 LRC 补回的制作名单行（歌手/作曲等）
  List<_KaraokeDisplayItem> _karaokeDisplay = [];
  final Map<int, int> _karaokeDisplayIdx = {}; // 逐字行下标 → 显示下标
  // 填充进度走 ValueNotifier 细粒度刷新：只有当前行监听它，
  // 避免每个位置 tick 都重建整个歌词列表（卡顿根源）
  final ValueNotifier<double> _karaokeTick = ValueNotifier(0.0);
  late final ScrollController _scrollController;
  bool _userScrolling = false;
  Timer? _scrollResumeTimer;
  final Map<int, GlobalKey> _itemKeys = {};
  static const double _topPadding = 200.0;
  static const double _bottomPadding = 500.0;

  bool get _karaokeMode => _karaoke != null && _karaoke!.lines.isNotEmpty;
  int get _activeIndex => _karaokeMode
      ? (_karaokeIndex >= 0 ? (_karaokeDisplayIdx[_karaokeIndex] ?? -1) : -1)
      : _currentIndex;
  int get _itemCount => _karaokeMode ? _karaokeDisplay.length : _lyrics.length;

  /// 合并逐字行与制作名单行：对齐管线按 kCreditLineRe 剔除了制作名单，
  /// 这里从 _lyrics 中找回这些行，按时间轴插回逐字行之间
  void _rebuildKaraokeDisplay() {
    final k = _karaoke;
    _karaokeDisplay = [];
    _karaokeDisplayIdx.clear();
    if (k == null || k.lines.isEmpty) return;
    final credits = <LyricLine>[
      for (final l in _lyrics)
        if (kCreditLineRe.hasMatch(l.text)) l,
    ];
    int ci = 0;
    for (int i = 0; i < k.lines.length; i++) {
      final line = k.lines[i];
      while (ci < credits.length &&
          credits[ci].timestamp.inMilliseconds / 1000.0 <= line.start) {
        _karaokeDisplay.add(_KaraokeDisplayItem.credit(credits[ci]));
        ci++;
      }
      _karaokeDisplayIdx[i] = _karaokeDisplay.length;
      _karaokeDisplay.add(_KaraokeDisplayItem.line(line, i));
    }
    for (; ci < credits.length; ci++) {
      _karaokeDisplay.add(_KaraokeDisplayItem.credit(credits[ci]));
    }
  }

  void _afterLayout(VoidCallback callback) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback();
    });
  }

  @override
  void initState() {
    super.initState();
    _lyrics = _audioPlayer.lyrics;
    _currentIndex = _audioPlayer.currentLyricIndex;
    _karaoke = _audioPlayer.karaoke;
    _rebuildKaraokeDisplay();
    _scrollController = ScrollController();
    _afterLayout(_doScroll);

    _lyricsSub = _audioPlayer.onLyricsChanged.listen((lyrics) {
      if (mounted) {
        setState(() {
          _lyrics = lyrics;
          _currentIndex = _audioPlayer.currentLyricIndex;
          _rebuildKaraokeDisplay();
        });
        if (!_userScrolling) _doScroll();
      }
    });

    _karaokeSub = _audioPlayer.onKaraokeChanged.listen((k) {
      if (!mounted) return;
      setState(() {
        _karaoke = k;
        _karaokeIndex = -1;
        _rebuildKaraokeDisplay();
      });
      if (!_userScrolling) _doScroll();
    });

    _lyricSub = _audioPlayer.onLyricChanged.listen((_) {
      if (mounted) {
        setState(() {
          _currentIndex = _audioPlayer.currentLyricIndex;
        });
        if (!_userScrolling) _doScroll();
      }
    });

    _positionSub = _audioPlayer.onPositionChanged.listen((pos) {
      if (!mounted) return;
      if (_karaokeMode) {
        // 逐字模式：填充进度只推给 ValueNotifier（仅当前行重建），
        // 行索引变化才 setState 列表
        final t = pos.inMilliseconds / 1000.0;
        _karaokeTick.value = t;
        final newIndex = _karaoke!.lineIndexAt(t);
        if (newIndex != _karaokeIndex) {
          setState(() {
            _karaokeIndex = newIndex;
          });
          if (!_userScrolling) _doScroll();
        }
        return;
      }
      final newIndex = _audioPlayer.currentLyricIndex;
      if (newIndex != _currentIndex) {
        setState(() {
          _currentIndex = newIndex;
        });
        if (!_userScrolling) _doScroll();
      }
    });
  }

  // 区分用户拖动与程序自动滚动：只有带 dragDetails（手指触摸拖动）的
  // 滚动通知才算用户操作；程序 animateTo 产生的通知 dragDetails 为 null
  void _onUserDragStart() {
    _userScrolling = true;
    _scrollResumeTimer?.cancel();
  }

  void _onUserDragEnd() {
    if (!_userScrolling) return;
    _scrollResumeTimer?.cancel();
    // 用户停手3秒后恢复自动跟随；若当前行仍在可视区域内则不打断浏览
    _scrollResumeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        _userScrolling = false;
        if (!_isCurrentLineVisible()) _doScroll();
      }
    });
  }

  // 当前行是否完整在可视区域内
  bool _isCurrentLineVisible() {
    if (_activeIndex < 0) return false;
    final ctx = _itemKeys[_activeIndex]?.currentContext;
    if (ctx == null || !ctx.mounted) return false; // 未构建 = 不可见
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final revealTop = RenderAbstractViewport.of(
      box,
    ).getOffsetToReveal(box, 0.0).offset;
    final itemH = box.size.height;
    final offset = _scrollController.offset;
    final viewportH = _scrollController.position.viewportDimension;
    return revealTop >= offset && revealTop + itemH <= offset + viewportH;
  }

  // 自动滚动到当前高亮歌词行（行顶精确停靠在视口 28% 高度处，在顶部渐隐区之下）
  void _doScroll() {
    if (_activeIndex < 0 || _itemCount == 0) return;
    if (!_scrollController.hasClients) return;
    final anchorY = _scrollController.position.viewportDimension * 0.28;
    final key = _itemKeys[_activeIndex];

    if (key != null && key.currentContext != null) {
      // 情况1：当前歌词行已构建，按其真实渲染位置精确计算目标偏移
      _scrollToLine(
        key.currentContext!,
        anchorY,
        const Duration(milliseconds: 300),
      );
    } else {
      // 情况2：目标行被懒加载回收：按已构建行的平均高度估算粗滚，
      // 行构建出来后再做一次精确定位
      double sum = 0;
      int count = 0;
      _itemKeys.forEach((_, k) {
        final c = k.currentContext;
        if (c != null && c.mounted) {
          final b = c.findRenderObject() as RenderBox?;
          if (b != null && b.hasSize) {
            sum += b.size.height;
            count++;
          }
        }
      });
      final estimatedItemHeight = count > 0 ? sum / count : 46.0;
      final targetOffset =
          _activeIndex * estimatedItemHeight + _topPadding - anchorY;
      final clampedOffset = targetOffset.clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController
          .animateTo(
            clampedOffset,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          )
          .then((_) {
            // 第二步：item构建完成后精确停靠
            _afterLayout(() {
              if (!mounted) return;
              final key = _itemKeys[_activeIndex];
              if (key != null && key.currentContext != null) {
                _scrollToLine(
                  key.currentContext!,
                  anchorY,
                  const Duration(milliseconds: 150),
                );
              }
            });
          });
    }
  }

  // 用目标行的真实渲染位置计算滚动偏移，保证每行停靠位置一致
  void _scrollToLine(BuildContext ctx, double anchorY, Duration duration) {
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final viewport = RenderAbstractViewport.of(box);
    final target = (viewport.getOffsetToReveal(box, 0.0).offset - anchorY)
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(
      target,
      duration: duration,
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _lyricSub?.cancel();
    _lyricsSub?.cancel();
    _positionSub?.cancel();
    _karaokeSub?.cancel();
    _karaokeTick.dispose();
    _scrollResumeTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 没有歌词时不显示任何占位内容
    if (_itemCount == 0) {
      return const SizedBox.shrink();
    }

    // 上下渐隐遮罩：歌词靠近边缘时淡出，避免生硬截断
    // 渐隐区收窄（顶 22%→12%，底 15%→8%）且坡度更陡，边缘淡出更快更明显
    return ShaderMask(
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          Colors.white,
          Colors.white,
          Colors.transparent,
        ],
        stops: [0.0, 0.12, 0.92, 1.0],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n is ScrollStartNotification) {
            if (n.dragDetails != null) _onUserDragStart();
          } else if (n is ScrollUpdateNotification) {
            if (n.dragDetails != null) _onUserDragStart();
          } else if (n is ScrollEndNotification) {
            _onUserDragEnd();
          }
          return false;
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 25),
          // 手指按下瞬间记录"当时是否允许点击跳转"。
          // 不能用 onTap 是否为 null 判断：沉浸模式下按下时页面级 Listener
          // 会先恢复播控并重建本组件，抬起时 onTap 又变回可跳转，导致误跳。
          child: Listener(
            onPointerDown: (_) => _tapStartedWhileSeekable = widget.tapToSeek,
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.only(
                top: _topPadding,
                bottom: _bottomPadding,
              ),
              itemCount: _itemCount,
              itemBuilder: (context, index) {
                final isCurrent = index == _activeIndex;

                if (!_itemKeys.containsKey(index)) {
                  _itemKeys[index] = GlobalKey();
                }

                final distance = (index - _activeIndex).abs();
                final scale = isCurrent ? 1.0 : 0.8;
                final opacity = isCurrent
                    ? 1.0
                    : distance <= 2
                    ? 0.6
                    : distance <= 5
                    ? 0.35
                    : 0.15;

                final Widget content;
                if (_karaokeMode) {
                  final item = _karaokeDisplay[index];
                  final kLine = item.line;
                  if (kLine == null) {
                    // 制作名单行：普通文本展示，不参与逐字高亮
                    content = Text(
                      item.credit!.text,
                      textAlign: TextAlign.left,
                      style: const TextStyle(
                        fontSize: 24,
                        color: Colors.white,
                        height: 1.4,
                      ),
                    );
                  } else {
                    content = item.karaokeIdx == _karaokeIndex
                        ? _KaraokeActiveLine(line: kLine, tick: _karaokeTick)
                        : _buildKaraokeLine(kLine, false, 0.0);
                  }
                } else {
                  final lyric = _lyrics[index];
                  content = Text(
                    lyric.text,
                    textAlign: TextAlign.left,
                    // 不加 shadow 辉光：溢出行边界的发光会被列表合成层硬裁出直边
                    style: TextStyle(
                      fontSize: isCurrent ? 30 : 24,
                      fontWeight: isCurrent
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: Colors.white,
                      height: 1.4,
                    ),
                  );
                }

                return GestureDetector(
                  key: _itemKeys[index],
                  // 按下时不允许跳转（沉浸模式）则松手不跳转，点击仅用于恢复播控
                  onTap: () {
                    if (!_tapStartedWhileSeekable) return;
                    if (_karaokeMode) {
                      final item = _karaokeDisplay[index];
                      if (item.line == null) return; // 制作名单行不可点击跳转
                      _audioPlayer.seek(
                        Duration(
                          milliseconds: (item.line!.start * 1000).round(),
                        ),
                      );
                    } else {
                      _audioPlayer.seek(_lyrics[index].timestamp);
                    }
                    _userScrolling = false;
                    _scrollResumeTimer?.cancel();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: AnimatedScale(
                      scale: scale,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOut,
                      alignment: Alignment.centerLeft,
                      child: AnimatedOpacity(
                        opacity: opacity,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOut,
                        child: content,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  // ---- 逐字卡拉OK行渲染 ----

  static const double _sungOpacity = 1.0; // 已唱
  static const double _unsungOpacity = 0.38; // 未唱

  // 按下瞬间快照：按下时是否允许点击歌词跳转（沉浸模式按下时为 false）
  bool _tapStartedWhileSeekable = true;

  // 词字符（拉丁字母/数字）：补空格判断用
  static final RegExp _wordCharSp = RegExp(r'[A-Za-zÀ-ɏḀ-ỿ0-9]');
  // CJK 或全角标点：两侧永不补空格
  static final RegExp _cjkOrFullwidthSp = RegExp(r'[㐀-䶿一-鿿豈-﫿　-〿＀-￯]');
  // 闭合标点：右侧可接空格
  static final RegExp _closingPunctSp = RegExp(r'''[,.!?;:)\]}'"`’”]''');
  // 开放标点：左侧可接空格
  static final RegExp _openingPunctSp = RegExp(r'''[(\[{‘“（【《「『]''');

  /// 相邻 token 补空格规则（tokenize 丢弃了原文空白）：
  /// 左为词字符/闭合标点、右为词字符/开放标点且至少一侧是词字符才补；
  /// CJK 与全角标点永不补
  static bool _needsSpaceBetween(String prevText, String curText) {
    if (prevText.isEmpty || curText.isEmpty) return false;
    final l = prevText[prevText.length - 1];
    final r = curText[0];
    if (_cjkOrFullwidthSp.hasMatch(l) || _cjkOrFullwidthSp.hasMatch(r)) {
      return false;
    }
    final lWord = _wordCharSp.hasMatch(l);
    final rWord = _wordCharSp.hasMatch(r);
    if (!(lWord || _closingPunctSp.hasMatch(l))) return false;
    if (!(rWord || _openingPunctSp.hasMatch(r))) return false;
    return lWord || rWord;
  }

  Widget _buildKaraokeLine(KaraokeLine line, bool isCurrent, double t) {
    if (!isCurrent) {
      return Text(
        line.text,
        textAlign: TextAlign.left,
        style: TextStyle(fontSize: 24, color: Colors.white, height: 1.4),
      );
    }
    // 当前行交给独立 widget：Ticker 逐帧平滑填充
    return _KaraokeActiveLine(line: line, tick: _karaokeTick);
  }

  /// 构建当前行 token 渲染（按时间 t 决定每个字：已唱/未唱/填充中）
  /// [fontSize] 大歌词 30 / 小歌词 16；不要加 shadow 辉光——列表内每行都有
  /// AnimatedOpacity/Scale 合成层，辉光溢出行边界会被图层硬裁出直边（视觉 bug）
  static List<InlineSpan> _buildKaraokeSpans(
    KaraokeLine line,
    double t, {
    double fontSize = 30,
  }) {
    final base = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.bold,
      color: Colors.white,
      height: 1.4,
    );
    final sungStyle = base.copyWith(
      color: Colors.white.withValues(alpha: _sungOpacity),
    );
    final unsungStyle = base.copyWith(
      color: Colors.white.withValues(alpha: _unsungOpacity),
    );

    final spans = <InlineSpan>[];
    for (int i = 0; i < line.tokens.length; i++) {
      final tok = line.tokens[i];
      // 相邻 token 补空格（tokenize 时丢弃了原文空白）
      if (spans.isNotEmpty && i > 0) {
        final prev = line.tokens[i - 1];
        if (!prev.isSpace &&
            !tok.isSpace &&
            _needsSpaceBetween(prev.text, tok.text)) {
          spans.add(TextSpan(text: ' ', style: unsungStyle));
        }
      }
      if (tok.isSpace) {
        spans.add(TextSpan(text: tok.text, style: unsungStyle));
        continue;
      }
      if (t >= tok.end) {
        spans.add(TextSpan(text: tok.text, style: sungStyle));
      } else if (t <= tok.start) {
        spans.add(TextSpan(text: tok.text, style: unsungStyle));
      } else {
        // 正在唱的字：横向渐变填充（左白右灰），平滑过渡
        final frac = ((t - tok.start) / (tok.end - tok.start)).clamp(0.0, 1.0);
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: ShaderMask(
              shaderCallback: (rect) {
                final edge = 1.0 / mathMax(rect.width, 1.0);
                final p = (frac * (1 + 2 * edge) - edge).clamp(0.0, 1.0);
                return LinearGradient(
                  colors: const [
                    Colors.white,
                    Colors.white,
                    Colors.white38,
                    Colors.white38,
                  ],
                  stops: [0.0, p, p, 1.0],
                ).createShader(rect);
              },
              blendMode: BlendMode.srcIn,
              child: Text(
                tok.text,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  height: 1.4,
                ),
              ),
            ),
          ),
        );
      }
    }
    return spans;
  }
}

/// 当前行逐字填充 widget：位置流只有约 200ms 一跳（一个字的填充期只够 3 帧），
/// 用 Ticker 每帧向最新锚点指数收敛，把填充插值到 60fps；暂停/seek 自动跟随锚点。
class _KaraokeActiveLine extends StatefulWidget {
  final KaraokeLine line;
  final ValueNotifier<double> tick;
  final double fontSize;
  const _KaraokeActiveLine({
    required this.line,
    required this.tick,
    this.fontSize = 30,
  });

  @override
  State<_KaraokeActiveLine> createState() => _KaraokeActiveLineState();
}

class _KaraokeActiveLineState extends State<_KaraokeActiveLine>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _disp = 0; // 平滑后的显示时间
  Duration? _lastElapsed;
  double _lastAnchor = 0;
  Duration _lastAnchorAt = Duration.zero; // 锚点最后变化的时刻（ticker 时基）

  @override
  void initState() {
    super.initState();
    _disp = widget.tick.value;
    _lastAnchor = widget.tick.value;
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    final dt = _lastElapsed == null
        ? 0.0
        : (elapsed - _lastElapsed!).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    if (dt <= 0) return;
    final anchor = widget.tick.value;
    if (anchor != _lastAnchor) {
      _lastAnchor = anchor;
      _lastAnchorAt = elapsed;
    }
    // 时钟外推：播放时显示时间以 1 倍速自走（锚点 200ms 才来一次），
    // 锚点只做微小校正 → 零系统性延迟；锚点 ~300ms 未更新视为暂停，停走
    final sinceAnchor = (elapsed - _lastAnchorAt).inMicroseconds / 1e6;
    final predicted = sinceAnchor < 0.30 ? anchor + sinceAnchor : anchor;
    final err = predicted - _disp;
    double next;
    if (err.abs() > 1.0) {
      next = predicted; // seek 跳变直接贴齐
    } else {
      next = _disp + err * (dt / (dt + 0.10)); // 慢校正，消除累计漂移
      if (err.abs() < 0.0015) next = predicted;
    }
    if (next != _disp) {
      setState(() => _disp = next);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: _FullLyricDisplayState._buildKaraokeSpans(
          widget.line,
          _disp,
          fontSize: widget.fontSize,
        ),
      ),
      textAlign: TextAlign.left,
    );
  }
}

// math.max 简写（避免整文件引入 dart:math）
double mathMax(double a, double b) => a > b ? a : b;
