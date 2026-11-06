import 'package:nexus_bridges_core/nexus_bridges_core.dart'
    show PairingOutcome, TransferOutcome;

import '../ui/format.dart';
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
  String get noticeSharesNotSaved =>
      'No se ha podido guardar el cambio de carpetas; al reiniciar volvería '
      'a estar abierta.';

  @override
  String get noticeShareAddNotSaved =>
      'La carpeta se ha añadido, pero no se recordará al reiniciar.';

  @override
  String get noticePeerNotesNotSaved =>
      'Los favoritos, apodos e historial no se recordarán al reiniciar.';

  @override
  String get noticeSharesReset =>
      'El archivo de carpetas compartidas estaba dañado; ahora no hay '
      'ninguna abierta.';

  @override
  String get noticeSharesPartlyReset =>
      'Se quitaron las carpetas de equipos que ya no están vinculados.';

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
  String arrivesIn(String time) => 'Llega en $time';

  @override
  String get arrivesInFewSeconds => 'Llega en unos segundos';

  @override
  String get calculatingTime => 'Calculando…';

  @override
  String incomingRequestTitle(String name) =>
      '$name quiere enviarte un archivo';

  @override
  String incomingFolderRequestTitle(String name) =>
      '$name quiere enviarte una carpeta';

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
      'No se puede enviar: son datos de la propia app o un recurso '
          'administrativo.',
    TransferOutcome.notFound => 'Ya no existe.',
    TransferOutcome.tooManyEntries =>
      'La carpeta tiene demasiados elementos para enviarla.',
    TransferOutcome.tooDeep => 'La carpeta tiene más de 64 niveles.',
    TransferOutcome.tooLargeForPeer =>
      'La carpeta es demasiado grande para el otro equipo.',
    TransferOutcome.unexpectedData =>
      'El otro equipo mandó datos que no había anunciado.',
    TransferOutcome.defaultFolderOnly =>
      'El otro equipo solo admite envíos a su carpeta por defecto.',
    TransferOutcome.destinationUnavailable =>
      'Esa carpeta ya no está disponible en el otro equipo.',
    TransferOutcome.destinationMissing =>
      'Esa carpeta ya no existe en el otro equipo.',
    TransferOutcome.destinationLost =>
      'Esa carpeta dejó de estar disponible en el otro equipo.',
    TransferOutcome.shareRemoved =>
      'Quitaste esa carpeta de las que le compartes al otro equipo.',
    TransferOutcome.peerMarkedForeign => 'Marcaste al otro equipo como ajeno.',
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
      'Se rechazó porque la carpeta tiene demasiados elementos.',
    TransferOutcome.tooDeep =>
      'Se rechazó porque la carpeta tiene más de 64 niveles.',
    TransferOutcome.tooLargeForPeer =>
      'Se rechazó porque la carpeta es demasiado grande.',
    TransferOutcome.unexpectedData =>
      'Se cortó porque llegaron datos que no se habían anunciado.',
    TransferOutcome.defaultFolderOnly =>
      'El otro equipo solo admite envíos a su carpeta por defecto.',
    TransferOutcome.destinationUnavailable =>
      'Esa carpeta ya no está disponible en el otro equipo.',
    TransferOutcome.destinationMissing =>
      'Esa carpeta ya no existe en el otro equipo.',
    TransferOutcome.destinationLost =>
      'Esa carpeta dejó de estar disponible en el otro equipo.',
    TransferOutcome.shareRemoved =>
      'Quitaste esa carpeta de las que le compartes al otro equipo.',
    TransferOutcome.peerMarkedForeign => 'Marcaste al otro equipo como ajeno.',
  };

  @override
  String get closeDuringTransferTitle => 'Hay un envío en curso';

  @override
  String get closeDuringTransferBody =>
      'Si cierras la app ahora, el envío se cancelará.';

  @override
  String get closeWithQueuesBody =>
      'Si cierras la app ahora, el envío se cancelará y lo que aún está '
      'pendiente no se enviará.';

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

  @override
  String get sendEllipsis => 'Enviar…';

  @override
  String get sendFilesEllipsis => 'Enviar archivos…';

  @override
  String get sendFilesOption => 'Archivos…';

  @override
  String get sendFoldersOption => 'Carpetas…';

  @override
  String preparingItems(int count) =>
      'Preparando… ${formatCount(count, 'es')} '
      "${count == 1 ? 'elemento encontrado' : 'elementos encontrados'}";

  @override
  String folderSummary(int files, String size) =>
      "${formatCount(files, 'es')} ${files == 1 ? 'archivo' : 'archivos'} · "
      '$size';

  @override
  String foldersLeftOut(int count, String? size) =>
      "${formatCount(count, 'es')} "
      "${count == 1 ? 'carpeta queda' : 'carpetas quedan'} fuera"
      "${size == null ? '' : ' ($size)'}";

  @override
  String linksNotFollowed(int count) =>
      "${formatCount(count, 'es')} "
      "${count == 1 ? 'enlace no se sigue' : 'enlaces no se siguen'}";

  @override
  String get appDataLeftOut => 'Los datos de NexusBridges nunca se envían';

  @override
  String blockedLeftOut(int count) => count == 1
      ? '1 archivo no se envía: accesos directos y archivos de sistema del '
            'Explorador'
      : "${formatCount(count, 'es')} archivos no se envían: accesos directos "
            'y archivos de sistema del Explorador';

  @override
  String get containsPrograms => 'contiene programas';

  @override
  String filesProgress(int done, int total) =>
      "${formatCount(done, 'es')} de ${formatCount(total, 'es')} "
      "${total == 1 ? 'archivo' : 'archivos'}";

  @override
  String firstLevelMore(int count) => "y ${formatCount(count, 'es')} más";

  @override
  String outcomeUnreadableEntry(String path) =>
      'No se pudo leer o cambió mientras se enviaba: $path';

  @override
  String outcomeInvalidNameEntry(String path) =>
      'Este nombre no se puede usar en el otro equipo: $path';

  @override
  String get outcomeFolderIncompatible =>
      'El otro equipo no puede recibir carpetas; puede que tenga que '
      'actualizar NexusBridges';

  @override
  String queueTitle(String name) => 'Enviando a $name';

  @override
  String get looseQueue => 'Archivos';

  @override
  String get bundleQueue => 'Carpetas y comprimidos';

  @override
  String get queuePending => 'Pendiente';

  @override
  String queueNotSent(String reason) => 'No enviado: $reason';

  @override
  String get queueRemove => 'Quitar';

  @override
  String get queueCancelAll => 'Cancelar todo';

  @override
  String queueRemaining(int count) => count == 1
      ? 'Queda 1 en cola'
      : "Quedan ${formatCount(count, 'es')} en cola";

  @override
  String get queueLastItem => 'Último elemento';

  @override
  String deliveredSummary(int delivered, int total) =>
      "${formatCount(delivered, 'es')} de ${formatCount(total, 'es')} "
      "${total == 1 ? 'entregado' : 'entregados'}";

  @override
  String waitForQueues(String name) =>
      'Espera a que terminen los envíos a $name';

  @override
  String get tooManySelected =>
      'Se pueden enviar como mucho 1 000 elementos a la vez';

  @override
  String trayTitle(int count) => "Para enviar (${formatCount(count, 'es')})";

  @override
  String get trayRemoveAll => 'Quitar todo';

  @override
  String traySendTo(String name) => 'Enviar a $name';

  @override
  String get trayFull =>
      'La bandeja Para enviar admite como mucho 1 000 elementos';

  @override
  String get trayNothingNew => 'Ya estaban en Para enviar';

  @override
  String get dragHint =>
      'Suelta sobre un equipo · fuera de ellos, a Para enviar';

  @override
  String get dragTipTitle => 'Arrastra y suelta';

  @override
  String get dragTipBody =>
      'Sobre un equipo para enviárselo; fuera de ellos, a Para enviar';

  @override
  String get settingsButton => 'Ajustes';

  @override
  String get settingsTitle => 'Ajustes';

  @override
  String settingsSubtitle(String name) => 'Este equipo · $name';

  @override
  String get settingsBack => 'Volver';

  @override
  String get settingsNavFoot => 'Esc o la flecha vuelven a tus equipos.';

  @override
  String get settingsFooter =>
      'Todo se guarda al momento, salvo el nombre: Intro o Guardar.';

  @override
  String moreInfo(String text) => 'Más información: $text';

  @override
  String get sectionAppearance => 'Apariencia';

  @override
  String get appearanceInfo =>
      'Cambia al momento, también la barra de título de Windows.';

  @override
  String get themeDark => 'Oscuro';

  @override
  String get themeLight => 'Claro';

  @override
  String get themeWindows => 'Windows';

  @override
  String get sectionLanguage => 'Idioma';

  @override
  String get languageSpanish => 'Español';

  @override
  String get languageEnglish => 'English';

  @override
  String get sectionDevice => 'Este equipo';

  @override
  String get deviceNameLabel => 'Nombre del equipo';

  @override
  String get deviceNameDesc => 'Así te ven los equipos de tus redes.';

  @override
  String get deviceNameInfo =>
      'Lo ven todos los equipos con NexusBridges de tus redes de confianza, también los que aún no has vinculado.';

  @override
  String get saveButton => 'Guardar';

  @override
  String useWindowsName(String name) => 'Usar el nombre de Windows · $name';

  @override
  String get nameEmpty => 'Escribe un nombre.';

  @override
  String get nameTooLong => 'Como mucho 64 caracteres.';

  @override
  String get nameInvalid =>
      'Tiene caracteres que los demás no verían igual: invisibles, de control '
      'o partes de algunos emojis compuestos. Quítalos o escribe el nombre a '
      'mano.';

  @override
  String get nameNamesake =>
      'Otro equipo de la lista se llama así: los demás verán la huella junto '
      'al nombre para distinguiros.';

  @override
  String get sectionReceive => 'Recepción';

  @override
  String get receiveDesc => 'Aquí llega lo que viene sin destino.';

  @override
  String get receiveInfo =>
      'También todo lo que te envía un equipo ajeno, que nunca ve tus carpetas.';

  @override
  String get receiveNotSet => 'Se preguntará la primera vez que recibas algo';

  @override
  String get changeFolderButton => 'Cambiar…';

  @override
  String get changeFolderLocked =>
      'Antes responde a la pregunta de la carpeta.';

  @override
  String get sectionExclusions => 'Carpetas excluidas';

  @override
  String ofMax(int n, int max) => '$n de $max';

  @override
  String get exclusionsDesc => 'Subcarpetas que nunca se envían.';

  @override
  String get exclusionsInfo =>
      'Al enviar una carpeta, las que se llamen así se quedan fuera, estén al nivel que estén. Los archivos sueltos se envían igual.';

  @override
  String get exclusionsEmpty => 'Ninguna: se envía todo.';

  @override
  String get exclusionPlaceholder => 'Nombre de carpeta, por ejemplo dist';

  @override
  String get addButton => 'Añadir';

  @override
  String removeExclusion(String name) => 'Quitar $name';

  @override
  String get exclusionEmpty => 'Escribe un nombre de carpeta.';

  @override
  String get exclusionInvalid =>
      'Ese nombre no vale para una carpeta en Windows.';

  @override
  String get exclusionDuplicate => 'Ya está en la lista.';

  @override
  String get exclusionFull => 'Como mucho 64 nombres.';

  @override
  String get restoreDefaults => 'Restaurar la lista por defecto';

  @override
  String get restoreConfirm =>
      '¿Volver a node_modules, build y .dart_tool? Se quitan los nombres que '
      'hayas añadido.';

  @override
  String get restoreButton => 'Restaurar';

  @override
  String get sectionSystemTray => 'Bandeja del sistema';

  @override
  String get systemTrayInfo =>
      'Para salir del todo: clic derecho en el icono de la bandeja y Salir.';

  @override
  String get systemTraySwitch => 'Seguir en la bandeja al cerrar';

  @override
  String get systemTraySwitchHelp =>
      'Al cerrar la ventana se sigue recibiendo con la app en segundo plano';

  @override
  String get systemTrayOffHelp =>
      'La X cerrará la app. Si hay un envío, te preguntará.';

  @override
  String get systemTrayOpen => 'Abrir NexusBridges';

  @override
  String get systemTrayExit => 'Salir';

  @override
  String get systemTrayHintTitle => 'NexusBridges sigue funcionando';

  @override
  String get systemTrayHintBody =>
      'Sigue recibiendo archivos. Para salir, haz clic derecho en este icono '
      'y elige Salir.';

  @override
  String get sectionNetworks => 'Redes de confianza';

  @override
  String get networksInfo => 'Solo funciona en estas. En las demás, en pausa.';

  @override
  String get connectedNow => 'Conectada ahora';

  @override
  String get unnamedNetwork => 'Red sin nombre';

  @override
  String get networksEmpty => 'Aún no usas NexusBridges en ninguna red';

  @override
  String trustedOn(String date) => 'Aceptada el $date';

  @override
  String get stopUsingButton => 'Dejar de usar en esta red';

  @override
  String stopUsingConfirm(String network) =>
      '¿Dejar de usar NexusBridges en $network? Estás conectado a ella: la '
      'app se pondrá en pausa aquí y tus otros equipos dejarán de ver este.';

  @override
  String transfersStopped(int count) => count == 1
      ? 'Se cortará 1 envío en curso.'
      : 'Se cortarán $count envíos en curso.';

  @override
  String get pairingCancelled => 'Se cancelará la vinculación en curso.';

  @override
  String get stopUsingConfirmButton => 'Dejar de usar';

  @override
  String noticeNetworkStopNotSaved(String network) =>
      'Has dejado de usar $network hasta que cierres la app, pero no se ha '
      'podido guardar: al volver a abrirla se usaría otra vez.';

  @override
  String get sectionIgnored => 'Equipos ignorados';

  @override
  String get ignoredInfo => 'Estos equipos no pueden pedirte vincularse.';

  @override
  String get ignoredEmpty => 'No has ignorado ningún equipo';

  @override
  String ignoredOn(String date) => 'Ignorado el $date';

  @override
  String get noticeSettingNotSaved =>
      'No se pudo guardar el cambio: se aplica hasta que cierres la app.';

  @override
  String monthShort(int month) => const [
    'ene',
    'feb',
    'mar',
    'abr',
    'may',
    'jun',
    'jul',
    'ago',
    'sep',
    'oct',
    'nov',
    'dic',
  ][month - 1];

  @override
  String get configure => 'Configurar';

  @override
  String get configureEllipsis => 'Configurar…';

  @override
  String get thisDeviceIs => 'Este equipo es';

  @override
  String get mineCard => 'Mío';

  @override
  String get mineCardHelp =>
      'Puedes compartirle carpetas y te envía sin preguntar';

  @override
  String get foreignCard => 'Ajeno';

  @override
  String get foreignCardHelp =>
      'Te pide permiso cada vez y nunca ve tus carpetas';

  @override
  String get sharesTitle => 'Carpetas que le compartes';

  @override
  String sharesDesc(String name) =>
      'De este equipo. $name podrá enviarte aquí.';

  @override
  String sharesInfo(String name) =>
      'Son carpetas de este equipo. $name ve sus subcarpetas, nunca tus archivos. Valen unidades locales, USB y microSD; las de red, no.';

  @override
  String get sharesEmpty =>
      'Ninguna. Lo que envíe irá a tu carpeta de recepción';

  @override
  String get sharesAdd => 'Añadir carpeta…';

  @override
  String get sharesPaused =>
      'En pausa mientras sea ajeno. Vuelven si lo marcas como mío';

  @override
  String get sharesForeignOnly =>
      'Solo puedes compartir carpetas con equipos tuyos';

  @override
  String get shareUnavailable => 'No disponible';

  @override
  String get chipRemovable => 'USB / microSD';

  @override
  String get shareRemoveTooltip => 'Dejar de compartir esta carpeta';

  @override
  String get shareCloudConfirm =>
      'Esta carpeta se sincroniza con la nube: lo que llegue puede subirse';

  @override
  String get shareNoMarkConfirm =>
      'Esta unidad no puede marcar los archivos de internet';

  @override
  String get shareAddAnyway => 'Añadir igualmente';

  @override
  String get shareRefusedNetwork =>
      'No se pueden usar unidades de red ni carpetas compartidas';

  @override
  String get shareRefusedAdminShare =>
      'Los recursos administrativos nunca se admiten';

  @override
  String get shareRefusedUnknownDrive => 'Windows no identifica esta unidad';

  @override
  String get shareRefusedForbidden =>
      'No se pueden compartir las carpetas de Windows y de programas, la de Inicio ni la raíz del disco del sistema';

  @override
  String get shareRefusedAppData => 'Son los datos de la propia app';

  @override
  String get shareRefusedTemp => 'Es una carpeta temporal de la app';

  @override
  String get shareRefusedTooLong =>
      'La ruta es demasiado larga (más de 236 caracteres)';

  @override
  String get shareRefusedMissing => 'La carpeta ya no existe';

  @override
  String get shareRefusedAlready => 'Ya está en la lista';

  @override
  String get shareRefusedFull => 'Como mucho 16 carpetas por equipo';

  @override
  String get shareFailed => 'No se pudo añadir la carpeta';

  @override
  String get favoritesTitle => 'Destinos favoritos';

  @override
  String get favoritesDesc => 'Salen primero al enviar';

  @override
  String favoritesInfo(String name) =>
      'Se eligen entre las carpetas que $name te comparte';

  @override
  String get favoritesEmpty => 'Sin favoritos todavía';

  @override
  String get favoritesAdd => 'Añadir…';

  @override
  String get favoritesNeedVisible => 'Tiene que estar a la vista';

  @override
  String get favoritesPaused =>
      'Un ajeno no tiene favoritos. Vuelven si lo marcas como mío';

  @override
  String get favoritesFull => 'Como mucho 8 favoritos por equipo';

  @override
  String get favoriteRemoveTooltip => 'Quitar de favoritos';

  @override
  String get aliasTitle => 'Apodo local';

  @override
  String get aliasPlaceholder => 'Sin apodo';

  @override
  String aliasHelp(String real) => 'Solo lo ves tú. Los demás ven «$real»';

  @override
  String historyTitle(String name) => 'Historial con $name';

  @override
  String get historyEmpty => 'Todavía no os habéis enviado nada';

  @override
  String historySeeAll(int n) => 'Ver todo ($n)';

  @override
  String get historyLast3 => 'Últimos 3 · se guardan hasta 50';

  @override
  String get historyKept => 'Se guardan hasta 50';

  @override
  String get historyInfo =>
      'Se guarda solo en este equipo: nombres, tamaños y destinos. Nunca el contenido';

  @override
  String get historyBack => 'Volver a Configurar';

  @override
  String get historyCancelled => 'Cancelado';

  @override
  String get historyFailed => 'Falló';

  @override
  String get historyDefaultFolder => 'Carpeta de recepción';

  @override
  String get historyDeliveredTip => 'Entregado';

  @override
  String get historySavedTip => 'Guardado';

  @override
  String get historySentLabel => 'Enviado';

  @override
  String get historyReceivedLabel => 'Recibido';

  @override
  String get historyToday => 'Hoy';

  @override
  String get historyYesterday => 'Ayer';

  @override
  String historySummary(int sent, int received) =>
      '$sent enviados y $received recibidos · se guardan hasta 50';

  @override
  String filesCount(int n) => '$n archivos';

  @override
  String historyItems(int n) => '$n elementos';

  @override
  String historyFirstAndMore(String name, int n) => '${n}ame y $n más';

  @override
  String historyDelivered(int d, int n) => 'entregados $d de $n';

  @override
  String get homeFolder => 'Carpeta personal';

  @override
  String get unpairSectionTitle => 'Desvincular';

  @override
  String get unpairSectionHelp =>
      'Borra sus carpetas, favoritos, apodo e historial';

  @override
  String get unpairSectionInfo =>
      'Para volver a enviaros archivos tendréis que vincularos otra vez';

  @override
  String destTitle(String name) => 'Enviar a $name';

  @override
  String get destQuestion => '¿Dónde lo dejo?';

  @override
  String get destFavorites => 'Favoritos';

  @override
  String destFoldersOf(String name) => 'Carpetas de $name';

  @override
  String get destShared => 'compartidas contigo';

  @override
  String get destDefaultFolder => 'Carpeta por defecto';

  @override
  String get destDefaultTag => 'la de recepción';

  @override
  String get destRecent => 'Últimas usadas';

  @override
  String get destExplore => 'Explorar…';

  @override
  String get destLoading => 'Pidiendo sus carpetas…';

  @override
  String destNoChoice(String name) =>
      '$name no te deja elegir carpeta en este momento; irá a su carpeta por defecto';

  @override
  String destUnreadable(String name) =>
      'No se pudo leer la lista de carpetas de $name';

  @override
  String get destNoLongerAvailable => 'Ya no está disponible';

  @override
  String get destKeys => '↑ ↓ elegir · Intro enviar · Esc cancelar';

  @override
  String get navSendHere => 'Enviar aquí';

  @override
  String get navSaveFavorite => 'Guardar como favorito';

  @override
  String get navNewFolder => 'Nueva carpeta';

  @override
  String get navNewFolderPlaceholder => 'Nombre de la carpeta nueva';

  @override
  String get navCreate => 'Crear';

  @override
  String get navWillBeCreated => 'Se creará al recibir';

  @override
  String navNewFolderEmpty(String name) =>
      '$name la creará cuando llegue el envío. Si no llega, no queda nada';

  @override
  String get navNoSubfolders => 'Sin subcarpetas';

  @override
  String get navChoose => 'Elige una carpeta';

  @override
  String navIn(String name) => 'En $name';

  @override
  String get navMore => 'Se muestran las 1 000 primeras carpetas';

  @override
  String get navPartial =>
      'La lista está incompleta: la carpeta tardó demasiado';

  @override
  String get navGone => 'Esa carpeta ya no está disponible';

  @override
  String navBusy(String name) => '$name está ocupado; prueba en unos segundos';

  @override
  String navUnreadable(String name) =>
      'No se pudieron leer las carpetas de $name';

  @override
  String get navNameInvalid => 'Ese nombre no vale para una carpeta';

  @override
  String get navNameRepository =>
      'Por seguridad, no se puede crear una carpeta .git';

  @override
  String get navNameExists => 'Ya hay una carpeta con ese nombre';

  @override
  String get navBack => 'Atrás';

  @override
  String get portalDropIn => 'Suelta en una carpeta';

  @override
  String get portalHold =>
      'Mantén sobre una carpeta para entrar. Suelta para enviar ahí';

  @override
  String portalBack(String name) => 'Volver a $name';

  @override
  String portalHereIn(String name) => 'Aquí, en $name';

  @override
  String dragHintMine(String name) =>
      'Enviar a $name · mantén para ver sus carpetas';

  @override
  String outcomeShareRemoved(String name) =>
      'Quitaste esa carpeta de las que le compartes a $name';

  @override
  String outcomePeerMarkedForeign(String name) => 'Marcaste a $name como ajeno';

  @override
  String resultIn(String label) => 'en $label';

  @override
  String nameWithReal(String alias, String real) => '$alias ($real)';
}
