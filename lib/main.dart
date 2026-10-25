import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:marquee/marquee.dart';
import 'package:netease_music_api/netease_music_api.dart';
import 'screens/agreement_page.dart';
import 'screens/home_page.dart';
import 'screens/player_page.dart';
import 'screens/profile_page.dart';
import 'services/audio_player_handler.dart';
import 'services/audio_player_service.dart';
import 'services/app_init.dart';
import 'models/song_model.dart';
import 'utils/navigation_guard.dart';
import 'widgets/design_dialog.dart';
import 'widgets/update_checker.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AudioService.init(
    builder: () => AudioPlayerHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.suchmusic.audio.v2',
      androidNotificationChannelName: 'Such Music',
      androidNotificationChannelDescription: '音乐播放控制',
      androidStopForegroundOnPause: false,
      androidNotificationIcon: 'drawable/ic_notification',
      androidShowNotificationBadge: true,
    ),
  );
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
      systemNavigationBarContrastEnforced: false,
    ),
  );

  runApp(const MyApp());
  // debug: true 会挂 PrettyDioLogger 全量打印每个接口的响应体（歌单详情能打几千行），关闭
  await NeteaseMusicApi.init(debug: false);
  await AudioPlayerService().init();
  markInitialized();
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      ),
      child: MaterialApp(
        title: 'Such Music',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          useMaterial3: true,
        ),
        home: const MainShell(),
      ),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;
  final AudioPlayerService _audioPlayer = AudioPlayerService();
  StreamSubscription<SongModel?>? _currentSongSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _trialSub;
  SongModel? _currentSong;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  // 播放胶囊封面拖动手势：原始位移判定方向（含上滑暂停），
  // 跟手反馈仅水平方向；切歌滑动动画与播放页大封面一致
  Offset _miniPanDelta = Offset.zero;
  Offset _miniDragOffset = Offset.zero;
  bool _miniDragging = false;
  Offset? _miniDragExitBegin;
  // 拖动切歌后的冻结：封面停在松手位置不回弹，出场/入场动画通过
  // _miniDragExitBegin 补偿轨迹，300ms 后外层位移才瞬时归零（两帧衔接无缝）
  bool _miniFrozen = false;
  Timer? _miniSnapTimer;
  Timer? _miniExitTimer;
  int _miniSlideDir = 0;
  int _lastMiniIndex = -1;

  final List<Widget> _pages = const [HomePage(), ProfilePage()];

  @override
  void initState() {
    super.initState();
    _currentSong = _audioPlayer.currentSong;
    _position = _audioPlayer.position;
    _duration = _audioPlayer.duration;
    _lastMiniIndex = _audioPlayer.currentIndex;
    _currentSongSub = _audioPlayer.onCurrentSongChanged.listen((song) {
      if (mounted) {
        // 依据播放列表索引变化判定切歌方向，驱动胶囊封面滑动动画
        final idx = _audioPlayer.currentIndex;
        final switched =
            idx >= 0 && _lastMiniIndex >= 0 && idx != _lastMiniIndex;
        if (switched) {
          final len = _audioPlayer.playlist.length;
          if (_lastMiniIndex == len - 1 && idx == 0) {
            _miniSlideDir = 1; // 末尾回环到开头，视为下一首
          } else if (_lastMiniIndex == 0 && idx == len - 1) {
            _miniSlideDir = -1; // 开头回环到末尾，视为上一曲
          } else {
            _miniSlideDir = idx > _lastMiniIndex ? 1 : -1;
          }
        } else {
          _miniSlideDir = 0;
        }
        _lastMiniIndex = idx;
        setState(() {
          _currentSong = song ?? _audioPlayer.currentSong;
          if (_miniFrozen) {
            if (switched) {
              // 拖动切歌：出场动画随本次 setState 启动（子组件 key 换成新歌
              // id）。外层跟手位移此时仍生效，出场/入场轨迹已按它补偿，
              // 300ms 后（旧内容滑出灰区、新内容仍在灰区外）外层位移瞬时
              // 归零并同帧清除补偿，总位置保持连续无跳变
              _miniSnapTimer?.cancel();
              _miniSnapTimer = Timer(const Duration(milliseconds: 300), () {
                if (mounted) {
                  setState(() {
                    _miniDragOffset = Offset.zero;
                    _miniDragExitBegin = null;
                  });
                }
              });
              // 出场动画结束后解除冻结、清除轨迹补偿
              _miniExitTimer?.cancel();
              _miniExitTimer = Timer(const Duration(milliseconds: 650), () {
                if (mounted) {
                  setState(() {
                    _miniFrozen = false;
                    _miniDragExitBegin = null;
                  });
                }
              });
            } else {
              // 未真正切歌（重播当前歌）：解除冻结，250ms 回弹归位
              _miniFrozen = false;
              _miniDragOffset = Offset.zero;
              _miniDragExitBegin = null;
            }
          }
        });
      }
    });
    _positionSub = _audioPlayer.onPositionChanged.listen((pos) {
      if (mounted) {
        setState(() => _position = pos);
      }
    });
    _durationSub = _audioPlayer.onDurationChanged.listen((dur) {
      if (mounted) {
        setState(() => _duration = dur);
      }
    });
    // VIP 试听片段提示：无权益（非 VIP 且免费听时长未生效）时服务端返回试听地址
    _trialSub = _audioPlayer.onTrialPlaybackChanged.listen((isTrial) {
      if (mounted && isTrial) {
        DesignToast.show(context, 'VIP歌曲试听中');
      }
    });
    // 首次启动（或协议版本更新后）弹出《用户协议》确认弹窗
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showAgreementConsentDialogIfNeed(context);
      // 启动 3 秒后静默检查更新：有新版本时弹提示（远端 force 为 true 时强制更新，无法跳过）
      Timer(const Duration(seconds: 3), () {
        if (mounted) UpdateChecker.check(context, silent: true);
      });
    });
  }

  @override
  void dispose() {
    _currentSongSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _trialSub?.cancel();
    _miniSnapTimer?.cancel();
    _miniExitTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      backgroundColor: const Color(0xFFF1F2F4),
      extendBody: true,
      body: Stack(
        children: [
          IndexedStack(index: _currentIndex, children: _pages),
          Positioned(
            left: 0,
            right: 0,
            bottom: 10 + bottomPadding,
            child: _buildTabBar(),
          ),
        ],
      ),
    );
  }

  /// 播放胶囊封面拖动手势：跟手移动，左滑下一首、右滑上一首、上滑暂停/恢复
  /// 距离超过 40px 或松手速度超过 250px/s 即触发，取分量更大的轴判定方向
  void _handleMiniPanStart(DragStartDetails details) {
    // 新一次拖动：清掉上一轮冻结/定时器/补偿
    _miniSnapTimer?.cancel();
    _miniExitTimer?.cancel();
    setState(() {
      _miniDragging = true;
      _miniFrozen = false;
      _miniDragExitBegin = null;
      _miniPanDelta = Offset.zero;
      _miniDragOffset = Offset.zero;
    });
  }

  void _handleMiniPanUpdate(DragUpdateDetails details) {
    setState(() {
      _miniPanDelta += details.delta;
      // 跟手反馈只保留水平方向，竖直拖动封面不动
      _miniDragOffset += Offset(details.delta.dx, 0);
    });
  }

  void _handleMiniPanEnd(DragEndDetails details) {
    final v = details.velocity.pixelsPerSecond;
    final d = _miniPanDelta;
    final dx = d.dx.abs() >= 40 || v.dx.abs() >= 250 ? d.dx : 0.0;
    final dy = d.dy.abs() >= 40 || v.dy.abs() >= 250 ? d.dy : 0.0;

    if (dx != 0 && dx.abs() >= dy.abs()) {
      // 横向拖动切歌：封面冻结在松手位置不回弹，等出场动画开始时
      // 由切歌回调解除冻结并接棒滑出，避免回弹动画抢跑
      setState(() {
        _miniDragging = false;
        _miniFrozen = true;
        _miniDragExitBegin = _miniDragOffset;
        _miniSlideDir = dx < 0 ? 1 : -1;
      });
      if (dx < 0) {
        _audioPlayer.playNext();
      } else {
        _audioPlayer.playPrevious();
      }
      // 兜底：切歌回调迟迟不来（如重播当前歌），解除冻结回弹归位
      _miniSnapTimer?.cancel();
      _miniSnapTimer = Timer(const Duration(milliseconds: 800), () {
        if (mounted) {
          setState(() {
            _miniFrozen = false;
            _miniDragOffset = Offset.zero;
            _miniDragExitBegin = null;
          });
        }
      });
    } else {
      // 上滑暂停/恢复，或未达阈值：封面回弹归位
      if (dy < 0 && dy.abs() > dx.abs()) {
        _audioPlayer.togglePlayPause();
      }
      setState(() {
        _miniDragging = false;
        _miniDragOffset = Offset.zero;
      });
    }
  }

  Widget _buildTabBar() {
    final screenWidth = MediaQuery.of(context).size.width;
    final barWidth = screenWidth * 0.85 - 44;
    final barHeight = 72.0;
    final coverSize = barWidth * (42 / 320);
    final coverTop = (barHeight - coverSize) / 2;
    // 歌曲信息区宽度（胶囊内歌名+歌手文字列）
    final textWidth = barWidth * (74 / 320);
    final iconTop = (barHeight - 36) / 2;
    final pillLeft = barWidth * (91 / 320);
    final pillWidth = barWidth * (138 / 320);

    return Center(
      child: GestureDetector(
        onTapUp: (details) {
          final dx = details.localPosition.dx;
          final dy = details.localPosition.dy;
          final inPill =
              dx >= pillLeft &&
              dx <= pillLeft + pillWidth &&
              dy >= 8 &&
              dy <= 64;
          if (!inPill) return;
          if (!NavigationGuard.isPlayerPageOpen) {
            NavigationGuard.isPlayerPageOpen = true;
            Navigator.push(
              context,
              PageRouteBuilder(
                pageBuilder: (context, animation, secondaryAnimation) =>
                    const PlayerPage(),
                transitionsBuilder:
                    (context, animation, secondaryAnimation, child) {
                      final tween = Tween(
                        begin: const Offset(0.0, 1.0),
                        end: Offset.zero,
                      ).chain(CurveTween(curve: Curves.easeOutCubic));
                      return SlideTransition(
                        position: animation.drive(tween),
                        child: child,
                      );
                    },
              ),
            ).then((_) {
              NavigationGuard.isPlayerPageOpen = false;
            });
          }
        },
        child: Container(
          width: barWidth,
          height: barHeight,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(100),
          ),
          child: Stack(
            children: [
              // 灰色小胶囊：圆角裁剪容器，封面/歌曲信息滑动限制在此区域内
              Positioned(
                left: barWidth * (91 / 320),
                top: 8,
                width: barWidth * (138 / 320),
                height: 56,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(323),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: Container(color: const Color(0xFFF1F2F4)),
                      ),
                      if (_currentSong != null)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: PillProgressPainter(
                                progress: _duration.inMilliseconds > 0
                                    ? _position.inMilliseconds /
                                          _duration.inMilliseconds
                                    : 0,
                                pillWidth: barWidth * (138 / 320),
                                pillHeight: 56,
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        left: barWidth * (6 / 320),
                        top: coverTop - 8,
                        child: GestureDetector(
                          // 胶囊封面手势：左滑下一首、右滑上一首、上滑暂停/恢复
                          onPanStart: _handleMiniPanStart,
                          onPanUpdate: _handleMiniPanUpdate,
                          onPanEnd: _handleMiniPanEnd,
                          // 拖动跟手：拖动中瞬时跟随，松手回弹时 250ms 缓动归位
                          child: AnimatedSlide(
                            // 拖动中瞬时跟手；切歌冻结期不回弹（停在松手位置）；
                            // 其余情况 250ms 缓动归位
                            duration: _miniDragging
                                ? const Duration(milliseconds: 1)
                                : _miniFrozen
                                ? Duration.zero
                                : const Duration(milliseconds: 250),
                            curve: Curves.easeOutCubic,
                            offset: Offset(
                              _miniDragOffset.dx / coverSize,
                              _miniDragOffset.dy / coverSize,
                            ),
                            child: AnimatedSwitcher(
                              // 前半段旧封面滑出，后半段新封面才滑入，
                              // 与歌曲信息区共用 _miniSlideTransitionBuilder
                              duration: const Duration(milliseconds: 600),
                              // 不裁剪：滑动位移由灰色区域外层 ClipRRect 统一裁剪
                              layoutBuilder:
                                  (
                                    Widget? currentChild,
                                    List<Widget> previousChildren,
                                  ) {
                                    return Stack(
                                      clipBehavior: Clip.none,
                                      alignment: Alignment.center,
                                      children: [
                                        ...previousChildren,
                                        ?currentChild,
                                      ],
                                    );
                                  },
                              transitionBuilder:
                                  (Widget child, Animation<double> animation) {
                                    // 位移比例：灰区宽+封面宽——滑出灰色胶囊
                                    // 裁剪范围即可，不必跑整个屏幕
                                    final pillW = barWidth * (138 / 320);
                                    final frac = (pillW + coverSize) / coverSize;
                                    // 拖动切歌补偿：冻结期间外层跟手位移仍生效，
                                    // 出/入位移各减去该量，300ms 外层归零后总位置连续
                                    final comp = _miniDragExitBegin == null
                                        ? Offset.zero
                                        : Offset(
                                            _miniDragExitBegin!.dx / coverSize,
                                            _miniDragExitBegin!.dy / coverSize,
                                          );
                                    return _miniSlideTransitionBuilder(
                                      child,
                                      animation,
                                      frac,
                                      comp,
                                    );
                                  },
                              child: ClipOval(
                                key: ValueKey(_currentSong?.id),
                                child: Container(
                                  width: coverSize,
                                  height: coverSize,
                                  color: const Color(0xFFE8E8E8),
                                  child: _buildMiniCoverImage(coverSize),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: barWidth * (54 / 320),
                        top: coverTop - 8 + (coverSize - 32) / 2,
                        width: barWidth * (74 / 320),
                        child: GestureDetector(
                          // 歌曲信息区同样支持拖动手势（左滑下一首/右滑上一首/上滑暂停）
                          onPanStart: _handleMiniPanStart,
                          onPanUpdate: _handleMiniPanUpdate,
                          onPanEnd: _handleMiniPanEnd,
                          // 歌曲信息与封面共用切歌滑动动画：旧信息滑出、新信息滑入；
                          // 外层同款 AnimatedSlide 让拖动封面时信息一起跟手
                          child: AnimatedSlide(
                            duration: _miniDragging
                                ? const Duration(milliseconds: 1)
                                : _miniFrozen
                                ? Duration.zero
                                : const Duration(milliseconds: 250),
                            curve: Curves.easeOutCubic,
                            offset: Offset(
                              _miniDragOffset.dx / textWidth,
                              _miniDragOffset.dy / textWidth,
                            ),
                            // 歌曲信息与封面共用切歌滑动动画：旧信息滑出、新信息滑入
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 600),
                              layoutBuilder:
                                  (
                                    Widget? currentChild,
                                    List<Widget> previousChildren,
                                  ) {
                                    return Stack(
                                      clipBehavior: Clip.none,
                                      alignment: Alignment.centerLeft,
                                      children: [
                                        ...previousChildren,
                                        ?currentChild,
                                      ],
                                    );
                                  },
                              transitionBuilder:
                                  (Widget child, Animation<double> animation) {
                                    // 拖动补偿按文字区宽度换算：300ms 外层跟手位移
                                    // 归零前后总位置连续
                                    final comp = _miniDragExitBegin == null
                                        ? Offset.zero
                                        : Offset(
                                            _miniDragExitBegin!.dx / textWidth,
                                            _miniDragExitBegin!.dy / textWidth,
                                          );
                                    // 位移按文字区宽度算足灰区宽：滑出灰色
                                    // 胶囊裁剪范围即可，不必跑整个屏幕
                                    final pillW = barWidth * (138 / 320);
                                    final frac = (pillW + textWidth) / textWidth;
                                    return _miniSlideTransitionBuilder(
                                      child,
                                      animation,
                                      frac,
                                      comp,
                                    );
                                  },
                              child: KeyedSubtree(
                                key: ValueKey(_currentSong?.id),
                                child: _currentSong != null
                                    ? Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          _buildScrollText(
                                            _currentSong!.name,
                                            const TextStyle(
                                              color: Colors.black,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w500,
                                            ),
                                            textWidth,
                                          ),
                                          const SizedBox(height: 2),
                                          _buildScrollText(
                                            _currentSong!.artist,
                                            TextStyle(
                                              color: Colors.black.withValues(
                                                alpha: 0.5,
                                              ),
                                              fontSize: 10,
                                            ),
                                            textWidth,
                                          ),
                                        ],
                                      )
                                    : Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            '暂无播放',
                                            style: TextStyle(
                                              color: Colors.black.withValues(
                                                alpha: 0.4,
                                              ),
                                              fontSize: 12,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: barWidth * (30 / 320),
                top: iconTop,
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => setState(() => _currentIndex = 0),
                      customBorder: const CircleBorder(),
                      child: Center(
                        child: SvgPicture.string(
                          '<svg viewBox="0 0 24 24"><path fill="${_currentIndex == 0 ? '#2F84FEFF' : '#979797FF'}" d="M13.2 2.65a2 2 0 0 0-2.4 0l-7 5.25A2 2 0 0 0 3 9.5V19a2 2 0 0 0 2 2h3.9a1.1 1.1 0 0 0 1.1-1.1V15a2 2 0 1 1 4 0v4.9a1.1 1.1 0 0 0 1.1 1.1H19a2 2 0 0 0 2-2V9.5a2 2 0 0 0-.8-1.6z"/></svg>',
                          width: 22,
                          height: 22,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: barWidth * (256 / 320),
                top: iconTop,
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => setState(() => _currentIndex = 1),
                      customBorder: const CircleBorder(),
                      child: Center(
                        child: SvgPicture.string(
                          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="${_currentIndex == 1 ? '#2F84FEFF' : '#979797FF'}" d="M12 2c5.523 0 10 4.477 10 10s-4.477 10-10 10S2 17.523 2 12 6.477 2 12 2m0 2a8 8 0 1 0 0 16 8 8 0 0 0 0-16m3.167 8c1.012 0 1.833.82 1.833 1.833V14a5 5 0 0 1-10 0v-.167C7 12.821 7.82 12 8.833 12zM15 14H9a3 3 0 1 0 6 0M9 7a1 1 0 0 1 .993.883L10 8v2a1 1 0 0 1-1.993.117L8 10V8a1 1 0 0 1 1-1m5.293.293a1 1 0 0 1 1.497 1.32l-.083.094-.293.293.293.293a1 1 0 0 1-1.32 1.497l-.094-.083-1-1a1 1 0 0 1-.083-1.32l.083-.094z"/></svg>',
                          width: 22,
                          height: 22,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 胶囊内容（封面/歌曲信息）切歌滑动的公共 transitionBuilder：
  /// 前半段旧内容滑出屏幕，后半段新内容才滑入。不用 switchIn/OutCurve：
  /// CurvedAnimation 在端点（t=0/1）会跳过曲线返回原始值导致第一帧闪跳，
  /// 改用原始 animation.value 自行分段计算，端点确定。
  /// frac 为相对 child 宽度的位移比例；comp 为拖动跟手位移补偿
  Widget _miniSlideTransitionBuilder(
    Widget child,
    Animation<double> animation,
    double frac,
    Offset comp,
  ) {
    final dir = _miniSlideDir == 0 ? 1 : _miniSlideDir;
    // 子组件按歌曲 id 区分，动画不等封面加载立即开始
    final incoming = child.key == ValueKey(_currentSong?.id);
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
          v = Curves.easeOutCubic.transform(((t - 0.5) * 2).clamp(0.0, 1.0));
          begin = enterBegin;
        } else {
          // 出场 t: 1→0，前半段从原位滑出，后半段停在屏幕外
          v = Curves.easeInCubic.transform(((1.0 - t) * 2).clamp(0.0, 1.0));
          begin = Offset.zero;
        }
        return FractionalTranslation(
          translation: Offset.lerp(begin, incoming ? Offset.zero : exitEnd, v)!,
          child: child,
        );
      },
    );
  }

  Widget _buildMiniCoverImage(double size) {
    if (_currentSong?.coverUrl == null) {
      return Image.asset(
        'assets/images/SuchMusic@1x.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
      );
    }

    final coverUrl = _currentSong!.coverUrl!;
    final cachedImage = AudioPlayerService.cachedCover(coverUrl);
    if (cachedImage != null) {
      return Image.memory(
        cachedImage,
        width: size,
        height: size,
        fit: BoxFit.cover,
      );
    }

    final lastCover = AudioPlayerService.lastCoverBytes;
    if (lastCover != null) {
      AudioPlayerService.preFetchCover(coverUrl).then((_) {
        if (mounted) setState(() {});
      });
      return Image.memory(
        lastCover,
        width: size,
        height: size,
        fit: BoxFit.cover,
      );
    }

    AudioPlayerService.preFetchCover(coverUrl).then((_) {
      if (mounted) setState(() {});
    });
    return Image.asset(
      'assets/images/SuchMusic@1x.png',
      width: size,
      height: size,
      fit: BoxFit.cover,
    );
  }

  Widget _buildScrollText(String text, TextStyle style, double maxWidth) {
    final textPainter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: double.infinity);
    if (textPainter.width <= maxWidth) {
      return SizedBox(
        width: maxWidth,
        height: 18,
        child: Text(text, style: style, maxLines: 1, softWrap: false),
      );
    }
    return SizedBox(
      width: maxWidth,
      height: 18,
      child: Marquee(
        text: text,
        style: style,
        velocity: 20,
        blankSpace: 60,
        fadingEdgeStartFraction: 0.06,
        fadingEdgeEndFraction: 0.06,
        pauseAfterRound: const Duration(seconds: 2),
      ),
    );
  }
}

class PillProgressPainter extends CustomPainter {
  final double progress;
  final double pillWidth;
  final double pillHeight;

  PillProgressPainter({
    required this.progress,
    required this.pillWidth,
    required this.pillHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final paint = Paint()
      ..color = const Color(0xFF2F84FE)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    // 路径向内偏移半个描边宽度：进度条画在灰色胶囊的 ClipRRect 裁剪区内，
    // 不内缩时描边外半圈会被圆角裁剪切掉（视觉厚度减半）。
    // x/y 都要带 inset 偏移，左右半圆弧才与外轮廓同心贴合
    final inset = paint.strokeWidth / 2;
    final radius = (pillHeight - inset * 2) / 2;
    final path = Path();

    path.moveTo(inset + radius, inset);
    path.lineTo(pillWidth - inset - radius, inset);
    path.arcToPoint(
      Offset(pillWidth - inset - radius, pillHeight - inset),
      radius: Radius.circular(radius),
      clockwise: true,
    );
    path.lineTo(inset + radius, pillHeight - inset);
    path.arcToPoint(
      Offset(inset + radius, inset),
      radius: Radius.circular(radius),
      clockwise: true,
    );

    final metric = path.computeMetrics().first;
    final totalLength = metric.length;
    final extractPath = metric.extractPath(0, totalLength * progress);

    canvas.drawPath(extractPath, paint);
  }

  @override
  bool shouldRepaint(covariant PillProgressPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.pillWidth != pillWidth ||
        oldDelegate.pillHeight != pillHeight;
  }
}
