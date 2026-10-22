import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:test/test.dart';

final String _paired = 'A' * 64;
final String _unpaired = 'B' * 64;
const String _register = '$apiPrefix/register';

RouteDecision _decide(String method, String path, String? fingerprint) =>
    decideRoute(
      method: method,
      path: path,
      clientFingerprint: fingerprint,
      isPaired: (fp) => fp == _paired,
    );

const List<String> _lookalikePaths = [
  '$apiPrefix/REGISTER',
  '/API/NEXUSBRIDGES/V1/register',
  '$apiPrefix/register/',
  '$apiPrefix/register?x=1',
  '$apiPrefix/register#x',
  '$apiPrefix/../v1/register',
  '$apiPrefix/./register',
  '$apiPrefix//register',
  '/$apiPrefix/register',
  '$apiPrefix/registerx',
  '$apiPrefix/register%20',
  '$apiPrefix/register ',
  ' $apiPrefix/register',
  '/api/nexusbridges/v2/register',
  '/api/nexusbridges/register',
  '/register',
  'register',
  '$apiPrefix/register/../register',
];

void main() {
  group('rule 1: a fingerprint that is not paired (RF-33, RF-29)', () {
    test('is unauthorized on POST /register', () {
      expect(_decide('POST', _register, _unpaired), RouteDecision.unauthorized);
    });

    test('is unauthorized on /register with another method', () {
      for (final method in ['GET', 'PUT', 'DELETE', 'HEAD']) {
        expect(
          _decide(method, _register, _unpaired),
          RouteDecision.unauthorized,
          reason: method,
        );
      }
    });

    test('is unauthorized on any other route', () {
      for (final path in ['/', apiPrefix, '$apiPrefix/devices', '/x']) {
        expect(
          _decide('GET', path, _unpaired),
          RouteDecision.unauthorized,
          reason: path,
        );
      }
    });

    test('asks isPaired with the exact client fingerprint', () {
      final asked = <String>[];

      decideRoute(
        method: 'POST',
        path: _register,
        clientFingerprint: _unpaired,
        isPaired: (fp) {
          asked.add(fp);
          return false;
        },
      );

      expect(asked, [_unpaired]);
    });
  });

  group('rule 2: /register', () {
    test('POST without fingerprint is register', () {
      expect(_decide('POST', _register, null), RouteDecision.register);
    });

    test('POST with a paired fingerprint is register', () {
      expect(_decide('POST', _register, _paired), RouteDecision.register);
    });

    test('another method without fingerprint is methodNotAllowed', () {
      for (final method in [
        'GET',
        'PUT',
        'DELETE',
        'HEAD',
        'PATCH',
        'OPTIONS',
      ]) {
        expect(
          _decide(method, _register, null),
          RouteDecision.methodNotAllowed,
          reason: method,
        );
      }
    });

    test('another method with a paired fingerprint is methodNotAllowed', () {
      expect(
        _decide('GET', _register, _paired),
        RouteDecision.methodNotAllowed,
      );
    });

    test('a lowercase or padded method is not POST', () {
      for (final method in ['post', 'Post', ' POST', 'POST ', '']) {
        expect(
          _decide(method, _register, null),
          RouteDecision.methodNotAllowed,
          reason: '"$method"',
        );
      }
    });
  });

  group('rule 3: no fingerprint on another route (RF-31)', () {
    test('is unauthorized', () {
      for (final path in [
        '/',
        '',
        apiPrefix,
        '$apiPrefix/',
        '$apiPrefix/devices',
        '$apiPrefix/files/C:/Users',
      ]) {
        for (final method in ['GET', 'POST', 'PUT', 'DELETE']) {
          expect(
            _decide(method, path, null),
            RouteDecision.unauthorized,
            reason: '$method $path',
          );
        }
      }
    });

    test('is unauthorized on paths that only look like /register', () {
      for (final path in _lookalikePaths) {
        expect(
          _decide('POST', path, null),
          RouteDecision.unauthorized,
          reason: path,
        );
      }
    });
  });

  group('rule 4: a paired fingerprint on another route', () {
    test('is notFound', () {
      for (final path in ['/', apiPrefix, '$apiPrefix/devices', '/x']) {
        for (final method in ['GET', 'POST']) {
          expect(
            _decide(method, path, _paired),
            RouteDecision.notFound,
            reason: '$method $path',
          );
        }
      }
    });

    test('is notFound on paths that only look like /register', () {
      for (final path in _lookalikePaths) {
        expect(
          _decide('POST', path, _paired),
          RouteDecision.notFound,
          reason: path,
        );
      }
    });
  });

  test('the path must match /register exactly, not by prefix', () {
    expect(_register, '/api/nexusbridges/v1/register');
    expect(_decide('POST', '$_register/', null), isNot(RouteDecision.register));
    expect(
      _decide('POST', '${_register}s', null),
      isNot(RouteDecision.register),
    );
  });
}
