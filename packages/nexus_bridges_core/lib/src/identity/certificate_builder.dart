import 'dart:convert';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';

import 'der.dart';

const String pemBegin = '-----BEGIN CERTIFICATE-----';
const String pemEnd = '-----END CERTIFICATE-----';

const List<int> _oidCommonName = [0x55, 0x04, 0x03];
const List<int> _oidEcdsaWithSha256 = [
  0x2A,
  0x86,
  0x48,
  0xCE,
  0x3D,
  0x04,
  0x03,
  0x02,
];
const List<int> _oidEcPublicKey = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01];
const List<int> _oidPrime256v1 = [
  0x2A,
  0x86,
  0x48,
  0xCE,
  0x3D,
  0x03,
  0x01,
  0x07,
];

const String _notBefore = '000101000000Z';
const String _notAfter = '99991231235959Z';

String normalizedPemOf(List<int> der) {
  final body = base64.encode(der);
  final lines = StringBuffer('$pemBegin\n');
  for (var i = 0; i < body.length; i += 64) {
    final stop = i + 64 > body.length ? body.length : i + 64;
    lines.write('${body.substring(i, stop)}\n');
  }
  lines.write('$pemEnd\n');
  return lines.toString();
}

String buildSelfSignedCertificatePem({
  required ECPrivateKey privateKey,
  required ECPublicKey publicKey,
  required String commonName,
  required Uint8List serialNumber,
  bool utf8CommonName = false,
}) {
  try {
    final name = derSequence([
      derSet([
        derSequence([
          derOid(_oidCommonName),
          utf8CommonName ? derUtf8(commonName) : derPrintable(commonName),
        ]),
      ]),
    ]);
    final signatureAlgorithm = derSequence([derOid(_oidEcdsaWithSha256)]);
    final point = publicKey.Q!.getEncoded(false);
    final spki = derSequence([
      derSequence([derOid(_oidEcPublicKey), derOid(_oidPrime256v1)]),
      derBitString(point),
    ]);
    final tbs = derSequence([
      derExplicit(0, derInteger(Uint8List.fromList([2]))),
      derInteger(serialNumber),
      signatureAlgorithm,
      name,
      derSequence([derUtcTime(_notBefore), derGeneralizedTime(_notAfter)]),
      name,
      spki,
    ]);
    final signature = CryptoUtils.ecSign(
      privateKey,
      tbs,
      algorithmName: 'SHA-256/ECDSA',
    );
    final certificate = derSequence([
      tbs,
      signatureAlgorithm,
      derBitString(
        derSequence([
          derIntegerFromBigInt(signature.r),
          derIntegerFromBigInt(signature.s),
        ]),
      ),
    ]);
    return normalizedPemOf(certificate);
  } catch (_) {
    throw StateError('certificate build failed');
  }
}
