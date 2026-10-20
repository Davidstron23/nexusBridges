import 'package:nexus_bridges_core/nexus_bridges_core.dart';
import 'package:test/test.dart';

void main() {
  test('protocol version has the major.minor format', () {
    expect(protocolVersion, matches(RegExp(r'^\d+\.\d+$')));
  });
}
