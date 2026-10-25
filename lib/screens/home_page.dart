import 'dart:math';
import 'dart:typed_data';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../models/song_model.dart';
import '../services/music_api_service.dart';
import '../services/audio_player_service.dart';
import '../services/app_init.dart';
import 'playlist_detail_page.dart';
import 'player_page.dart';
import 'search_page.dart';
import '../widgets/local_music_view.dart';
import '../utils/navigation_guard.dart';
import '../widgets/design_dialog.dart';

enum CardType { fm, placeholder }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _apiService = MusicApiService();
  // 顶部标签当前页：0=首页 1=本地（「歌单」暂未开放）
  int _homeTabIndex = 0;
  List<PlaylistModel> _rankings = [];
  bool _loadingRankings = true;
  List<SongModel> _hotSongs = [];
  bool _loadingHotSongs = true;
  PlaylistModel? _hotChart;
  List<SongModel> _dailySongs = [];
  bool _loadingDailySongs = true;
  List<PlaylistModel> _squarePlaylists = [];
  bool _loadingSquare = true;
  final Random _random = Random();
  String? _fmCoverUrl;
  SongModel? _fmFirstSong;
  StreamSubscription<SongModel?>? _fmSongSub;
  int _cardIndex = 0;
  // 已在最后一页显示"继续滑动"提示的列表
  final Set<PageController> _hintShownCtrls = {};
  // 提示展示后该次手势已结束，下一次 overscroll 手势进入榜单
  final Set<PageController> _hintArmedCtrls = {};
  final PageController _cardPageController = PageController(viewportFraction: 0.86);
  final PageController _recommendPageController = PageController(viewportFraction: 0.95 / 1.05);
  final PageController _recommendPageController2 = PageController(viewportFraction: 0.95 / 1.05);

  @override
  void initState() {
    super.initState();
    _loadRankings();
    _loadDailySongs();
    _loadPlaylistSquare();
    _loadFmCover();
    // FM模式切歌时，同步更新首页卡片封面
    _fmSongSub = AudioPlayerService().onCurrentSongChanged.listen((song) {
      final player = AudioPlayerService();
      if (!player.isFmMode || song == null || song.coverUrl == null) return;
      if (song.id == _fmFirstSong?.id) return;
      if (!mounted) return;
      setState(() {
        _fmFirstSong = song;
        _fmCoverUrl = song.coverUrl;
      });
    });
  }

  @override
  void dispose() {
    _fmSongSub?.cancel();
    _cardPageController.dispose();
    _recommendPageController.dispose();
    _recommendPageController2.dispose();
    super.dispose();
  }

  Future<void> _loadRankings() async {
    await ensureInitialized;
    final results = await Future.wait([
      _apiService.topList(),
      _apiService.playlistDetail('3778678', subCount: 12, limit: 12),
    ]);
    if (!mounted) return;
    final rankings = results[0] as List<PlaylistModel>;
    final songs = results[1] as List<SongModel>;
    final hotChart = rankings.firstWhere(
      (r) => r.name.contains('热歌'),
      orElse: () => rankings.isNotEmpty ? rankings[0] : PlaylistModel(id: '', name: ''),
    );
    setState(() {
      _rankings = rankings;
      _loadingRankings = false;
      _hotSongs = songs.take(12).toList();
      _loadingHotSongs = false;
      _hotChart = hotChart.id.isNotEmpty ? hotChart : null;
    });
  }

  /// 每日推荐：匿名登录的设备账号也能获取（service 内自动处理），
  /// 请求失败时展示空态
  Future<void> _loadDailySongs() async {
    await ensureInitialized;
    try {
      final songs = await _apiService.getDailyRecommendSongs();
      if (!mounted) return;
      setState(() {
        _dailySongs = songs.take(12).toList();
        _loadingDailySongs = false;
      });
    } catch (e) {
      debugPrint('⚠️ 获取每日推荐失败: $e');
      if (!mounted) return;
      setState(() => _loadingDailySongs = false);
    }
  }

  /// 歌单广场：热门歌单 18 个（6 行 × 每行 3 个），匿名可用，失败时隐藏模块
  /// 每次随机取一页（'全部'+最热列表总量很大，偏移限制在安全范围避免越界），空结果回退第一页
  Future<void> _loadPlaylistSquare() async {
    await ensureInitialized;
    final offset = _random.nextInt(150) * 18;
    try {
      var playlists =
          await _apiService.fetchCategoryPlaylists(limit: 18, offset: offset);
      if (playlists.isEmpty && offset > 0) {
        playlists = await _apiService.fetchCategoryPlaylists(limit: 18);
      }
      if (!mounted) return;
      setState(() {
        _squarePlaylists = playlists;
        _loadingSquare = false;
      });
    } catch (e) {
      debugPrint('⚠️ 歌单广场拉取失败: $e');
      if (!mounted) return;
      setState(() => _loadingSquare = false);
    }
  }

  /// 刷新按钮：换一批歌单
  void _refreshSquare() {
    if (_loadingSquare) return;
    setState(() => _loadingSquare = true);
    _loadPlaylistSquare();
  }

  void _openSquarePlaylist(PlaylistModel playlist) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage(playlist: playlist),
      ),
    );
  }

  /// 私人FM卡片背景：取FM队列第一首歌的封面，失败时保留红色渐变。
  /// 同时记住这首歌，点卡片进FM时直接从它开始播（/personal_fm 每次调用会刷新队列）
  Future<void> _loadFmCover() async {
    await ensureInitialized;
    try {
      final songs = await _apiService.userRadio();
      if (!mounted) return;
      if (songs.isNotEmpty && songs.first.coverUrl != null) {
        setState(() {
          _fmFirstSong = songs.first;
          _fmCoverUrl = songs.first.coverUrl;
        });
      }
    } catch (e) {
      debugPrint('⚠️ 获取FM封面失败: $e');
    }
  }

  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour >= 0 && hour <= 5) {
      return '深夜了 让旋律陪你入梦 💤';
    } else if (hour >= 6 && hour <= 8) {
      return '早安 用一首歌唤醒美好的一天♫';
    } else if (hour >= 9 && hour <= 11) {
      return '上午好 音乐伴你高效前行🎧✨';
    } else if (hour >= 12 && hour <= 13) {
      return '午安 听首轻音乐放松一下🍀';
    } else if (hour >= 14 && hour <= 17) {
      return '下午好 让节奏点亮心情♫😊';
    } else if (hour >= 18 && hour <= 19) {
      return '傍晚好 用音乐收尾一天的精彩🎇';
    } else {
      return '晚上好 沉浸在旋律里享受时光 🎧';
    }
  }

  /// 顶部分类标签：选中项黑字加底部下划线，未选中灰字
  Widget _buildHomeTab(String label, {bool active = false, VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        // 选中项 padding 4 + 下划线 2 = 6，与未选中 padding 6 对齐，保证文字基线一致
        padding: EdgeInsets.only(bottom: active ? 4 : 6),
        decoration: active
            ? const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Color(0xFF1A1A1A), width: 2),
                ),
              )
            : null,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 16,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color: active ? const Color(0xFF1A1A1A) : const Color(0xFF9C9C9C),
          ),
        ),
      ),
    );
  }

  void _openRanking(PlaylistModel ranking) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage(playlist: ranking),
      ),
    );
  }

  void _openDailyRecommend() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage.daily(
          coverUrl: _dailySongs.isNotEmpty ? _dailySongs.first.coverUrl : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15),
            child: Text(
              _getGreeting(),
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15),
            child: SizedBox(
              // 必须占满整行宽度：否则 Stack 收缩为标签行宽度，
              // Positioned(right:0) 的搜索按钮会叠在「歌单」上
              width: double.infinity,
              height: 40,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildHomeTab('首页',
                          active: _homeTabIndex == 0,
                          onTap: () {
                            if (_homeTabIndex != 0) {
                              setState(() => _homeTabIndex = 0);
                            }
                          }),
                      const SizedBox(width: 28),
                      _buildHomeTab('本地',
                          active: _homeTabIndex == 1,
                          onTap: () {
                            if (_homeTabIndex != 1) {
                              setState(() => _homeTabIndex = 1);
                            }
                          }),
                      const SizedBox(width: 28),
                      _buildHomeTab('歌单',
                          onTap: () =>
                              DesignToast.show(context, '歌单功能敬请期待')),
                    ],
                  ),
                  Positioned(
                    right: 0,
                    child: _SearchCircleButton(),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _homeTabIndex == 1
                ? const LocalMusicView()
                : SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 滑动卡片铺满全屏宽（父级已无水平边距）
                        _buildSlidingCards(),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.only(left: 15),
                          child: _buildRecommendPlaylists(
                            title: '每日推荐',
                            songs: _dailySongs,
                            loading: _loadingDailySongs,
                            onSlideEnter: _openDailyRecommend,
                            lastPageHint: '继\n续\n滑\n动\n进\n入\n每\n日\n推\n荐',
                          ),
                        ),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.only(left: 15),
                          child: _buildRecommendPlaylists(
                            controller: _recommendPageController2,
                            title: '热歌推荐',
                            songs: _hotSongs,
                            loading: _loadingHotSongs,
                            onSlideEnter: _hotChart != null
                                ? () => _openRanking(_hotChart!)
                                : null,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.only(left: 15),
                          child: _buildRankingSection(),
                        ),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 15),
                          child: _buildPlaylistSquare(),
                        ),
                        const SizedBox(height: 100),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  void _openFm() async {
    if (NavigationGuard.isPlayerPageOpen) return;
    final audioPlayer = AudioPlayerService();
    await audioPlayer.enterFmMode(startSong: _fmFirstSong);
    if (!mounted || NavigationGuard.isPlayerPageOpen) return;
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

  /// 歌单广场模块：2 行 × 每行 3 个热门歌单卡片（封面 + 歌单名），点击进歌单详情
  Widget _buildPlaylistSquare() {
    // 数据为空且已结束加载：不显示占位
    if (!_loadingSquare && _squarePlaylists.isEmpty) {
      return const SizedBox.shrink();
    }
    final screenW = MediaQuery.of(context).size.width;
    // 卡片宽 = (屏宽 - 左右 15 - 列间距 10*2) / 3；高 = 封面(正方形) + 间距 6 + 歌单名两行
    // 文字高度留 36 而非理论值 34：中文行高渲染存在亚像素舍入（实测多出 ~0.5px），不足会触发溢出条纹
    final cardW = (screenW - 15 - 15 - 10 * 2) / 3;
    final cardH = cardW + 6 + 36;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '歌单广场',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
            const Spacer(),
            // 刷新按钮：换一批歌单（到底后自动回到第一页）；加载中保持图标不变，仅禁点
            IconButton(
              onPressed: _loadingSquare ? null : _refreshSquare,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              splashRadius: 18,
              icon: SvgPicture.asset(
                'assets/images/svg/refresh.svg',
                width: 22,
                height: 22,
                colorFilter: const ColorFilter.mode(
                    Colors.black54, BlendMode.srcIn),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_loadingSquare)
          SizedBox(
            height: cardH * 6 + 14 * 5,
            child: GridView.builder(
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 14,
                crossAxisSpacing: 10,
                childAspectRatio: cardW / cardH,
              ),
              itemCount: 18,
              itemBuilder: (_, i) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AspectRatio(
                    aspectRatio: 1,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width: cardW * 0.8,
                    height: 12,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          SizedBox(
            height: cardH * 6 + 14 * 5,
            child: GridView.builder(
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 14,
                crossAxisSpacing: 10,
                childAspectRatio: cardW / cardH,
              ),
              itemCount: _squarePlaylists.length,
              itemBuilder: (_, i) {
                final playlist = _squarePlaylists[i];
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _openSquarePlaylist(playlist),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AspectRatio(
                        aspectRatio: 1,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: _SongCoverImage(
                            url: playlist.coverUrl ?? '',
                            width: cardW,
                            height: cardW,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        playlist.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.3,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildSlidingCards() {
    final screenW = MediaQuery.of(context).size.width;
    final contentW = screenW;
    final cardH = contentW * 0.277 + 25;

    return SizedBox(
      height: cardH,
      child: AnimatedBuilder(
        animation: _cardPageController,
        builder: (_, _) {
          final page = _cardPageController.hasClients &&
                  _cardPageController.position.haveDimensions
              ? (_cardPageController.page ?? 0)
              : 0.0;
          return PageView.builder(
            controller: _cardPageController,
            itemCount: 3,
            onPageChanged: (index) => setState(() => _cardIndex = index),
            itemBuilder: (_, index) {
              final cardType = index == 0 ? CardType.fm : CardType.placeholder;
              final diff = (page - index).abs().clamp(0.0, 1.0);
              final scale = 1 - diff * 0.12;
              final dx = (index - page).clamp(-1.0, 1.0) * -8.0;
              return Transform.translate(
                offset: Offset(dx, 0),
                child: Transform.scale(
                  scale: scale,
                  child: GestureDetector(
                  onTap: () {
                    if (cardType == CardType.fm) {
                      if (_cardIndex == 0) {
                        _openFm();
                      } else {
                        _cardPageController.animateToPage(
                          0,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                        );
                      }
                    } else if (_cardIndex != index) {
                      _cardPageController.animateToPage(
                        index,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOut,
                      );
                    }
                  },
                    child: _buildCard(
                      contentW * 0.86,
                      cardH,
                      null,
                      isCenter: true,
                      cardType: cardType,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildRecommendPlaylists({
    PageController? controller,
    String title = '根据你的口味推荐',
    List<SongModel>? songs,
    bool loading = false,
    VoidCallback? onSlideEnter,
    String lastPageHint = '继\n续\n滑\n动\n进\n入\n榜\n单',
  }) {
    final ctrl = controller ?? _recommendPageController;
    final source = songs ?? _hotSongs;
    final list = source.length >= 12 ? source.sublist(0, 12) : source;
    final pages = <List<SongModel>>[];
    for (var i = 0; i < list.length; i += 4) {
      final end = (i + 4 > list.length) ? list.length : i + 4;
      pages.add(list.sublist(i, end));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 6),
        if (loading)
          Column(
            children: List.generate(
              4,
              (i) => Container(
                height: 48,
                margin: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 140,
                            height: 14,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade300,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            width: 80,
                            height: 10,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade300,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 26),
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        else if (pages.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text(
              '暂无推荐',
              style: TextStyle(fontSize: 14, color: Colors.black45),
            ),
          )
        else ...[
          Builder(
            builder: (context) {
              // 末页需与其他页停靠在相同的靠左位置：padEnds:false 时滚动余量不足，
              // 末页会靠右停靠、左侧多出空隙。这里加宽 PageView 并整体左移，
              // 使每页实际宽度仍为 0.95*可用宽、右侧露出 0.05*可用宽不变，
              // 同时末页可精确停靠靠左（此时 maxScroll 恰为 (页数-1)*页宽）。
              final availableW = MediaQuery.of(context).size.width - 15;
              final pvWidth = availableW * 1.05;
              return SizedBox(
                height: pages[0].length * 58.0,
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: pvWidth,
                  maxWidth: pvWidth,
                  child: Transform.translate(
                    offset: Offset(-availableW * 0.05, 0),
                    child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollEndNotification) {
                  final onLast = (ctrl.page?.round() ?? 0) == pages.length - 1;
                  if (!onLast) {
                    // 离开最后一页，重置提示状态
                    final removed = _hintShownCtrls.remove(ctrl);
                    _hintArmedCtrls.remove(ctrl);
                    if (removed) setState(() {});
                  } else if (_hintShownCtrls.contains(ctrl)) {
                    // 本次手势结束，下一次 overscroll 才进入榜单
                    _hintArmedCtrls.add(ctrl);
                  }
                  return false;
                }
                if (notification is OverscrollNotification &&
                    notification.overscroll > 0 &&
                    (ctrl.page?.round() ?? 0) == pages.length - 1) {
                  if (_hintShownCtrls.contains(ctrl)) {
                    if (_hintArmedCtrls.contains(ctrl) && onSlideEnter != null) {
                      setState(() {
                        _hintShownCtrls.remove(ctrl);
                        _hintArmedCtrls.remove(ctrl);
                      });
                      onSlideEnter();
                    }
                    return true;
                  }
                  // 第一次在最后一页继续滑动：显示提示（仅限手指主动拖动，
                  // 到达最后一页时的惯性越界不算）
                  if (notification.dragDetails != null) {
                    setState(() => _hintShownCtrls.add(ctrl));
                  }
                  return true;
                }
                return false;
              },
              child: PageView.builder(
                controller: ctrl,
                padEnds: true,
                itemCount: pages.length,
                itemBuilder: (_, pageIndex) {
                final chunk = pages[pageIndex];
                final isLast = pageIndex == pages.length - 1;
                final listColumn = Column(
                  children: chunk
                      .map((song) => _buildRecommendItem(song,
                          iconRightPadding: isLast ? 10 : 18))
                      .toList(),
                );
                if (!isLast) return listColumn;
                final showHint = _hintShownCtrls.contains(ctrl);
                return Row(
                  children: [
                    Expanded(child: listColumn),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (child, animation) {
                        // 槽位宽度渐变使列表（播放按钮等）平滑让位，同时淡入淡出
                        return SizeTransition(
                          axis: Axis.horizontal,
                          sizeFactor: animation,
                          alignment: Alignment.centerLeft,
                          child: FadeTransition(
                            opacity: animation,
                            child: child,
                          ),
                        );
                      },
                      child: showHint
                          ? Row(
                              key: const ValueKey('hint'),
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Padding(
                                  padding: EdgeInsets.zero,
                                  child: Text(
                                    lastPageHint,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.black38,
                                      height: 1.5,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: SvgPicture.asset(
                                    'assets/images/svg/Chevron Right.svg',
                                    width: 14,
                                    height: 14,
                                    colorFilter: const ColorFilter.mode(
                                      Colors.black38,
                                      BlendMode.srcIn,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : const SizedBox.shrink(key: ValueKey('hint-none')),
                    ),
                  ],
                );
              },
            ),
            ),
          ),
            ),
          );
            },
          ),
        ],
      ],
    );
  }

  Widget _buildRecommendItem(SongModel song, {double iconRightPadding = 18}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _playSong(song),
      child: Container(
        height: 48,
        margin: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _SongCoverImage(
                url: song.coverUrl ?? '',
                width: 48,
                height: 48,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.black45,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: EdgeInsets.only(right: iconRightPadding),
              child: SvgPicture.asset(
                'assets/images/svg/Play.svg',
                width: 14,
                height: 14,
                colorFilter: const ColorFilter.mode(
                  Colors.black45,
                  BlendMode.srcIn,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(double width, double height, String? imageUrl,
      {bool isCenter = false, CardType cardType = CardType.placeholder}) {
    if (cardType == CardType.fm) {
      return _buildFmCard(width, height, isCenter);
    }
    return _buildPlaceholderCard(width, height, isCenter);
  }

  Widget _buildFmCard(double width, double height, bool isCenter) {
    final coverUrl = _fmCoverUrl;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        // 无封面时回退到红色渐变
        gradient: coverUrl == null
            ? const LinearGradient(
                colors: [Color(0xFFE53935), Color(0xFFFF6F60)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: coverUrl != null ? const Color(0xFF2A2A35) : null,
        borderRadius: BorderRadius.circular(10),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          children: [
            if (coverUrl != null)
              Positioned.fill(
                child: _FmCoverBackground(url: coverUrl),
              ),
            if (coverUrl != null)
              // 深色遮罩保证白色文字/图标可读
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Colors.black.withValues(alpha: 0.55),
                        Colors.black.withValues(alpha: 0.30),
                        Colors.black.withValues(alpha: 0.15),
                      ],
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 10,
              child: Row(
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '私人FM',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: isCenter ? 14 : 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '听你想听',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: isCenter ? 11 : 9,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: isCenter ? 28 : 20,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholderCard(double width, double height, bool isCenter) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFFD9E8FF),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Center(
          child: Text(
            '敬请期待',
            style: TextStyle(
              fontSize: isCenter ? 14 : 11,
              color: const Color(0xFF2F84FE),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRankingSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '榜单',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 12),
        if (_loadingRankings)
          SizedBox(
            height: 140,
            child: Row(
              children: List.generate(
                4,
                (i) => Expanded(
                  child: Container(
                    margin: EdgeInsets.only(right: i == 3 ? 0 : 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AspectRatio(
                          aspectRatio: 1,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.grey.shade300,
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          width: 56,
                          height: 12,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade300,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          )
        else if (_rankings.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text(
              '暂无榜单数据',
              style: TextStyle(fontSize: 14, color: Colors.black45),
            ),
          )
        else
          SizedBox(
            height: 140,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _rankings.length > 4 ? 4 : _rankings.length,
              itemBuilder: (_, index) {
                final ranking = _rankings[index];
                return _buildRankingItem(ranking);
              },
            ),
          ),
      ],
    );
  }

  Widget _buildRankingItem(PlaylistModel ranking) {
    return GestureDetector(
      onTap: () => _openRanking(ranking),
      child: Container(
        width: 110,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 110,
              height: 110,
              decoration: BoxDecoration(
                color: const Color(0xFFF0F0F0),
                borderRadius: BorderRadius.circular(12),
              ),
              child: ranking.coverUrl != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: _RankingCoverImage(url: ranking.coverUrl!),
                    )
                  : const Icon(Icons.music_note,
                      size: 40, color: Colors.grey),
            ),
            const SizedBox(height: 6),
            Text(
              ranking.name,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Colors.black87,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  void _playSong(SongModel song) async {
    final audioPlayer = AudioPlayerService();
    await audioPlayer.playAndAdd(song);
  }
}

/// 首页顶栏圆形搜索按钮：白底无墨水效果，按压缩放反馈（按下缩小、松开弹回）
class _SearchCircleButton extends StatefulWidget {
  @override
  State<_SearchCircleButton> createState() => _SearchCircleButtonState();
}

class _SearchCircleButtonState extends State<_SearchCircleButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const SearchPage()),
        );
      },
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _pressed ? 0.86 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        // 无白色圆底，仅显示搜索图标
        child: const SizedBox(
          width: 36,
          height: 36,
          child: Icon(
            Icons.search,
            size: 24,
            color: Color(0xFF09244B),
          ),
        ),
      ),
    );
  }
}

class _RankingCoverImage extends StatefulWidget {
  final String url;
  const _RankingCoverImage({required this.url});

  @override
  State<_RankingCoverImage> createState() => _RankingCoverImageState();
}

class _RankingCoverImageState extends State<_RankingCoverImage> {
  Uint8List? _imageBytes;
  bool _loading = true;

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ));

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final response = await _dio.get(
        '${widget.url.split('?').first}?param=300y300',
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'Referer': 'https://music.163.com',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          },
        ),
      );
      if (response.statusCode == 200 && response.data != null) {
        if (mounted) {
          setState(() {
            _imageBytes = response.data as Uint8List;
            _loading = false;
          });
        }
      } else {
        if (mounted) setState(() => _loading = false);
      }
    } catch (e) {
      debugPrint('🎵 封面加载失败: ${widget.url} | 错误: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        width: 110,
        height: 110,
        color: Colors.grey.shade300,
      );
    }
    if (_imageBytes != null) {
      return Image.memory(
        _imageBytes!,
        width: 110,
        height: 110,
        fit: BoxFit.cover,
      );
    }
    return const Icon(Icons.music_note, size: 40, color: Colors.grey);
  }
}

class _SongCoverImage extends StatefulWidget {
  final String url;
  final double width;
  final double height;
  const _SongCoverImage({
    required this.url,
    required this.width,
    required this.height,
  });

  @override
  State<_SongCoverImage> createState() => _SongCoverImageState();
}

class _SongCoverImageState extends State<_SongCoverImage> {
  Uint8List? _imageBytes;
  bool _loading = true;

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ));

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final response = await _dio.get(
        '${widget.url.split('?').first}?param=150y150',
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'Referer': 'https://music.163.com',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          },
        ),
      );
      if (response.statusCode == 200 && response.data != null) {
        if (mounted) {
          setState(() {
            _imageBytes = response.data as Uint8List;
            _loading = false;
          });
        }
      } else {
        if (mounted) setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        width: widget.width,
        height: widget.height,
        color: Colors.grey.shade300,
      );
    }
    if (_imageBytes != null) {
      return Image.memory(
        _imageBytes!,
        width: widget.width,
        height: widget.height,
        fit: BoxFit.cover,
      );
    }
    return Container(
      width: widget.width,
      height: widget.height,
      color: Colors.grey[300],
      child: Icon(Icons.music_note, color: Colors.grey, size: widget.width * 0.5),
    );
  }
}

/// 私人FM卡片背景封面（宽幅裁剪，深色遮罩由外层负责）
class _FmCoverBackground extends StatefulWidget {
  final String url;
  const _FmCoverBackground({required this.url});

  @override
  State<_FmCoverBackground> createState() => _FmCoverBackgroundState();
}

class _FmCoverBackgroundState extends State<_FmCoverBackground> {
  Uint8List? _imageBytes;

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ));

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(covariant _FmCoverBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    // FM切歌后URL变化时重新加载封面
    if (oldWidget.url != widget.url) {
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    final url = widget.url;
    try {
      final response = await _dio.get(
        '${url.split('?').first}?param=600y200',
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'Referer': 'https://music.163.com',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          },
        ),
      );
      // 请求期间URL又变了就丢弃这次结果
      if (url != widget.url) return;
      if (response.statusCode == 200 && response.data != null) {
        if (mounted) {
          setState(() => _imageBytes = response.data as Uint8List);
        }
      }
    } catch (e) {
      debugPrint('🎵 FM封面加载失败: $url | 错误: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_imageBytes != null) {
      return Image.memory(
        _imageBytes!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    }
    // 加载中/失败时透出底色（深灰），遮罩与文字不受影响
    return const SizedBox.expand();
  }
}