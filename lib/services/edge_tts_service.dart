import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// نطق عصبي مجاني عبر Microsoft Edge TTS — بلا مفاتيح API وبلا تكلفة.
///
/// البروتوكول: WebSocket إلى خدمة القراءة الجهرية في Edge، مع رموز
/// DRM التي يفرضها الطرف الخادم (Sec-MS-GEC = SHA-256 لوقت Windows
/// مقرباً لخمس دقائق + رمز العميل الثابت). الصوت الناتج MP3 يُحفظ
/// في ملف مؤقت ويعيده المسار ليتولّى المشغّل الأصلي تشغيله.
///
/// عند أي فشل (لا إنترنت، رفض خادم، مهلة) تعيد null — وعلى المستدعي
/// التراجع للنطق عبر محرك النظام (Android TTS).
///
/// ⚠️ هذا الملف مكتوب بـ dart:io/dart:convert فقط (بلا حزم خارجية)
///    حتى يعمل أيضاً كأداة سطر أوامر مستقلة للاختبار: `dart run`.
class EdgeTtsService {
  EdgeTtsService._();

  /// الصوت العصبي العربي الرجالي الافتراضي (سعودي — هاديء وواضح).
  static const String defaultVoice = 'ar-SA-ZariyahNeural';

  /// الصوت البديل (مصري) إن رُفض الأساسي.
  static const String fallbackVoice = 'ar-EG-SalmaNeural';

  /// رمز العميل العلني الثابت لتطبيق Edge.
  static const String _trustedClientToken =
      '6A5AA1D4EAFF4E9FB37E23D68491D6F4';

  static const String _wsBase =
      'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1';

  /// إصدارات Edge مرشحة لرمز DRM — الخادم يقبل النطاق الحديث منها،
  /// ونجرّبها بالترتيب عند الرفض حتى ينجح أحدها (يُحفظ الناجح للجلسة).
  static const List<String> _candidateVersions = <String>[
    '1-140.0.3462.56',
    '1-142.0.3595.94',
    '1-138.0.3351.117',
    '1-136.0.3240.92',
  ];

  static String? _workingVersion;

  /// مهلة العملية كلها (اتصال + توليد + تنزيل).
  static const Duration _totalTimeout = Duration(seconds: 25);

  /// آخر سبب فشل للتوليد العصبي — يعرضه التطبيق لتشخيص التراجع
  /// لمحرك النظام على الجهاز الفعلي (null بعد أي نجاح).
  static String? lastError;

  /// توليد كلام عصبي وإعادة مسار ملف MP3 محلي — أو null عند الفشل.
  ///
  /// [voice] اختياري؛ الافتراضي [defaultVoice] مع إعادة محاولة واحدة
  /// بالصوت البديل إن فشل الأساسي بعد نجاح الاتصال (رفض صوت مثلاً).
  static Future<String?> synthesize(
    String text, {
    String? voice,
    Duration timeout = _totalTimeout,
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) return null;
    final primary = (voice == null || voice.trim().isEmpty)
        ? defaultVoice
        : voice.trim();

    try {
      final path = await _synthesizeWithFallbackVoice(clean, primary, timeout);
      if (path == null) {
        lastError ??= 'رفض الخادم كل إصدارات DRM المرشحة';
      } else {
        lastError = null;
      }
      return path;
    } catch (e) {
      lastError = 'استثناء: ${e.toString().split(':').first}';
      return null; // أي استثناء = تراجع صامت لمحرك النظام
    }
  }

  static Future<String?> _synthesizeWithFallbackVoice(
    String text,
    String voice,
    Duration timeout,
  ) async {
    final first = await _synthesizeVersions(text, voice, timeout);
    if (first != null) return first;
    if (voice != fallbackVoice) {
      // إعادة محاولة واحدة بالصوت البديل
      return _synthesizeVersions(text, fallbackVoice, timeout);
    }
    return null;
  }

  /// تجرّب إصدارات DRM بالترتيب: الناجح يُحفظ ويُجرَّب أولاً في المرات التالية.
  static Future<String?> _synthesizeVersions(
    String text,
    String voice,
    Duration timeout,
  ) async {
    final versions = <String>[
      if (_workingVersion != null) _workingVersion!,
      ..._candidateVersions.where((v) => v != _workingVersion),
    ];
    for (final version in versions) {
      try {
        final path = await _attempt(text, voice, version)
            .timeout(timeout);
        if (path != null) {
          _workingVersion = version;
          return path;
        }
      } on TimeoutException {
        // الإصدار التالي
      } catch (_) {
        // الإصدار التالي
      }
    }
    return null;
  }

  /// محاولة واحدة بإصدار DRM محدد: تعيد مسار الملف أو null.
  static Future<String?> _attempt(
    String text,
    String voice,
    String version,
  ) async {
    final connectionId = _randomHex32();
    final url = '$_wsBase'
        '?TrustedClientToken=$_trustedClientToken'
        '&ConnectionId=$connectionId'
        '&Sec-MS-GEC=${gecToken()}'
        '&Sec-MS-GEC-Version=$version';

    WebSocket? ws;
    try {
      // ⚠️ مهم: WebSocket.connect يضيف UA افتراضياً «Dart/x.x (dart:io)»
      //    **ولا يستبدله** بما في headers — والبوابة ترفض أي UA غير متصفح.
      //    الحل: عميل HttpClient مخصص يحمل userAgent المتصفح وحده.
      final httpClient = HttpClient()
        ..userAgent = _edgeUserAgent(version);
      ws = await WebSocket.connect(
        url,
        headers: <String, String>{
          'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
          'Pragma': 'no-cache',
          'Cache-Control': 'no-cache',
        },
        customClient: httpClient,
        compression: CompressionOptions.compressionOff,
      ).timeout(const Duration(seconds: 12));
    } catch (e) {
      lastError = 'اتصال: ${e.toString().split('(').first.trim()}';
      return null; // 403/شبكة → المجرّب يجرب الإصدار التالي
    }

    final chunks = <int>[];
    final done = Completer<bool>();
    StreamSubscription<dynamic>? sub;

    try {
      final timestamp = _jsUtcDate();
      // 1) إعداد الجلسة: صيغة الصوت MP3 أحادي 24kHz/48kbps
      ws.add(
        'X-Timestamp:$timestamp\r\n'
        'Content-Type:application/json; charset=utf-8\r\n'
        'Path:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":'
        '{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"true"},'
        '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}',
      );
      // 2) طلب التوليد SSML
      ws.add(
        'X-RequestId:$connectionId\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'X-Timestamp:$timestamp\r\n'
        'Path:ssml\r\n\r\n'
        "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' "
        "xml:lang='ar-SA'><voice name='$voice'>"
        "<prosody pitch='+0Hz' rate='+0%' volume='+0%'>"
        '${escapeXml(text)}</prosody></voice></speak>',
      );

      sub = ws.listen(
        (dynamic data) {
          if (data is String) {
            if (data.contains('Path:turn.end')) {
              if (!done.isCompleted) done.complete(chunks.isNotEmpty);
            } else if (data.contains('"code"') || data.contains('Message')) {
              // رسالة خطأ من الخادم (403 صوت غير معروف …)
              if (!done.isCompleted) done.complete(false);
            }
          } else if (data is List<int>) {
            final offset = audioPayloadOffset(data);
            if (offset > 0) chunks.addAll(data.sublist(offset));
          }
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete(chunks.isNotEmpty);
        },
        onDone: () {
          if (!done.isCompleted) done.complete(chunks.isNotEmpty);
        },
        cancelOnError: false,
      );

      final ok = await done.future;
      if (!ok || chunks.isEmpty) {
        lastError = 'الخادم أغلق البث دون صوت (ربما شبكة وسيطة تحجب WSS)';
        return null;
      }

      final file = File(
        '${Directory.systemTemp.path}/'
        'edge_tts_${DateTime.now().microsecondsSinceEpoch}.mp3',
      );
      await file.writeAsBytes(chunks, flush: true);
      if (!await file.exists() || await file.length() == 0) return null;
      return file.path;
    } finally {
      await sub?.cancel();
      try {
        // ws مُرقّى لغير فارغ هنا: فشل الاتصال يخرج من الدالة قبل هذا الكتلة
        await ws.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }

  /// بداية حمولة الصوت في إطار ثنائي — أو -1 إن لم يكن إطار صوت.
  ///
  /// البنية الحقيقية (التقطت من الخادم مباشرة): بايتا نوع `00 80` ثم
  /// ترويسة نصية أسطرها `X-RequestId` و`Content-Type:audio/mpeg` و
  /// `X-StreamId` و`Path:audio` — وبعد `Path:audio\r\n` تبدأ بايتات
  /// MP3 فوراً **بلا سطر فارغ فاصل**.
  static final List<int> _audioMarker = utf8.encode('Path:audio\r\n');

  static int audioPayloadOffset(List<int> data) {
    if (data.length < _audioMarker.length + 1) return -1;
    outer:
    for (var i = 0; i <= data.length - _audioMarker.length; i++) {
      for (var j = 0; j < _audioMarker.length; j++) {
        if (data[i + j] != _audioMarker[j]) continue outer;
      }
      return i + _audioMarker.length;
    }
    return -1;
  }

  /// هروب XML آمن لنص المستخدم داخل SSML.
  static String escapeXml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  /// تاريخ بصيغة JS المستخدمة في ترويسات Edge:
  /// `Tue Sep 15 2026 19:30:00 GMT+0000 (Coordinated Universal Time)`
  static String _jsUtcDate() {
    const days = <String>[
      'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
    ];
    const months = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final n = DateTime.now().toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    // weekday: Monday=1..Sunday=7
    return '${days[n.weekday - 1]} ${months[n.month - 1]} '
        '${two(n.day)} ${n.year} ${two(n.hour)}:${two(n.minute)}:'
        '${two(n.second)} GMT+0000 (Coordinated Universal Time)';
  }

  static String _edgeUserAgent(String version) {
    final ver = version.replaceFirst('1-', '');
    return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/$ver Safari/537.36 Edg/$ver';
  }

  /// رمز DRM: SHA-256(وقت Windows بالخامات مقرباً لخمس دقائق + رمز العميل).
  /// عام ومكشوف للاختبارات — صيغة ثابتة يحددها الطرف الخادم.
  static String gecToken({DateTime? now}) {
    final unixSeconds =
        (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
    // وقت Windows File Time: 100ns منذ 1601-01-01
    var ticks = (unixSeconds + 11644473600) * 10000000;
    ticks -= ticks % (5 * 60 * 10000000); // تقريب لخمس دقائق
    return sha256Hex('$ticks$_trustedClientToken').toUpperCase();
  }

  static String _randomHex32() {
    final rnd = Random.secure();
    final sb = StringBuffer();
    for (var i = 0; i < 32; i++) {
      sb.write(rnd.nextInt(16).toRadixString(16).toUpperCase());
    }
    return sb.toString();
  }

  // ═══════════════════════════════════════════
  //  SHA-256 خالص بـ Dart — التطبيق بلا حزم خارجية
  // ═══════════════════════════════════════════

  /// SHA-256 hex (أحرف صغيرة) لنص UTF-8.
  static String sha256Hex(String input) =>
      _sha256Bytes(utf8.encode(input))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

  static const List<int> _k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  static int _rotr(int x, int n) =>
      ((x >>> n) | (x << (32 - n))) & 0xffffffff;

  static List<int> _sha256Bytes(List<int> msg) {
    final bitLen = msg.length * 8;
    final bytes = <int>[...msg, 0x80];
    while (bytes.length % 64 != 56) {
      bytes.add(0);
    }
    for (var i = 7; i >= 0; i--) {
      bytes.add((bitLen >>> (i * 8)) & 0xff);
    }

    var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
    var h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;
    final w = List<int>.filled(64, 0);

    for (var chunk = 0; chunk < bytes.length; chunk += 64) {
      for (var i = 0; i < 16; i++) {
        w[i] = (bytes[chunk + i * 4] << 24) |
            (bytes[chunk + i * 4 + 1] << 16) |
            (bytes[chunk + i * 4 + 2] << 8) |
            bytes[chunk + i * 4 + 3];
      }
      for (var i = 16; i < 64; i++) {
        final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
        final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
      }

      var a = h0, b = h1, c = h2, d = h3;
      var e = h4, f = h5, g = h6, h = h7;
      for (var i = 0; i < 64; i++) {
        final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
        final ch = (e & f) ^ ((~e & 0xffffffff) & g);
        final t1 = (h + s1 + ch + _k[i] + w[i]) & 0xffffffff;
        final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final t2 = (s0 + maj) & 0xffffffff;
        h = g;
        g = f;
        f = e;
        e = (d + t1) & 0xffffffff;
        d = c;
        c = b;
        b = a;
        a = (t1 + t2) & 0xffffffff;
      }
      h0 = (h0 + a) & 0xffffffff;
      h1 = (h1 + b) & 0xffffffff;
      h2 = (h2 + c) & 0xffffffff;
      h3 = (h3 + d) & 0xffffffff;
      h4 = (h4 + e) & 0xffffffff;
      h5 = (h5 + f) & 0xffffffff;
      h6 = (h6 + g) & 0xffffffff;
      h7 = (h7 + h) & 0xffffffff;
    }

    final out = <int>[];
    for (final v in <int>[h0, h1, h2, h3, h4, h5, h6, h7]) {
      out.addAll(<int>[(v >>> 24) & 0xff, (v >>> 16) & 0xff, (v >>> 8) & 0xff, v & 0xff]);
    }
    return out;
  }
}
