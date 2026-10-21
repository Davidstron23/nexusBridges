import '../storage/storage.dart';

final class SettingsStore {
  SettingsStore(this._store);

  final JsonFileStore _store;

  Future<String?> readLanguage() async {
    try {
      final language = (await _store.read())?['language'];
      return language == 'es' || language == 'en' ? language as String : null;
    } on Exception {
      return null;
    }
  }
}

String resolveLanguage({
  required String? saved,
  required String platformLanguageCode,
}) {
  if (saved == 'es' || saved == 'en') return saved!;
  return platformLanguageCode == 'es' ? 'es' : 'en';
}
