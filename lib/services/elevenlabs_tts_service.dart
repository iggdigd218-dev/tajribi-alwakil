import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// نطق عصبي عبر ElevenLabs — المحرك الأول بطلب المستخدم.
///
/// المفتاح يُحقن زمن الترجمة:
///   flutter build apk --dart-define=AGENT_ELEVENLABS_KEY=‹المفتاح›
/// (سكربتات البناء تمرّره تلقائياً — لا يدخل تاريخ Git).
///
/// النموذج `eleven_multilingual_v2` يدعم العربية بصوت طبيعي جداً.
/// عند أي فشل (402 رصيد / شبكة / مهلة) تعود السلسلة لصوت Edge العصبي
/// المجاني ثم محرك النظام — فلا ينقطع الكلام أبداً.
class ElevenLabsTtsService {
  ElevenLabsTtsService._();

  static const String apiKey = String.fromEnvironment('AGENT_ELEVENLABS_KEY');

  /// الصوت الوحيد المعتمد (طلب المستخدم): Wim44P0dU9HtjyzNnFsv
  static const String defaultVoiceId = 'Wim44P0dU9HtjyzNnFsv';

  static const String modelId = 'eleven_multilingual_v2';

  static const String userAgent =
      'AgentAutomation/1.3 (Linux; Android 14) Mobile Connector';

  /// آخر سبب فشل — يُعرض في تشخيص التراجع الصوتي بالواجهة.
  static String? lastError;

  static bool get isConfigured => apiKey.isNotEmpty;

  /// توليد MP3 عصبي وإعادة مسار ملف مؤقت — أو null عند أي فشل.
  static Future<String?> synthesize(
    String text, {
    String? voiceId,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final clean = text.trim();
    if (!isConfigured || clean.isEmpty) return null;

    // صوت واحد ثابت — لا بدائل ولا أنماط
    return await _attempt(clean, defaultVoiceId, timeout);
  }

  static Future<String?> _attempt(
    String text,
    String voiceId,
    Duration timeout,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..userAgent = userAgent;
    try {
      final uri = Uri.parse(
        'https://api.elevenlabs.io/v1/text-to-speech/$voiceId'
        '?model_id=$modelId',
      );
      final request = await client.postUrl(uri).timeout(timeout);
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );
      request.headers.set('xi-api-key', apiKey);
      request.add(utf8.encode(jsonEncode(<String, dynamic>{
        'text': text,
        'voice_settings': <String, dynamic>{
          'stability': 0.5,
          'similarity_boost': 0.75,
        },
      })));

      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        await response.drain<void>();
        lastError = switch (response.statusCode) {
          401 => 'ElevenLabs: المفتاح مرفوض (401)',
          402 => 'ElevenLabs: رصيد الحساب نفد (402)',
          429 => 'ElevenLabs: تجاوز حد الطلبات (429)',
          _ => 'ElevenLabs: HTTP ${response.statusCode}',
        };
        return null;
      }

      final chunks = <int>[];
      await for (final chunk in response) {
        chunks.addAll(chunk);
      }
      if (chunks.length < 512) {
        lastError = 'ElevenLabs: استجابة صوتية فارغة/ناقصة';
        return null;
      }

      final file = File(
        '${Directory.systemTemp.path}/'
        'el_${DateTime.now().microsecondsSinceEpoch}.mp3',
      );
      await file.writeAsBytes(chunks, flush: true);
      lastError = null;
      return file.path;
    } on TimeoutException {
      lastError = 'ElevenLabs: انتهت المهلة';
      return null;
    } on SocketException catch (e) {
      lastError = 'ElevenLabs: شبكة (${e.message})';
      return null;
    } catch (e) {
      lastError = 'ElevenLabs: ${e.toString().split('(').first.trim()}';
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
