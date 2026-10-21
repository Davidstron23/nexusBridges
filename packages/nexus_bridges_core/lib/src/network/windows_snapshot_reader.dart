import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'network.dart';

const int _errorBufferOverflow = 111;
const int _initialBufferBytes = 32 * 1024;
const int _maxAttempts = 4;
const int _operStatusUp = 1;
const int _sockaddrInBytes = 8;

final class _NetworkRef {
  const _NetworkRef(this.id, this.name);

  final String id;
  final String name;
}

final class WindowsNetworkSnapshotReader implements NetworkSnapshotReader {
  @override
  List<AdapterInfo> read() {
    final comReady = CoInitializeEx(COINIT_MULTITHREADED).isOk;
    try {
      final networks = comReady
          ? _readNetworks()
          : const <String, _NetworkRef>{};
      return _readAdapters(networks);
    } finally {
      if (comReady) CoUninitialize();
    }
  }
}

String _guidText(Pointer<GUID> pointer) {
  try {
    return pointer.ref.toString().toUpperCase();
  } finally {
    free(pointer);
  }
}

Map<String, _NetworkRef> _readNetworks() {
  final result = <String, _NetworkRef>{};
  try {
    using((arena) {
      final manager = createInstance<INetworkListManager>(NetworkListManager);
      try {
        final connections = manager.getNetworkConnections();
        if (connections == null) return;
        try {
          final slot = arena<VTablePointer>();
          final fetched = arena<Uint32>();
          while (true) {
            fetched.value = 0;
            connections.next(1, slot, fetched);
            if (fetched.value == 0) break;
            _collectConnection(INetworkConnection(slot.value), result);
          }
        } finally {
          connections.release();
        }
      } finally {
        manager.release();
      }
    });
  } catch (_) {
    return result;
  }
  return result;
}

void _collectConnection(
  INetworkConnection connection,
  Map<String, _NetworkRef> into,
) {
  try {
    final adapterId = _guidText(connection.getAdapterId());
    final network = connection.getNetwork();
    if (network == null) return;
    try {
      final networkId = _guidText(network.getNetworkId());
      final name = network.getName();
      try {
        into.putIfAbsent(
          adapterId,
          () => _NetworkRef(networkId, name.toDartString()),
        );
      } finally {
        SysFreeString(name);
      }
    } finally {
      network.release();
    }
  } finally {
    connection.release();
  }
}

List<AdapterInfo> _readAdapters(Map<String, _NetworkRef> networks) {
  return using((arena) {
    var size = _initialBufferBytes;
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      final sizePointer = arena<Uint32>()..value = size;
      final buffer = arena<Uint8>(size);
      final code = GetAdaptersAddresses(
        AF_INET,
        GAA_FLAG_INCLUDE_GATEWAYS,
        buffer.cast<IP_ADAPTER_ADDRESSES_LH>(),
        sizePointer,
      );
      if (code == _errorBufferOverflow) {
        size = sizePointer.value;
        continue;
      }
      if (code != 0) return const <AdapterInfo>[];
      return _parseAdapters(buffer.cast<IP_ADAPTER_ADDRESSES_LH>(), networks);
    }
    return const <AdapterInfo>[];
  });
}

List<AdapterInfo> _parseAdapters(
  Pointer<IP_ADAPTER_ADDRESSES_LH> first,
  Map<String, _NetworkRef> networks,
) {
  final adapters = <AdapterInfo>[];
  var current = first;
  while (current != nullptr) {
    final entry = current.ref;
    final id = entry.AdapterName.toDartString().toUpperCase();
    final network = networks[id];
    adapters.add(
      AdapterInfo(
        id: id,
        friendlyName: entry.FriendlyName.toDartString(),
        description: entry.Description.toDartString(),
        ifType: entry.IfType,
        isUp: entry.OperStatus == _operStatusUp,
        ipv4: _parseSubnets(entry.FirstUnicastAddress),
        hasGateway: entry.FirstGatewayAddress != nullptr,
        networkId: network?.id,
        networkName: network?.name,
      ),
    );
    current = entry.Next;
  }
  return adapters;
}

List<Ipv4Subnet> _parseSubnets(Pointer<IP_ADAPTER_UNICAST_ADDRESS_LH> first) {
  final subnets = <Ipv4Subnet>[];
  var current = first;
  while (current != nullptr) {
    final entry = current.ref;
    final sockaddr = entry.Address.lpSockaddr;
    if (sockaddr != nullptr &&
        entry.Address.iSockaddrLength >= _sockaddrInBytes) {
      final bytes = sockaddr.cast<Uint8>().asTypedList(_sockaddrInBytes);
      subnets.add(
        Ipv4Subnet(
          InternetAddress.fromRawAddress(
            Uint8List.fromList(bytes.sublist(4, 8)),
            type: InternetAddressType.IPv4,
          ),
          entry.OnLinkPrefixLength,
        ),
      );
    }
    current = entry.Next;
  }
  return subnets;
}
