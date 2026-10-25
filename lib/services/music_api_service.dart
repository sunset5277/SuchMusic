import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:netease_music_api/netease_music_api.dart';
import 'package:path_provider/path_provider.dart';
import '../models/song_model.dart';

/// 歌曲播放地址结果：url 为播放地址（含 fallback），isTrial 表示试听片段，
/// fee 为服务端返回的收费标记（接口失败走 fallback 时为 null）
class SongUrlResult {
  final String? url;
  final bool isTrial;
  final int? fee;
  const SongUrlResult(this.url, {this.isTrial = false, this.fee});
}

class MusicApiService {
  static final MusicApiService _instance = MusicApiService._internal();
  factory MusicApiService() => _instance;
  MusicApiService._internal();

  static final Dio _dio = Dio();

  static const _cacheFileName = 'user_cache.json';

  String? _cachedNickname;
  String? _cachedAvatarUrl;
  String? _cachedUserId;
  String? _cachedMusicU;

  String? get cachedNickname => _cachedNickname;
  String? get cachedAvatarUrl => _cachedAvatarUrl;
  String? get cachedUserId => _cachedUserId;

  Future<File> _getCacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_cacheFileName');
  }

  Future<void> init() async {
    await _loadCachedUserInfo();
    if (_cachedMusicU != null && _cachedMusicU!.isNotEmpty) {
      try {
        final uri = Uri.parse('https://music.163.com');
        final cookieJar =
            NeteaseMusicApi.cookieManager.cookieJar as PersistCookieJar;
        final cookies = await cookieJar.loadForRequest(uri);
        final hasMusicU = cookies.any((c) => c.name == 'MUSIC_U');
        if (!hasMusicU) {
          cookieJar.saveFromResponse(
              uri, [Cookie('MUSIC_U', _cachedMusicU!)..path = '/']);
          debugPrint('🔄 已从本地恢复 MUSIC_U cookie');
        }
      } catch (e) {
        debugPrint('⚠️ 恢复 MUSIC_U cookie 失败: $e');
      }
    }
  }

  Future<void> _loadCachedUserInfo() async {
    try {
      final file = await _getCacheFile();
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      _cachedNickname = json['nickname'] as String?;
      _cachedAvatarUrl = json['avatarUrl'] as String?;
      _cachedUserId = json['userId'] as String?;
      _cachedMusicU = json['musicU'] as String?;
      debugPrint('📂 已从本地读取缓存: nickname=$_cachedNickname');
    } catch (e) {
      debugPrint('⚠️ 读取缓存失败: $e');
    }
  }

  Future<void> _saveCachedUserInfo(
      String nickname, String avatarUrl, String userId, String musicU) async {
    _cachedNickname = nickname;
    _cachedAvatarUrl = avatarUrl;
    _cachedUserId = userId;
    _cachedMusicU = musicU;
    await _writeCacheFile();
  }

  Future<void> _saveMusicU(String musicU) async {
    _cachedMusicU = musicU;
    await _writeCacheFile();
  }

  Future<void> _writeCacheFile() async {
    try {
      final file = await _getCacheFile();
      final json = jsonEncode({
        'nickname': _cachedNickname,
        'avatarUrl': _cachedAvatarUrl,
        'userId': _cachedUserId,
        'musicU': _cachedMusicU,
      });
      await file.writeAsString(json);
      debugPrint('💾 缓存已写入本地');
    } catch (e) {
      debugPrint('⚠️ 写入缓存失败: $e');
    }
  }

  Future<void> _clearCachedUserInfo() async {
    _cachedNickname = null;
    _cachedAvatarUrl = null;
    _cachedUserId = null;
    _cachedMusicU = null;
    try {
      final file = await _getCacheFile();
      if (await file.exists()) {
        await file.delete();
      }
      debugPrint('🧹 本地缓存已清除');
    } catch (e) {
      debugPrint('⚠️ 清除缓存失败: $e');
    }
  }

  bool get hasCachedUser => _cachedMusicU != null && _cachedMusicU!.isNotEmpty;

  /// 每日推荐歌曲（匿名登录的设备账号也可获取）
  Future<List<SongModel>> getDailyRecommendSongs() async {
    final result = await NeteaseMusicApi().recommendSongList();
    if (result.code == 200) {
      return (result.data.dailySongs ?? [])
          .map((song) => SongModel.fromSong2(song))
          .toList();
    }
    debugPrint('⚠️ 每日推荐返回 code=${result.code}，尝试匿名登录后重试');
    final uri = Uri.parse('https://music.163.com');
    final cookieJar =
        NeteaseMusicApi.cookieManager.cookieJar as PersistCookieJar;
    final cookies = await cookieJar.loadForRequest(uri);
    final hasMusicU = cookies.any((c) => c.name == 'MUSIC_U');
    if (!hasMusicU) {
      final anonResult = await NeteaseMusicApi().loginAnonimous();
      debugPrint('🔑 匿名登录: code=${anonResult.code}');
      final retry = await NeteaseMusicApi().recommendSongList();
      if (retry.code == 200) {
        return (retry.data.dailySongs ?? [])
            .map((song) => SongModel.fromSong2(song))
            .toList();
      }
      throw Exception('获取每日推荐失败: ${retry.realMsg}');
    }
    throw Exception('获取每日推荐失败: ${result.realMsg}');
  }

  Future<List<SongModel>> search(String keywords, {int limit = 30}) async {
    try {
      final result =
          await NeteaseMusicApi().searchSong(keywords, limit: limit);
      if (result.code != 200) {
        throw Exception('搜索失败: ${result.realMsg}');
      }
      final songs = result.result.songs
          .map((song) => SongModel.fromNeteaseSong(song))
          .toList();
      // 老搜索接口不返回封面，用 songDetail 批量补齐 al.picUrl
      if (songs.isNotEmpty) {
        try {
          final detail = await NeteaseMusicApi()
              .songDetail(songs.map((s) => s.id).toList());
          final covers = {
            for (final s in detail.songs ?? const <Song2>[]) s.id: s.al.picUrl,
          };
          return [for (final s in songs) s.copyWith(coverUrl: covers[s.id])];
        } catch (e) {
          debugPrint('⚠️ 搜索结果封面补齐失败: $e');
        }
      }
      return songs;
    } catch (e) {
      rethrow;
    }
  }

  Future<List<String>> searchSuggest(String keywords) async {
    try {
      final result = await NeteaseMusicApi().searchSuggest(keywords);
      if (result.code != 200) {
        return [];
      }
      return result.result.allMatch
          .map((item) => item.keyword ?? '')
          .where((k) => k.isNotEmpty)
          .toList();
    } catch (e) {
      return [];
    }
  }

  /// 热搜榜缓存：进程内只请求一次，重复进搜索页不再发请求
  static List<String>? _hotKeysCache;

  Future<List<String>> getHotSearchKeys() async {
    final cached = _hotKeysCache;
    if (cached != null) {
      return cached;
    }
    try {
      final result = await NeteaseMusicApi().searchHotKeyDetailed();
      if (result.code != 200) {
        return [];
      }
      final keys = result.data
          .map((item) => item.searchWord ?? '')
          .where((k) => k.isNotEmpty)
          .toList();
      _hotKeysCache = keys;
      return keys;
    } catch (e) {
      return [];
    }
  }

  /// 歌曲播放地址及试听状态：isTrial 为 true 表示返回的是试听片段
  /// 先请求最高音质，取不到 URL 时降级 320k 重试（免费听权益通常不含无损），最后走外链兜底；
  /// VIP 歌曲取不到地址时外链必为试听片段，按 fee 标记 isTrial 供 UI 提示
  Future<SongUrlResult> getSongUrlInfo(String songId, {int br = 999000}) async {
    final primary = await _requestSongUrl(songId, br);
    if (primary.$1 != null) return primary.$1!;
    if (br != 320000) {
      final lower = await _requestSongUrl(songId, 320000);
      if (lower.$1 != null) return lower.$1!;
      if ((primary.$2 ?? lower.$2) == 1) {
        return _fallbackResult(songId, vipTrial: true);
      }
    } else if (primary.$2 == 1) {
      return _fallbackResult(songId, vipTrial: true);
    }
    return _fallbackResult(songId);
  }

  SongUrlResult _fallbackResult(String songId, {bool vipTrial = false}) {
    final fallbackUrl =
        'https://music.163.com/song/media/outer/url?id=$songId.mp3';
    debugPrint('🎵 fallback URL${vipTrial ? '（VIP歌，外链为试听）' : ''}: $fallbackUrl');
    return SongUrlResult(fallbackUrl, isTrial: vipTrial, fee: vipTrial ? 1 : null);
  }

  /// 返回 (结果, 服务端响应的 fee)
  Future<(SongUrlResult?, int?)> _requestSongUrl(String songId, int br) async {
    try {
      final result = await NeteaseMusicApi()
          .songUrl([songId], br: br)
          .timeout(const Duration(seconds: 10));
      final item = (result.data != null && result.data!.isNotEmpty)
          ? result.data!.first
          : null;
      debugPrint(
          '🎵 songUrl(br=$br) resp: code=${result.code} msg=${result.message ?? result.msg} '
          'itemCode=${item?.code} hasUrl=${item?.url != null} fee=${item?.fee} trial=${item?.freeTrialInfo != null}');
      if (result.code == 200 &&
          item != null &&
          item.code == 200 &&
          item.url != null) {
        return (
          SongUrlResult(item.url,
              isTrial: item.freeTrialInfo != null, fee: item.fee),
          item.fee
        );
      }
      return (null, item?.fee);
    } catch (e) {
      debugPrint('⚠️ songUrl(br=$br) 异常: $e');
    }
    return (null, null);
  }

  Future<String?> getSongUrl(String songId, {int br = 999000}) async {
    return (await getSongUrlInfo(songId, br: br)).url;
  }

  Future<SongModel?> getSongDetail(String songId) async {
    try {
      final result = await NeteaseMusicApi().songDetail([songId]);
      if (result.code != 200 || result.songs == null || result.songs!.isEmpty) {
        return null;
      }
      final song2 = result.songs!.first;
      final artistNames = song2.ar
              ?.map((a) => a.name ?? '')
              .where((n) => n.isNotEmpty)
              .join(' / ') ??
          '';
      final coverUrl = song2.al.picUrl;
      return SongModel(
        id: song2.id,
        name: song2.name ?? '',
        artist: artistNames,
        album: song2.al.name ?? '',
        coverUrl: coverUrl,
        duration: song2.dt,
      );
    } catch (e) {
      return null;
    }
  }

  Future<NeteaseAccountInfoWrap?> setMusicUCookie(String musicUInput) async {
    try {
      var musicU = musicUInput.trim();
      if (musicU.startsWith('MUSIC_U=')) {
        musicU = musicU.substring('MUSIC_U='.length);
      }
      if (musicU.isEmpty) {
        debugPrint('❌ MUSIC_U 值为空');
        return null;
      }
      debugPrint('💾 MUSIC_U 长度: ${musicU.length}');

      final uri = Uri.parse('https://music.163.com');
      final cookieJar =
          NeteaseMusicApi.cookieManager.cookieJar as PersistCookieJar;

      await NeteaseMusicApi().usc.onLogout();
      debugPrint('🧹 已清除旧登录状态');

      cookieJar.saveFromResponse(
          uri, [Cookie('MUSIC_U', musicU)..path = '/']);
      debugPrint('💾 MUSIC_U 已保存到 cookie jar');

      await _saveMusicU(musicU);
      debugPrint('💾 MUSIC_U 已保存到本地');

      final info = await NeteaseMusicApi().loginAccountInfo();
      debugPrint(
          '👤 loginAccountInfo: code=${info.code}, profile=${info.profile?.nickname}');
      if (info.code == 200 && info.profile != null) {
        NeteaseMusicApi().usc.onLogined(info);
        await _saveCachedUserInfo(
          info.profile!.nickname ?? '',
          info.profile!.avatarUrl ?? '',
          info.profile!.userId.toString(),
          musicU,
        );
        return info;
      }

      debugPrint('⚠️ 直接使用 MUSIC_U 未获取到 profile，尝试匿名登录获取 __csrf...');
      await NeteaseMusicApi().usc.onLogout();

      final anonResult = await NeteaseMusicApi().loginAnonimous();
      debugPrint('🔑 匿名登录: code=${anonResult.code}');
      if (anonResult.code != 200) {
        debugPrint('❌ 匿名登录失败');
        return null;
      }

      final allCookies = await cookieJar.loadForRequest(uri);
      final keptCookies =
          allCookies.where((c) => c.name != 'MUSIC_U').toList();
      await cookieJar.deleteAll();
      if (keptCookies.isNotEmpty) {
        cookieJar.saveFromResponse(uri, keptCookies);
      }
      cookieJar.saveFromResponse(
          uri, [Cookie('MUSIC_U', musicU)..path = '/']);
      debugPrint('💾 已移除匿名 MUSIC_U，保存用户的 MUSIC_U');

      final info2 = await NeteaseMusicApi().loginAccountInfo();
      debugPrint(
          '👤 loginAccountInfo (重试): code=${info2.code}, profile=${info2.profile?.nickname}');
      if (info2.code == 200 && info2.profile != null) {
        NeteaseMusicApi().usc.onLogined(info2);
        await _saveCachedUserInfo(
          info2.profile!.nickname ?? '',
          info2.profile!.avatarUrl ?? '',
          info2.profile!.userId.toString(),
          musicU,
        );
        return info2;
      }

      debugPrint('❌ 登录失败: MUSIC_U 可能已过期');
      return null;
    } catch (e) {
      debugPrint('❌ setMusicUCookie 异常: $e');
      return null;
    }
  }

  Future<NeteaseAccountInfoWrap?> verifyLogin() async {
    try {
      final info = await NeteaseMusicApi().loginAccountInfo();
      if (info.code == 200 && info.profile != null) {
        NeteaseMusicApi().usc.onLogined(info);
        await _saveCachedUserInfo(
          info.profile!.nickname ?? '',
          info.profile!.avatarUrl ?? '',
          info.profile!.userId.toString(),
          _cachedMusicU ?? '',
        );
        return info;
      }
      await clearCookie();
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<void> clearCookie() async {
    try {
      final cookieJar =
          NeteaseMusicApi.cookieManager.cookieJar as PersistCookieJar;
      await cookieJar.deleteAll();
      await NeteaseMusicApi().usc.onLogout();
      _likedIds.clear();
      _likelistLoaded = false;
      await _clearCachedUserInfo();
    } catch (e) {
      // ignore
    }
  }

  // ---------------- 红心（喜欢歌曲） ----------------

  /// 红心过的歌曲 id 缓存（进程内）。登录后懒加载拉取，红心操作同步维护。
  final Set<String> _likedIds = {};
  bool _likelistLoaded = false;

  /// 拉取当前用户红心列表（幂等，本会话只拉一次；未登录直接跳过）
  Future<void> ensureLikelist() async {
    if (_likelistLoaded) return;
    final uid = cachedUserId;
    if (uid == null || uid.isEmpty) return;
    try {
      final result = await NeteaseMusicApi().likeSongList(uid);
      if (result.code == 200) {
        _likedIds
          ..clear()
          ..addAll(result.ids.map((e) => e.toString()));
        _likelistLoaded = true;
        debugPrint('❤️ 红心列表已加载: ${_likedIds.length} 首');
      }
    } catch (e) {
      debugPrint('❌ 红心列表拉取失败: $e');
    }
  }

  bool isLiked(String songId) => _likedIds.contains(songId);

  /// 歌单广场：分类热门歌单列表（匿名可用）
  /// [category] 分类 tag，如 '全部'/'华语'/'流行'；[limit] 返回数量
  Future<List<PlaylistModel>> fetchCategoryPlaylists(
      {String category = '全部', int limit = 6, int offset = 0}) async {
    try {
      final result = await NeteaseMusicApi()
          .categorySongList(category: category, limit: limit, offset: offset);
      return (result.playlists ?? [])
          .map((p) => PlaylistModel(
                id: p.id,
                name: p.name ?? '',
                coverUrl: p.coverImgUrl,
                trackCount: p.trackCount,
                playCount: p.playCount,
              ))
          .toList();
    } catch (e) {
      debugPrint('❌ 歌单广场拉取失败: $e');
      return [];
    }
  }

  /// 红心/取消红心；成功后同步本地缓存。返回是否成功。
  Future<bool> likeSong(String songId, bool like) async {
    try {
      final result = await NeteaseMusicApi().likeSong(songId, like);
      if (result.code == 200) {
        like ? _likedIds.add(songId) : _likedIds.remove(songId);
        return true;
      }
      debugPrint('❌ 红心失败: code=${result.code}');
      return false;
    } catch (e) {
      debugPrint('❌ 红心异常: $e');
      return false;
    }
  }

  Future<dynamic> getQrCodeKey() async {
    try {
      final uri = Uri.parse('https://music.163.com');
      final cookieJar =
          NeteaseMusicApi.cookieManager.cookieJar as PersistCookieJar;
      var cookies = await cookieJar.loadForRequest(uri);
      var hasCsrf = cookies.any((c) => c.name == '__csrf');

      if (!hasCsrf) {
        debugPrint('🔑 cookie jar 为空，先匿名登录获取基础 cookie...');
        final anonResult = await NeteaseMusicApi().loginAnonimous();
        debugPrint('🔑 匿名登录: code=${anonResult.code}');
        if (anonResult.code != 200) {
          return QrCodeError('初始化失败，请稍后重试');
        }
        cookies = await cookieJar.loadForRequest(uri);
        final keptCookies =
            cookies.where((c) => c.name != 'MUSIC_A' && c.name != 'MUSIC_U').toList();
        await cookieJar.deleteAll();
        if (keptCookies.isNotEmpty) {
          cookieJar.saveFromResponse(uri, keptCookies);
        }
        debugPrint('🧹 已移除匿名 MUSIC_A/MUSIC_U，保留基础 cookie');
        hasCsrf = keptCookies.any((c) => c.name == '__csrf');
      }

      if (!hasCsrf) {
        return QrCodeError('无法获取基础 cookie，请使用手动输入');
      }

      final currentCookies = await cookieJar.loadForRequest(uri);
      final csrfToken =
          currentCookies.firstWhere((c) => c.name == '__csrf').value;
      final cookieHeader =
          currentCookies.map((c) => '${c.name}=${c.value}').join('; ');

      debugPrint('🔑 请求二维码 key (api)...');

      final dio = _dio;
      final response = await dio.post(
        'https://music.163.com/api/login/qrcode/unikey',
        data: 'type=1&csrf_token=$csrfToken',
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {
            'Cookie': cookieHeader,
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
            'Referer': 'https://music.163.com/',
            'Accept': '*/*',
            'Origin': 'https://music.163.com',
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
          },
        ),
      );

      final data = response.data;
      debugPrint('🔑 二维码 key 响应: $data');

      if (data['code'] == 200 && data['unikey'] != null) {
        return data['unikey'] as String;
      }
      if (data['code'] == -462) {
        return QrCodeError('服务器拒绝请求，请使用手动输入 MUSIC_U');
      }
      return QrCodeError('获取二维码失败 (${data['code']})，请重试');
    } catch (e) {
      debugPrint('❌ 获取二维码 key 失败: $e');
      return QrCodeError('获取二维码失败，请重试');
    }
  }

  String getQrCodeUrl(String key) {
    return NeteaseMusicApi().loginQrCodeUrl(key);
  }

  static String _cleanCookie(String rawCookie) {
    if (rawCookie.isEmpty) return '';
    const attrKeywords = [
      'max-age', 'path', 'domain', 'expires', 'secure',
      'httponly', 'samesite', 'priority', 'partitioned',
    ];
    final parts = rawCookie.split(';');
    final cleaned = <String>[];
    for (final part in parts) {
      final p = part.trim();
      if (p.isEmpty) continue;
      final eqIdx = p.indexOf('=');
      if (eqIdx > 0) {
        final key = p.substring(0, eqIdx).trim().toLowerCase();
        if (!attrKeywords.contains(key)) {
          cleaned.add(p);
        }
      }
    }
    return cleaned.join('; ');
  }

  Future<int> checkQrCodeStatus(String key) async {
    try {
      final result = await NeteaseMusicApi().loginQrCodeCheck(key);
      debugPrint('🔑 二维码状态 (WeApi): code=${result.code}');
      if (result.code == 803) {
        await _ensureMusicUCookieFromJar();
      }
      return result.code;
    } catch (e) {
      debugPrint('❌ WeApi 检查失败，尝试 /api/ 端点: $e');
    }

    try {
      final uri = Uri.parse('https://music.163.com');
      final cookieJar =
          NeteaseMusicApi.cookieManager.cookieJar as PersistCookieJar;
      final cookies = await cookieJar.loadForRequest(uri);
      final csrfToken =
          cookies.firstWhere((c) => c.name == '__csrf', orElse: () => Cookie('', '')..path = '/').value;
      final cookieHeader =
          cookies.map((c) => '${c.name}=${c.value}').join('; ');

      final dio = _dio;
      var response = await dio.post(
        'https://music.163.com/api/login/qrcode/client/login',
        data: 'key=$key&type=1&csrf_token=$csrfToken',
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {
            'Cookie': cookieHeader,
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
            'Referer': 'https://music.163.com/',
            'Accept': '*/*',
            'Origin': 'https://music.163.com',
          },
        ),
      );

      var data = response.data;
      var code = data['code'] as int? ?? 800;
      debugPrint('🔑 二维码状态 (/api/): code=$code');

      if (code == 502) {
        debugPrint('🔑 收到 502，使用 noCookie=true 重试...');
        response = await dio.post(
          'https://music.163.com/api/login/qrcode/client/login',
          data: 'key=$key&type=1&csrf_token=$csrfToken&noCookie=true',
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            headers: {
              'Cookie': cookieHeader,
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
              'Referer': 'https://music.163.com/',
              'Accept': '*/*',
              'Origin': 'https://music.163.com',
            },
          ),
        );
        data = response.data;
        code = data['code'] as int? ?? 800;
        debugPrint('🔑 二维码状态 (noCookie重试): code=$code');
      }

      if (code == 803) {
        final rawCookieStr = (data['cookie'] ?? data['data'] ?? '') as String;
        if (rawCookieStr.isNotEmpty) {
          final cleaned = _cleanCookie(rawCookieStr);
          debugPrint('🔑 从响应体提取 cookie: $cleaned');
          if (cleaned.isNotEmpty) {
            final newCookies = <Cookie>[];
            for (final part in cleaned.split(';')) {
              final p = part.trim();
              if (p.isEmpty) continue;
              final eq = p.indexOf('=');
              if (eq > 0) {
                final name = p.substring(0, eq).trim();
                final value = p.substring(eq + 1).trim();
                newCookies.add(Cookie(name, value)..path = '/');
              }
            }
            if (newCookies.isNotEmpty) {
              cookieJar.saveFromResponse(uri, newCookies);
              debugPrint('💾 从响应体保存 cookie: ${newCookies.map((c) => c.name).join(', ')}');
            }
          }
        }

        final setCookies = response.headers['set-cookie'];
        if (setCookies != null) {
          final newCookies = <Cookie>[];
          for (final sc in setCookies) {
            final parts = sc.split(';')[0];
            final eq = parts.indexOf('=');
            if (eq > 0) {
              final name = parts.substring(0, eq).trim();
              final value = parts.substring(eq + 1).trim();
              newCookies.add(Cookie(name, value)..path = '/');
            }
          }
          if (newCookies.isNotEmpty) {
            cookieJar.saveFromResponse(uri, newCookies);
            debugPrint('💾 从 Set-Cookie 头保存 cookie: ${newCookies.map((c) => c.name).join(', ')}');
          }
        }
      }

      return code;
    } catch (e) {
      debugPrint('❌ 检查二维码状态失败: $e');
      return 800;
    }
  }

  Future<void> _ensureMusicUCookieFromJar() async {
    final uri = Uri.parse('https://music.163.com');
    final cookieJar =
        NeteaseMusicApi.cookieManager.cookieJar as PersistCookieJar;
    final cookies = await cookieJar.loadForRequest(uri);
    final hasMusicU = cookies.any((c) => c.name == 'MUSIC_U' && c.value.isNotEmpty);
    if (!hasMusicU) {
      debugPrint('⚠️ WeApi 803 后 cookie jar 无 MUSIC_U，尝试 loginAccountInfo 触发写入...');
      await NeteaseMusicApi().loginAccountInfo();
    }
  }

  Future<NeteaseAccountInfoWrap?> handleQrCodeLoginSuccess() async {
    try {
      await _ensureMusicUCookieFromJar();

      final info = await NeteaseMusicApi().loginAccountInfo();
      debugPrint('👤 loginAccountInfo: code=${info.code}, profile=${info.profile?.nickname}');

      if (info.code == 200 && info.profile != null) {
        NeteaseMusicApi().usc.onLogined(info);
        final musicU = await _extractMusicU();
        await _saveCachedUserInfo(
          info.profile!.nickname ?? '',
          info.profile!.avatarUrl ?? '',
          info.profile!.userId.toString(),
          musicU,
        );
        return info;
      }

      if (info.code == 301) {
        debugPrint('⚠️ loginAccountInfo 返回 301，Cookie 可能未正确写入，尝试用 /login/status 校验...');
        final statusInfo = await _validateLoginStatus();
        if (statusInfo != null) return statusInfo;
      }

      debugPrint('❌ 二维码登录后获取用户信息失败: code=${info.code}');
      return null;
    } catch (e) {
      debugPrint('❌ 处理二维码登录失败: $e');
      return null;
    }
  }

  Future<String> _extractMusicU() async {
    final uri = Uri.parse('https://music.163.com');
    final cookieJar =
        NeteaseMusicApi.cookieManager.cookieJar as PersistCookieJar;
    final cookies = await cookieJar.loadForRequest(uri);
    final musicUCookie = cookies.where((c) => c.name == 'MUSIC_U').firstOrNull;
    if (musicUCookie != null && musicUCookie.value.isNotEmpty) {
      return musicUCookie.value;
    }
    debugPrint('⚠️ 未能获取 MUSIC_U cookie');
    return '';
  }

  Future<NeteaseAccountInfoWrap?> _validateLoginStatus() async {
    try {
      final uri = Uri.parse('https://music.163.com');
      final cookieJar =
          NeteaseMusicApi.cookieManager.cookieJar as PersistCookieJar;
      final cookies = await cookieJar.loadForRequest(uri);
      final cookieHeader =
          cookies.map((c) => '${c.name}=${c.value}').join('; ');

      final dio = _dio;
      final response = await dio.get(
        'https://music.163.com/api/w/nuser/account',
        options: Options(
          headers: {
            'Cookie': cookieHeader,
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
            'Referer': 'https://music.163.com/',
          },
        ),
      );

      final data = response.data;
      final code = data['code'] as int? ?? -1;
      debugPrint('🔑 /api/w/nuser/account: code=$code');

      if (code == 200) {
        final profile = data['profile'];
        if (profile != null) {
          final info = await NeteaseMusicApi().loginAccountInfo();
          if (info.code == 200 && info.profile != null) {
            NeteaseMusicApi().usc.onLogined(info);
            final musicU = await _extractMusicU();
            await _saveCachedUserInfo(
              info.profile!.nickname ?? '',
              info.profile!.avatarUrl ?? '',
              info.profile!.userId.toString(),
              musicU,
            );
            return info;
          }
        }
      }
      return null;
    } catch (e) {
      debugPrint('❌ 校验登录状态失败: $e');
      return null;
    }
  }

  Future<NeteaseAccountInfoWrap?> loginWithPassword(
      String phone, String password, {String countryCode = '86'}) async {
    try {
      debugPrint('📱 手机号密码登录: phone=$phone');

      final info = await NeteaseMusicApi()
          .loginCellPhone(phone, password, countryCode: countryCode);

      if (info.codeEnum == RetCode.Ok && info.profile != null) {
        final uri = Uri.parse('https://music.163.com');
        final cookieJar =
            NeteaseMusicApi.cookieManager.cookieJar as PersistCookieJar;
        var allCookies = await cookieJar.loadForRequest(uri);
        var musicUCookie =
            allCookies.where((c) => c.name == 'MUSIC_U').firstOrNull;

        if (musicUCookie == null || musicUCookie.value.isEmpty) {
          await NeteaseMusicApi().loginAccountInfo();
          allCookies = await cookieJar.loadForRequest(uri);
          musicUCookie =
              allCookies.where((c) => c.name == 'MUSIC_U').firstOrNull;
        }

        if (musicUCookie != null && musicUCookie.value.isNotEmpty) {
          await _saveCachedUserInfo(
            info.profile!.nickname ?? '',
            info.profile!.avatarUrl ?? '',
            info.profile!.userId.toString(),
            musicUCookie.value,
          );
        } else {
          await _saveCachedUserInfo(
            info.profile!.nickname ?? '',
            info.profile!.avatarUrl ?? '',
            info.profile!.userId.toString(),
            '',
          );
        }
        _lastLoginError = null;
        return info;
      }

      _lastLoginError = _parseLoginError(info.code, info.realMsg);
      debugPrint('❌ 手机号密码登录失败: code=${info.code}, message=${info.realMsg}');
      return null;
    } catch (e) {
      debugPrint('❌ 手机号密码登录失败: $e');
      _lastLoginError = '登录请求异常，请稍后重试';
      return null;
    }
  }

  String? _lastLoginError;
  String? get lastLoginError => _lastLoginError;

  static String _parseLoginError(int? code, String message) {
    switch (code) {
      case -462:
        return '网络环境被风控拦截，请使用扫码登录或切换网络后重试';
      case 400:
        return '手机号或密码错误，请重新输入';
      case 502:
        return '密码错误，请重新输入';
      case 503:
        return '该手机号未注册网易云音乐账号';
      default:
        if (message.isNotEmpty) return message;
        return '登录失败 (错误码: $code)，请稍后重试';
    }
  }

  bool get isLogined => NeteaseMusicApi().usc.isLogined;

  Future<String?> getLyrics(String songId) async {
    try {
      final result = await NeteaseMusicApi().songLyric(songId);
      if (result.code == 200 && result.lrc.lyric != null) {
        return result.lrc.lyric;
      }
      return null;
    } catch (e) {
      debugPrint('❌ 获取歌词失败: $e');
      return null;
    }
  }

  Future<List<PlaylistModel>> topList() async {
    try {
      final result = await NeteaseMusicApi().topList();
      if (result.code != 200) {
        return [];
      }
      return result.list
          .map((t) => PlaylistModel.fromNeteaseTopList(t))
          .toList();
    } catch (e) {
      debugPrint('❌ 获取榜单列表失败: $e');
      return [];
    }
  }

  Future<List<PlaylistModel>> userPlaylist(String uid,
      {int limit = 30, int offset = 0}) async {
    try {
      final result = await NeteaseMusicApi()
          .userPlayList(uid, limit: limit, offset: offset);
      if (result.code != 200 || result.playlist == null) {
        return [];
      }
      return result.playlist!
          .map((p) => PlaylistModel.fromNeteasePlay(p))
          .toList();
    } catch (e) {
      debugPrint('❌ 获取用户歌单失败: $e');
      return [];
    }
  }

  Future<List<SongModel>> userRadio() async {
    try {
      final result = await NeteaseMusicApi().userRadio();
      if (result.code != 200 || result.data == null) {
        return [];
      }
      return result.data!
          .map((song) => SongModel.fromNeteaseSong(song))
          .toList();
    } catch (e) {
      debugPrint('❌ 获取私人FM失败: $e');
      return [];
    }
  }

  Future<void> userRadioTrash(String songId) async {
    try {
      await NeteaseMusicApi().userRadioTrash(songId);
    } catch (e) {
      debugPrint('❌ FM垃圾桶失败: $e');
    }
  }

  Future<List<SongModel>> playlistDetail(String playlistId,
      {int subCount = 5, int limit = 100000}) async {
    try {
      // n 控制返回的完整歌曲条数：首页等只需少量歌曲时传小值可大幅减少响应体积
      final result = await NeteaseMusicApi()
          .playListDetail(playlistId, subCount: subCount, n: limit);
      if (result.code != 200 || result.playlist == null) return [];
      final play = result.playlist!;

      // 映射接口直接返回的完整歌曲对象
      final byId = <String, SongModel>{};
      for (final track in play.tracks ?? const <PlayTrack>[]) {
        byId[track.id] = _songFromTrack(
          id: track.id,
          name: track.name,
          ar: track.ar,
          al: track.al,
          dt: track.dt,
        );
      }

      // 网易服务端会把 tracks 完整对象截断（登录约 20 首/匿名约 10 首），
      // 但 trackIds 是全量返回的；缺失部分用 /api/v3/song/detail 按 id 分批补齐
      final allIds = (play.trackIds ?? const <PlayTrackId>[])
          .map((e) => e.id)
          .take(limit)
          .toList();
      if (allIds.length > byId.length) {
        final missing = allIds.where((id) => !byId.containsKey(id)).toList();
        for (var i = 0; i < missing.length; i += 500) {
          final end = i + 500 > missing.length ? missing.length : i + 500;
          try {
            final detail =
                await NeteaseMusicApi().songDetail(missing.sublist(i, end));
            for (final s in detail.songs ?? const <Song2>[]) {
              byId[s.id] = _songFromTrack(
                id: s.id,
                name: s.name,
                ar: s.ar,
                al: s.al,
                dt: s.dt,
              );
            }
          } catch (e) {
            debugPrint('❌ 补齐歌单歌曲失败(${missing.sublist(i, end).length}首): $e');
          }
        }
      }

      // 按歌单原始顺序输出（已下架歌曲会缺失，自动跳过）
      return [
        for (final id in allIds)
          if (byId[id] != null) byId[id]!,
      ];
    } catch (e) {
      debugPrint('❌ 获取歌单详情失败: $e');
      return [];
    }
  }

  /// PlayTrack / Song2 共有字段 → SongModel（两个类的结构一致但无公共接口）
  SongModel _songFromTrack({
    required String id,
    String? name,
    List<Artists>? ar,
    required Album al,
    int? dt,
  }) {
    return SongModel(
      id: id,
      name: name ?? '',
      artist: ar
              ?.map((a) => a.name ?? '')
              .where((n) => n.isNotEmpty)
              .join(' / ') ??
          '',
      album: al.name ?? '',
      coverUrl: al.picUrl,
      duration: dt,
    );
  }
}

class QrCodeError {
  final String message;
  QrCodeError(this.message);
}