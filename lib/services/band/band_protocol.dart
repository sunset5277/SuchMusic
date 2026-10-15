/// SuchMusic 手环通信 · 协议纯函数与信封模型。
///
/// 本文件**不依赖任何 Flutter / 播放服务**，只做：信封编解码、错误码、版本/能力协商、
/// 方法→能力映射、请求 id 生成、LRU 去重缓存。便于单测。
/// 字段名与消息名均为设计文档冻结值，不得自创。
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:math';

/// 协议主版本（会话内固定为协商值）。
const int kBandProtoVersion = 1;

/// 信封 `type` 取值。
class BandType {
  static const String req = 'req';
  static const String res = 'res';
  static const String evt = 'evt';
  static const String err = 'err';
}

/// 能力令牌（冻结值）。
class BandCaps {
  static const String playback = 'playback';
  static const String queue = 'queue';
  static const String search = 'search';
  static const String lyric = 'lyric';
  static const String playmode = 'playmode';
  static const String volume = 'volume';
  static const String cover = 'cover';
  static const String transfer = 'transfer';

  static const List<String> all = [
    playback,
    queue,
    search,
    lyric,
    playmode,
    volume,
    cover,
    transfer,
  ];
}

/// 手机端（上游原版）声明的能力集合。
///
/// 注意：上游原版没有独立的音量控制（`AudioPlayerService` 未暴露 `setVolume`），
/// 故**不含** [BandCaps.volume]，握手时手环端据此隐藏音量页（降级）。
const List<String> kPhoneCaps = [
  BandCaps.playback,
  BandCaps.queue,
  BandCaps.search,
  BandCaps.lyric,
  BandCaps.playmode,
  BandCaps.cover,
  BandCaps.transfer,
];

/// 错误码（冻结）。
enum BandError {
  badReq('E_BADREQ'),
  unsupported('E_UNSUPPORTED'),
  timeout('E_TIMEOUT'),
  notReady('E_NOT_READY'),
  empty('E_EMPTY'),
  notFound('E_NOT_FOUND'),
  link('E_LINK'),
  tooLarge('E_TOOLARGE'),
  crc('E_CRC'),
  internal('E_INTERNAL');

  const BandError(this.code);

  /// 协议中的错误码字符串。
  final String code;

  /// 由字符串反查错误码，未知值回退 [BandError.internal]。
  static BandError fromCode(String? code) {
    for (final e in BandError.values) {
      if (e.code == code) return e;
    }
    return BandError.internal;
  }
}

/// 方法 → 所需能力（`null` 表示无能力要求）。冻结清单。
const Map<String, String?> kMethodCaps = {
  'sys.hello': null,
  'sys.ping': null,
  'state.get': null,
  'song.info': null,
  'playback.play': BandCaps.playback,
  'playback.pause': BandCaps.playback,
  'playback.toggle': BandCaps.playback,
  'playback.next': BandCaps.playback,
  'playback.prev': BandCaps.playback,
  'playback.seek': BandCaps.playback,
  'playback.setMode': BandCaps.playmode,
  'playback.setVolume': BandCaps.volume,
  'queue.play': BandCaps.queue,
  'queue.clear': BandCaps.queue,
  'search.song': BandCaps.search,
  'search.suggest': BandCaps.search,
  'search.hot': BandCaps.search,
  'lyric.window': BandCaps.lyric,
  'cover.get': BandCaps.cover,
  'xfer.nack': BandCaps.transfer,
};

/// 事件 → 所需能力（`null` 表示无能力要求）。冻结清单。
const Map<String, String?> kEventCaps = {
  'sys.hello_ack': null,
  'sys.error': null,
  'player.state': BandCaps.playback,
  'player.song': null,
  'player.progress': BandCaps.playback,
  'player.mode': BandCaps.playmode,
  'player.volume': BandCaps.volume,
  'player.queue': BandCaps.queue,
  'lyric.line': BandCaps.lyric,
  'lyric.meta': BandCaps.lyric,
  'search.result': BandCaps.search,
  'search.preset': BandCaps.search,
  'xfer.chunk': BandCaps.transfer,
  'band.toast': null,
};

/// 方法所需能力，未知方法返回 [kMethodUnsupported] 语义由调用方处理。
String? methodCap(String method) => kMethodCaps[method];

/// 事件所需能力。
String? eventCap(String event) => kEventCaps[event];

/// 统一信封 `{v,id,type,method|event,payload,ts}`。
class BandEnvelope {
  BandEnvelope({
    this.v = kBandProtoVersion,
    this.id,
    required this.type,
    this.method,
    this.event,
    Map<String, dynamic>? payload,
    this.ts,
  }) : payload = payload ?? <String, dynamic>{};

  /// 协议主版本。
  final int v;

  /// 格式 `{origin}-{bootId}-{seq}`；`evt` 可为 null。
  final String? id;

  /// `req` / `res` / `evt` / `err`。
  final String type;

  /// 仅 `req`。
  final String? method;

  /// 仅 `evt`。
  final String? event;

  /// 恒存在，可为 `{}`。
  final Map<String, dynamic> payload;

  /// 发送时间戳（ms）。
  final int? ts;

  /// 构造 `req`。
  factory BandEnvelope.req({
    required String id,
    required String method,
    Map<String, dynamic>? payload,
    int? ts,
    int v = kBandProtoVersion,
  }) =>
      BandEnvelope(
        v: v,
        id: id,
        type: BandType.req,
        method: method,
        payload: payload,
        ts: ts,
      );

  /// 构造 `res`。
  factory BandEnvelope.res({
    String? id,
    Map<String, dynamic>? payload,
    int v = kBandProtoVersion,
  }) =>
      BandEnvelope(v: v, id: id, type: BandType.res, payload: payload);

  /// 构造 `err`。
  factory BandEnvelope.err({
    String? id,
    required BandError code,
    String message = '',
    String? missing,
    int v = kBandProtoVersion,
  }) =>
      BandEnvelope(
        v: v,
        id: id,
        type: BandType.err,
        payload: {
          'code': code.code,
          'message': message,
          'missing': ?missing,
        },
      );

  /// 构造 `evt`。
  factory BandEnvelope.evt({
    String? id,
    required String event,
    Map<String, dynamic>? payload,
    int? ts,
    int v = kBandProtoVersion,
  }) =>
      BandEnvelope(
        v: v,
        id: id,
        type: BandType.evt,
        event: event,
        payload: payload,
        ts: ts,
      );

  /// 转为有序 Map（字段顺序与冻结信封一致）。
  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{'v': v};
    if (id != null) map['id'] = id;
    map['type'] = type;
    if (method != null) map['method'] = method;
    if (event != null) map['event'] = event;
    map['payload'] = payload;
    if (ts != null) map['ts'] = ts;
    return map;
  }

  /// 从 Map 还原；字段缺失时给出安全默认值。
  factory BandEnvelope.fromMap(Map<String, dynamic> map) {
    return BandEnvelope(
      v: (map['v'] as num?)?.toInt() ?? kBandProtoVersion,
      id: map['id'] as String?,
      type: map['type'] as String? ?? BandType.evt,
      method: map['method'] as String?,
      event: map['event'] as String?,
      payload: (map['payload'] as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{},
      ts: (map['ts'] as num?)?.toInt(),
    );
  }

  /// 序列化为 UTF-8 JSON 字符串（供传输）。
  String encode() => jsonEncode(toMap());

  /// 从 JSON 字符串解析。非法输入抛出 [FormatException]，由调用方按 E_BADREQ 处理。
  factory BandEnvelope.decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('envelope must be a JSON object');
    }
    return BandEnvelope.fromMap(decoded.cast<String, dynamic>());
  }

  bool get isReq => type == BandType.req;
  bool get isRes => type == BandType.res;
  bool get isEvt => type == BandType.evt;
  bool get isErr => type == BandType.err;
}

/// 版本协商：取两端协议版本交集的最大值；交集为空返回 `null`。
int? negotiateVersion(List<int> bandProto, List<int> phoneProto) {
  final common = bandProto.toSet().intersection(phoneProto.toSet());
  if (common.isEmpty) return null;
  return common.reduce(max);
}

/// 能力协商：`band.caps ∩ phone.caps`，返回去重且排序后的列表（保证确定性）。
List<String> negotiateCaps(List<String> bandCaps, List<String> phoneCaps) {
  final phone = phoneCaps.toSet();
  return bandCaps.where(phone.contains).toSet().toList()..sort();
}

/// 请求 id 生成器：`{origin}-{bootId}-{seq}`。
class BandIdGenerator {
  BandIdGenerator({this.origin = 'p', String? bootId, Random? random})
      : bootId = bootId ?? _randomHex4(random ?? Random());

  /// `b` 手环 / `p` 手机 / `w` Windows。
  final String origin;

  /// 各端随机 4 位 hex。
  final String bootId;

  int _seq = 0;

  /// 下一个 id。
  String next() {
    final seq = _seq++;
    return '$origin-$bootId-${seq.toString().padLeft(4, '0')}';
  }

  static String _randomHex4(Random r) =>
      r.nextInt(0x10000).toRadixString(16).padLeft(4, '0');
}

/// 通用 LRU 缓存（用于 `req.id` 幂等去重，容量默认 64）。
class LruCache<K, V> {
  LruCache(this.capacity)
      : assert(capacity > 0, 'capacity 必须为正');

  final int capacity;
  final LinkedHashMap<K, V> _map = LinkedHashMap<K, V>();

  int get length => _map.length;

  bool containsKey(K key) => _map.containsKey(key);

  /// 命中即刷新使用顺序。
  V? get(K key) {
    if (!_map.containsKey(key)) return null;
    final value = _map.remove(key) as V;
    _map[key] = value;
    return value;
  }

  void put(K key, V value) {
    if (_map.containsKey(key)) _map.remove(key);
    _map[key] = value;
    if (_map.length > capacity) {
      _map.remove(_map.keys.first);
    }
  }

  void clear() => _map.clear();
}
