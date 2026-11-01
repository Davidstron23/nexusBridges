# Security policy

NexusBridges moves files between your own devices, so security issues matter a lot. Thank you for taking the time to report one.

## Supported versions

Only the latest release gets security fixes.

| Version | Supported |
|---------|-----------|
| 0.1.x   | Yes       |

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Report it privately through GitHub: go to the **Security** tab of this repository and choose **Report a vulnerability**. Include:

- what an attacker can do and under which conditions (same network, paired or not, etc.);
- the steps to reproduce it;
- the version of NexusBridges and of Windows.

You should get an answer within a week. Once the problem is confirmed, the fix ships in a new release and the advisory is published, crediting you if you want.

## Security model in short

- Every device has its own certificate. Devices only talk to each other after a one-time pairing with a 6-digit code confirmed on both screens.
- All traffic uses TLS with mutual authentication and pinned fingerprints. Unpaired fingerprints are rejected before reaching the API.
- Received files are written to a hidden temporary folder, checked with SHA-256 and only then moved to their destination. Nothing received is opened or run automatically, and nothing is overwritten.
- The app only listens on networks you approved, and only accepts connections from the local subnet.

Out of scope: attacks that need code already running on your computer, or another Windows account with write access to your receive folder.
