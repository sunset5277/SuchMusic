# 本地音乐功能（基础版）实现计划

## Context

用户希望为 such\_music 添加"本地音乐"功能：扫描设备本地音频文件并播放。已确认的需求边界：

* **入口**：首页顶部标签栏已有「本地」标签（home\_page.dart L275-277，目前点击仅弹 toast「本地音乐敬请期待」），直接接入新页面，无需新增 UI

* **播放集成**：统一播放队列 —— SongModel 增加本地路径字段，播放时跳过在线 URL 获取，直接用 `AudioSource.file` 播放；本地歌曲可与在线歌曲共存于同一队列，播放页/迷你播放条/通知栏全部复用

* **范围（基础版）**：扫描设备全部音频（MediaStore），列表显示歌名/歌手/时长，支持播放全部 + 单曲播放 + 当前播放行高亮。不做文件夹分组、排序、本地封面提取

## 现状核实结论（已读源码确认）

* `play()`（audio\_player\_service.dart L572-640）：走 `getSongUrlInfo` → `AudioSource.uri`，含歌词拉取（L589）、试听判定（L601）、封面回填（L615-630 调 getSongDetail）——本地歌曲必须全部跳过，否则会拿 `local_x` 这种 id 去打在线接口

* `playSongs()`（L705-792）：并行预取 URL（L737-747）→ 组 ConcatenatingAudioSource；本地歌曲需在 fetchWorker 与组源循环中分支处理

* 播放列表持久化走 `SongModel.toJson/fromStorage`（L317/333），**localPath 必须序列化**，否则重启后本地歌恢复播放失败

* `audio_player_handler.dart` `_songToMediaItem`（L6-32）：coverUrl 为 null 时 artUri 为 null → 通知栏显示默认图标，**无需改动**（注意不可把音频文件路径传给 filePath 参数，那是封面文件参数）

* 歌单详情页 L308-368 的歌曲行布局（48px 高、序号+歌名+歌手+Play 图标）可作列表 UI 参考

## 实现步骤

### 1. pubspec.yaml — 添加依赖

```yaml
  # 本地音乐扫描（MediaStore）
  on_audio_query: ^2.9.0
```

自带 `permissionsRequest()/permissionsStatus()`，无需 permission\_handler。
**关键**：其返回类型 `SongModel` 与项目 `SongModel` 同名，引用处必须前缀导入 `import 'package:on_audio_query/on_audio_query.dart' as aq;`

### 2. AndroidManifest.xml — 添加权限

`<application>` 之前追加：

```xml
<uses-permission android:name="android.permission.READ_MEDIA_AUDIO"/>
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>
```

Android 13+ 走 READ\_MEDIA\_AUDIO，12 及以下走 READ\_EXTERNAL\_STORAGE。

### 3. lib/models/song\_model.dart — 扩展 SongModel

* 新增字段 `final String? localPath;`（在线歌为 null），加入构造函数

* 新增 `bool get isLocal => localPath != null;`

* `copyWith` 增加 localPath 参数（用 `localPath ?? this.localPath`）

* `toJson` 增加 `'localPath': localPath`；`fromStorage` 增加 `localPath: json['localPath'] as String?`

* 本地歌曲 id 约定为 `'local_<MediaStore id>'`（与网易云纯数字 id 零冲突，天然防在线接口误调）

### 4. lib/services/audio\_player\_service.dart — 播放分支

**play()（L572）顶部加本地分支**：

```dart
if (song.isLocal) {
  // 本地歌曲：清空上一首在线歌的歌词/卡拉OK，直接播文件
  _lyrics = []; _lyricController.add([]); _karaoke = null; _karaokeController.add(null);
  ...（沿用 _updateState(loading)、_currentSong 赋值、stop 等）
  await _player.setAudioSource(AudioSource.file(File(song.localPath!)))
      .timeout(const Duration(seconds: 15));
  if (gen != _playGeneration) return true;
  _trialController.add(false);
  await _player.play();
  return true;
}
```

跳过：`_fetchLyrics`、`getSongUrlInfo`、试听判定、封面回填（L615-630）。

**playSongs()（L705）两处分支**：

* fetchWorker（L737-747）：`if (songs[i].isLocal) { urls[i] = 'local'; trialFlags[i] = false; continue; }`（不消耗在线 API 并发）

* 组源循环（L754-761）：`if (songs[i].isLocal)` → 无条件加入 playable，`sources.add(AudioSource.file(File(songs[i].localPath!)))`，否则沿用 `AudioSource.uri`

* L728/L778 的 `_fetchLyrics(...)` 加 isLocal 守卫（本地歌不拉歌词，同时清空歌词状态）

### 5. lib/screens/home\_page.dart — 接入入口（L275-277）

```dart
_buildHomeTab('本地', onTap: () => Navigator.push(
  context, MaterialPageRoute(builder: (_) => const LocalMusicPage()))),
```

### 6. 新建 lib/screens/local\_music\_page.dart（约 250 行）

参考 playlist\_detail\_page.dart 的结构与风格：

* **状态**：`_granted`（权限）、`_loading`（扫描中）、`_songs`（项目 SongModel 列表）

* **权限流程**：initState → `aq.OnAudioQuery().permissionsStatus()`；未授权则 `permissionsRequest()`；拒绝后显示引导文案 + 「重试」按钮（基础版不做跳系统设置）

* **扫描**：授权后 `querySongs()` 映射为项目 SongModel：

  * `id: 'local_${s.id}'`、`name: s.title`、`artist: s.artist == '<unknown>' ? '未知歌手' : s.artist`、`album: s.album ?? ''`、`duration: int.tryParse(s.duration)`、`localPath: s.data`

* **UI**：AppBar「本地音乐」+ 数量副标题；扫描中 CircularProgressIndicator；已授权但列表为空显示「未找到音频文件」；列表行照搬 L308-368 布局（48px、序号+歌名+歌手+时长+Play 图标），头部「播放全部」按钮

* **播放**：播放全部 → `AudioPlayerService().playSongs(_songs)`；点击行 → `playAndAdd(song)`

* **当前播放高亮**：StreamBuilder 订阅 `AudioPlayerService().onCurrentSongChanged`，命中 `song.id` 的行歌名变主题色 + 图标切换为暂停样式

## 无需改动的文件

audio\_player\_handler.dart（通知栏，null 封面已有默认兜底）、player\_page.dart（无封面走默认背景）、main.dart（迷你条 null 封面回退 App logo）。

## 风险点

* on\_audio\_query 2023 年后停更，但 API 稳定、与 just\_audio 无依赖冲突；SongModel 同名冲突靠前缀导入规避

* 部分 ROM `permissionsStatus` 首次返回不准 → 用「已授权但扫描为空 → 提示未找到音频文件」兜底

* 损坏文件在 Concatenating 模式切到时会卡住 → 基础版接受此限制

* 本地歌播放页沿用上一首封面（现有 L100 故意不退回占位），基础版接受

## 验证方案

1. `adb push` 3-5 个音频文件（mp3/flac/m4a）到 `/sdcard/Music/`
2. 首次进入本地页 → 系统权限弹窗 → 授予 → 列表出现；拒绝路径显示引导 + 重试
3. 播放全部 / 单曲播放 / 切歌 / 暂停恢复 / 行高亮跟随
4. 混合队列：本地列表播放完在迷你条加一首在线歌，验证切歌、试听 toast 不误弹
5. 通知栏标题/歌手正确；杀进程重启后播放列表恢复，本地歌仍可播（验证 localPath 序列化）
6. `flutter analyze` 无新增告警；真机完整运行验证（热重载不影响本功能，纯 Dart 改动）

