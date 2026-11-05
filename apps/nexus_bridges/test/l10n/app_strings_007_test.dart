import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';

typedef _Text = String Function(AppStrings strings);

final RegExp _abstractMember = RegExp(
  r'^\s+String(?: get)? ([a-zA-Z0-9]+)(?:\(|;)',
  multiLine: true,
);
final RegExp _implementedMember = RegExp(
  r'^\s+String(?: get)? ([a-zA-Z0-9]+)(?:\(| =>| \{)',
  multiLine: true,
);

Set<String> _declared(String file, RegExp pattern) {
  final source = File(
    'lib${Platform.pathSeparator}src'
    '${Platform.pathSeparator}l10n${Platform.pathSeparator}$file',
  ).readAsStringSync();
  return {for (final match in pattern.allMatches(source)) match.group(1)!};
}

final Map<String, _Text> _texts = {
  'configure': (s) => s.configure,
  'configureEllipsis': (s) => s.configureEllipsis,
  'thisDeviceIs': (s) => s.thisDeviceIs,
  'mineCard': (s) => s.mineCard,
  'mineCardHelp': (s) => s.mineCardHelp,
  'foreignCard': (s) => s.foreignCard,
  'foreignCardHelp': (s) => s.foreignCardHelp,
  'sharesTitle': (s) => s.sharesTitle,
  'sharesDesc': (s) => s.sharesDesc('X'),
  'sharesInfo': (s) => s.sharesInfo('X'),
  'sharesEmpty': (s) => s.sharesEmpty,
  'sharesAdd': (s) => s.sharesAdd,
  'sharesPaused': (s) => s.sharesPaused,
  'shareUnavailable': (s) => s.shareUnavailable,
  'shareCloudConfirm': (s) => s.shareCloudConfirm,
  'shareNoMarkConfirm': (s) => s.shareNoMarkConfirm,
  'shareAddAnyway': (s) => s.shareAddAnyway,
  'shareRefusedNetwork': (s) => s.shareRefusedNetwork,
  'shareRefusedAdminShare': (s) => s.shareRefusedAdminShare,
  'shareRefusedUnknownDrive': (s) => s.shareRefusedUnknownDrive,
  'shareRefusedForbidden': (s) => s.shareRefusedForbidden,
  'shareRefusedAppData': (s) => s.shareRefusedAppData,
  'shareRefusedTemp': (s) => s.shareRefusedTemp,
  'shareRefusedTooLong': (s) => s.shareRefusedTooLong,
  'shareRefusedMissing': (s) => s.shareRefusedMissing,
  'shareRefusedAlready': (s) => s.shareRefusedAlready,
  'shareRefusedFull': (s) => s.shareRefusedFull,
  'favoritesTitle': (s) => s.favoritesTitle,
  'favoritesDesc': (s) => s.favoritesDesc,
  'favoritesInfo': (s) => s.favoritesInfo('X'),
  'favoritesEmpty': (s) => s.favoritesEmpty,
  'favoritesAdd': (s) => s.favoritesAdd,
  'favoritesNeedVisible': (s) => s.favoritesNeedVisible,
  'favoritesPaused': (s) => s.favoritesPaused,
  'aliasTitle': (s) => s.aliasTitle,
  'aliasPlaceholder': (s) => s.aliasPlaceholder,
  'aliasHelp': (s) => s.aliasHelp('X'),
  'historyTitle': (s) => s.historyTitle('X'),
  'historyEmpty': (s) => s.historyEmpty,
  'historySeeAll': (s) => s.historySeeAll(3),
  'historyLast3': (s) => s.historyLast3,
  'historyKept': (s) => s.historyKept,
  'historyInfo': (s) => s.historyInfo,
  'historyBack': (s) => s.historyBack,
  'historyItems': (s) => s.historyItems(3),
  'historyFirstAndMore': (s) => s.historyFirstAndMore('a', 3),
  'historyDelivered': (s) => s.historyDelivered(1, 3),
  'homeFolder': (s) => s.homeFolder,
  'destTitle': (s) => s.destTitle('X'),
  'destQuestion': (s) => s.destQuestion,
  'destFavorites': (s) => s.destFavorites,
  'destFoldersOf': (s) => s.destFoldersOf('X'),
  'destShared': (s) => s.destShared,
  'destDefaultFolder': (s) => s.destDefaultFolder,
  'destDefaultTag': (s) => s.destDefaultTag,
  'destRecent': (s) => s.destRecent,
  'destExplore': (s) => s.destExplore,
  'destLoading': (s) => s.destLoading,
  'destNoChoice': (s) => s.destNoChoice('X'),
  'destUnreadable': (s) => s.destUnreadable('X'),
  'destNoLongerAvailable': (s) => s.destNoLongerAvailable,
  'destKeys': (s) => s.destKeys,
  'navSendHere': (s) => s.navSendHere,
  'navSaveFavorite': (s) => s.navSaveFavorite,
  'navNewFolder': (s) => s.navNewFolder,
  'navNewFolderPlaceholder': (s) => s.navNewFolderPlaceholder,
  'navCreate': (s) => s.navCreate,
  'navWillBeCreated': (s) => s.navWillBeCreated,
  'navNewFolderEmpty': (s) => s.navNewFolderEmpty('X'),
  'navNoSubfolders': (s) => s.navNoSubfolders,
  'navChoose': (s) => s.navChoose,
  'navIn': (s) => s.navIn('X'),
  'navMore': (s) => s.navMore,
  'navPartial': (s) => s.navPartial,
  'navGone': (s) => s.navGone,
  'navBusy': (s) => s.navBusy('X'),
  'navNameInvalid': (s) => s.navNameInvalid,
  'navNameExists': (s) => s.navNameExists,
  'navBack': (s) => s.navBack,
  'portalDropIn': (s) => s.portalDropIn,
  'portalHold': (s) => s.portalHold,
  'portalBack': (s) => s.portalBack('X'),
  'portalHereIn': (s) => s.portalHereIn('X'),
  'noticeSharesNotSaved': (s) => s.noticeSharesNotSaved,
  'noticeShareAddNotSaved': (s) => s.noticeShareAddNotSaved,
  'noticePeerNotesNotSaved': (s) => s.noticePeerNotesNotSaved,
  'noticeSharesReset': (s) => s.noticeSharesReset,
  'noticeSharesPartlyReset': (s) => s.noticeSharesPartlyReset,
};

const Set<String> _sameInBothLanguages = {'homeFolderIcon'};

void main() {
  group('E788 the two tables of texts (RF-427 to RF-435)', () {
    test('both tables implement every key of AppStrings', () {
      final keys = _declared('app_strings.dart', _abstractMember);
      final en = _declared('app_strings_en.dart', _implementedMember);
      final es = _declared('app_strings_es.dart', _implementedMember);

      expect(keys, isNotEmpty);
      expect(keys.difference(en), isEmpty);
      expect(keys.difference(es), isEmpty);
      expect(en.difference(es), isEmpty);
      expect(es.difference(en), isEmpty);
    });

    for (final MapEntry(key: name, value: text) in _texts.entries) {
      test('$name exists in both, is not empty and differs', () {
        final en = text(stringsFor('en'));
        final es = text(stringsFor('es'));

        expect(en.trim(), isNotEmpty);
        expect(es.trim(), isNotEmpty);
        if (!_sameInBothLanguages.contains(name)) {
          expect(es, isNot(en));
        }
      });
    }

    test('the sentences with a name carry it in both languages', () {
      for (final code in ['en', 'es']) {
        final strings = stringsFor(code);
        expect(strings.destNoChoice('Torre'), contains('Torre'));
        expect(strings.destUnreadable('Torre'), contains('Torre'));
        expect(strings.navBusy('Torre'), contains('Torre'));
        expect(strings.historyDelivered(2, 5), contains('2'));
        expect(strings.historyDelivered(2, 5), contains('5'));
      }
    });
  });
}
