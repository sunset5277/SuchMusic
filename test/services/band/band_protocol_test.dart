import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/band/band_protocol.dart';

void main() {
  group('BandEnvelope 编解码往返', () {
    test('req 信封字段完整且可往返', () {
      final env = BandEnvelope.req(
        id: 'p-3c0e-0007',
        method: 'playback.next',
        payload: const {},
        ts: 1730000000000,
      );
      final raw = env.encode();
      // 字段顺序与冻结信封一致
      expect(raw.startsWith('{"v":1,"id":"p-3c0e-0007","type":"req","method":"playback.next"'), isTrue);

      final decoded = BandEnvelope.decode(raw);
      expect(decoded.v, kBandProtoVersion);
      expect(decoded.id, 'p-3c0e-0007');
      expect(decoded.type, BandType.req);
      expect(decoded.method, 'playback.next');
      expect(decoded.payload, isEmpty);
      expect(decoded.ts, 1730000000000);
    });

    test('evt 信封（event 字段）往返', () {
      final env = BandEnvelope.evt(
        id: 'p-3c0e-0012',
        event: 'player.song',
        payload: {'song': {'id': 'x', 'durationMs': 1000}},
      );
      final decoded = BandEnvelope.decode(env.encode());
      expect(decoded.type, BandType.evt);
      expect(decoded.event, 'player.song');
      expect(decoded.method, isNull);
      expect((decoded.payload['song'] as Map)['id'], 'x');
    });

    test('res / err 复用请求 id', () {
      final res = BandEnvelope.res(id: 'b-7fa1-0001', payload: {'ok': true});
      expect(BandEnvelope.decode(res.encode()).id, 'b-7fa1-0001');

      final err = BandEnvelope.err(
        id: 'b-7fa1-0001',
        code: BandError.unsupported,
        message: 'no cap',
        missing: BandCaps.volume,
      );
      final decoded = BandEnvelope.decode(err.encode());
      expect(decoded.type, BandType.err);
      expect(decoded.payload['code'], 'E_UNSUPPORTED');
      expect(decoded.payload['missing'], 'volume');
    });

    test('随机 payload 编解码幂等', () {
      for (final sample in <Map<String, dynamic>>[
        {'a': 1, 'b': '中文', 'c': [1, 2, 3]},
        {'nested': {'k': true}, 'f': 3.14},
        {'empty': {}},
      ]) {
        final env = BandEnvelope.evt(event: 'player.queue', payload: sample);
        final decoded = BandEnvelope.decode(env.encode());
        expect(jsonEncode(decoded.payload), jsonEncode(sample));
      }
    });

    test('非法 JSON 抛 FormatException', () {
      expect(() => BandEnvelope.decode('not-json'), throwsFormatException);
      expect(() => BandEnvelope.decode('[1,2,3]'), throwsFormatException);
    });
  });

  group('版本协商', () {
    test('取交集最大值', () {
      expect(negotiateVersion(const [1], const [1]), 1);
      expect(negotiateVersion(const [1, 2], const [2, 3]), 2);
      expect(negotiateVersion(const [2, 3], const [1, 2, 3]), 3);
    });

    test('交集为空返回 null', () {
      expect(negotiateVersion(const [1], const [2]), isNull);
      expect(negotiateVersion(const [], const [1]), isNull);
    });
  });

  group('能力协商', () {
    test('交集 + 确定性排序', () {
      final caps = negotiateCaps(
        const ['playback', 'volume', 'queue'],
        const ['playback', 'queue', 'search'],
      );
      expect(caps, ['playback', 'queue']);
    });

    test('方法/事件 → 能力映射', () {
      expect(methodCap('playback.setMode'), BandCaps.playmode);
      expect(methodCap('playback.setVolume'), BandCaps.volume);
      expect(methodCap('state.get'), isNull);
      expect(eventCap('player.progress'), BandCaps.playback);
      expect(eventCap('player.song'), isNull);
    });

    test('手机能力不含 volume（上游无独立音量控制）', () {
      expect(kPhoneCaps.contains(BandCaps.volume), isFalse);
    });
  });

  group('错误码', () {
    test('码值冻结', () {
      expect(BandError.badReq.code, 'E_BADREQ');
      expect(BandError.tooLarge.code, 'E_TOOLARGE');
      expect(BandError.crc.code, 'E_CRC');
    });

    test('字符串反查，未知回退 internal', () {
      expect(BandError.fromCode('E_TIMEOUT'), BandError.timeout);
      expect(BandError.fromCode('E_UNKNOWN'), BandError.internal);
      expect(BandError.fromCode(null), BandError.internal);
    });
  });

  group('id 生成与 LRU', () {
    test('id 格式 {origin}-{bootId}-{seq}', () {
      final gen = BandIdGenerator(origin: 'p', bootId: 'abcd');
      expect(gen.next(), 'p-abcd-0000');
      expect(gen.next(), 'p-abcd-0001');
      expect(gen.next(), 'p-abcd-0002');
    });

    test('LRU 容量与顺序', () {
      final lru = LruCache<String, int>(2);
      lru.put('a', 1);
      lru.put('b', 2);
      expect(lru.get('a'), 1); // 刷新 a 的使用顺序
      lru.put('c', 3); // 淘汰最久未用的 b
      expect(lru.containsKey('b'), isFalse);
      expect(lru.containsKey('a'), isTrue);
      expect(lru.containsKey('c'), isTrue);
      expect(lru.length, 2);
    });
  });
}
