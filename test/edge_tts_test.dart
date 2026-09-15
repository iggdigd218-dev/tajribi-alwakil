// اختبارات خدمة Edge TTS العصبية — منطق خالص بلا شبكة (آمن للتشغيل دائماً).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:agent_automation/services/edge_tts_service.dart';

void main() {
  group('SHA-256 الخالص (بلا حزم خارجية)', () {
    test('متجهات قياسية معروفة', () {
      expect(
        EdgeTtsService.sha256Hex(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        EdgeTtsService.sha256Hex('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      // متجه يتجاوز كتلة 64 بايت (يختبر الحشو والتكتيل)
      expect(
        EdgeTtsService.sha256Hex(
          'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });

    test('نص عربي طويل — لا ينهار', () {
      final h = EdgeTtsService.sha256Hex('الوكيل العصبي ' * 20);
      expect(h.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(h), isTrue);
    });
  });

  group('رمز DRM (Sec-MS-GEC)', () {
    test('64 حرفاً سداسياً عريضاً', () {
      final t = EdgeTtsService.gecToken();
      expect(RegExp(r'^[0-9A-F]{64}$').hasMatch(t), isTrue);
    });

    test('مستقر داخل نافذة الخمس دقائق ويتغير بعدها', () {
      final base = DateTime.utc(2026, 9, 15, 12, 7, 30);
      final a = EdgeTtsService.gecToken(now: base);
      final b = EdgeTtsService.gecToken(
        now: base.add(const Duration(seconds: 60)),
      );
      final c = EdgeTtsService.gecToken(
        now: base.add(const Duration(minutes: 5)),
      );
      expect(a, b, reason: 'داخل نفس نافذة 12:05–12:10');
      expect(a, isNot(c), reason: 'النافذة التالية رمزها مختلف');
    });

    test('قابل لإعادة الإنتاج يدوياً (توافق مع خوارزمية Edge)', () {
      // 2026-09-15 12:00:00 UTC → ticks = (unix + 11644473600) * 1e7
      final fixed = DateTime.utc(2026, 9, 15, 12, 0, 0);
      final unix = fixed.millisecondsSinceEpoch ~/ 1000;
      var ticks = (unix + 11644473600) * 10000000;
      ticks -= ticks % (5 * 60 * 10000000);
      final expected = EdgeTtsService.sha256Hex('$ticks'
              '6A5AA1D4EAFF4E9FB37E23D68491D6F4')
          .toUpperCase();
      expect(EdgeTtsService.gecToken(now: fixed), expected);
    });
  });

  group('هروب XML للـ SSML', () {
    test('الرموز الخطرة تُهرَب', () {
      expect(
        EdgeTtsService.escapeXml('<a & b> "x" \'y\''),
        '&lt;a &amp; b&gt; &quot;x&quot; &apos;y&apos;',
      );
    });
    test('العربية تمر كما هي', () {
      expect(EdgeTtsService.escapeXml('افتح واتساب الآن'), 'افتح واتساب الآن');
    });
  });

  group('تحليل إطارات الصوت الثنائية', () {
    test('يجد بداية الحمولة بعد Path:audio', () {
      final header = utf8.encode(
        'X-RequestId:ABC\r\nContent-Type:audio/mpeg\r\n'
        'X-StreamId:D\r\nPath:audio\r\n',
      );
      final frame = <int>[0x00, 0x80, ...header, 0xFF, 0xFB, 0x90, 0x64];
      final off = EdgeTtsService.audioPayloadOffset(frame);
      expect(off, 2 + header.length);
      expect(frame.sublist(off).first, 0xFF, reason: 'أول بايت MP3 sync');
    });

    test('إطار غير صوتي → -1', () {
      final frame = utf8.encode('X-RequestId:ABC\r\nPath:turn.start\r\n\r\n{}');
      expect(EdgeTtsService.audioPayloadOffset(frame), -1);
    });

    test('إطار فارغ/قصير → -1 بلا انهيار', () {
      expect(EdgeTtsService.audioPayloadOffset(<int>[]), -1);
      expect(EdgeTtsService.audioPayloadOffset(<int>[1, 2, 3]), -1);
    });
  });

  group('ثوابت الخدمة', () {
    test('الصوت الافتراضي رجالي عربي', () {
      expect(EdgeTtsService.defaultVoice, 'ar-SA-HamedNeural');
      expect(EdgeTtsService.fallbackVoice, 'ar-EG-ShakirNeural');
    });

    test('synthesize بنص فارغ → null فوراً (بلا شبكة)', () async {
      expect(await EdgeTtsService.synthesize('   '), isNull);
    });
  });
}
