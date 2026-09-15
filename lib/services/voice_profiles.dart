/// أنماط الأصوات الرجالية الخمسة — يختار المستخدم أحدها من الإعدادات.
///
/// كل نمط يحدّد صوت Edge TTS المجاني (لهجة عربية مختلفة) وصوت ElevenLabs
/// المقابل حين يتوفر رصيد — فيبقى النطق رجالياً طبيعياً بأي محرك عمل.
class VoiceProfile {
  const VoiceProfile({
    required this.id,
    required this.label,
    required this.description,
    required this.edgeVoice,
    required this.elevenVoiceId,
  });

  final String id;
  final String label;
  final String description;
  final String edgeVoice;
  final String elevenVoiceId;

  static const List<VoiceProfile> all = [
    VoiceProfile(
      id: 'calm',
      label: 'عميق هادئ',
      description: 'سرد سعودي مطمئن بإيقاع بطيء',
      edgeVoice: 'ar-SA-HamedNeural',
      elevenVoiceId: 'pNInz6obpgDQGcFmaJgB',
    ),
    VoiceProfile(
      id: 'news',
      label: 'إخباري واضح',
      description: 'نبرة مصرية واضحة كنشرات الأخبار',
      edgeVoice: 'ar-EG-ShakirNeural',
      elevenVoiceId: 'ErXwobaYiN019PkySvjV',
    ),
    VoiceProfile(
      id: 'warm',
      label: 'دافئ مغاربي',
      description: 'نبرة مغربية ودودة قريبة من القلب',
      edgeVoice: 'ar-MA-JamalNeural',
      elevenVoiceId: 'TxGEqnHWrfWFTfGW9XjX',
    ),
    VoiceProfile(
      id: 'young',
      label: 'شبابي سريع',
      description: 'صوت تونسي حيوي سريع الاستجابة',
      edgeVoice: 'ar-TN-HediNeural',
      elevenVoiceId: 'yoZ06aMxZJJ28mfd3AtQ',
    ),
    VoiceProfile(
      id: 'formal',
      label: 'فصيح رسمي',
      description: 'جزائري واثق بلهجة رسمية وقورة',
      edgeVoice: 'ar-DZ-IsmaelNeural',
      elevenVoiceId: 'VR6AewLTigWG4xSOukaG',
    ),
  ];

  static VoiceProfile byId(String? id) =>
      all.firstWhere((p) => p.id == id, orElse: () => all.first);
}
