import 'dart:async';
import 'dart:io';

import '../identity/identity.dart';
import '../network/network.dart';
import '../pairing/pairing.dart';
import '../protocol/protocol.dart';
import 'multicast.dart';
import 'registry.dart';
import 'scanner.dart';
import 'verification_gate.dart';
import 'verifier.dart';

void _noLog(String message) {}

final Duration _replyInterval = Limits.announceInterval ~/ 2;

typedef _Signature = List<(String, String, String?, bool)>;

final class DiscoveryService {
  DiscoveryService({
    required this._identity,
    required this._selfInfo,
    required this._paired,
    required this._channel,
    required this._verifier,
    required this._scanner,
    this._now = DateTime.now,
    this._monotonic = monotonicClock,
    this._announceInterval = Limits.announceInterval,
    this._presentInterval = Limits.announceInterval,
    this._expireInterval = const Duration(seconds: 1),
    this._log = _noLog,
  });

  final DeviceIdentity _identity;
  final DeviceInfo Function() _selfInfo;
  final PairedDevicesStore _paired;
  final MulticastChannel _channel;
  final DeviceVerifier _verifier;
  final SubnetScanner _scanner;
  final DateTime Function() _now;
  final Duration Function() _monotonic;
  final Duration _announceInterval;
  final Duration _presentInterval;
  final Duration _expireInterval;
  final void Function(String) _log;

  late final DiscoveryRegistry _registry = DiscoveryRegistry(
    selfFingerprint: _identity.fingerprint,
    isPaired: _paired.isPaired,
    now: _now,
    clock: _monotonic,
  );
  late final VerificationGate _gate = VerificationGate(now: _now);

  final AbortSignal _globalAbort = AbortSignal();
  final Map<String, ActiveInterface> _active = {};
  final Map<String, AbortSignal> _aborts = {};
  final Map<String, DateTime> _lastReplies = {};
  final Map<String, DateTime> _goodbyeChecks = {};
  final Set<String> _presenting = {};
  final StreamController<List<DiscoveredDevice>> _controller =
      StreamController<List<DiscoveredDevice>>.broadcast();

  StreamSubscription<(Announcement, InternetAddress, ActiveInterface)>?
  _incomingSubscription;
  StreamSubscription<void>? _pairedSubscription;
  Timer? _announceTimer;
  Timer? _presentTimer;
  Timer? _expireTimer;
  Future<void>? _stopping;
  bool _started = false;
  bool _stopped = false;
  _Signature _lastSignature = [];

  Stream<List<DiscoveredDevice>> get devices => _controller.stream;

  List<DiscoveredDevice> get current => _registry.devices;

  Future<void> start() async {
    if (_stopped || _started) return;
    _started = true;
    _incomingSubscription = _channel.incoming.listen(
      _onIncoming,
      onError: (Object e) => _log('incoming failed: ${e.runtimeType}'),
    );
    _announceTimer = Timer.periodic(_announceInterval, (_) => announceNow());
    _presentTimer = Timer.periodic(
      _presentInterval,
      (_) => _presentToScanned(),
    );
    _expireTimer = Timer.periodic(_expireInterval, (_) => _expire());
    _pairedSubscription = _paired.changes.listen(
      (_) => _emitIfChanged(),
      onError: (Object e) => _log('paired changes failed: ${e.runtimeType}'),
    );
  }

  Future<void> syncInterfaces(List<ActiveInterface> active) async {
    if (_stopped) return;
    final wanted = {for (final iface in active) iface.id: iface};
    for (final id in _active.keys.toList()) {
      if (wanted.containsKey(id)) continue;
      _active.remove(id);
      _gate.dropInterface(id);
      _aborts.remove(id)?.abort();
      _registry.dropInterface(id);
    }
    _emitIfChanged();
    for (final iface in wanted.values) {
      final current = _active[iface.id];
      if (current != null) {
        if (current.subnet != iface.subnet ||
            current.friendlyName != iface.friendlyName) {
          _active[iface.id] = iface;
        }
        continue;
      }
      _active[iface.id] = iface;
      _aborts[iface.id] = AbortSignal();
      _send(AnnouncementKind.hello, iface);
    }
  }

  void announceNow() {
    if (_stopped) return;
    for (final iface in _active.values.toList()) {
      _send(AnnouncementKind.hello, iface);
    }
  }

  void handleRegistration(
    DeviceInfo caller,
    InternetAddress from,
    ActiveInterface via,
  ) {
    if (_stopped || caller.fingerprint == _identity.fingerprint) return;
    _process(
      Announcement(AnnouncementKind.hello, caller),
      from,
      via,
      reverse: true,
    );
  }

  Future<void> rescan() async {
    if (_stopped || _active.isEmpty) return;
    final targets = _active.values.toList();
    final signals = {for (final iface in targets) iface.id: _aborts[iface.id]!};
    final scanAbort = AbortSignal();
    final removers = [
      _globalAbort.onAbort(scanAbort.abort),
      for (final signal in signals.values) signal.onAbort(scanAbort.abort),
    ];
    try {
      await for (final (info, address, iface) in _scanner.scan(
        active: targets,
        self: _selfInfo(),
        abort: scanAbort,
      )) {
        final signal = signals[iface.id];
        if (_stopped || signal == null || signal.aborted) continue;
        final changed = _registry.onVerified(
          info,
          address,
          iface.id,
          fromScan: true,
        );
        _gate.clearFailures(info.fingerprint);
        if (changed) _emitIfChanged();
      }
    } catch (e) {
      _log('rescan failed: ${e.runtimeType}');
    } finally {
      for (final remove in removers) {
        remove();
      }
    }
  }

  Future<void> stop({required bool sayGoodbye}) {
    return _stopping ??= _stop(sayGoodbye);
  }

  Future<void> _stop(bool sayGoodbye) async {
    _stopped = true;
    _globalAbort.abort();
    for (final signal in _aborts.values.toList()) {
      signal.abort();
    }
    _gate.clear();
    _lastReplies.clear();
    _goodbyeChecks.clear();
    _announceTimer?.cancel();
    _presentTimer?.cancel();
    _expireTimer?.cancel();
    _announceTimer = null;
    _presentTimer = null;
    _expireTimer = null;
    final incoming = _incomingSubscription;
    final paired = _pairedSubscription;
    _incomingSubscription = null;
    _pairedSubscription = null;
    await incoming?.cancel();
    await paired?.cancel();
    if (sayGoodbye) {
      for (final iface in _active.values.toList()) {
        _send(AnnouncementKind.bye, iface);
      }
    }
    _active.clear();
    _aborts.clear();
    if (!_controller.isClosed) await _controller.close();
  }

  void _onIncoming((Announcement, InternetAddress, ActiveInterface) event) {
    final (announcement, from, via) = event;
    _process(announcement, from, via, reverse: false);
  }

  void _process(
    Announcement announcement,
    InternetAddress from,
    ActiveInterface via, {
    required bool reverse,
  }) {
    if (_stopped || !_active.containsKey(via.id)) return;
    try {
      switch (_registry.onAnnouncement(announcement, from, via.id)) {
        case Ignore():
          return;
        case Refreshed():
          _emitIfChanged();
          if (!reverse && announcement.kind == AnnouncementKind.hello) {
            _replyTo(announcement.info.fingerprint, from, via.id);
          }
        case Verify(:final info, :final address, :final interfaceId):
          _submit(info, address, interfaceId, reverse: reverse);
        case VerifyGoodbye(:final info, :final address, :final interfaceId):
          _submitGoodbye(info, address, interfaceId);
      }
    } catch (e) {
      _log('announcement failed: ${e.runtimeType}');
    }
  }

  void _submit(
    DeviceInfo info,
    InternetAddress address,
    String interfaceId, {
    required bool reverse,
  }) {
    final abort = _aborts[interfaceId];
    if (abort == null) return;
    final port = _paired.isPaired(info.fingerprint) ? info.port : null;
    _gate.submit(
      fingerprint: info.fingerprint,
      ip: address.address,
      interfaceId: interfaceId,
      reverse: reverse,
      port: port,
      job: () => _verify(info, address, interfaceId, abort, reverse, port),
    );
  }

  void _submitGoodbye(
    DeviceInfo info,
    InternetAddress address,
    String interfaceId,
  ) {
    final abort = _aborts[interfaceId];
    if (abort == null) return;
    final fingerprint = info.fingerprint;
    final now = _now();
    final last = _goodbyeChecks[fingerprint];
    if (last != null && !_goodbyeExpired(now, last)) return;
    _goodbyeChecks[fingerprint] = now;
    _gate.submit(
      fingerprint: fingerprint,
      ip: address.address,
      interfaceId: interfaceId,
      port: info.port,
      job: () => _verifyGoodbye(info, address, interfaceId, abort),
    );
  }

  Future<void> _verifyGoodbye(
    DeviceInfo info,
    InternetAddress address,
    String interfaceId,
    AbortSignal abort,
  ) async {
    DeviceInfo? verified;
    try {
      verified = await _verifier.register(
        address: address,
        port: info.port,
        expectedFingerprint: info.fingerprint,
        self: _selfInfo(),
        abort: abort,
      );
    } catch (e) {
      _log('goodbye verification failed: ${e.runtimeType}');
    }
    if (_stopped || abort.aborted) return;
    if (verified != null &&
        verified.fingerprint == info.fingerprint &&
        _active.containsKey(interfaceId)) {
      final changed = _registry.onVerified(verified, address, interfaceId);
      _gate.clearFailures(info.fingerprint);
      if (changed) _emitIfChanged();
      return;
    }
    if (_registry.onGoodbyeFailed(info.fingerprint, address)) {
      _emitIfChanged();
    }
  }

  Future<void> _verify(
    DeviceInfo info,
    InternetAddress address,
    String interfaceId,
    AbortSignal abort,
    bool reverse,
    int? port,
  ) async {
    DeviceInfo? verified;
    try {
      verified = await _verifier.register(
        address: address,
        port: info.port,
        expectedFingerprint: info.fingerprint,
        self: _selfInfo(),
        abort: abort,
      );
    } catch (e) {
      _log('verification failed: ${e.runtimeType}');
    }
    if (_stopped || abort.aborted) return;
    if (verified != null &&
        verified.fingerprint == info.fingerprint &&
        _active.containsKey(interfaceId)) {
      final changed = _registry.onVerified(verified, address, interfaceId);
      _gate.clearFailures(info.fingerprint);
      if (changed) _emitIfChanged();
      return;
    }
    _gate.markFailed(
      info.fingerprint,
      address.address,
      reverse: reverse,
      port: port,
    );
  }

  void _presentToScanned() {
    if (_stopped) return;
    try {
      for (final device in _registry.dueForPresentation(_announceInterval)) {
        final fingerprint = device.info.fingerprint;
        final abort = _aborts[device.interfaceId];
        if (_presenting.contains(fingerprint) ||
            abort == null ||
            !_active.containsKey(device.interfaceId)) {
          continue;
        }
        _presenting.add(fingerprint);
        unawaited(_present(device, abort));
      }
    } catch (e) {
      _log('presentation failed: ${e.runtimeType}');
    }
  }

  Future<void> _present(DiscoveredDevice device, AbortSignal abort) async {
    final fingerprint = device.info.fingerprint;
    try {
      final verified = await _verifier.register(
        address: device.address,
        port: device.info.port,
        expectedFingerprint: fingerprint,
        self: _selfInfo(),
        abort: abort,
      );
      if (_stopped || abort.aborted) return;
      if (verified != null &&
          verified.fingerprint == fingerprint &&
          _active.containsKey(device.interfaceId)) {
        final changed = _registry.onVerified(
          verified,
          device.address,
          device.interfaceId,
          fromScan: true,
        );
        _gate.clearFailures(fingerprint);
        if (changed) _emitIfChanged();
      }
    } catch (e) {
      _log('presentation failed: ${e.runtimeType}');
    } finally {
      _presenting.remove(fingerprint);
    }
  }

  void _send(AnnouncementKind kind, ActiveInterface iface) {
    try {
      _channel.send(Announcement(kind, _selfInfo()), iface);
    } catch (e) {
      _log('announce failed: ${e.runtimeType}');
    }
  }

  void _replyTo(String fingerprint, InternetAddress to, String interfaceId) {
    final iface = _active[interfaceId];
    if (_stopped || iface == null) return;
    final now = _now();
    final last = _lastReplies[fingerprint];
    if (last != null && !_replyExpired(now, last)) return;
    _lastReplies[fingerprint] = now;
    try {
      _channel.sendTo(
        Announcement(AnnouncementKind.hello, _selfInfo()),
        iface,
        to,
      );
    } catch (e) {
      _log('reply failed: ${e.runtimeType}');
    }
  }

  static bool _replyExpired(DateTime now, DateTime last) {
    final age = now.difference(last);
    return age.isNegative || age >= _replyInterval;
  }

  static bool _goodbyeExpired(DateTime now, DateTime last) {
    final age = now.difference(last);
    return age.isNegative || age >= Limits.goodbyeCheckInterval;
  }

  void _expire() {
    if (_stopped) return;
    final now = _now();
    _lastReplies.removeWhere((_, last) => _replyExpired(now, last));
    _goodbyeChecks.removeWhere((_, last) => _goodbyeExpired(now, last));
    try {
      if (_registry.expire().isNotEmpty) _emitIfChanged();
    } catch (e) {
      _log('expire failed: ${e.runtimeType}');
    }
  }

  void _emitIfChanged() {
    if (_stopped || _controller.isClosed) return;
    final devices = _registry.devices;
    final signature = [
      for (final device in devices)
        (
          device.info.fingerprint,
          device.address.address,
          device.info.name,
          device.paired,
        ),
    ];
    if (_sameSignature(signature, _lastSignature)) return;
    _lastSignature = signature;
    _controller.add(List.unmodifiable(devices));
  }

  static bool _sameSignature(_Signature a, _Signature b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
