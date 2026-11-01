import 'package:nexus_bridges_core/nexus_bridges_core.dart'
    show PairingOutcome, TransferOutcome;

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
  String compareCode(String name) =>
      'Comprueba que $name muestra el mismo código.';

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
  String get keepBothButton => 'Conservar ambos';

  @override
  String mineTitle(String name) => 'Vinculado con $name';

  @override
  String get mineBody =>
      '¿Este equipo es tuyo? Si es tuyo, lo que envíe entrará sin preguntar y '
      'podrá explorar las carpetas que compartas. Si es de otra persona, '
      'siempre te pedirá permiso.';

  @override
  String get mineQuestion => '¿Este equipo es tuyo?';

  @override
  String get mineYesDetail =>
      'Lo que envíe entra sin preguntar y puede explorar las carpetas que '
      'compartas.';

  @override
  String get mineNoDetail =>
      'Siempre te pedirá permiso antes de enviarte nada.';

  @override
  String replaceShortBody(String newName) =>
      '$newName se llama igual que uno vinculado que no está a la vista. Si '
      'es el mismo reinstalado, sustitúyelo.';

  @override
  String pairingEyebrow(PairingOutcome? outcome) => switch (outcome) {
    PairingOutcome.paired => 'Puente Nexus establecido',
    PairingOutcome.rejected => 'Conexión rechazada',
    PairingOutcome.busy => 'Dispositivo ocupado',
    PairingOutcome.paused => 'Conexión congelada',
    PairingOutcome.cancelledByPeer => 'Conexión cancelada',
    PairingOutcome.expired => 'Tiempo agotado',
    PairingOutcome.lost => 'Equipo desaparecido',
    PairingOutcome.networkChanged => 'Cambio de red',
    PairingOutcome.failed || null => 'Error inesperado',
    PairingOutcome.notSaved => 'Error al guardar',
  };

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

  @override
  String get sendFileButton => 'Enviar archivo';

  @override
  String get sendNeedsVisible =>
      'Tiene que estar a la vista para enviarle archivos.';

  @override
  String get sendNeedsPairAgain =>
      'Vuelve a vincularlo antes de enviarle archivos.';

  @override
  String get alreadySending => 'Espera a que termine el envío actual.';

  @override
  String get sendUnavailable =>
      'Ahora no se pueden enviar archivos a este equipo.';

  @override
  String get searchingDevices => 'Buscando dispositivos…';

  @override
  String sendingToTitle(String name) => 'Enviando a $name';

  @override
  String fileLine(String file, String size) => 'Archivo: $file ($size)';

  @override
  String get programLabel => 'Es un programa';

  @override
  String get containsGitRepository =>
      'contiene un repositorio Git, que puede ejecutar código al abrirlo';

  @override
  String preparingFile(String file) => 'Preparando $file…';

  @override
  String contactingPeer(String name) => 'Contactando con $name…';

  @override
  String waitingAcceptance(String name) => 'Esperando a que $name acepte…';

  @override
  String progressLine(int percent, String done, String total) =>
      '$percent % · $done de $total';

  @override
  String peerCheckingFile(String name) => '$name está comprobando el archivo…';

  @override
  String get cancellingTransfer => 'Cancelando…';

  @override
  String incomingRequestTitle(String name) =>
      '$name quiere enviarte un archivo';

  @override
  String get withoutMarkNote =>
      'Se guardará sin la marca que indica a Windows que viene de otro '
      'equipo, porque esa unidad no la admite.';

  @override
  String get acceptButton => 'Aceptar';

  @override
  String get rejectButton => 'Rechazar';

  @override
  String folderQuestionTitle(String name) =>
      '$name te está enviando un archivo';

  @override
  String get folderFirstTimeBody =>
      'Elige dónde guardar los archivos que recibas. '
      'Se recordará para las próximas veces.';

  @override
  String get folderThisTimeBody =>
      'La carpeta de siempre no está disponible ahora. Elige dónde guardar '
      'este archivo; la próxima vez se volverá a usar la de siempre.';

  @override
  String proposedFolderLine(String path) => 'Carpeta: $path';

  @override
  String get useThisFolderButton => 'Usar esta';

  @override
  String get chooseOtherFolderButton => 'Elegir otra';

  @override
  String get pickerOpenNote => 'Elige una carpeta en la ventana de Windows…';

  @override
  String folderForbidden(String path) =>
      'En $path no se pueden guardar archivos recibidos. Elige otra carpeta.';

  @override
  String folderCannotUse(String path) =>
      'No se puede crear $path o no se puede escribir en ella. '
      'Elige otra carpeta.';

  @override
  String folderStillUnavailable(String path) =>
      '$path sigue sin estar disponible. Elige otra carpeta.';

  @override
  String folderUnknownVolume(String path) =>
      'Windows no identifica la unidad de $path, así que no se puede usar '
      'para recibir archivos. Elige otra carpeta.';

  @override
  String folderAdminShare(String path) =>
      '$path está en un recurso compartido administrativo de Windows, así '
      'que no se puede usar para recibir archivos. Elige otra carpeta.';

  @override
  String get checkingFolder => 'Comprobando la carpeta…';

  @override
  String cautionNoMark(String path) =>
      'Los archivos que se guarden en $path no llevarán la marca que indica a '
      'Windows que vienen de otro equipo, así que Windows no avisará antes '
      'de abrir un programa recibido.';

  @override
  String cautionRemote(String path) =>
      '$path está en una unidad de red o en una carpeta sincronizada con la '
      'nube: lo que recibas puede subirse a la nube o depender de la red.';

  @override
  String get useAnywayButton => 'Usarla igualmente';

  @override
  String get transferAlreadyEnded => 'Ese envío ya ha terminado.';

  @override
  String folderRememberedNote(String path) =>
      'Los archivos que recibas se guardarán en $path.';

  @override
  String folderNotUsable(String path) =>
      '$path no se puede usar, así que no se ha recordado.';

  @override
  String get rememberAnywayButton => 'Recordarla igualmente';

  @override
  String get dontRememberButton => 'No recordarla';

  @override
  String receivingFromTitle(String name) => 'Recibiendo de $name';

  @override
  String get waitingForData => 'Esperando los datos…';

  @override
  String get checkingFile => 'Comprobando el archivo…';

  @override
  String get lastSentTitle => 'Último envío';

  @override
  String get lastReceivedTitle => 'Última recepción';

  @override
  String toPeer(String name) => 'Para $name';

  @override
  String fromPeer(String name) => 'De $name';

  @override
  String get showInFolderButton => 'Mostrar en la carpeta';

  @override
  String get revealFolderOnly =>
      'Se ha abierto la carpeta, pero no se ha podido seleccionar el '
      'archivo. Puede que se haya movido, cambiado de nombre o borrado.';

  @override
  String get folderUnavailable => 'Esa carpeta no está disponible.';

  @override
  String sentOutcome(TransferOutcome outcome) => switch (outcome) {
    TransferOutcome.saved => 'Ha llegado intacto.',
    TransferOutcome.savedWithoutMark =>
      'Ha llegado intacto, pero se ha guardado sin la marca que indica a '
          'Windows que viene de otro equipo.',
    TransferOutcome.declined =>
      'El otro equipo no lo ha aceptado. Puedes volver a intentarlo dentro '
          'de un minuto.',
    TransferOutcome.busy =>
      'El otro equipo está ocupado con otro envío. Inténtalo dentro de un '
          'momento.',
    TransferOutcome.unanswered => 'El otro equipo no ha respondido.',
    TransferOutcome.invalidName =>
      'El otro equipo no admite ese nombre de archivo.',
    TransferOutcome.blockedType =>
      'El otro equipo no admite ese tipo de archivo.',
    TransferOutcome.incompatible =>
      'Tu petición no es compatible con el otro equipo.',
    TransferOutcome.noSpace => 'En el otro equipo no hay espacio suficiente.',
    TransferOutcome.noFolder =>
      'El otro equipo no ha elegido dónde guardar los archivos.',
    TransferOutcome.pathTooLong =>
      'La ruta donde lo guardaría el otro equipo es demasiado larga para '
          'Windows.',
    TransferOutcome.cancelledHere => 'Lo has cancelado.',
    TransferOutcome.cancelledByPeer => 'El otro equipo lo ha cancelado.',
    TransferOutcome.unpaired =>
      'Se ha cancelado porque ya no estáis vinculados.',
    TransferOutcome.unreadable => 'No se ha podido leer el archivo.',
    TransferOutcome.noContact =>
      'No se ha podido contactar con el otro equipo.',
    TransferOutcome.uploadNotStarted =>
      'No se ha completado: la transferencia no empezó a tiempo.',
    TransferOutcome.connectionLost =>
      'Se ha cortado la conexión antes de terminar.',
    TransferOutcome.idle =>
      'Se ha cortado porque no se movieron datos durante 30 segundos.',
    TransferOutcome.tooManyBytes =>
      'Se ha cortado porque llegaron más datos de los anunciados.',
    TransferOutcome.writeFailed =>
      'El otro equipo no ha podido escribirlo (por ejemplo, porque se ha '
          'llenado el disco).',
    TransferOutcome.diskFull =>
      'Se ha llenado el disco del otro equipo mientras lo recibía, así que '
          'se ha borrado.',
    TransferOutcome.damaged =>
      'Ha llegado dañado, así que se ha borrado. Si el archivo cambió '
          'mientras se enviaba, vuelve a enviarlo.',
    TransferOutcome.markFailed =>
      'No se ha podido marcar como venido de otro equipo, así que se ha '
          'borrado.',
    TransferOutcome.moveFailed =>
      'No se ha podido mover a la carpeta, así que se ha borrado.',
    TransferOutcome.noFreeName =>
      'No quedaba ningún nombre libre en la carpeta, así que no se ha '
          'guardado.',
    TransferOutcome.interfaceDown =>
      'Se ha cortado porque ha cambiado la conexión de red.',
    TransferOutcome.unconfirmed =>
      'Se ha enviado todo, pero el otro equipo no lo ha confirmado: no se '
          'sabe si ha llegado.',
    TransferOutcome.shortcut => 'Los accesos directos no se envían.',
    TransferOutcome.wholeDrive =>
      'No se pueden enviar unidades enteras, solo carpetas de dentro.',
    TransferOutcome.protectedData =>
      'Son datos de la propia app y nunca se envían.',
    TransferOutcome.notFound => 'Ya no existe.',
    TransferOutcome.tooManyEntries =>
      'La carpeta tiene más de 100 000 elementos.',
    TransferOutcome.tooDeep => 'La carpeta tiene más de 64 niveles.',
    TransferOutcome.tooLargeForPeer =>
      'La carpeta es demasiado grande para el otro equipo.',
    TransferOutcome.unexpectedData =>
      'El otro equipo mandó datos que no había anunciado.',
  };

  @override
  String receivedOutcome(TransferOutcome outcome) => switch (outcome) {
    TransferOutcome.saved => 'Guardado.',
    TransferOutcome.savedWithoutMark =>
      'Guardado sin la marca que indica a Windows que viene de otro equipo.',
    TransferOutcome.declined => 'Lo has rechazado.',
    TransferOutcome.busy => 'Se ha rechazado porque había otro envío en curso.',
    TransferOutcome.unanswered => 'Ha caducado sin respuesta.',
    TransferOutcome.invalidName =>
      'Se ha rechazado porque su nombre no es válido.',
    TransferOutcome.blockedType =>
      'Se ha rechazado porque no se admite ese tipo de archivo.',
    TransferOutcome.incompatible =>
      'Se ha rechazado porque la petición no era compatible.',
    TransferOutcome.noSpace =>
      'Se ha rechazado porque no hay espacio: tiene que quedar libre el '
          'tamaño del archivo más 1 GB.',
    TransferOutcome.noFolder =>
      'Se ha rechazado porque no elegiste dónde guardarlo.',
    TransferOutcome.pathTooLong =>
      'Se ha rechazado porque la ruta donde se guardaría es demasiado larga '
          'para Windows.',
    TransferOutcome.cancelledHere => 'Lo has cancelado.',
    TransferOutcome.cancelledByPeer => 'El otro equipo lo ha cancelado.',
    TransferOutcome.unpaired =>
      'Se ha cancelado porque ya no estáis vinculados.',
    TransferOutcome.unreadable =>
      'El otro equipo ha dejado de poder leer el archivo.',
    TransferOutcome.noContact =>
      'No se ha podido contactar con el otro equipo.',
    TransferOutcome.uploadNotStarted =>
      'No se ha completado: la transferencia no empezó a tiempo.',
    TransferOutcome.connectionLost =>
      'Se ha cortado la conexión antes de terminar.',
    TransferOutcome.idle =>
      'Se ha cortado porque no se movieron datos durante 30 segundos.',
    TransferOutcome.tooManyBytes =>
      'Se ha cortado porque llegaron más datos de los anunciados.',
    TransferOutcome.writeFailed =>
      'No se ha podido escribir (por ejemplo, porque se ha llenado el '
          'disco), así que se ha borrado.',
    TransferOutcome.diskFull =>
      'Se ha llenado el disco mientras se recibía, así que se ha borrado.',
    TransferOutcome.damaged => 'Ha llegado dañado, así que se ha borrado.',
    TransferOutcome.markFailed =>
      'No se ha podido marcar como venido de otro equipo, así que se ha '
          'borrado.',
    TransferOutcome.moveFailed =>
      'No se ha podido mover a la carpeta, así que se ha borrado.',
    TransferOutcome.noFreeName =>
      'No quedaba ningún nombre libre en la carpeta, así que no se ha '
          'guardado.',
    TransferOutcome.interfaceDown =>
      'Se ha cortado porque ha cambiado la conexión de red.',
    TransferOutcome.unconfirmed =>
      'Se ha enviado todo, pero no se ha confirmado.',
    TransferOutcome.shortcut =>
      'Se rechazó porque no se aceptan accesos directos.',
    TransferOutcome.wholeDrive =>
      'Se rechazó porque no se aceptan unidades enteras.',
    TransferOutcome.protectedData =>
      'Se rechazó porque los datos de NexusBridges nunca se envían.',
    TransferOutcome.notFound => 'Ya no existía en el otro equipo.',
    TransferOutcome.tooManyEntries =>
      'Se rechazó porque la carpeta tiene más de 100 000 elementos.',
    TransferOutcome.tooDeep =>
      'Se rechazó porque la carpeta tiene más de 64 niveles.',
    TransferOutcome.tooLargeForPeer =>
      'Se rechazó porque la carpeta es demasiado grande.',
    TransferOutcome.unexpectedData =>
      'Se cortó porque llegaron datos que no se habían anunciado.',
  };

  @override
  String get closeDuringTransferTitle => 'Hay un envío en curso';

  @override
  String get closeDuringTransferBody =>
      'Si cierras la app ahora, el envío se cancelará.';

  @override
  String get keepOpenButton => 'No cerrar';

  @override
  String get closeAndCancelButton => 'Cerrar y cancelar';

  @override
  String get trustedNetworkLabel => 'Red de confianza';

  @override
  String get onlyPairedCanSend =>
      'Solo tus equipos vinculados pueden enviarte archivos';

  @override
  String get activityTab => 'Actividad';

  @override
  String get devicesTab => 'Equipos';

  @override
  String get activityEmpty =>
      'Aquí verás el envío en curso y el último archivo que hayas enviado o '
      'recibido.';

  @override
  String get sectionUnpaired => 'Sin vincular';

  @override
  String get chipMine => 'Mío';

  @override
  String get chipForeign => 'Ajeno';

  @override
  String get visibleLabel => 'A la vista';

  @override
  String get diagramTitle => 'Mi red';

  @override
  String diagramCount(int total, int visible) =>
      "${total == 1 ? '1 equipo' : '$total equipos'} · $visible a la vista";

  @override
  String thisDeviceCaption(String short) =>
      short.isEmpty ? 'este equipo' : '$short · este equipo';

  @override
  String get chipPreparing => 'Preparando';

  @override
  String get chipWaiting => 'Esperando';

  @override
  String get chipInProgress => 'En curso';

  @override
  String get chipChecking => 'Comprobando';

  @override
  String get chipDelivered => 'Entregado';

  @override
  String get chipSaved => 'Guardado';

  @override
  String get chipRejected => 'Rechazado';

  @override
  String get chipCancelled => 'Cancelado';

  @override
  String get chipFailed => 'Fallido';

  @override
  String get chipUnconfirmed => 'Sin confirmar';

  @override
  String foreignSenderNote(String short) =>
      'Es un equipo ajeno (huella $short). Acepta solo si lo esperabas.';

  @override
  String get incomingExpiresNote =>
      'Si no respondes, el aviso caduca al cabo de un minuto.';
}
