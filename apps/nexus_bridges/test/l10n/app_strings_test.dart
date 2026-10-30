import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/l10n/app_strings_en.dart';
import 'package:nexus_bridges/src/l10n/app_strings_es.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart'
    show PairingOutcome, TransferOutcome;

typedef _Text = String Function(AppStrings strings);

const String _sampleName = 'Casa de Ana';
const int _samplePort = 53530;

final Map<String, _Text> _texts = {
  'appTitle': (s) => s.appTitle,
  'devicesTitle': (s) => s.devicesTitle,
  'noDevicesYet': (s) => s.noDevicesYet,
  'rescanHint': (s) => s.rescanHint,
  'rescanButton': (s) => s.rescanButton,
  'pausedBanner': (s) => s.pausedBanner,
  'trustNetworkButton': (s) => s.trustNetworkButton(_sampleName),
  'networkPromptTitle': (s) => s.networkPromptTitle,
  'networkPromptBody': (s) => s.networkPromptBody(_sampleName),
  'yes': (s) => s.yes,
  'no': (s) => s.no,
  'pairedLabel': (s) => s.pairedLabel,
  'notPairedLabel': (s) => s.notPairedLabel,
  'deviceTypeDesktop': (s) => s.deviceTypeDesktop,
  'deviceTypeMobile': (s) => s.deviceTypeMobile,
  'identityResetWarning': (s) => s.identityResetWarning,
  'identityFailed': (s) => s.identityFailed,
  'portInUse': (s) => s.portInUse(_samplePort),
  'retryButton': (s) => s.retryButton,
  'decisionNotSaved': (s) => s.decisionNotSaved,
  'closeButton': (s) => s.closeButton,
  'pairButton': (s) => s.pairButton,
  'unpairButton': (s) => s.unpairButton,
  'moreOptions': (s) => s.moreOptions,
  'notVisibleLabel': (s) => s.notVisibleLabel,
  'pairedMineLabel': (s) => s.pairedMineLabel,
  'pairedForeignLabel': (s) => s.pairedForeignLabel,
  'markAsMine': (s) => s.markAsMine,
  'markAsForeign': (s) => s.markAsForeign,
  'ignoredLabel': (s) => s.ignoredLabel,
  'unignoreButton': (s) => s.unignoreButton,
  'mismatchWarning': (s) => s.mismatchWarning,
  'removeButton': (s) => s.removeButton,
  'pairAgainButton': (s) => s.pairAgainButton,
  'possibleReinstall': (s) => s.possibleReinstall(_sampleName),
  'pairingAlreadyInProgress': (s) => s.pairingAlreadyInProgress,
  'tooManyPaired': (s) => s.tooManyPaired,
  'pairUnavailable': (s) => s.pairUnavailable,
  'pairingWithTitle': (s) => s.pairingWithTitle(_sampleName),
  'connectingTo': (s) => s.connectingTo(_sampleName),
  'compareCode': (s) => s.compareCode(_sampleName),
  'matchesButton': (s) => s.matchesButton,
  'doesNotMatchButton': (s) => s.doesNotMatchButton,
  'cancelButton': (s) => s.cancelButton,
  'waitingForPeer': (s) => s.waitingForPeer(_sampleName),
  'pairingRequestTitle': (s) => s.pairingRequestTitle(_sampleName),
  'fingerprintLine': (s) => s.fingerprintLine(_sampleShort),
  'alreadyPairedNote': (s) => s.alreadyPairedNote,
  'ignoreDeviceButton': (s) => s.ignoreDeviceButton,
  'receiverWaiting': (s) => s.receiverWaiting(_sampleName),
  'pairingResultTitle': (s) => s.pairingResultTitle,
  'outcomePaired': (s) => s.outcomePaired(_sampleName),
  'outcomeRejected': (s) => s.outcomeRejected(_sampleName),
  'outcomeBusy': (s) => s.outcomeBusy(_sampleName),
  'outcomePaused': (s) => s.outcomePaused(_sampleName),
  'outcomeCancelledByPeer': (s) => s.outcomeCancelledByPeer(_sampleName),
  'outcomeExpired': (s) => s.outcomeExpired,
  'outcomeLost': (s) => s.outcomeLost(_sampleName),
  'outcomeNetworkChanged': (s) => s.outcomeNetworkChanged,
  'outcomeFailed': (s) => s.outcomeFailed(_sampleName),
  'outcomeNotSaved': (s) => s.outcomeNotSaved,
  'replaceTitle': (s) => s.replaceTitle(_sampleOldName),
  'replaceBody': (s) => s.replaceBody(_sampleName, _sampleOldName),
  'replaceButton': (s) => s.replaceButton,
  'keepBothButton': (s) => s.keepBothButton,
  'mineTitle': (s) => s.mineTitle(_sampleName),
  'mineBody': (s) => s.mineBody,
  'mineYesButton': (s) => s.mineYesButton,
  'mineNoButton': (s) => s.mineNoButton,
  'unpairTitle': (s) => s.unpairTitle(_sampleName),
  'unpairBody': (s) => s.unpairBody(_sampleName),
  'noticeAttemptCancelled': (s) => s.noticeAttemptCancelled(_sampleShort),
  'noticeAttemptPeerCancelled': (s) =>
      s.noticeAttemptPeerCancelled(_sampleShort),
  'noticeAttemptsCancelled': (s) => s.noticeAttemptsCancelled(_sampleCount),
  'noticePairingPaused': (s) => s.noticePairingPaused,
  'noticeUnpairedByPeer': (s) => s.noticeUnpairedByPeer(_sampleName),
  'noticeUnpairNotSaved': (s) => s.noticeUnpairNotSaved(_sampleName),
  'noticeChangeNotSaved': (s) => s.noticeChangeNotSaved,
  'noticeIgnoreNotSaved': (s) => s.noticeIgnoreNotSaved(_sampleName),
  'noticePairingNotSaved': (s) => s.noticePairingNotSaved(_sampleName),
  'noticePairingFailed': (s) => s.noticePairingFailed(_sampleName),
  'namesakeWarning': (s) => s.namesakeWarning(_sampleName),
  'noticeAttemptLost': (s) => s.noticeAttemptLost(_sampleShort),
  'noticeReplaceWithdrawn': (s) => s.noticeReplaceWithdrawn(_sampleOldName),
  'sendFileButton': (s) => s.sendFileButton,
  'sendNeedsVisible': (s) => s.sendNeedsVisible,
  'sendNeedsPairAgain': (s) => s.sendNeedsPairAgain,
  'alreadySending': (s) => s.alreadySending,
  'sendUnavailable': (s) => s.sendUnavailable,
  'searchingDevices': (s) => s.searchingDevices,
  'sendingToTitle': (s) => s.sendingToTitle(_sampleName),
  'fileLine': (s) => s.fileLine(_sampleFile, _sampleSize),
  'programLabel': (s) => s.programLabel,
  'containsGitRepository': (s) => s.containsGitRepository,
  'preparingFile': (s) => s.preparingFile(_sampleFile),
  'contactingPeer': (s) => s.contactingPeer(_sampleName),
  'waitingAcceptance': (s) => s.waitingAcceptance(_sampleName),
  'progressLine': (s) =>
      s.progressLine(_samplePercent, _sampleDone, _sampleSize),
  'peerCheckingFile': (s) => s.peerCheckingFile(_sampleName),
  'cancellingTransfer': (s) => s.cancellingTransfer,
  'incomingRequestTitle': (s) => s.incomingRequestTitle(_sampleName),
  'withoutMarkNote': (s) => s.withoutMarkNote,
  'acceptButton': (s) => s.acceptButton,
  'rejectButton': (s) => s.rejectButton,
  'folderQuestionTitle': (s) => s.folderQuestionTitle(_sampleName),
  'folderFirstTimeBody': (s) => s.folderFirstTimeBody,
  'folderThisTimeBody': (s) => s.folderThisTimeBody,
  'proposedFolderLine': (s) => s.proposedFolderLine(_samplePath),
  'useThisFolderButton': (s) => s.useThisFolderButton,
  'chooseOtherFolderButton': (s) => s.chooseOtherFolderButton,
  'pickerOpenNote': (s) => s.pickerOpenNote,
  'folderForbidden': (s) => s.folderForbidden(_samplePath),
  'folderCannotUse': (s) => s.folderCannotUse(_samplePath),
  'folderStillUnavailable': (s) => s.folderStillUnavailable(_samplePath),
  'folderUnknownVolume': (s) => s.folderUnknownVolume(_samplePath),
  'folderAdminShare': (s) => s.folderAdminShare(_samplePath),
  'checkingFolder': (s) => s.checkingFolder,
  'cautionNoMark': (s) => s.cautionNoMark(_samplePath),
  'cautionRemote': (s) => s.cautionRemote(_samplePath),
  'useAnywayButton': (s) => s.useAnywayButton,
  'transferAlreadyEnded': (s) => s.transferAlreadyEnded,
  'folderRememberedNote': (s) => s.folderRememberedNote(_samplePath),
  'folderNotUsable': (s) => s.folderNotUsable(_samplePath),
  'rememberAnywayButton': (s) => s.rememberAnywayButton,
  'dontRememberButton': (s) => s.dontRememberButton,
  'receivingFromTitle': (s) => s.receivingFromTitle(_sampleName),
  'waitingForData': (s) => s.waitingForData,
  'checkingFile': (s) => s.checkingFile,
  'lastSentTitle': (s) => s.lastSentTitle,
  'lastReceivedTitle': (s) => s.lastReceivedTitle,
  'toPeer': (s) => s.toPeer(_sampleName),
  'fromPeer': (s) => s.fromPeer(_sampleName),
  'showInFolderButton': (s) => s.showInFolderButton,
  'revealFolderOnly': (s) => s.revealFolderOnly,
  'folderUnavailable': (s) => s.folderUnavailable,
  'closeDuringTransferTitle': (s) => s.closeDuringTransferTitle,
  'closeDuringTransferBody': (s) => s.closeDuringTransferBody,
  'keepOpenButton': (s) => s.keepOpenButton,
  'closeAndCancelButton': (s) => s.closeAndCancelButton,
  'trustedNetworkLabel': (s) => s.trustedNetworkLabel,
  'onlyPairedCanSend': (s) => s.onlyPairedCanSend,
  'activityTab': (s) => s.activityTab,
  'devicesTab': (s) => s.devicesTab,
  'activityEmpty': (s) => s.activityEmpty,
  'sectionUnpaired': (s) => s.sectionUnpaired,
  'chipMine': (s) => s.chipMine,
  'chipForeign': (s) => s.chipForeign,
  'visibleLabel': (s) => s.visibleLabel,
  'diagramTitle': (s) => s.diagramTitle,
  'diagramCount': (s) => s.diagramCount(3, 2),
  'thisDeviceCaption': (s) => s.thisDeviceCaption(_sampleShort),
  'chipPreparing': (s) => s.chipPreparing,
  'chipWaiting': (s) => s.chipWaiting,
  'chipInProgress': (s) => s.chipInProgress,
  'chipChecking': (s) => s.chipChecking,
  'chipDelivered': (s) => s.chipDelivered,
  'chipSaved': (s) => s.chipSaved,
  'chipRejected': (s) => s.chipRejected,
  'chipCancelled': (s) => s.chipCancelled,
  'chipFailed': (s) => s.chipFailed,
  'chipUnconfirmed': (s) => s.chipUnconfirmed,
  'foreignSenderNote': (s) => s.foreignSenderNote(_sampleShort),
  'incomingExpiresNote': (s) => s.incomingExpiresNote,
  for (final outcome in PairingOutcome.values)
    'pairingEyebrow(${outcome.name})': (s) => s.pairingEyebrow(outcome),
  'mineQuestion': (s) => s.mineQuestion,
  'mineYesDetail': (s) => s.mineYesDetail,
  'mineNoDetail': (s) => s.mineNoDetail,
  'replaceShortBody': (s) => s.replaceShortBody(_sampleName),
};

final Map<String, (String, String)> _expectedPairingDesign = {
  'pairingEyebrow(paired)': (
    'Nexus bridge established',
    'Puente Nexus establecido',
  ),
  'pairingEyebrow(rejected)': ('Connection rejected', 'Conexión rechazada'),
  'pairingEyebrow(busy)': ('Device busy', 'Dispositivo ocupado'),
  'pairingEyebrow(paused)': ('Connection frozen', 'Conexión congelada'),
  'pairingEyebrow(cancelledByPeer)': (
    'Connection cancelled',
    'Conexión cancelada',
  ),
  'pairingEyebrow(expired)': ('Time is up', 'Tiempo agotado'),
  'pairingEyebrow(lost)': ('Device vanished', 'Equipo desaparecido'),
  'pairingEyebrow(networkChanged)': ('Network changed', 'Cambio de red'),
  'pairingEyebrow(failed)': ('Unexpected error', 'Error inesperado'),
  'pairingEyebrow(notSaved)': ('Could not save', 'Error al guardar'),
  'mineQuestion': ('Is this device yours?', '¿Este equipo es tuyo?'),
  'mineYesDetail': (
    'What it sends comes in without asking and it can browse the folders you '
        'share.',
    'Lo que envíe entra sin preguntar y puede explorar las carpetas que '
        'compartas.',
  ),
  'mineNoDetail': (
    'It will always ask for your permission before sending you anything.',
    'Siempre te pedirá permiso antes de enviarte nada.',
  ),
  'replaceShortBody': (
    '$_sampleName has the same name as a paired device that is not visible. '
        'If it is the same one reinstalled, replace it.',
    '$_sampleName se llama igual que uno vinculado que no está a la '
        'vista. Si es el mismo reinstalado, sustitúyelo.',
  ),
};

final Map<String, (String, String)> _expectedDesign = {
  'trustedNetworkLabel': ('Trusted network', 'Red de confianza'),
  'onlyPairedCanSend': (
    'Only your paired devices can send you files',
    'Solo tus equipos vinculados pueden enviarte archivos',
  ),
  'activityTab': ('Activity', 'Actividad'),
  'devicesTab': ('Devices', 'Equipos'),
  'activityEmpty': (
    "Here you'll see the send in progress and the last file you sent or "
        'received.',
    'Aqu\u00ed ver\u00e1s el env\u00edo en curso y el \u00faltimo archivo '
        'que hayas enviado o recibido.',
  ),
  'sectionUnpaired': ('Unpaired', 'Sin vincular'),
  'chipMine': ('Mine', 'M\u00edo'),
  'chipForeign': ("Someone else's", 'Ajeno'),
  'visibleLabel': ('Visible', 'A la vista'),
  'diagramTitle': ('My network', 'Mi red'),
  'diagramCount': (
    '3 devices \u00b7 2 visible',
    '3 equipos \u00b7 2 a la vista',
  ),
  'thisDeviceCaption': (
    'ABCD1234 \u00b7 this device',
    'ABCD1234 \u00b7 este equipo',
  ),
  'chipPreparing': ('Preparing', 'Preparando'),
  'chipWaiting': ('Waiting', 'Esperando'),
  'chipInProgress': ('In progress', 'En curso'),
  'chipChecking': ('Checking', 'Comprobando'),
  'chipDelivered': ('Delivered', 'Entregado'),
  'chipSaved': ('Saved', 'Guardado'),
  'chipRejected': ('Rejected', 'Rechazado'),
  'chipCancelled': ('Cancelled', 'Cancelado'),
  'chipFailed': ('Failed', 'Fallido'),
  'chipUnconfirmed': ('Unconfirmed', 'Sin confirmar'),
  'foreignSenderNote': (
    "It's someone else's device (fingerprint ABCD1234). Accept only if you "
        'were expecting it.',
    'Es un equipo ajeno (huella ABCD1234). Acepta solo si lo esperabas.',
  ),
  'incomingExpiresNote': (
    "If you don't answer, this request expires after a minute.",
    'Si no respondes, el aviso caduca al cabo de un minuto.',
  ),
};

const String _sampleFile = 'informe anual.pdf';
const String _sampleSize = '1,5 KB';
const String _sampleDone = '700 bytes';
const int _samplePercent = 42;
const String _samplePath = r'C:\Users\Ana\Downloads\NexusBridges';

final String _dots = String.fromCharCode(0x2026);
final String _middleDot = String.fromCharCode(0x00B7);

const Set<String> _withPath = {
  'proposedFolderLine',
  'folderForbidden',
  'folderCannotUse',
  'folderStillUnavailable',
  'folderUnknownVolume',
  'folderAdminShare',
  'cautionNoMark',
  'cautionRemote',
  'folderRememberedNote',
  'folderNotUsable',
};

const Set<String> _withFile = {'fileLine', 'preparingFile'};

final Map<String, String Function(AppStrings, String)> _byArgument = {
  'sendingToTitle': (s, v) => s.sendingToTitle(v),
  'fileLine': (s, v) => s.fileLine(v, _sampleSize),
  'preparingFile': (s, v) => s.preparingFile(v),
  'contactingPeer': (s, v) => s.contactingPeer(v),
  'waitingAcceptance': (s, v) => s.waitingAcceptance(v),
  'peerCheckingFile': (s, v) => s.peerCheckingFile(v),
  'incomingRequestTitle': (s, v) => s.incomingRequestTitle(v),
  'folderQuestionTitle': (s, v) => s.folderQuestionTitle(v),
  'proposedFolderLine': (s, v) => s.proposedFolderLine(v),
  'folderForbidden': (s, v) => s.folderForbidden(v),
  'folderCannotUse': (s, v) => s.folderCannotUse(v),
  'folderStillUnavailable': (s, v) => s.folderStillUnavailable(v),
  'folderUnknownVolume': (s, v) => s.folderUnknownVolume(v),
  'folderAdminShare': (s, v) => s.folderAdminShare(v),
  'cautionNoMark': (s, v) => s.cautionNoMark(v),
  'cautionRemote': (s, v) => s.cautionRemote(v),
  'folderRememberedNote': (s, v) => s.folderRememberedNote(v),
  'folderNotUsable': (s, v) => s.folderNotUsable(v),
  'receivingFromTitle': (s, v) => s.receivingFromTitle(v),
  'toPeer': (s, v) => s.toPeer(v),
  'fromPeer': (s, v) => s.fromPeer(v),
};

final Map<String, (String, String)> _expectedTransfer = {
  'sendFileButton': ('Send file', 'Enviar archivo'),
  'sendNeedsVisible': (
    'It has to be visible to send it files.',
    'Tiene que estar a la vista para enviarle archivos.',
  ),
  'sendNeedsPairAgain': (
    'Pair it again before sending it files.',
    'Vuelve a vincularlo antes de enviarle archivos.',
  ),
  'alreadySending': (
    'Wait for the current send to finish.',
    'Espera a que termine el envío actual.',
  ),
  'sendUnavailable': (
    "You can't send files to this device right now.",
    'Ahora no se pueden enviar archivos a este equipo.',
  ),
  'searchingDevices': (
    'Searching for devices$_dots',
    'Buscando dispositivos$_dots',
  ),
  'sendingToTitle': ('Sending to $_sampleName', 'Enviando a $_sampleName'),
  'fileLine': (
    'File: $_sampleFile ($_sampleSize)',
    'Archivo: $_sampleFile ($_sampleSize)',
  ),
  'programLabel': ("It's a program", 'Es un programa'),
  'containsGitRepository': (
    'contains a Git repository, which can run code when opened',
    'contiene un repositorio Git, que puede ejecutar código al abrirlo',
  ),
  'preparingFile': (
    'Preparing $_sampleFile$_dots',
    'Preparando $_sampleFile$_dots',
  ),
  'contactingPeer': (
    'Contacting $_sampleName$_dots',
    'Contactando con $_sampleName$_dots',
  ),
  'waitingAcceptance': (
    'Waiting for $_sampleName to accept$_dots',
    'Esperando a que $_sampleName acepte$_dots',
  ),
  'progressLine': (
    '$_samplePercent% $_middleDot $_sampleDone of $_sampleSize',
    '$_samplePercent % $_middleDot $_sampleDone de $_sampleSize',
  ),
  'peerCheckingFile': (
    '$_sampleName is checking the file$_dots',
    '$_sampleName está comprobando el archivo$_dots',
  ),
  'cancellingTransfer': ('Cancelling$_dots', 'Cancelando$_dots'),
  'incomingRequestTitle': (
    '$_sampleName wants to send you a file',
    '$_sampleName quiere enviarte un archivo',
  ),
  'withoutMarkNote': (
    'It will be saved without the mark that tells Windows it comes from '
        "another device, because that drive doesn't support it.",
    'Se guardará sin la marca que indica a Windows que viene de otro '
        'equipo, porque esa unidad no la admite.',
  ),
  'acceptButton': ('Accept', 'Aceptar'),
  'rejectButton': ('Reject', 'Rechazar'),
  'folderQuestionTitle': (
    '$_sampleName is sending you a file',
    '$_sampleName te está enviando un archivo',
  ),
  'folderFirstTimeBody': (
    'Choose where to save the files you receive. It will be remembered for '
        'next time.',
    'Elige dónde guardar los archivos que recibas. Se recordará para las '
        'próximas veces.',
  ),
  'folderThisTimeBody': (
    "The usual folder isn't available right now. Choose where to save this "
        'file; next time the usual one will be used again.',
    'La carpeta de siempre no está disponible ahora. Elige dónde guardar '
        'este archivo; la próxima vez se volverá a usar la de siempre.',
  ),
  'proposedFolderLine': ('Folder: $_samplePath', 'Carpeta: $_samplePath'),
  'useThisFolderButton': ('Use this one', 'Usar esta'),
  'chooseOtherFolderButton': ('Choose another', 'Elegir otra'),
  'pickerOpenNote': (
    'Choose a folder in the Windows window$_dots',
    'Elige una carpeta en la ventana de Windows$_dots',
  ),
  'folderForbidden': (
    "Received files can't be saved in $_samplePath. Choose another folder.",
    'En $_samplePath no se pueden guardar archivos recibidos. Elige otra '
        'carpeta.',
  ),
  'folderCannotUse': (
    "$_samplePath can't be created or written to. Choose another folder.",
    'No se puede crear $_samplePath o no se puede escribir en ella. Elige '
        'otra carpeta.',
  ),
  'folderStillUnavailable': (
    '$_samplePath is still not available. Choose another folder.',
    '$_samplePath sigue sin estar disponible. Elige otra carpeta.',
  ),
  'folderUnknownVolume': (
    "Windows doesn't identify the drive of $_samplePath, so it can't be "
        'used to receive files. Choose another folder.',
    'Windows no identifica la unidad de $_samplePath, así que no se puede '
        'usar para recibir archivos. Elige otra carpeta.',
  ),
  'folderAdminShare': (
    "$_samplePath is in an administrative share of Windows, so it can't be "
        'used to receive files. Choose another folder.',
    '$_samplePath está en un recurso compartido administrativo de Windows, '
        'así que no se puede usar para recibir archivos. Elige otra carpeta.',
  ),
  'checkingFolder': (
    'Checking the folder$_dots',
    'Comprobando la carpeta$_dots',
  ),
  'cautionNoMark': (
    "Files saved in $_samplePath won't carry the mark that tells Windows "
        "they come from another device, so Windows won't warn you before "
        'opening a received program.',
    'Los archivos que se guarden en $_samplePath no llevarán la marca que '
        'indica a Windows que vienen de otro equipo, así que Windows no '
        'avisará antes de abrir un programa recibido.',
  ),
  'cautionRemote': (
    '$_samplePath is on a network drive or in a folder synced with the '
        'cloud: what you receive may be uploaded to the cloud or depend on '
        'the network.',
    '$_samplePath está en una unidad de red o en una carpeta sincronizada '
        'con la nube: lo que recibas puede subirse a la nube o depender de la '
        'red.',
  ),
  'useAnywayButton': ('Use it anyway', 'Usarla igualmente'),
  'transferAlreadyEnded': (
    'That send has already ended.',
    'Ese envío ya ha terminado.',
  ),
  'folderRememberedNote': (
    'Files you receive will be saved in $_samplePath.',
    'Los archivos que recibas se guardarán en $_samplePath.',
  ),
  'folderNotUsable': (
    "$_samplePath can't be used, so it hasn't been remembered.",
    '$_samplePath no se puede usar, así que no se ha recordado.',
  ),
  'rememberAnywayButton': ('Remember it anyway', 'Recordarla igualmente'),
  'dontRememberButton': ("Don't remember it", 'No recordarla'),
  'receivingFromTitle': (
    'Receiving from $_sampleName',
    'Recibiendo de $_sampleName',
  ),
  'waitingForData': ('Waiting for the data$_dots', 'Esperando los datos$_dots'),
  'checkingFile': ('Checking the file$_dots', 'Comprobando el archivo$_dots'),
  'lastSentTitle': ('Last send', 'Último envío'),
  'lastReceivedTitle': ('Last received', 'Última recepción'),
  'toPeer': ('To $_sampleName', 'Para $_sampleName'),
  'fromPeer': ('From $_sampleName', 'De $_sampleName'),
  'showInFolderButton': ('Show in folder', 'Mostrar en la carpeta'),
  'revealFolderOnly': (
    "The folder was opened, but the file couldn't be selected. It may have "
        'been moved, renamed or deleted.',
    'Se ha abierto la carpeta, pero no se ha podido seleccionar el archivo. '
        'Puede que se haya movido, cambiado de nombre o borrado.',
  ),
  'folderUnavailable': (
    "That folder isn't available.",
    'Esa carpeta no está disponible.',
  ),
  'closeDuringTransferTitle': (
    'A send is in progress',
    'Hay un envío en curso',
  ),
  'closeDuringTransferBody': (
    'If you close the app now, the send will be cancelled.',
    'Si cierras la app ahora, el envío se cancelará.',
  ),
  'keepOpenButton': ('Keep open', 'No cerrar'),
  'closeAndCancelButton': ('Close and cancel', 'Cerrar y cancelar'),
};

final Map<TransferOutcome, (String, String)> _expectedSent = {
  TransferOutcome.saved: ('It arrived intact.', 'Ha llegado intacto.'),
  TransferOutcome.savedWithoutMark: (
    'It arrived intact, but it was saved without the mark that tells Windows '
        'it comes from another device.',
    'Ha llegado intacto, pero se ha guardado sin la marca que indica a '
        'Windows que viene de otro equipo.',
  ),
  TransferOutcome.declined: (
    "The other device didn't accept it. You can try again in a minute.",
    'El otro equipo no lo ha aceptado. Puedes volver a intentarlo dentro de '
        'un minuto.',
  ),
  TransferOutcome.busy: (
    'The other device is busy with another send. Try again in a moment.',
    'El otro equipo está ocupado con otro envío. Inténtalo dentro de un '
        'momento.',
  ),
  TransferOutcome.unanswered: (
    "The other device didn't respond.",
    'El otro equipo no ha respondido.',
  ),
  TransferOutcome.invalidName: (
    "The other device doesn't accept that file name.",
    'El otro equipo no admite ese nombre de archivo.',
  ),
  TransferOutcome.blockedType: (
    "The other device doesn't accept that type of file.",
    'El otro equipo no admite ese tipo de archivo.',
  ),
  TransferOutcome.incompatible: (
    "Your request isn't compatible with the other device.",
    'Tu petición no es compatible con el otro equipo.',
  ),
  TransferOutcome.noSpace: (
    "There isn't enough space on the other device.",
    'En el otro equipo no hay espacio suficiente.',
  ),
  TransferOutcome.noFolder: (
    "The other device hasn't chosen where to save the files.",
    'El otro equipo no ha elegido dónde guardar los archivos.',
  ),
  TransferOutcome.pathTooLong: (
    'The path where the other device would save it is too long for Windows.',
    'La ruta donde lo guardaría el otro equipo es demasiado larga para '
        'Windows.',
  ),
  TransferOutcome.cancelledHere: ('You cancelled it.', 'Lo has cancelado.'),
  TransferOutcome.cancelledByPeer: (
    'The other device cancelled it.',
    'El otro equipo lo ha cancelado.',
  ),
  TransferOutcome.unpaired: (
    "It was cancelled because you're no longer paired.",
    'Se ha cancelado porque ya no estáis vinculados.',
  ),
  TransferOutcome.unreadable: (
    "The file couldn't be read.",
    'No se ha podido leer el archivo.',
  ),
  TransferOutcome.noContact: (
    "Couldn't contact the other device.",
    'No se ha podido contactar con el otro equipo.',
  ),
  TransferOutcome.uploadNotStarted: (
    "It didn't complete: the transfer didn't start in time.",
    'No se ha completado: la transferencia no empezó a tiempo.',
  ),
  TransferOutcome.connectionLost: (
    'The connection was cut before it finished.',
    'Se ha cortado la conexión antes de terminar.',
  ),
  TransferOutcome.idle: (
    'It was cut because no data moved for 30 seconds.',
    'Se ha cortado porque no se movieron datos durante 30 segundos.',
  ),
  TransferOutcome.tooManyBytes: (
    'It was cut because more data arrived than announced.',
    'Se ha cortado porque llegaron más datos de los anunciados.',
  ),
  TransferOutcome.writeFailed: (
    "The other device couldn't write it (for example, because its disk is "
        'full).',
    'El otro equipo no ha podido escribirlo (por ejemplo, porque se ha '
        'llenado el disco).',
  ),
  TransferOutcome.diskFull: (
    "The other device's disk filled up while receiving it, so it was "
        'deleted.',
    'Se ha llenado el disco del otro equipo mientras lo recibía, así que se '
        'ha borrado.',
  ),
  TransferOutcome.damaged: (
    'It arrived damaged, so it was deleted. If the file changed while it was '
        'being sent, send it again.',
    'Ha llegado dañado, así que se ha borrado. Si el archivo cambió mientras '
        'se enviaba, vuelve a enviarlo.',
  ),
  TransferOutcome.markFailed: (
    "It couldn't be marked as coming from another device, so it was "
        'deleted.',
    'No se ha podido marcar como venido de otro equipo, así que se ha '
        'borrado.',
  ),
  TransferOutcome.moveFailed: (
    "It couldn't be moved to the folder, so it was deleted.",
    'No se ha podido mover a la carpeta, así que se ha borrado.',
  ),
  TransferOutcome.noFreeName: (
    "There was no free name for it in the folder, so it wasn't saved.",
    'No quedaba ningún nombre libre en la carpeta, así que no se ha '
        'guardado.',
  ),
  TransferOutcome.interfaceDown: (
    'It was cut because the network connection changed.',
    'Se ha cortado porque ha cambiado la conexión de red.',
  ),
  TransferOutcome.unconfirmed: (
    "Everything was sent, but the other device didn't confirm it: it's not "
        'known whether it arrived.',
    'Se ha enviado todo, pero el otro equipo no lo ha confirmado: no se sabe '
        'si ha llegado.',
  ),
  TransferOutcome.shortcut: (
    'Shortcuts are not sent.',
    'Los accesos directos no se envían.',
  ),
  TransferOutcome.wholeDrive: (
    "Whole drives can't be sent, only folders inside them.",
    'No se pueden enviar unidades enteras, solo carpetas de dentro.',
  ),
  TransferOutcome.protectedData: (
    "This is NexusBridges' own data and is never sent.",
    'Son datos de la propia app y nunca se envían.',
  ),
  TransferOutcome.notFound: ('It no longer exists.', 'Ya no existe.'),
  TransferOutcome.tooManyEntries: (
    'The folder has more than 100,000 items.',
    'La carpeta tiene más de 100 000 elementos.',
  ),
  TransferOutcome.tooDeep: (
    'The folder has more than 64 levels.',
    'La carpeta tiene más de 64 niveles.',
  ),
  TransferOutcome.tooLargeForPeer: (
    'The folder is too big for the other device.',
    'La carpeta es demasiado grande para el otro equipo.',
  ),
  TransferOutcome.unexpectedData: (
    "The other device sent data it hadn't announced.",
    'El otro equipo mandó datos que no había anunciado.',
  ),
};

final Map<TransferOutcome, (String, String)> _expectedReceived = {
  TransferOutcome.saved: ('Saved.', 'Guardado.'),
  TransferOutcome.savedWithoutMark: (
    'Saved without the mark that tells Windows it comes from another device.',
    'Guardado sin la marca que indica a Windows que viene de otro equipo.',
  ),
  TransferOutcome.declined: ('You rejected it.', 'Lo has rechazado.'),
  TransferOutcome.busy: (
    'It was rejected because another send was in progress.',
    'Se ha rechazado porque había otro envío en curso.',
  ),
  TransferOutcome.unanswered: (
    'It expired without an answer.',
    'Ha caducado sin respuesta.',
  ),
  TransferOutcome.invalidName: (
    "It was rejected because its name isn't valid.",
    'Se ha rechazado porque su nombre no es válido.',
  ),
  TransferOutcome.blockedType: (
    "It was rejected because that type of file isn't accepted.",
    'Se ha rechazado porque no se admite ese tipo de archivo.',
  ),
  TransferOutcome.incompatible: (
    "It was rejected because the request wasn't compatible.",
    'Se ha rechazado porque la petición no era compatible.',
  ),
  TransferOutcome.noSpace: (
    "It was rejected because there isn't enough space: the file size plus "
        '1 GB must be free.',
    'Se ha rechazado porque no hay espacio: tiene que quedar libre el tamaño '
        'del archivo más 1 GB.',
  ),
  TransferOutcome.noFolder: (
    "It was rejected because you didn't choose where to save it.",
    'Se ha rechazado porque no elegiste dónde guardarlo.',
  ),
  TransferOutcome.pathTooLong: (
    'It was rejected because the path where it would be saved is too long '
        'for Windows.',
    'Se ha rechazado porque la ruta donde se guardaría es demasiado larga '
        'para Windows.',
  ),
  TransferOutcome.cancelledHere: ('You cancelled it.', 'Lo has cancelado.'),
  TransferOutcome.cancelledByPeer: (
    'The other device cancelled it.',
    'El otro equipo lo ha cancelado.',
  ),
  TransferOutcome.unpaired: (
    "It was cancelled because you're no longer paired.",
    'Se ha cancelado porque ya no estáis vinculados.',
  ),
  TransferOutcome.unreadable: (
    'The other device could no longer read the file.',
    'El otro equipo ha dejado de poder leer el archivo.',
  ),
  TransferOutcome.noContact: (
    "Couldn't contact the other device.",
    'No se ha podido contactar con el otro equipo.',
  ),
  TransferOutcome.uploadNotStarted: (
    "It didn't complete: the transfer didn't start in time.",
    'No se ha completado: la transferencia no empezó a tiempo.',
  ),
  TransferOutcome.connectionLost: (
    'The connection was cut before it finished.',
    'Se ha cortado la conexión antes de terminar.',
  ),
  TransferOutcome.idle: (
    'It was cut because no data moved for 30 seconds.',
    'Se ha cortado porque no se movieron datos durante 30 segundos.',
  ),
  TransferOutcome.tooManyBytes: (
    'It was cut because more data arrived than announced.',
    'Se ha cortado porque llegaron más datos de los anunciados.',
  ),
  TransferOutcome.writeFailed: (
    "It couldn't be written (for example, because the disk is full), so it "
        'was deleted.',
    'No se ha podido escribir (por ejemplo, porque se ha llenado el disco), '
        'así que se ha borrado.',
  ),
  TransferOutcome.diskFull: (
    'The disk filled up while receiving it, so it was deleted.',
    'Se ha llenado el disco mientras se recibía, así que se ha borrado.',
  ),
  TransferOutcome.damaged: (
    'It arrived damaged, so it was deleted.',
    'Ha llegado dañado, así que se ha borrado.',
  ),
  TransferOutcome.markFailed: (
    "It couldn't be marked as coming from another device, so it was "
        'deleted.',
    'No se ha podido marcar como venido de otro equipo, así que se ha '
        'borrado.',
  ),
  TransferOutcome.moveFailed: (
    "It couldn't be moved to the folder, so it was deleted.",
    'No se ha podido mover a la carpeta, así que se ha borrado.',
  ),
  TransferOutcome.noFreeName: (
    "There was no free name for it in the folder, so it wasn't saved.",
    'No quedaba ningún nombre libre en la carpeta, así que no se ha '
        'guardado.',
  ),
  TransferOutcome.interfaceDown: (
    'It was cut because the network connection changed.',
    'Se ha cortado porque ha cambiado la conexión de red.',
  ),
  TransferOutcome.unconfirmed: (
    "Everything was sent, but it wasn't confirmed.",
    'Se ha enviado todo, pero no se ha confirmado.',
  ),
  TransferOutcome.shortcut: (
    "It was rejected because shortcuts aren't accepted.",
    'Se rechazó porque no se aceptan accesos directos.',
  ),
  TransferOutcome.wholeDrive: (
    "It was rejected because whole drives aren't accepted.",
    'Se rechazó porque no se aceptan unidades enteras.',
  ),
  TransferOutcome.protectedData: (
    "It was rejected because NexusBridges' own data is never sent.",
    'Se rechazó porque los datos de NexusBridges nunca se envían.',
  ),
  TransferOutcome.notFound: (
    'It no longer existed on the other device.',
    'Ya no existía en el otro equipo.',
  ),
  TransferOutcome.tooManyEntries: (
    'It was rejected because the folder has more than 100,000 items.',
    'Se rechazó porque la carpeta tiene más de 100 000 elementos.',
  ),
  TransferOutcome.tooDeep: (
    'It was rejected because the folder has more than 64 levels.',
    'Se rechazó porque la carpeta tiene más de 64 niveles.',
  ),
  TransferOutcome.tooLargeForPeer: (
    'It was rejected because the folder is too big.',
    'Se rechazó porque la carpeta es demasiado grande.',
  ),
  TransferOutcome.unexpectedData: (
    "It was cut because data arrived that hadn't been announced.",
    'Se cortó porque llegaron datos que no se habían anunciado.',
  ),
};

const String _sampleShort = 'ABCD1234';
const String _sampleOldName = 'Portátil · 9999AAAA';
const int _sampleCount = 4;

const Set<String> _withName = {
  'possibleReinstall',
  'pairingWithTitle',
  'connectingTo',
  'compareCode',
  'waitingForPeer',
  'pairingRequestTitle',
  'receiverWaiting',
  'outcomePaired',
  'outcomeRejected',
  'outcomeBusy',
  'outcomePaused',
  'outcomeCancelledByPeer',
  'outcomeLost',
  'outcomeFailed',
  'replaceBody',
  'mineTitle',
  'unpairTitle',
  'unpairBody',
  'noticeUnpairedByPeer',
  'noticeUnpairNotSaved',
  'noticeIgnoreNotSaved',
  'noticePairingNotSaved',
  'noticePairingFailed',
  'namesakeWarning',
  'sendingToTitle',
  'contactingPeer',
  'waitingAcceptance',
  'peerCheckingFile',
  'incomingRequestTitle',
  'folderQuestionTitle',
  'receivingFromTitle',
  'toPeer',
  'fromPeer',
  'replaceShortBody',
};

const Set<String> _withShort = {
  'fingerprintLine',
  'noticeAttemptCancelled',
  'noticeAttemptPeerCancelled',
  'noticeAttemptLost',
};

const Set<String> _withOldName = {
  'replaceTitle',
  'replaceBody',
  'noticeReplaceWithdrawn',
};

const Set<String> _meaningOnly = {
  'noticeAttemptCancelled',
  'noticePairingNotSaved',
  'noticePairingFailed',
};

final Map<String, (String, String)> _expectedPairing = {
  'pairButton': ('Pair', 'Vincular'),
  'unpairButton': ('Unpair', 'Desvincular'),
  'moreOptions': ('More options', 'Más opciones'),
  'notVisibleLabel': ('Not visible', 'No visible'),
  'pairedMineLabel': ('Paired · Mine', 'Vinculado · Mío'),
  'pairedForeignLabel': ("Paired · Someone else's", 'Vinculado · Ajeno'),
  'markAsMine': ('Mark as mine', 'Marcar como mío'),
  'markAsForeign': ("Mark as someone else's", 'Marcar como ajeno'),
  'ignoredLabel': ('Ignored', 'Ignorado'),
  'unignoreButton': ('Stop ignoring', 'Dejar de ignorar'),
  'mismatchWarning': (
    'This device no longer has you paired.',
    'Ya no te tiene vinculado.',
  ),
  'removeButton': ('Remove', 'Quitar'),
  'pairAgainButton': ('Pair again', 'Volver a vincular'),
  'possibleReinstall': (
    'It has the same name as $_sampleName, which is paired and not visible. '
        'It may be that device after a reinstall, or someone pretending to '
        'be it.',
    'Tiene el mismo nombre que $_sampleName, que está vinculado y no está a '
        'la vista. Puede ser ese equipo reinstalado o alguien haciéndose '
        'pasar por él.',
  ),
  'pairingAlreadyInProgress': (
    'There is already a pairing in progress.',
    'Ya hay una vinculación en curso.',
  ),
  'tooManyPaired': (
    'You already have 32 paired devices. Unpair one to pair a new one.',
    'Ya tienes 32 equipos vinculados. Desvincula alguno para vincular otro.',
  ),
  'pairUnavailable': (
    "This device can't be paired right now.",
    'Ahora no se puede vincular este equipo.',
  ),
  'pairingWithTitle': (
    'Pairing with $_sampleName',
    'Vinculando con $_sampleName',
  ),
  'connectingTo': (
    'Connecting to $_sampleName…',
    'Conectando con $_sampleName…',
  ),
  'compareCode': (
    'Check that $_sampleName shows the same code.',
    'Comprueba que $_sampleName muestra el mismo código.',
  ),
  'matchesButton': ('It matches', 'Coincide'),
  'doesNotMatchButton': ("It doesn't match", 'No coincide'),
  'cancelButton': ('Cancel', 'Cancelar'),
  'waitingForPeer': (
    'Waiting for the code to be confirmed on $_sampleName…',
    'Esperando a que se confirme el código en $_sampleName…',
  ),
  'pairingRequestTitle': (
    '$_sampleName wants to pair',
    '$_sampleName quiere vincularse',
  ),
  'fingerprintLine': ('Fingerprint: $_sampleShort', 'Huella: $_sampleShort'),
  'alreadyPairedNote': (
    'This device is already paired. If you confirm, it stays as it is.',
    'Este equipo ya está vinculado. Si confirmas, se queda como está.',
  ),
  'ignoreDeviceButton': ('Ignore this device', 'Ignorar este dispositivo'),
  'receiverWaiting': (
    'You have confirmed the code. Waiting for $_sampleName to confirm it '
        'too…',
    'Has confirmado el código. Esperando a que $_sampleName también lo '
        'confirme…',
  ),
  'pairingResultTitle': ('Pairing', 'Vinculación'),
  'outcomePaired': (
    '$_sampleName is now paired.',
    '$_sampleName ya está vinculado.',
  ),
  'outcomeRejected': (
    '$_sampleName has not accepted the pairing.',
    '$_sampleName no ha aceptado la vinculación.',
  ),
  'outcomeBusy': (
    '$_sampleName is busy with another pairing. Try again in a minute.',
    '$_sampleName está ocupado con otra vinculación. '
        'Inténtalo dentro de un minuto.',
  ),
  'outcomePaused': (
    '$_sampleName is not accepting pairings for a few minutes.',
    '$_sampleName no admite vinculaciones durante unos minutos.',
  ),
  'noticeAttemptPeerCancelled': (
    'The device with fingerprint $_sampleShort has cancelled the pairing.',
    'El equipo con huella $_sampleShort ha cancelado la vinculación.',
  ),
  'noticeAttemptsCancelled': (
    '$_sampleCount pairing attempts were cancelled in the last few minutes. '
        "If it wasn't you, check your network.",
    'Se han cancelado $_sampleCount intentos de vinculación en los últimos '
        'minutos. Si no has sido tú, revisa tu red.',
  ),
  'noticePairingPaused': (
    'Pairing is paused for a few minutes after 3 failed attempts: this '
        'device will not accept new requests until then.',
    'Vinculaciones en pausa durante unos minutos tras 3 intentos fallidos: '
        'este equipo no acepta peticiones nuevas hasta entonces.',
  ),
  'outcomeCancelledByPeer': (
    '$_sampleName has cancelled the pairing. Nothing has been saved.',
    '$_sampleName ha cancelado la vinculación. No se ha guardado nada.',
  ),
  'outcomeExpired': (
    'The pairing has expired. Nothing has been saved.',
    'La vinculación ha caducado. No se ha guardado nada.',
  ),
  'outcomeLost': (
    '$_sampleName has stopped responding. Nothing has been saved.',
    '$_sampleName ha dejado de responder. No se ha guardado nada.',
  ),
  'outcomeNetworkChanged': (
    'The pairing was cancelled because the network changed.',
    'La vinculación se ha cancelado porque ha cambiado la red.',
  ),
  'outcomeFailed': (
    'Could not pair with $_sampleName.',
    'No se ha podido vincular con $_sampleName.',
  ),
  'outcomeNotSaved': (
    'The pairing could not be saved, so it has not been completed.',
    'No se ha podido guardar la vinculación, así que no se ha completado.',
  ),
  'replaceTitle': ('Replace $_sampleOldName?', '¿Sustituir a $_sampleOldName?'),
  'replaceBody': (
    '$_sampleName has the same name as $_sampleOldName, which is paired but '
        'not visible. If it is the same device after a reinstall, replace it '
        'to remove the old pairing.',
    '$_sampleName tiene el mismo nombre que $_sampleOldName, que está '
        'vinculado pero no está a la vista. Si es el mismo equipo '
        'reinstalado, sustitúyelo para quitar la vinculación antigua.',
  ),
  'replaceButton': ('Replace', 'Sustituir'),
  'keepBothButton': ('Keep both', 'Conservar ambos'),
  'mineTitle': ('Paired with $_sampleName', 'Vinculado con $_sampleName'),
  'mineBody': (
    'Is this device yours? If it is, what it sends will come in without '
        'asking and it will be able to browse the folders you share. If it '
        'belongs to someone else, it will always ask for your permission.',
    '¿Este equipo es tuyo? Si es tuyo, lo que envíe entrará sin preguntar y '
        'podrá explorar las carpetas que compartas. Si es de otra persona, '
        'siempre te pedirá permiso.',
  ),
  'mineYesButton': ("It's mine", 'Es mío'),
  'mineNoButton': ("It's someone else's", 'Es de otra persona'),
  'unpairTitle': ('Unpair $_sampleName?', '¿Desvincular $_sampleName?'),
  'unpairBody': (
    '$_sampleName will no longer be able to connect to this device, starting '
        'now. To use it again you will have to pair them again.',
    '$_sampleName dejará de poder conectarse con este equipo desde ahora. '
        'Para volver a usarlo tendréis que vincularlos otra vez.',
  ),
  'noticeUnpairedByPeer': (
    '$_sampleName has unpaired this device.',
    '$_sampleName ha desvinculado este equipo.',
  ),
  'noticeUnpairNotSaved': (
    '$_sampleName is unpaired until you close the app, but it could not be '
        'saved: if you restart, it would be paired again.',
    '$_sampleName está desvinculado hasta que cierres la app, pero no se ha '
        'podido guardar: si la reinicias, volvería a estar vinculado.',
  ),
  'noticeChangeNotSaved': (
    'Your change applies until you close the app, but it could not be saved '
        'and will not be remembered.',
    'Tu cambio se aplica hasta que cierres la app, pero no se ha podido '
        'guardar y no se recordará.',
  ),
  'noticeIgnoreNotSaved': (
    '$_sampleName is ignored until you close the app, but it could not be '
        'saved and will not be remembered.',
    '$_sampleName queda ignorado hasta que cierres la app, pero no se ha '
        'podido guardar y no se recordará.',
  ),
  'namesakeWarning': (
    'You already have a paired device called $_sampleName with a different '
        'fingerprint.',
    'Ya tienes vinculado un equipo llamado $_sampleName con otra huella.',
  ),
  'noticeAttemptLost': (
    'The device with fingerprint $_sampleShort stopped responding after '
        'seeing the pairing code.',
    'El equipo con huella $_sampleShort dejó de responder después de ver el '
        'código de vinculación.',
  ),
  'noticeReplaceWithdrawn': (
    '$_sampleOldName showed up again, so it was not replaced.',
    '$_sampleOldName ha vuelto a aparecer, así que no se ha sustituido.',
  ),
};

final Map<String, (String, String)> _expected = {
  'appTitle': ('NexusBridges', 'NexusBridges'),
  'devicesTitle': ('Devices nearby', 'Equipos cerca'),
  'noDevicesYet': ('No devices found yet', 'Todavía no hay equipos'),
  'rescanHint': (
    'No devices found. Some networks block devices from seeing each other.',
    'No se encuentran equipos. '
        'Algunas redes impiden que los equipos se vean entre sí.',
  ),
  'rescanButton': ('Search again', 'Buscar de nuevo'),
  'pausedBanner': (
    'NexusBridges is paused on this network',
    'NexusBridges está en pausa en esta red',
  ),
  'trustNetworkButton': ('Use on "$_sampleName"', 'Usar en "$_sampleName"'),
  'networkPromptTitle': (
    'Use NexusBridges on this network?',
    '¿Usar NexusBridges en esta red?',
  ),
  'networkPromptBody': (
    'Other devices on "$_sampleName" will be able to see this device. '
        'Only say yes on networks you trust, like your home.',
    'Los demás equipos de "$_sampleName" podrán ver este equipo. '
        'Di que sí solo en redes en las que confíes, como la de tu casa.',
  ),
  'yes': ('Use it here', 'Usar aquí'),
  'no': ('Not on this network', 'En esta red no'),
  'pairedLabel': ('Paired', 'Vinculado'),
  'notPairedLabel': ('Not paired', 'No vinculado'),
  'deviceTypeDesktop': ('Computer', 'Ordenador'),
  'deviceTypeMobile': ('Phone', 'Teléfono'),
  'identityResetWarning': (
    'This device has a new identity. '
        'You will need to pair it again with your other devices.',
    'Este equipo tiene una identidad nueva. '
        'Tendrás que volver a vincularlo con tus otros equipos.',
  ),
  'identityFailed': (
    "NexusBridges could not create this device's identity.",
    'NexusBridges no ha podido crear la identidad de este equipo.',
  ),
  'portInUse': (
    'Port $_samplePort is being used by another program.',
    'El puerto $_samplePort lo está usando otro programa.',
  ),
  'retryButton': ('Retry', 'Reintentar'),
  'decisionNotSaved': (
    'Your choice will apply until you close the app, '
        'but it could not be saved.',
    'Tu elección se aplicará hasta que cierres la app, '
        'pero no se ha podido guardar.',
  ),
  'closeButton': ('Close', 'Cerrar'),
};

void main() {
  final english = AppStringsEn();
  final spanish = AppStringsEs();

  group('RF-62: every text exists in both languages', () {
    test('the table covers the 177 texts of the plans of 001 to 006: the 84 '
        'of 001, 002 and 003, the 55 of the transfer (E145), the 24 of the '
        'design (E256) and the 14 of the pairing design (E281)', () {
      expect(_texts.length, 177);
      expect(_expectedTransfer.length, 55);
      expect(_expectedDesign.length, 24);
      expect(_expectedPairingDesign.length, 14);
      expect(
        _expected.keys.toSet().intersection(_expectedPairing.keys.toSet()),
        isEmpty,
      );
      expect(
        _expectedTransfer.keys.toSet().intersection({
          ..._expected.keys,
          ..._expectedPairing.keys,
          ..._meaningOnly,
        }),
        isEmpty,
      );
      expect(
        _expectedDesign.keys.toSet().intersection({
          ..._expected.keys,
          ..._expectedPairing.keys,
          ..._expectedTransfer.keys,
          ..._meaningOnly,
        }),
        isEmpty,
      );
      expect(
        _expectedPairingDesign.keys.toSet().intersection({
          ..._expected.keys,
          ..._expectedPairing.keys,
          ..._expectedTransfer.keys,
          ..._expectedDesign.keys,
          ..._meaningOnly,
        }),
        isEmpty,
      );
      expect({
        ..._expected.keys,
        ..._expectedPairing.keys,
        ..._expectedTransfer.keys,
        ..._expectedDesign.keys,
        ..._expectedPairingDesign.keys,
        ..._meaningOnly,
      }, _texts.keys.toSet());
    });

    for (final entry in _expectedPairingDesign.entries) {
      test('${entry.key} matches the exact text of point 196 of the plan of '
          '004 (E281)', () {
        final text = _texts[entry.key]!;
        expect(text(english), entry.value.$1);
        expect(text(spanish), entry.value.$2);
      });
    }

    test('the pairing design texts differ from each other in each language '
        '(E281)', () {
      for (final strings in [english, spanish]) {
        final seen = <String, String>{};
        for (final key in _expectedPairingDesign.keys) {
          final text = _texts[key]!(strings);
          expect(seen[text], isNull, reason: '$key repeats ${seen[text]}');
          seen[text] = key;
        }
      }
    });

    test('the pairing design texts reuse no older key with the same text '
        '(E281)', () {
      for (final strings in [english, spanish]) {
        final older = {
          for (final key in _texts.keys)
            if (!_expectedPairingDesign.containsKey(key)) _texts[key]!(strings),
        };
        expect(older, hasLength(greaterThan(150)));
        for (final key in _expectedPairingDesign.keys) {
          expect(older, isNot(contains(_texts[key]!(strings))), reason: key);
        }
      }
    });

    for (final entry in _expectedDesign.entries) {
      test('${entry.key} matches the exact text of the design points 122, '
          '140 and 151 (E256)', () {
        final text = _texts[entry.key]!;
        expect(text(english), entry.value.$1);
        expect(text(spanish), entry.value.$2);
      });
    }

    test('the design texts differ from each other in each language '
        '(E256)', () {
      for (final strings in [english, spanish]) {
        final seen = <String, String>{};
        for (final key in _expectedDesign.keys) {
          final text = _texts[key]!(strings);
          expect(seen[text], isNull, reason: '$key repeats ${seen[text]}');
          seen[text] = key;
        }
      }
    });

    test('the design texts reuse no older key with the same text '
        '(E256)', () {
      for (final strings in [english, spanish]) {
        final older = {
          for (final key in _texts.keys)
            if (!_expectedDesign.containsKey(key)) _texts[key]!(strings),
        };
        expect(older, hasLength(greaterThan(130)));
        for (final key in _expectedDesign.keys) {
          expect(older, isNot(contains(_texts[key]!(strings))), reason: key);
        }
      }
    });

    for (final entry in _expectedTransfer.entries) {
      test('${entry.key} matches the exact text of the plan of 004 and 005 '
          '(E145)', () {
        final text = _texts[entry.key]!;
        expect(text(english), entry.value.$1);
        expect(text(spanish), entry.value.$2);
      });
    }

    test('the transfer texts differ from each other in each language '
        '(E145)', () {
      for (final strings in [english, spanish]) {
        final seen = <String, String>{};
        for (final key in _expectedTransfer.keys) {
          final text = _texts[key]!(strings);
          expect(seen[text], isNull, reason: '$key repeats ${seen[text]}');
          seen[text] = key;
        }
      }
    });

    test('the transfer texts reuse no older key with the same text '
        '(E145)', () {
      for (final strings in [english, spanish]) {
        final older = {
          for (final key in [..._expected.keys, ..._expectedPairing.keys])
            _texts[key]!(strings),
        };
        for (final key in _expectedTransfer.keys) {
          expect(older, isNot(contains(_texts[key]!(strings))), reason: key);
        }
      }
    });

    test('fileNoLongerThere is gone and revealFolderOnly takes its place '
        '(point 97)', () {
      for (final name in [
        'app_strings.dart',
        'app_strings_en.dart',
        'app_strings_es.dart',
      ]) {
        final source = File(
          'lib${Platform.pathSeparator}src${Platform.pathSeparator}l10n'
          '${Platform.pathSeparator}$name',
        ).readAsStringSync();
        expect(source, isNot(contains('fileNoLongerThere')), reason: name);
        expect(source, contains('revealFolderOnly'), reason: name);
      }
    });

    test('folderThisTimeBody takes no path and does not name the usual '
        'folder (point 99)', () {
      for (final strings in [english, spanish]) {
        expect(strings.folderThisTimeBody, isNot(contains(_samplePath)));
        expect(strings.folderThisTimeBody, isNot(contains(r'\')));
        expect(strings.folderThisTimeBody, isNot(contains('(')));
      }
    });

    for (final entry in _expectedPairing.entries) {
      test('${entry.key} matches the exact text of the plan of 003', () {
        final text = _texts[entry.key]!;
        expect(text(english), entry.value.$1);
        expect(text(spanish), entry.value.$2);
      });
    }

    test('no text uses long dashes', () {
      for (final strings in [english, spanish]) {
        for (final entry in _texts.entries) {
          final text = entry.value(strings);
          expect(text, isNot(contains('\u2014')), reason: entry.key);
          expect(text, isNot(contains('\u2013')), reason: entry.key);
        }
      }
    });

    for (final entry in _texts.entries) {
      test('${entry.key} is not empty in English nor in Spanish', () {
        expect(entry.value(english).trim(), isNotEmpty);
        expect(entry.value(spanish).trim(), isNotEmpty);
      });
    }

    for (final entry in _texts.entries) {
      if (entry.key == 'appTitle') continue;
      test('${entry.key} differs between English and Spanish', () {
        expect(entry.value(english), isNot(entry.value(spanish)));
      });
    }

    test('appTitle is the same brand in both languages', () {
      expect(english.appTitle, 'NexusBridges');
      expect(spanish.appTitle, 'NexusBridges');
    });

    for (final entry in _expected.entries) {
      test('${entry.key} matches the exact text of the plan', () {
        final text = _texts[entry.key]!;
        expect(text(english), entry.value.$1);
        expect(text(spanish), entry.value.$2);
      });
    }

    test('no text leaves an unresolved placeholder', () {
      for (final strings in [english, spanish]) {
        for (final text in _texts.values) {
          expect(text(strings), isNot(contains(r'$')));
          expect(text(strings), isNot(contains('{')));
        }
      }
    });
  });

  group('RF-62: texts with an argument include it', () {
    const odd = 'Red «rara» 5G';

    for (final strings in [english, spanish]) {
      final language = strings is AppStringsEs ? 'es' : 'en';

      test('trustNetworkButton includes the network name ($language)', () {
        expect(strings.trustNetworkButton(odd), contains(odd));
        expect(
          strings.trustNetworkButton('A'),
          isNot(strings.trustNetworkButton('B')),
        );
      });

      test('networkPromptBody includes the network name ($language)', () {
        expect(strings.networkPromptBody(odd), contains(odd));
        expect(
          strings.networkPromptBody('A'),
          isNot(strings.networkPromptBody('B')),
        );
      });

      test('portInUse includes the port ($language)', () {
        expect(strings.portInUse(53530), contains('53530'));
        expect(strings.portInUse(1), contains('1'));
        expect(strings.portInUse(1), isNot(strings.portInUse(2)));
      });

      for (final key in _withName) {
        test('$key includes the device name ($language)', () {
          expect(_texts[key]!(strings), contains(_sampleName));
        });
      }

      for (final key in _withShort) {
        test('$key includes the short fingerprint ($language)', () {
          expect(_texts[key]!(strings), contains(_sampleShort));
        });
      }

      for (final key in _withOldName) {
        test('$key includes the old name ($language)', () {
          expect(_texts[key]!(strings), contains(_sampleOldName));
        });
      }

      test('the device name of a text with a name changes the text '
          '($language)', () {
        expect(strings.pairingWithTitle(odd), contains(odd));
        expect(strings.outcomeFailed('A'), isNot(strings.outcomeFailed('B')));
        expect(
          strings.replaceBody('A', 'B'),
          isNot(strings.replaceBody('B', 'A')),
        );
        expect(strings.unpairBody('A'), isNot(strings.unpairBody('B')));
      });

      test('C115: noticeAttemptsCancelled includes the count, changes with '
          'it and carries no fingerprint ($language)', () {
        final text = strings.noticeAttemptsCancelled(4);
        expect(text, contains('4'));
        expect(text, isNot(contains(_sampleShort)));
        expect(strings.noticeAttemptsCancelled(17), contains('17'));
        expect(
          strings.noticeAttemptsCancelled(2),
          isNot(strings.noticeAttemptsCancelled(3)),
        );
        expect(
          strings.noticeAttemptsCancelled(2),
          isNot(strings.noticeAttemptCancelled(_sampleShort)),
        );
      });

      test('C115: noticeAttemptPeerCancelled includes the short fingerprint '
          'and is neutral, not the data mismatch text ($language)', () {
        final neutral = strings.noticeAttemptPeerCancelled(_sampleShort);
        expect(neutral, contains(_sampleShort));
        expect(
          strings.noticeAttemptPeerCancelled('X1'),
          isNot(strings.noticeAttemptPeerCancelled('X2')),
        );
        expect(neutral, isNot(strings.noticeAttemptCancelled(_sampleShort)));
        expect(
          neutral,
          isNot(contains(strings.noticeAttemptCancelled(_sampleShort))),
        );
      });

      test('C115: outcomePaused includes the name and differs from the other '
          'outcomes ($language)', () {
        expect(strings.outcomePaused(odd), contains(odd));
        expect(strings.outcomePaused('A'), isNot(strings.outcomePaused('B')));
        for (final other in [
          strings.outcomeRejected(_sampleName),
          strings.outcomeBusy(_sampleName),
          strings.outcomeFailed(_sampleName),
        ]) {
          expect(strings.outcomePaused(_sampleName), isNot(other));
        }
      });

      test('C115: noticePairingPaused is a fixed text without arguments that '
          'differs from the other notices ($language)', () {
        expect(strings.noticePairingPaused.trim(), isNotEmpty);
        expect(strings.noticePairingPaused, contains('3'));
        expect(
          strings.noticePairingPaused,
          isNot(strings.noticeAttemptsCancelled(3)),
        );
      });

      test('C136: namesakeWarning changes with the name and is not the '
          'possible reinstall warning ($language)', () {
        expect(strings.namesakeWarning(odd), contains(odd));
        expect(
          strings.namesakeWarning('A'),
          isNot(strings.namesakeWarning('B')),
        );
        expect(
          strings.namesakeWarning(_sampleName),
          isNot(strings.possibleReinstall(_sampleName)),
        );
      });

      test('C136: noticeAttemptLost changes with the short fingerprint and '
          'differs from the cancelled notices and the lost outcome '
          '($language)', () {
        final lost = strings.noticeAttemptLost(_sampleShort);
        expect(
          strings.noticeAttemptLost('X1'),
          isNot(strings.noticeAttemptLost('X2')),
        );
        for (final other in [
          strings.noticeAttemptPeerCancelled(_sampleShort),
          strings.noticeAttemptCancelled(_sampleShort),
          strings.outcomeLost(_sampleShort),
        ]) {
          expect(lost, isNot(other));
        }
      });

      test('C136: noticeReplaceWithdrawn changes with the name and differs '
          'from the replace question ($language)', () {
        expect(strings.noticeReplaceWithdrawn(odd), contains(odd));
        expect(
          strings.noticeReplaceWithdrawn('A'),
          isNot(strings.noticeReplaceWithdrawn('B')),
        );
        expect(
          strings.noticeReplaceWithdrawn(_sampleOldName),
          isNot(strings.replaceTitle(_sampleOldName)),
        );
      });

      test('the pairing notices of Q-9 include who and differ ($language)', () {
        expect(strings.noticePairingNotSaved('X1'), contains('X1'));
        expect(strings.noticePairingFailed('X1'), contains('X1'));
        expect(
          strings.noticePairingNotSaved('X1'),
          isNot(strings.noticePairingFailed('X1')),
        );
      });
    }
  });

  group('E145: transfer texts with arguments', () {
    const odd = 'Equipo «raro» 5G';

    for (final strings in [english, spanish]) {
      final language = strings is AppStringsEs ? 'es' : 'en';

      for (final key in _withPath) {
        test('$key includes the path ($language)', () {
          expect(_texts[key]!(strings), contains(_samplePath));
        });
      }

      for (final key in _withFile) {
        test('$key includes the file name ($language)', () {
          expect(_texts[key]!(strings), contains(_sampleFile));
        });
      }

      for (final entry in _byArgument.entries) {
        test('${entry.key} changes with its argument and keeps it whole '
            '($language)', () {
          expect(entry.value(strings, odd), contains(odd));
          expect(entry.value(strings, 'A1'), isNot(entry.value(strings, 'B2')));
        });
      }

      test('fileLine includes the size and changes with it ($language)', () {
        expect(strings.fileLine(_sampleFile, '150 MB'), contains('150 MB'));
        expect(
          strings.fileLine(_sampleFile, '1 byte'),
          isNot(strings.fileLine(_sampleFile, '2 bytes')),
        );
      });

      test('progressLine includes the percent, the done bytes and the total, '
          'each in its place ($language)', () {
        final line = strings.progressLine(37, '5,0 GB', '9,5 GB');
        expect(line, contains('37'));
        expect(line, contains('5,0 GB'));
        expect(line, contains('9,5 GB'));
        expect(line.indexOf('37'), lessThan(line.indexOf('5,0 GB')));
        expect(line.indexOf('5,0 GB'), lessThan(line.indexOf('9,5 GB')));
        expect(
          strings.progressLine(100, '0 bytes', '0 bytes'),
          contains('100'),
        );
        expect(
          strings.progressLine(1, 'x', 'y'),
          isNot(strings.progressLine(2, 'x', 'y')),
        );
      });

      test('the transfer texts with a name and with a path keep the same '
          'placeholders as the other language ($language)', () {
        final other = strings is AppStringsEs ? english : spanish;
        for (final entry in _byArgument.entries) {
          expect(entry.value(other, odd), contains(odd), reason: entry.key);
          expect(entry.value(strings, odd), isNot(entry.value(other, odd)));
        }
      });
    }
  });

  group('E256: design texts with arguments', () {
    test('diagramCount is singular with one device and plural with more', () {
      expect(english.diagramCount(1, 0), '1 device \u00b7 0 visible');
      expect(spanish.diagramCount(1, 0), '1 equipo \u00b7 0 a la vista');
      expect(english.diagramCount(3, 2), '3 devices \u00b7 2 visible');
      expect(spanish.diagramCount(3, 2), '3 equipos \u00b7 2 a la vista');
    });

    test('diagramCount is plural with no devices and keeps both '
        'numbers', () {
      expect(english.diagramCount(0, 0), '0 devices \u00b7 0 visible');
      expect(spanish.diagramCount(0, 0), '0 equipos \u00b7 0 a la vista');
      expect(english.diagramCount(12, 7), '12 devices \u00b7 7 visible');
      expect(spanish.diagramCount(12, 7), '12 equipos \u00b7 7 a la vista');
      expect(english.diagramCount(1, 1), '1 device \u00b7 1 visible');
      expect(spanish.diagramCount(1, 1), '1 equipo \u00b7 1 a la vista');
    });

    test('thisDeviceCaption with an empty fingerprint gives only "this '
        'device", without separator (point 140)', () {
      expect(english.thisDeviceCaption(''), 'this device');
      expect(spanish.thisDeviceCaption(''), 'este equipo');
      for (final strings in [english, spanish]) {
        expect(strings.thisDeviceCaption(''), isNot(contains('\u00b7')));
      }
    });

    test('thisDeviceCaption puts the short fingerprint first', () {
      expect(english.thisDeviceCaption('1A2B'), '1A2B \u00b7 this device');
      expect(spanish.thisDeviceCaption('1A2B'), '1A2B \u00b7 este equipo');
    });

    for (final strings in [english, spanish]) {
      final language = strings is AppStringsEs ? 'es' : 'en';

      test('foreignSenderNote includes the short fingerprint and changes '
          'with it ($language)', () {
        expect(strings.foreignSenderNote(_sampleShort), contains(_sampleShort));
        expect(
          strings.foreignSenderNote('A1'),
          isNot(strings.foreignSenderNote('B2')),
        );
      });
    }
  });

  group('E281: pairing design texts', () {
    test('the table covers the 10 values of PairingOutcome', () {
      expect(PairingOutcome.values, hasLength(10));
      expect(
        {
          for (final key in _expectedPairingDesign.keys)
            if (key.startsWith('pairingEyebrow(')) key,
        },
        {
          for (final outcome in PairingOutcome.values)
            'pairingEyebrow(${outcome.name})',
        },
      );
    });

    for (final strings in [english, spanish]) {
      final language = strings is AppStringsEs ? 'es' : 'en';

      test('pairingEyebrow(null) gives the failed eyebrow ($language)', () {
        expect(
          strings.pairingEyebrow(null),
          strings.pairingEyebrow(PairingOutcome.failed),
        );
        expect(
          strings.pairingEyebrow(null),
          language == 'es' ? 'Error inesperado' : 'Unexpected error',
        );
      });

      test('every outcome has its own eyebrow ($language)', () {
        expect({
          for (final outcome in PairingOutcome.values)
            strings.pairingEyebrow(outcome),
        }, hasLength(PairingOutcome.values.length));
      });

      test('the eyebrow is not the result text of the same outcome '
          '($language)', () {
        expect(
          strings.pairingEyebrow(PairingOutcome.expired),
          isNot(strings.outcomeExpired),
        );
        expect(
          strings.pairingEyebrow(PairingOutcome.networkChanged),
          isNot(strings.outcomeNetworkChanged),
        );
        expect(
          strings.pairingEyebrow(PairingOutcome.notSaved),
          isNot(strings.outcomeNotSaved),
        );
        expect(
          strings.pairingEyebrow(PairingOutcome.paired),
          isNot(strings.pairingResultTitle),
        );
      });

      test('replaceShortBody changes with the new name and keeps it whole '
          '($language)', () {
        const odd = 'Equipo «raro» 5G';
        expect(strings.replaceShortBody(odd), startsWith(odd));
        expect(
          strings.replaceShortBody('A1'),
          isNot(strings.replaceShortBody('B2')),
        );
        expect(
          strings.replaceShortBody(_sampleName),
          isNot(strings.replaceBody(_sampleName, _sampleOldName)),
        );
      });

      test('the mine question and its details differ from the old mineBody '
          'and from the buttons ($language)', () {
        for (final text in [
          strings.mineQuestion,
          strings.mineYesDetail,
          strings.mineNoDetail,
        ]) {
          expect(text, isNot(strings.mineBody));
          expect(text, isNot(strings.mineYesButton));
          expect(text, isNot(strings.mineNoButton));
        }
      });
    }

    test('keepBothButton is "Conservar ambos" in Spanish and stays "Keep '
        'both" in English', () {
      expect(spanish.keepBothButton, 'Conservar ambos');
      expect(english.keepBothButton, 'Keep both');
    });

    test('pairingResultTitle, mineBody and replaceBody are kept (point '
        '196)', () {
      for (final name in [
        'app_strings.dart',
        'app_strings_en.dart',
        'app_strings_es.dart',
      ]) {
        final source = File(
          'lib${Platform.pathSeparator}src${Platform.pathSeparator}l10n'
          '${Platform.pathSeparator}$name',
        ).readAsStringSync();
        for (final key in ['pairingResultTitle', 'mineBody', 'replaceBody']) {
          expect(source, contains(key), reason: '$name: $key');
        }
      }
    });
  });

  group('E145: sentOutcome and receivedOutcome', () {
    test('the plan tables cover the 36 values of TransferOutcome', () {
      expect(TransferOutcome.values, hasLength(36));
      expect(_expectedSent.keys.toSet(), TransferOutcome.values.toSet());
      expect(_expectedReceived.keys.toSet(), TransferOutcome.values.toSet());
    });

    for (final outcome in TransferOutcome.values) {
      test('sentOutcome(${outcome.name}) matches the plan', () {
        expect(english.sentOutcome(outcome), _expectedSent[outcome]!.$1);
        expect(spanish.sentOutcome(outcome), _expectedSent[outcome]!.$2);
      });

      test('receivedOutcome(${outcome.name}) matches the plan', () {
        expect(
          english.receivedOutcome(outcome),
          _expectedReceived[outcome]!.$1,
        );
        expect(
          spanish.receivedOutcome(outcome),
          _expectedReceived[outcome]!.$2,
        );
      });

      test('${outcome.name} is not empty, differs between languages and '
          'has no long dashes nor placeholders', () {
        for (final text in [
          english.sentOutcome(outcome),
          spanish.sentOutcome(outcome),
          english.receivedOutcome(outcome),
          spanish.receivedOutcome(outcome),
        ]) {
          expect(text.trim(), isNotEmpty);
          expect(text, isNot(contains(String.fromCharCode(0x2014))));
          expect(text, isNot(contains(String.fromCharCode(0x2013))));
          expect(text, isNot(contains(r'$')));
          expect(text, isNot(contains('{')));
        }
        expect(
          english.sentOutcome(outcome),
          isNot(spanish.sentOutcome(outcome)),
        );
        expect(
          english.receivedOutcome(outcome),
          isNot(spanish.receivedOutcome(outcome)),
        );
      });
    }

    test('within each side, every outcome has its own text', () {
      for (final strings in [english, spanish]) {
        expect({
          for (final o in TransferOutcome.values) strings.sentOutcome(o),
        }, hasLength(36));
        expect({
          for (final o in TransferOutcome.values) strings.receivedOutcome(o),
        }, hasLength(36));
      }
    });

    test('declined and damaged differ between the sender and the receiver '
        '(points 96 and 98)', () {
      for (final strings in [english, spanish]) {
        for (final outcome in [
          TransferOutcome.declined,
          TransferOutcome.damaged,
        ]) {
          expect(
            strings.sentOutcome(outcome),
            isNot(strings.receivedOutcome(outcome)),
          );
        }
      }
    });
  });

  group('RF-63/64: stringsFor', () {
    test('es gives the Spanish texts', () {
      expect(stringsFor('es'), isA<AppStringsEs>());
    });

    for (final code in ['en', 'fr', '', 'de', 'pt']) {
      test('"$code" gives the English texts', () {
        expect(stringsFor(code), isA<AppStringsEn>());
      });
    }
  });

  group('RF-63/64: AppStringsDelegate', () {
    const delegate = AppStringsDelegate();

    test('supports es and en', () {
      expect(delegate.isSupported(const Locale('es')), isTrue);
      expect(delegate.isSupported(const Locale('en')), isTrue);
    });

    test('supports regional variants of es and en', () {
      expect(delegate.isSupported(const Locale('es', 'ES')), isTrue);
      expect(delegate.isSupported(const Locale('es', 'MX')), isTrue);
      expect(delegate.isSupported(const Locale('en', 'US')), isTrue);
    });

    test('rejects fr and other languages', () {
      expect(delegate.isSupported(const Locale('fr')), isFalse);
      expect(delegate.isSupported(const Locale('de')), isFalse);
      expect(delegate.isSupported(const Locale('pt', 'BR')), isFalse);
    });

    test('load gives the strings of the locale synchronously', () async {
      final es = delegate.load(const Locale('es'));
      final en = delegate.load(const Locale('en'));
      expect(es, isA<SynchronousFuture<AppStrings>>());
      expect(en, isA<SynchronousFuture<AppStrings>>());
      expect(await es, isA<AppStringsEs>());
      expect(await en, isA<AppStringsEn>());
    });

    test('load of a regional Spanish locale gives Spanish', () async {
      expect(
        await delegate.load(const Locale('es', 'MX')),
        isA<AppStringsEs>(),
      );
    });

    test('never asks to reload', () {
      expect(delegate.shouldReload(const AppStringsDelegate()), isFalse);
    });

    testWidgets('of(context) gives the strings of the active locale', (
      tester,
    ) async {
      AppStrings? found;
      await tester.pumpWidget(
        Localizations(
          locale: const Locale('es'),
          delegates: const [
            AppStringsDelegate(),
            DefaultWidgetsLocalizations.delegate,
          ],
          child: Builder(
            builder: (context) {
              found = AppStringsDelegate.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(found, isA<AppStringsEs>());

      await tester.pumpWidget(
        Localizations(
          locale: const Locale('en'),
          delegates: const [
            AppStringsDelegate(),
            DefaultWidgetsLocalizations.delegate,
          ],
          child: Builder(
            builder: (context) {
              found = AppStringsDelegate.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(found, isA<AppStringsEn>());
    });
  });
}
