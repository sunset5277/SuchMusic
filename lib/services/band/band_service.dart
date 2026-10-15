import 'dart:async';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'band_channel.dart';
import 'band_player_port.dart';
import 'band_protocol.dart';
import 'band_router.dart';

/// SuchMusic 手环通信 · 连接门面。
///
/// 负责：连接生命周期、握手（`sys.hello` → `sys.hello_ack`，含版本/能力协商）、
/// 信封收发、把 `req` 交给 [BandRouter] 落地到上游播放服务。
///
/// **可插拔**：功能默认关闭，只有用户在设置页显式开启后才建连；
/// 未开启时对 App 既有行为**零影响**（不注册监听、不占用资源）。
class BandService {
  BandService._internal();

  static final BandService _instance = BandService._internal();

  factory BandService() => _instance;

  /// 持久化开关键。
  static const String enabledKey = 'band.enabled';

  final BandChannel _channel = BandChannel();

  BandRouter? _router;
  StreamSubscription<dynamic>? _eventSub;

  bool _enabled = false;
  bool _sdkAvailable = false;
  int _state = BandChannel.stateUnavailable;
  String _appVersion = '1.0.0';

  final StreamController<int> _stateController =
      StreamController<int>.broadcast();

  /// 连接状态变化流。
  Stream<int> get onStateChanged => _stateController.stream;

  /// 是否已启用（用户开关）。
  bool get enabled => _enabled;

  /// 原生 SDK 是否可用（是否放置了 AAR）。
  bool get sdkAvailable => _sdkAvailable;

  /// 当前连接状态（-2 不可用 / 0 未连接 / 1 已连接）。
  int get connectionState => _state;

  /// App 启动时调用：仅当用户此前开启过才自动建连。**默认 no-op**。
  Future<void> autoStart() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(enabledKey) ?? false;
      if (_enabled) {
        await start();
      }
    } catch (_) {
      // 读取偏好失败：保持关闭
    }
  }

  /// 用户切换开关。
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(enabledKey, value);
    } catch (_) {
      // 忽略持久化失败
    }
    if (value) {
      await start();
    } else {
      await stop();
    }
  }

  /// 建立连接并开始监听入站消息。
  Future<void> start() async {
    _ensureRouter();
    await _loadVersion();
    _eventSub ??= _channel.events.listen(_onEvent, onError: (_) {});
    _sdkAvailable = await _channel.available();
    final status = await _channel.start();
    _updateState(status);
  }

  /// 断开连接。
  Future<void> stop() async {
    await _channel.stop();
    _updateState(BandChannel.stateUnavailable);
  }

  BandRouter _ensureRouter() {
    final existing = _router;
    if (existing != null) return existing;
    final router = BandRouter(
      port: AudioPlayerServiceBandPort(),
      send: _send,
    );
    router.attach();
    _router = router;
    return router;
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _appVersion = info.version;
    } catch (_) {
      // 非 Android / 测试环境：保留默认版本号
    }
  }

  // ----- 收发 -----

  void _send(BandEnvelope env) {
    unawaited(_channel.send(env.encode()));
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'];
    switch (type) {
      case 'available':
        _sdkAvailable = (event['available'] as bool?) ?? false;
        break;
      case 'state':
        _updateState((event['state'] as num?)?.toInt() ?? BandChannel.stateUnavailable);
        break;
      case 'message':
        final data = event['data'] as String?;
        if (data != null) {
          unawaited(_onInbound(data));
        }
        break;
      case 'error':
        // 链路错误：交由上层 UI 呈现即可，这里不改状态
        break;
      default:
        break;
    }
  }

  Future<void> _onInbound(String json) async {
    BandEnvelope env;
    try {
      env = BandEnvelope.decode(json);
    } catch (_) {
      return; // E_BADREQ：丢弃 + 不重试
    }
    if (!env.isReq) return; // 手机侧不处理来自手环的 res/err/evt

    final method = env.method ?? '';
    if (method.startsWith('sys.')) {
      _handleSys(env);
      return;
    }
    final router = _router;
    if (router == null) {
      _send(BandEnvelope.err(
        id: env.id,
        code: BandError.notReady,
        message: 'router not ready',
      ));
      return;
    }
    final res = await router.handleRequest(env);
    _send(res);
  }

  void _handleSys(BandEnvelope env) {
    switch (env.method) {
      case 'sys.hello':
        _handleHello(env);
        break;
      case 'sys.ping':
        _send(BandEnvelope.res(id: env.id, payload: {'t': _now()}));
        break;
      default:
        _send(BandEnvelope.err(
          id: env.id,
          code: BandError.unsupported,
          message: 'unknown sys method: ${env.method}',
        ));
    }
  }

  void _handleHello(BandEnvelope env) {
    final bandProto = _intList(env.payload['proto']);
    final bandCaps = _strList(env.payload['caps']);
    final version = negotiateVersion(bandProto, const [kBandProtoVersion]);
    if (version == null) {
      _send(BandEnvelope.err(
        id: env.id,
        code: BandError.unsupported,
        message: 'no common protocol',
        missing: 'proto',
      ));
      _send(BandEnvelope.evt(
        event: 'sys.error',
        payload: {'code': 'E_PROTO', 'message': 'no common protocol'},
      ));
      return;
    }
    final caps = negotiateCaps(bandCaps, kPhoneCaps);
    _router?.setSession(version: version, caps: caps);
    _send(BandEnvelope.evt(
      event: 'sys.hello_ack',
      payload: {
        'proto': [version],
        'caps': caps,
        'server': {'app': 'such_music', 'ver': _appVersion},
        'clock': _now(),
      },
    ));
  }

  void _updateState(int state) {
    if (_state == state) return;
    _state = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  int _now() => DateTime.now().millisecondsSinceEpoch;

  static List<int> _intList(dynamic value) {
    if (value is List) {
      return value.map((e) => (e as num).toInt()).toList();
    }
    return const <int>[];
  }

  static List<String> _strList(dynamic value) {
    if (value is List) {
      return value.map((e) => e.toString()).toList();
    }
    return const <String>[];
  }

  void dispose() {
    _eventSub?.cancel();
    _eventSub = null;
    _router?.dispose();
    _stateController.close();
  }
}
