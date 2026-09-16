/// أنماط الأصوات الرجالية الخمسة — يختار المستخدم أحدها من الإعدادات.
///
/// كل نمط يحدّد صوت Edge TTS المجاني (لهجة عربية مختلفة) للاحتياط والعينات؛
/// أما ElevenLabs فصوته الوحيد المعتمد داخل خدمته نفسها.
class VoiceProfile {
  const VoiceProfile({
    required this.id,
    required this.label,
    required this.description,
    required this.edgeVoice,
  });

  final String id;
  final String label;
  final String description;
  final String edgeVoice;

  static const List<VoiceProfile> all = [
    VoiceProfile(
      id: 'calm',
      label: 'أنثوي هادئ',
      description: 'صوت نسائي سعودي مطمئن بإيقاع هادئ',
      edgeVoice: 'ar-SA-ZariyahNeural',
    ),
    VoiceProfile(
      id: 'news',
      label: 'أنثوي إخباري',
      description: 'صوت نسائي مصري واضح كنشرات الأخبار',
      edgeVoice: 'ar-EG-SalmaNeural',
    ),
    VoiceProfile(
      id: 'warm',
      label: 'دافئ مغاربي',
      description: 'نبرة مغربية ودودة قريبة من القلب',
      edgeVoice: 'ar-MA-JamalNeural',
    ),
    VoiceProfile(
      id: 'young',
      label: 'شبابي سريع',
      description: 'صوت تونسي حيوي سريع الاستجابة',
      edgeVoice: 'ar-TN-HediNeural',
    ),
    VoiceProfile(
      id: 'formal',
      label: 'فصيح رسمي',
      description: 'جزائري واثق بلهجة رسمية وقورة',
      edgeVoice: 'ar-DZ-IsmaelNeural',
    ),
  ];

  static VoiceProfile byId(String? id) =>
      all.firstWhere((p) => p.id == id, orElse: () => all.first);
}
