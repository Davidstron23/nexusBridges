import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import '../l10n/app_strings.dart';

String shownPeerName(
  AppStrings strings,
  NodeState? state,
  String fingerprint,
  String realName,
) {
  if (state == null) return realName;
  for (final entry in state.entries) {
    final alias = entry.alias;
    if (entry.fingerprint == fingerprint && alias != null && alias.isNotEmpty) {
      return strings.nameWithReal(alias, realName);
    }
  }
  return realName;
}
