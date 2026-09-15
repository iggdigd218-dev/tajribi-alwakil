// ignore_for_file: avoid_print
// اختبار حيّ مستقل لخدمة Edge TTS: dart run tool/edge_tts_manual.dart
import '../lib/services/edge_tts_service.dart';

Future<void> main(List<String> args) async {
  final text = args.isNotEmpty ? args[0] : 'مرحباً، أنا الوكيل. تم ترقية صوتي إلى المحرك العصبي من مايكروسوفت.';
  // تحقق SHA-256 أولاً (متجهات قياسية)
  final e1 = EdgeTtsService.sha256Hex('');
  final e2 = EdgeTtsService.sha256Hex('abc');
  print('sha256("") = $e1 ${e1 == 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' ? "✅" : "❌"}');
  print('sha256("abc") = $e2 ${e2 == 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' ? "✅" : "❌"}');
  print('GEC token = ${EdgeTtsService.gecToken()}');
  final sw = Stopwatch()..start();
  final path = await EdgeTtsService.synthesize(text);
  sw.stop();
  if (path == null) {
    print('❌ فشل التوليد (${sw.elapsedMilliseconds}ms)');
  } else {
    print('✅ وُلّد في ${sw.elapsedMilliseconds}ms → $path');
  }
}
