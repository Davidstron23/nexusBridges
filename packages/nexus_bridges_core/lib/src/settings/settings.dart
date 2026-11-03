import 'dart:io';

import '../storage/storage.dart';

final RegExp _folderPathStart = RegExp(r'^(?:[A-Za-z]:\\|\\\\)');
final RegExp _folderVolume = RegExp(r'^[A-Za-z0-9]{1,16}-[0-9a-f]{8}$');
const int _maxFolderPathUnits = 32767;
const int _maxExclusions = 64;
const int _maxExclusionUnits = 255;
const int _maxDeviceNameUnits = 256;

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

enum ThemeChoice { dark, light, system }

final class SettingsSnapshot {
  const SettingsSnapshot({
    this.language,
    this.deviceName,
    this.theme = ThemeChoice.dark,
    this.receiveFolder,
    this.exclusions,
    this.closeToTray = true,
    this.trayHintShown = false,
  });

  final String? language;
  final String? deviceName;
  final ThemeChoice theme;
  final SavedReceiveFolder? receiveFolder;
  final List<String>? exclusions;
  final bool closeToTray;
  final bool trayHintShown;
}

final class StartupSettings {
  const StartupSettings({
    required this.language,
    this.theme = ThemeChoice.dark,
    this.closeToTray = true,
    this.trayHintShown = false,
  });

  final String language;
  final ThemeChoice theme;
  final bool closeToTray;
  final bool trayHintShown;
}

List<String>? _parseExclusions(Object? raw) {
  if (raw is! List<Object?> || raw.length > _maxExclusions) return null;
  final names = <String>[];
  for (final item in raw) {
    if (item is! String || item.isEmpty || item.length > _maxExclusionUnits) {
      return null;
    }
    names.add(item);
  }
  return names;
}

SavedReceiveFolder? _parseReceiveFolder(Object? raw) {
  if (raw is! Map<String, Object?> || raw.length != 2) return null;
  final path = raw['path'];
  final volume = raw['volume'];
  if (path is! String || volume is! String) return null;
  if (!_isValidSavedFolder(path, volume)) return null;
  return SavedReceiveFolder(path: path, volumeId: volume);
}

final class SettingsStore {
  SettingsStore(this._store, {this._now = DateTime.now});

  final JsonFileStore _store;
  final DateTime Function() _now;

  Future<void> _tail = Future<void>.value();
  bool _readOnly = false;

  Future<SettingsSnapshot> load() async {
    final Map<String, Object?>? json;
    try {
      json = await _store.read();
    } on FormatException {
      await _quarantine();
      return const SettingsSnapshot();
    } on Exception {
      return const SettingsSnapshot();
    }
    if (json == null) return const SettingsSnapshot();
    final version = json['version'];
    if (version is int && version > 1) {
      _readOnly = true;
      return const SettingsSnapshot();
    }
    if (version is! int || version < 1) {
      await _quarantine();
      return const SettingsSnapshot();
    }
    final language = json['language'];
    final deviceName = json['deviceName'];
    final theme = json['theme'];
    final closeToTray = json['closeToTray'];
    final trayHintShown = json['trayHintShown'];
    return SettingsSnapshot(
      language: language == 'es' || language == 'en'
          ? language as String
          : null,
      deviceName:
          deviceName is String &&
              deviceName.isNotEmpty &&
              deviceName.length <= _maxDeviceNameUnits
          ? deviceName
          : null,
      theme: theme is String
          ? ThemeChoice.values.asNameMap()[theme] ?? ThemeChoice.dark
          : ThemeChoice.dark,
      receiveFolder: _parseReceiveFolder(json['receiveFolder']),
      exclusions: _parseExclusions(json['exclusions']),
      closeToTray: closeToTray is bool ? closeToTray : true,
      trayHintShown: trayHintShown is bool ? trayHintShown : false,
    );
  }

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
      return _parseExclusions((await _store.readVersioned(1))?['exclusions']);
    } on Exception {
      return null;
    }
  }

  Future<SavedReceiveFolder?> readReceiveFolder() async {
    try {
      return _parseReceiveFolder(
        (await _store.readVersioned(1))?['receiveFolder'],
      );
    } on Exception {
      return null;
    }
  }

  Future<bool> writeDeviceName(String? name) {
    return _update((json) {
      if (name == null) {
        json.remove('deviceName');
      } else {
        json['deviceName'] = name;
      }
    });
  }

  Future<bool> writeLanguage(String code) {
    if (code != 'es' && code != 'en') return Future<bool>.value(false);
    return _update((json) => json['language'] = code);
  }

  Future<bool> writeTheme(ThemeChoice theme) {
    return _update((json) => json['theme'] = theme.name);
  }

  Future<bool> writeExclusions(List<String> names) {
    final copy = List<String>.of(names);
    if (_parseExclusions(copy) == null) return Future<bool>.value(false);
    return _update((json) => json['exclusions'] = copy);
  }

  Future<bool> writeCloseToTray(bool enabled) {
    return _update((json) => json['closeToTray'] = enabled);
  }

  Future<bool> writeTrayHintShown() {
    return _update((json) => json['trayHintShown'] = true);
  }

  Future<bool> writeReceiveFolder(SavedReceiveFolder folder) {
    if (!_isValidSavedFolder(folder.path, folder.volumeId)) {
      return Future<bool>.value(false);
    }
    return _update((json) {
      json['receiveFolder'] = {'path': folder.path, 'volume': folder.volumeId};
    });
  }

  Future<bool> _update(void Function(Map<String, Object?> json) change) {
    final run = _tail.then((_) => _updateOnce(change));
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<bool> _updateOnce(
    void Function(Map<String, Object?> json) change,
  ) async {
    if (_readOnly) return false;
    try {
      Map<String, Object?> json;
      try {
        final current = await _store.read();
        if (current == null) {
          json = {'version': 1};
        } else {
          final version = current['version'];
          if (version is int && version > 1) {
            _readOnly = true;
            return false;
          }
          if (version is! int || version < 1) {
            await _store.quarantine(_now());
            json = {'version': 1};
          } else {
            json = {...current};
          }
        }
      } on FormatException {
        await _store.quarantine(_now());
        json = {'version': 1};
      }
      change(json);
      await _store.write(json);
      return true;
    } on Exception {
      return false;
    }
  }

  Future<void> _quarantine() async {
    try {
      await _store.quarantine(_now());
    } on Exception {
      return;
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

Future<StartupSettings> loadStartupSettings({
  required String platformLanguageCode,
  Directory? dataDir,
}) async {
  var snapshot = const SettingsSnapshot();
  try {
    final dir = dataDir ?? defaultDataDir();
    snapshot = await SettingsStore(
      JsonFileStore(File('${dir.path}${Platform.pathSeparator}settings.json')),
    ).load();
  } catch (_) {
    snapshot = const SettingsSnapshot();
  }
  return StartupSettings(
    language: resolveLanguage(
      saved: snapshot.language,
      platformLanguageCode: platformLanguageCode,
    ),
    theme: snapshot.theme,
    closeToTray: snapshot.closeToTray,
    trayHintShown: snapshot.trayHintShown,
  );
}
