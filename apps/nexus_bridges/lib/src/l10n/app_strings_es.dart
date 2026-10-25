import 'app_strings.dart';

final class AppStringsEs implements AppStrings {
  @override
  String get appTitle => 'NexusBridges';

  @override
  String get devicesTitle => 'Equipos cerca';

  @override
  String get noDevicesYet => 'Todavía no hay equipos';

  @override
  String get rescanHint =>
      'No se encuentran equipos. '
      'Algunas redes impiden que los equipos se vean entre sí.';

  @override
  String get rescanButton => 'Buscar de nuevo';

  @override
  String get pausedBanner => 'NexusBridges está en pausa en esta red';

  @override
  String trustNetworkButton(String name) => 'Usar en "$name"';

  @override
  String get networkPromptTitle => '¿Usar NexusBridges en esta red?';

  @override
  String networkPromptBody(String name) =>
      'Los demás equipos de "$name" podrán ver este equipo. '
      'Di que sí solo en redes en las que confíes, como la de tu casa.';

  @override
  String get yes => 'Usar aquí';

  @override
  String get no => 'En esta red no';

  @override
  String get pairedLabel => 'Vinculado';

  @override
  String get notPairedLabel => 'No vinculado';

  @override
  String get deviceTypeDesktop => 'Ordenador';

  @override
  String get deviceTypeMobile => 'Teléfono';

  @override
  String get identityResetWarning =>
      'Este equipo tiene una identidad nueva. '
      'Tendrás que volver a vincularlo con tus otros equipos.';

  @override
  String get identityFailed =>
      'NexusBridges no ha podido crear la identidad de este equipo.';

  @override
  String portInUse(int port) => 'El puerto $port lo está usando otro programa.';

  @override
  String get retryButton => 'Reintentar';

  @override
  String get decisionNotSaved =>
      'Tu elección se aplicará hasta que cierres la app, '
      'pero no se ha podido guardar.';

  @override
  String get closeButton => 'Cerrar';

  @override
  String get pairButton => 'Vincular';

  @override
  String get unpairButton => 'Desvincular';

  @override
  String get moreOptions => 'Más opciones';

  @override
  String get notVisibleLabel => 'No visible';

  @override
  String get pairedMineLabel => 'Vinculado · Mío';

  @override
  String get pairedForeignLabel => 'Vinculado · Ajeno';

  @override
  String get markAsMine => 'Marcar como mío';

  @override
  String get markAsForeign => 'Marcar como ajeno';

  @override
  String get ignoredLabel => 'Ignorado';

  @override
  String get unignoreButton => 'Dejar de ignorar';

  @override
  String get mismatchWarning => 'Ya no te tiene vinculado.';

  @override
  String get removeButton => 'Quitar';

  @override
  String get pairAgainButton => 'Volver a vincular';

  @override
  String possibleReinstall(String oldName) =>
      'Tiene el mismo nombre que $oldName, que está vinculado y no está a la '
      'vista. Puede ser ese equipo reinstalado o alguien haciéndose pasar por '
      'él.';

  @override
  String get pairingAlreadyInProgress => 'Ya hay una vinculación en curso.';

  @override
  String get tooManyPaired =>
      'Ya tienes 32 equipos vinculados. Desvincula alguno para vincular otro.';

  @override
  String get pairUnavailable => 'Ahora no se puede vincular este equipo.';

  @override
  String pairingWithTitle(String name) => 'Vinculando con $name';

  @override
  String connectingTo(String name) => 'Conectando con $name…';

  @override
  String compareCode(String name) => 'Comprueba que $name muestra este código:';

  @override
  String get matchesButton => 'Coincide';

  @override
  String get doesNotMatchButton => 'No coincide';

  @override
  String get cancelButton => 'Cancelar';

  @override
  String waitingForPeer(String name) =>
      'Esperando a que se confirme el código en $name…';

  @override
  String pairingRequestTitle(String name) => '$name quiere vincularse';

  @override
  String fingerprintLine(String short) => 'Huella: $short';

  @override
  String get alreadyPairedNote =>
      'Este equipo ya está vinculado. Si confirmas, se queda como está.';

  @override
  String namesakeWarning(String name) =>
      'Ya tienes vinculado un equipo llamado $name con otra huella.';

  @override
  String get ignoreDeviceButton => 'Ignorar este dispositivo';

  @override
  String receiverWaiting(String name) =>
      'Has confirmado el código. Esperando a que $name también lo confirme…';

  @override
  String get pairingResultTitle => 'Vinculación';

  @override
  String outcomePaired(String name) => '$name ya está vinculado.';

  @override
  String outcomeRejected(String name) => '$name no ha aceptado la vinculación.';

  @override
  String outcomeBusy(String name) =>
      '$name está ocupado con otra vinculación. '
      'Inténtalo dentro de un minuto.';

  @override
  String outcomePaused(String name) =>
      '$name no admite vinculaciones durante unos minutos.';

  @override
  String outcomeCancelledByPeer(String name) =>
      '$name ha cancelado la vinculación. No se ha guardado nada.';

  @override
  String get outcomeExpired =>
      'La vinculación ha caducado. No se ha guardado nada.';

  @override
  String outcomeLost(String name) =>
      '$name ha dejado de responder. No se ha guardado nada.';

  @override
  String get outcomeNetworkChanged =>
      'La vinculación se ha cancelado porque ha cambiado la red.';

  @override
  String outcomeFailed(String name) => 'No se ha podido vincular con $name.';

  @override
  String get outcomeNotSaved =>
      'No se ha podido guardar la vinculación, así que no se ha completado.';

  @override
  String replaceTitle(String oldName) => '¿Sustituir a $oldName?';

  @override
  String replaceBody(String newName, String oldName) =>
      '$newName tiene el mismo nombre que $oldName, que está vinculado pero '
      'no está a la vista. Si es el mismo equipo reinstalado, sustitúyelo para '
      'quitar la vinculación antigua.';

  @override
  String get replaceButton => 'Sustituir';

  @override
  String get keepBothButton => 'Conservar los dos';

  @override
  String mineTitle(String name) => 'Vinculado con $name';

  @override
  String get mineBody =>
      '¿Este equipo es tuyo? Si es tuyo, lo que envíe entrará sin preguntar y '
      'podrá explorar las carpetas que compartas. Si es de otra persona, '
      'siempre te pedirá permiso.';

  @override
  String get mineYesButton => 'Es mío';

  @override
  String get mineNoButton => 'Es de otra persona';

  @override
  String unpairTitle(String name) => '¿Desvincular $name?';

  @override
  String unpairBody(String name) =>
      '$name dejará de poder conectarse con este equipo desde ahora. '
      'Para volver a usarlo tendréis que vincularlos otra vez.';

  @override
  String noticeAttemptCancelled(String short) =>
      'Se ha cancelado un intento de vinculación del equipo con huella '
      '$short porque sus datos no cuadraban.';

  @override
  String noticeAttemptPeerCancelled(String short) =>
      'El equipo con huella $short ha cancelado la vinculación.';

  @override
  String noticeAttemptsCancelled(int count) =>
      'Se han cancelado $count intentos de vinculación en los últimos '
      'minutos. Si no has sido tú, revisa tu red.';

  @override
  String noticeAttemptLost(String short) =>
      'El equipo con huella $short dejó de responder después de ver el código '
      'de vinculación.';

  @override
  String noticeReplaceWithdrawn(String name) =>
      '$name ha vuelto a aparecer, así que no se ha sustituido.';

  @override
  String get noticePairingPaused =>
      'Vinculaciones en pausa durante unos minutos tras 3 intentos fallidos: '
      'este equipo no acepta peticiones nuevas hasta entonces.';

  @override
  String noticeUnpairedByPeer(String name) =>
      '$name ha desvinculado este equipo.';

  @override
  String noticeUnpairNotSaved(String name) =>
      '$name está desvinculado hasta que cierres la app, pero no se ha podido '
      'guardar: si la reinicias, volvería a estar vinculado.';

  @override
  String get noticeChangeNotSaved =>
      'Tu cambio se aplica hasta que cierres la app, pero no se ha podido '
      'guardar y no se recordará.';

  @override
  String noticeIgnoreNotSaved(String name) =>
      '$name queda ignorado hasta que cierres la app, pero no se ha podido '
      'guardar y no se recordará.';

  @override
  String noticePairingNotSaved(String who) =>
      'No se ha podido guardar la vinculación con $who. Vuelve a intentarlo.';

  @override
  String noticePairingFailed(String who) =>
      'No se ha podido completar la vinculación con $who.';

  @override
  String noticeReceiveFolderNotSaved(String path) =>
      'Los archivos se guardarán en $path hasta que cierres la app, pero '
      'no se ha podido recordar.';

  @override
  String noticePeerCancelledTransfer(String name) => '$name canceló el envío.';
}
