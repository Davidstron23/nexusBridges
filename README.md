# Nexo

Send files and folders between your own devices on the same Wi-Fi. No cables, no USB sticks, no cloud, no accounts.

> **Status: work in progress.** Nothing is released yet. The first target is Windows; Android and iPhone come later.

## What it is

Nexo is a peer-to-peer file transfer app for a local network. Every device runs the same app, finds the others on the network, and sends files straight to them. There is no central server in the middle.

The idea that drives it: you are working on a project on one computer and you need that folder on another one, including things you would never push to GitHub. You open Nexo, drag the folder in, pick the other device, pick the folder where it should land, and it goes there.

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

Coming with the project skeleton. It will need Flutter (stable channel) and Visual Studio Build Tools with the C++ workload on Windows.

## Inspiration

[LocalSend](https://github.com/localsend/localsend) is a mature open source app that solves the same problem. Nexo is a separate project written from scratch in Dart, built to learn how this kind of protocol works.

## License

MIT, see `LICENSE`.

---

# Nexo (castellano)

Envía archivos y carpetas entre tus propios dispositivos conectados a la misma Wi-Fi. Sin cables, sin pendrives, sin nube y sin cuentas.

> **Estado: en desarrollo.** Todavía no hay ninguna versión publicada. Empieza por Windows; Android e iPhone llegarán después.

## Qué es

Nexo es una app de transferencia de archivos entre dispositivos de una red local, de igual a igual. Todos los dispositivos ejecutan la misma app, se encuentran en la red y se envían los archivos directamente. No hay un servidor central en medio.

La idea que lo mueve: estás trabajando en un proyecto en un ordenador y necesitas esa carpeta en otro, incluso con cosas que nunca subirías a GitHub. Abres Nexo, arrastras la carpeta, eliges el otro dispositivo, eliges la carpeta donde debe quedar y se envía.

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

Llegará con el esqueleto del proyecto. Hará falta Flutter (canal estable) y, en Windows, Visual Studio Build Tools con la carga de trabajo de C++.

## Inspiración

[LocalSend](https://github.com/localsend/localsend) es una app de código abierto madura que resuelve el mismo problema. Nexo es un proyecto aparte, escrito desde cero en Dart, para aprender cómo funciona este tipo de protocolo.

## Licencia

MIT, ver `LICENSE`.
