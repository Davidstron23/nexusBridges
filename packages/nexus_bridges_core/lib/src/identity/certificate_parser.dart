import 'dart:convert';
import 'dart:typed_data';

import 'der.dart';

const int _tagInteger = 0x02;
const int _tagBitString = 0x03;
const int _tagOid = 0x06;
const int _tagUtf8String = 0x0C;
const int _tagPrintableString = 0x13;
const int _tagSequence = 0x30;
const int _tagSet = 0x31;
const int _tagVersion = 0xA0;
const int _tagExtensions = 0xA3;

const List<int> _oidCommonName = [0x55, 0x04, 0x03];
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

const int _publicKeyBitStringLength = 66;

final RegExp commonNamePattern = RegExp(r'^NexusBridges-[0-9a-f]{16}$');

FormatException _invalid() => const FormatException('invalid DER');

final class ParsedCertificate {
  const ParsedCertificate({required this.spki, required this.commonName});

  final Uint8List spki;

  final String commonName;
}

ParsedCertificate parseCertificate(Uint8List der) {
  try {
    return _parse(der);
  } on FormatException {
    rethrow;
  } catch (_) {
    throw _invalid();
  }
}

ParsedCertificate _parse(Uint8List der) {
  final root = readDerElement(der, 0, der.length);
  if (root.tag != _tagSequence || root.end != der.length) throw _invalid();
  final parts = readDerChildren(der, root);
  if (parts.length != 3 ||
      parts[0].tag != _tagSequence ||
      parts[1].tag != _tagSequence ||
      parts[2].tag != _tagBitString) {
    throw _invalid();
  }

  final tbs = readDerChildren(der, parts[0]);
  var index = 0;
  if (index < tbs.length && tbs[index].tag == _tagVersion) index++;
  const expected = [
    _tagInteger,
    _tagSequence,
    _tagSequence,
    _tagSequence,
    _tagSequence,
    _tagSequence,
  ];
  if (tbs.length < index + expected.length) throw _invalid();
  for (var i = 0; i < expected.length; i++) {
    if (tbs[index + i].tag != expected[i]) throw _invalid();
  }
  final issuer = tbs[index + 2];
  final subject = tbs[index + 4];
  final spki = tbs[index + 5];
  index += expected.length;
  if (index < tbs.length && tbs[index].tag == _tagExtensions) index++;
  if (index != tbs.length) throw _invalid();

  final subjectBytes = derBytes(der, subject);
  final issuerBytes = derBytes(der, issuer);
  if (!_sameBytes(subjectBytes, issuerBytes)) throw _invalid();

  return ParsedCertificate(
    spki: _checkedSpki(der, spki),
    commonName: _commonNameOf(der, subject),
  );
}

String _commonNameOf(Uint8List der, DerElement subject) {
  final sets = readDerChildren(der, subject);
  if (sets.length != 1 || sets[0].tag != _tagSet) throw _invalid();
  final attributes = readDerChildren(der, sets[0]);
  if (attributes.length != 1 || attributes[0].tag != _tagSequence) {
    throw _invalid();
  }
  final pair = readDerChildren(der, attributes[0]);
  if (pair.length != 2 ||
      pair[0].tag != _tagOid ||
      !_sameBytes(derValue(der, pair[0]), _oidCommonName)) {
    throw _invalid();
  }
  final raw = derValue(der, pair[1]);
  final String name;
  if (pair[1].tag == _tagUtf8String) {
    name = utf8.decode(raw);
  } else if (pair[1].tag == _tagPrintableString) {
    if (raw.any((b) => b > 0x7F)) throw _invalid();
    name = ascii.decode(raw);
  } else {
    throw _invalid();
  }
  if (!commonNamePattern.hasMatch(name)) throw _invalid();
  return name;
}

Uint8List _checkedSpki(Uint8List der, DerElement spki) {
  final parts = readDerChildren(der, spki);
  if (parts.length != 2 ||
      parts[0].tag != _tagSequence ||
      parts[1].tag != _tagBitString) {
    throw _invalid();
  }
  final algorithm = readDerChildren(der, parts[0]);
  if (algorithm.length != 2 ||
      algorithm[0].tag != _tagOid ||
      algorithm[1].tag != _tagOid ||
      !_sameBytes(derValue(der, algorithm[0]), _oidEcPublicKey) ||
      !_sameBytes(derValue(der, algorithm[1]), _oidPrime256v1)) {
    throw _invalid();
  }
  final key = derValue(der, parts[1]);
  if (key.length != _publicKeyBitStringLength ||
      key[0] != 0x00 ||
      key[1] != 0x04) {
    throw _invalid();
  }
  return derBytes(der, spki);
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
