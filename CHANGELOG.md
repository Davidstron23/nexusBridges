# Changelog

All notable changes to NexusBridges are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### In progress
- Send whole folders, several files at once and drag and drop from the Explorer, with send queues and a "To send" tray.
- Choose the destination folder on the other device, with per-device shared folders.
- Settings screen and system tray.

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

[Unreleased]: https://github.com/Davidstron23/nexusBridges/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Davidstron23/nexusBridges/releases/tag/v0.1.0
