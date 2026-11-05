# Changelog

All notable changes to NexusBridges are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.3] - 2026-11-05

### Added
- Choose the destination folder on the other device: a menu on your own devices with its favourites, recent folders and the folders it shares with you.
- Drag and drop into a specific folder: hold over a device and its folders open, so you can drop where you want.
- Configure panel for each device: a local nickname, the folders it can use, favourites and history. The nickname stays on your computer.

## [0.1.2] - 2026-11-05

### Added
- System tray: closing the window keeps the app running, so your devices can still send you files. Open it from the tray icon, and use Exit in its menu to close it for good. You can turn this off in Settings.
- When something arrives with the window hidden, the app comes back to the front. Nothing is answered by accident: a keypress in another program does not accept anything.
- The installer is available in English and Spanish, and explains what to do if the app is running in the tray.

## [0.1.1] - 2026-11-04

### Added
- Send whole folders and several files at once, with a SHA-256 check of every file.
- Drag and drop from the Explorer onto a device, or onto the "To send" tray to prepare a send.
- Send queues, with one continuous progress for everything you sent together.
- Settings screen: device name, theme (dark, light or Windows), language, receive folder, excluded folders, trusted networks and ignored devices.
- Time left during a transfer: "Arrives in 3 min" appears after 5 seconds.

### Changed
- The progress bar of a transfer is thicker and sits at the bottom of the card, with Cancel above it.

## [0.1.0] - 2026-10-30

First public release, for Windows.

### Added
- Automatic discovery of other NexusBridges devices on the local network, plus a manual search.
- Trusted networks: the app only works on the networks you approve.
- One-time pairing between two devices with a 6-digit code compared on both screens, with "mine" and "someone else's" devices.
- Send a single file to a paired device, with progress, a SHA-256 check and the "comes from another computer" mark of Windows on every received file.
- Files from your own devices arrive without asking; files from someone else's device need your confirmation.
- The first time something arrives, the app asks where to save it (`Downloads\NexusBridges` by default).
- "Show in folder" for the last received file. Nothing received is ever opened or run automatically, and nothing is overwritten.
- Dark interface with an animated network diagram, English and Spanish.
- Windows installer with firewall rules limited to the local subnet.

[Unreleased]: https://github.com/Davidstron23/nexusBridges/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/Davidstron23/nexusBridges/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/Davidstron23/nexusBridges/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/Davidstron23/nexusBridges/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Davidstron23/nexusBridges/releases/tag/v0.1.0
