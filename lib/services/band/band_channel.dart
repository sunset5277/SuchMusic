import 'package:flutter/services.dart';

/// 手环原生通道封装（MethodChannel / EventChannel）。
///
/// 通道名与 `android/.../band/BandChannelBridge.kt` 严格一致。
/// 所有调用都做了异常兜底：在非 Android 平台或未注册通道时返回安全默认值。
class BandChannel {
  static const String methodChannelName = 'com.such.music.such_music/band';
  static const String eventChannelName = 'com.such.music.such_music/band_events';

  /// SDK 不可用（未放置 AAR / 反射失败）。
  static const int stateUnavailable = -2;

  /// 已就绪但未发现手环节点。
  static const int stateDisconnected = 0;

  /// 已连接。
  static const int stateConnected = 1;

  final MethodChannel _method = const MethodChannel(methodChannelName);
  final EventChannel _event = const EventChannel(eventChannelName);

  /// 原生事件流：`{type: available|state|message|error, ...}`。
  Stream<dynamic> get events => _event.receiveBroadcastStream();

  Future<int> status() async {
    try {
      return await _method.invokeMethod<int>('status') ?? stateUnavailable;
    } catch (_) {
      return stateUnavailable;
    }
  }

  Future<bool> available() async {
    try {
      return await _method.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<int> start() async {
    try {
      return await _method.invokeMethod<int>('start') ?? stateUnavailable;
    } catch (_) {
      return stateUnavailable;
    }
  }

  Future<void> stop() async {
    try {
      await _method.invokeMethod<void>('stop');
    } catch (_) {
      // 忽略：通道不可用时无需处理
    }
  }

  Future<bool> send(String json) async {
    try {
      return await _method.invokeMethod<bool>('send', json) ?? false;
    } catch (_) {
      return false;
    }
  }
}
