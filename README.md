# NexusBridges

Send files and folders between your own devices on the same Wi-Fi. No cables, no USB sticks, no cloud, no accounts.

> **Status: work in progress.** Nothing is released yet. The first target is Windows; Android and iPhone come later.

## What it is

NexusBridges is a peer-to-peer file transfer app for a local network. Every device runs the same app, finds the others on the network, and sends files straight to them. There is no central server in the middle.

The idea that drives it: you are working on a project on one computer and you need that folder on another one, including things you would never push to GitHub. You open NexusBridges, drag the folder in, pick the other device, pick the folder where it should land, and it goes there.

## Planned for the first version (0.1.0, Windows)

- Automatic discovery of other devices on the network.
- One-time pairing between two devices with a 6-digit code. Devices that were never paired are ignored.
- Encrypted transfers with mutual authentication, and a SHA-256 check on every file.
- Send single files or whole folders by drag and drop. Heavy folders such as `node_modules` are skipped.
- Choose the destination folder on the receiving computer, instead of a fixed downloads folder.
- Nothing received is ever opened automatically, and nothing is overwritten without asking.

## Not in the first version

- Android and iPhone (Android is next, then iPhone through a web page served by the desktop app).
- Controlling a transfer between two other devices from a third one.
- Browsing the full contents of another device.
- Linux and macOS.
- Resuming interrupted transfers.
- Transfers over the internet.

## Privacy

No accounts and no analytics. Nothing leaves your local network. The app has no secrets to configure, so there is no `.env` file.

## Build from source

You need Windows, Git, Flutter (the exact version pinned in `apps/nexus_bridges/pubspec.yaml`) and Visual Studio Build Tools 2022 with the "Desktop development with C++" workload. To build the installer you also need [Inno Setup 6](https://jrsoftware.org/isinfo.php).

```powershell
git clone https://github.com/Davidstron23/nexusBridges.git
cd nexusBridges
powershell -File tool/bootstrap.ps1
```

`bootstrap.ps1` checks the Flutter version, installs the dependencies and enables the git hooks. Then:

```powershell
cd apps/nexus_bridges
flutter run -d windows
```

To run the tests: `dart test` inside `packages/nexus_bridges_core` and `flutter test` inside `apps/nexus_bridges`.

To build the installer, run `powershell -File tool/build-installer.ps1`. It leaves `NexusBridges-Setup-<version>.exe` in `installer/Output/`.

The installer is not code-signed, so Windows SmartScreen may show a "Windows protected your PC" warning the first time you run it. Choose "More info" and then "Run anyway".

## Inspiration

[LocalSend](https://github.com/localsend/localsend) is a mature open source app that solves the same problem. NexusBridges is a separate project written from scratch in Dart, built to learn how this kind of protocol works.

## License

MIT, see `LICENSE`.

---

# NexusBridges (castellano)

Envía archivos y carpetas entre tus propios dispositivos conectados a la misma Wi-Fi. Sin cables, sin pendrives, sin nube y sin cuentas.

> **Estado: en desarrollo.** Todavía no hay ninguna versión publicada. Empieza por Windows; Android e iPhone llegarán después.

## Qué es

NexusBridges es una app de transferencia de archivos entre dispositivos de una red local, de igual a igual. Todos los dispositivos ejecutan la misma app, se encuentran en la red y se envían los archivos directamente. No hay un servidor central en medio.

La idea que lo mueve: estás trabajando en un proyecto en un ordenador y necesitas esa carpeta en otro, incluso con cosas que nunca subirías a GitHub. Abres NexusBridges, arrastras la carpeta, eliges el otro dispositivo, eliges la carpeta donde debe quedar y se envía.

## Previsto para la primera versión (0.1.0, Windows)

- Descubrimiento automático de los otros dispositivos de la red.
- Vinculación única entre dos dispositivos con un código de 6 dígitos. Los dispositivos que nunca se han vinculado se ignoran.
- Transferencias cifradas con autenticación en ambos sentidos, y comprobación SHA-256 de cada archivo.
- Envío de archivos sueltos o carpetas enteras arrastrando. Las carpetas pesadas como `node_modules` no se envían.
- Elegir la carpeta destino en el ordenador que recibe, en vez de una carpeta de descargas fija.
- Nada de lo recibido se abre automáticamente y nada se sobrescribe sin preguntar.

## Fuera de la primera versión

- Android e iPhone (primero Android, después iPhone mediante una página web servida por la app de escritorio).
- Ordenar un envío entre otros dos dispositivos desde un tercero.
- Explorar todo el contenido de otro dispositivo.
- Linux y macOS.
- Reanudar transferencias interrumpidas.
- Transferencias por internet.

## Privacidad

Sin cuentas y sin analíticas. Nada sale de tu red local. La app no tiene secretos que configurar, así que no hay archivo `.env`.

## Compilar desde el código

Necesitas Windows, Git, Flutter (la versión exacta que fija `apps/nexus_bridges/pubspec.yaml`) y Visual Studio Build Tools 2022 con la carga de trabajo "Desarrollo para el escritorio con C++". Para generar el instalador también hace falta [Inno Setup 6](https://jrsoftware.org/isinfo.php).

```powershell
git clone https://github.com/Davidstron23/nexusBridges.git
cd nexusBridges
powershell -File tool/bootstrap.ps1
```

`bootstrap.ps1` comprueba la versión de Flutter, instala las dependencias y activa los hooks de git. Después:

```powershell
cd apps/nexus_bridges
flutter run -d windows
```

Para ejecutar los tests: `dart test` dentro de `packages/nexus_bridges_core` y `flutter test` dentro de `apps/nexus_bridges`.

Para generar el instalador, ejecuta `powershell -File tool/build-installer.ps1`. Deja `NexusBridges-Setup-<versión>.exe` en `installer/Output/`.

El instalador no está firmado, así que Windows SmartScreen puede mostrar el aviso "Windows protegió su PC" la primera vez. Elige "Más información" y después "Ejecutar de todas formas".

## Inspiración

[LocalSend](https://github.com/localsend/localsend) es una app de código abierto madura que resuelve el mismo problema. NexusBridges es un proyecto aparte, escrito desde cero en Dart, para aprender cómo funciona este tipo de protocolo.

## Licencia

MIT, ver `LICENSE`.
