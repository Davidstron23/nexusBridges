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
}
