import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/band/band_chunk.dart';

void main() {
  group('CRC32', () {
    test('标准向量 "123456789" == 0xCBF43926', () {
      expect(BandChunk.crc32(utf8.encode('123456789')), 0xCBF43926);
      expect(BandChunk.crc32Hex(utf8.encode('123456789')), 'cbf43926');
    });

    test('空串 CRC32 == 0', () {
      expect(BandChunk.crc32(const []), 0);
      expect(BandChunk.crc32Hex(const []), '00000000');
    });
  });

  group('文本分片 / 组装往返', () {
    test('短文本单帧', () {
      final frames =
          BandChunk.splitText(tid: 't-0001', kind: 'lyric_window', text: '你好');
      expect(frames.length, 3); // header + 1 data + end
      expect(frames.first['phase'], 'header');
      expect(frames.first['total'], 1);
      expect(frames.last['phase'], 'end');
    });

    test('长文本多帧往返还原一致', () {
      final text = 'SuchMusic 手环歌词测试 ' * 200; // UTF-8 远超 900B
      final frames =
          BandChunk.splitText(tid: 't-0002', kind: 'search_result', text: text);
      expect(frames.first['total'], greaterThan(1));

      final asm = BandChunkAssembler();
      asm.onHeader(frames.first);
      // 逐 data 落位
      frames.sublist(1, frames.length - 1).forEach(asm.onData);
      final result = asm.onEnd(frames.last);
      expect(result.status, ChunkStatus.complete);
      expect(result.text, text);
    });

    test('不切断多字节字符：每片 UTF-8 字节数 <= 900', () {
      final text = '汉' * 1000; // 每字 3 字节
      final frames =
          BandChunk.splitText(tid: 't-0003', kind: 'lyric_window', text: text);
      for (final f in frames.where((e) => e['phase'] == 'data')) {
        expect(utf8.encode(f['txt'] as String).length, lessThanOrEqualTo(900));
      }
      final asm = BandChunkAssembler();
      asm.onHeader(frames.first);
      frames.sublist(1, frames.length - 1).forEach(asm.onData);
      expect(asm.onEnd(frames.last).text, text);
    });

    test('缺失分片 → 失败并给出 missing 序号', () {
      final text = 'A' * 2500;
      final frames =
          BandChunk.splitText(tid: 't-0004', kind: 'search_result', text: text);
      final asm = BandChunkAssembler();
      asm.onHeader(frames.first);
      // 故意漏掉 seq == 1 的 data 帧
      frames.sublist(1, frames.length - 1).forEach((f) {
        if (f['seq'] != 1) asm.onData(f);
      });
      final result = asm.onEnd(frames.last);
      expect(result.status, ChunkStatus.failed);
      expect(result.missing, contains(1));
    });

    test('CRC 不符 → 失败', () {
      final text = 'B' * 2000;
      final frames =
          BandChunk.splitText(tid: 't-0005', kind: 'search_result', text: text);
      final asm = BandChunkAssembler();
      asm.onHeader(frames.first);
      frames.sublist(1, frames.length - 1).forEach((f) {
        final corrupted = Map<String, dynamic>.from(f);
        corrupted['txt'] = '${f['txt']}X';
        asm.onData(corrupted);
      });
      final result = asm.onEnd(frames.last);
      expect(result.status, ChunkStatus.failed);
      expect(result.error, 'E_CRC');
    });

    test('超过组装上限 → E_TOOLARGE', () {
      final frames = BandChunk.splitText(
        tid: 't-0006',
        kind: 'search_result',
        text: 'C' * 100,
      );
      frames.first['bytes'] = BandChunk.assembleMaxBytes + 1;
      final asm = BandChunkAssembler();
      asm.onHeader(frames.first);
      frames.sublist(1, frames.length - 1).forEach(asm.onData);
      final result = asm.onEnd(frames.last);
      expect(result.status, ChunkStatus.failed);
      expect(result.error, 'E_TOOLARGE');
    });
  });

  group('二进制分片', () {
    test('base64 分片往返（length + crc 校验）', () {
      final bytes = List<int>.generate(2000, (i) => i % 256);
      final frames =
          BandChunk.splitBytes(tid: 't-0007', kind: 'cover', data: bytes);
      expect(frames.first['crc32'], BandChunk.crc32Hex(bytes));
      expect(frames.first['bytes'], bytes.length);

      // 手动按 base64 还原并校验
      final buffer = <int>[];
      for (final f in frames.where((e) => e['phase'] == 'data')) {
        buffer.addAll(base64Decode(f['b64'] as String));
      }
      expect(buffer, bytes);
      expect(BandChunk.crc32Hex(buffer), BandChunk.crc32Hex(bytes));
    });
  });

  group('内联阈值', () {
    test('exceedsInline 依据 UTF-8 字节数', () {
      expect(BandChunk.exceedsInline('a' * 899), isFalse);
      expect(BandChunk.exceedsInline('a' * 901), isTrue);
      expect(BandChunk.exceedsInline('汉' * 301), isTrue); // 903 字节
    });
  });
}
