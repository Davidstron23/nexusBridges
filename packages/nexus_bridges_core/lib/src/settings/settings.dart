import 'dart:io';

import '../storage/storage.dart';

final RegExp _folderPathStart = RegExp(r'^(?:[A-Za-z]:\\|\\\\)');
final RegExp _folderVolume = RegExp(r'^[A-Za-z0-9]{1,16}-[0-9a-f]{8}$');
const int _maxFolderPathUnits = 32767;
const int _maxExclusions = 64;
const int _maxExclusionUnits = 255;

bool _isValidSavedFolder(String path, String volume) =>
    path.isNotEmpty &&
    path.length <= _maxFolderPathUnits &&
    _folderPathStart.hasMatch(path) &&
    _folderVolume.hasMatch(volume);

final class SavedReceiveFolder {
  const SavedReceiveFolder({required this.path, required this.volumeId});

  final String path;
  final String volumeId;
}

final class SettingsStore {
  SettingsStore(this._store);

  final JsonFileStore _store;

  Future<String?> readLanguage() async {
    try {
      final language = (await _store.readVersioned(1))?['language'];
      return language == 'es' || language == 'en' ? language as String : null;
    } on Exception {
      return null;
    }
  }

  Future<List<String>?> readExclusions() async {
    try {
      final raw = (await _store.readVersioned(1))?['exclusions'];
      if (raw is! List<Object?> || raw.length > _maxExclusions) return null;
      final names = <String>[];
      for (final item in raw) {
        if (item is! String ||
            item.isEmpty ||
            item.length > _maxExclusionUnits) {
          return null;
        }
        names.add(item);
      }
      return names;
    } on Exception {
      return null;
    }
  }

  Future<SavedReceiveFolder?> readReceiveFolder() async {
    try {
      final raw = (await _store.readVersioned(1))?['receiveFolder'];
      if (raw is! Map<String, Object?> || raw.length != 2) return null;
      final path = raw['path'];
      final volume = raw['volume'];
      if (path is! String || volume is! String) return null;
      if (!_isValidSavedFolder(path, volume)) return null;
      return SavedReceiveFolder(path: path, volumeId: volume);
    } on Exception {
      return null;
    }
  }

  Future<bool> writeReceiveFolder(SavedReceiveFolder folder) async {
    if (!_isValidSavedFolder(folder.path, folder.volumeId)) return false;
    try {
      Map<String, Object?> json;
      try {
        final current = await _store.read();
        if (current == null) {
          json = {'version': 1};
        } else {
          final version = current['version'];
          if (version is! int || version != 1) return false;
          json = {...current};
        }
      } on FormatException {
        await _store.quarantine(DateTime.now());
        json = {'version': 1};
      }
      json['receiveFolder'] = {'path': folder.path, 'volume': folder.volumeId};
      await _store.write(json);
      return true;
    } on Exception {
      return false;
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

Future<String> loadLanguage({
  required String platformLanguageCode,
  Directory? dataDir,
}) async {
  final Directory dir;
  try {
    dir = dataDir ?? defaultDataDir();
  } on StateError {
    return resolveLanguage(
      saved: null,
      platformLanguageCode: platformLanguageCode,
    );
  }
  final saved = await SettingsStore(
    JsonFileStore(File('${dir.path}${Platform.pathSeparator}settings.json')),
  ).readLanguage();
  return resolveLanguage(
    saved: saved,
    platformLanguageCode: platformLanguageCode,
  );
}
