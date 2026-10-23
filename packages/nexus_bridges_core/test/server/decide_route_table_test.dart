import 'package:nexus_bridges_core/src/protocol/protocol.dart';
import 'package:nexus_bridges_core/src/server/server.dart';
import 'package:test/test.dart';

final String _paired = 'A' * 64;
final String _unpaired = 'B' * 64;

const List<String> _pairPaths = [
  ApiPaths.pairStart,
  ApiPaths.pairReveal,
  ApiPaths.pairWait,
  ApiPaths.pairConfirm,
  ApiPaths.pairCancel,
  ApiPaths.pairStatus,
];

final Map<String, RouteAccess> _table = {
  for (final path in _pairPaths) path: RouteAccess.anonymous,
  ApiPaths.unpair: RouteAccess.paired,
};

const List<String> _otherMethods = [
  'GET',
  'PUT',
  'DELETE',
  'HEAD',
  'PATCH',
  'OPTIONS',
  'post',
  ' POST',
  '',
];

RouteDecision _decide(
  String method,
  String path,
  String? fingerprint, {
  Map<String, RouteAccess>? routes,
}) => decideRoute(
  method: method,
  path: path,
  clientFingerprint: fingerprint,
  isPaired: (fp) => fp == _paired,
  routes: routes ?? _table,
);

List<String> _lookalikesOf(String path) => [
  '$path/',
  '$path ',
  ' $path',
  path.toUpperCase(),
  '${path}x',
  '$path?x=1',
  '$path#x',
  '/$path',
  path.replaceFirst('/pair/', '//pair/'),
  path.replaceFirst('/pair/', '/pair/./'),
  path.replaceFirst('/v1/', '/v2/'),
  path.substring(1),
];

void main() {
  group('C24: pairing routes without a certificate (SEC-03, RF-31)', () {
    test('every pair/ route on POST is route', () {
      for (final path in _pairPaths) {
        expect(_decide('POST', path, null), RouteDecision.route, reason: path);
      }
    });

    test('every pair/ route with another method is methodNotAllowed', () {
      for (final path in _pairPaths) {
        for (final method in _otherMethods) {
          expect(
            _decide(method, path, null),
            RouteDecision.methodNotAllowed,
            reason: '"$method" $path',
          );
        }
      }
    });

    test('isPaired is not asked when there is no certificate', () {
      final asked = <String>[];

      decideRoute(
        method: 'POST',
        path: ApiPaths.pairStart,
        clientFingerprint: null,
        isPaired: (fp) {
          asked.add(fp);
          return true;
        },
        routes: _table,
      );

      expect(asked, isEmpty);
    });

    test('paths that only look like a pair/ route are unauthorized', () {
      for (final path in _pairPaths) {
        for (final lookalike in _lookalikesOf(path)) {
          expect(
            _decide('POST', lookalike, null),
            RouteDecision.unauthorized,
            reason: lookalike,
          );
        }
      }
    });

    test('a pair/ route that is not in the table is unauthorized', () {
      for (final path in _pairPaths) {
        expect(
          _decide('POST', path, null, routes: const {}),
          RouteDecision.unauthorized,
          reason: path,
        );
      }
    });
  });

  group('C24: unpair needs a paired certificate (SEC-03)', () {
    test('without a certificate it is unauthorized with any method', () {
      for (final method in ['POST', ..._otherMethods]) {
        expect(
          _decide(method, ApiPaths.unpair, null),
          RouteDecision.unauthorized,
          reason: '"$method"',
        );
      }
    });

    test('with a paired certificate POST is route', () {
      expect(_decide('POST', ApiPaths.unpair, _paired), RouteDecision.route);
    });

    test('with a paired certificate another method is methodNotAllowed', () {
      for (final method in _otherMethods) {
        expect(
          _decide(method, ApiPaths.unpair, _paired),
          RouteDecision.methodNotAllowed,
          reason: '"$method"',
        );
      }
    });

    test('paths that only look like unpair are notFound for a paired '
        'certificate and unauthorized without one', () {
      for (final lookalike in [
        '${ApiPaths.unpair}/',
        '${ApiPaths.unpair}x',
        ApiPaths.unpair.toUpperCase(),
        '/${ApiPaths.unpair}',
      ]) {
        expect(
          _decide('POST', lookalike, _paired),
          RouteDecision.notFound,
          reason: lookalike,
        );
        expect(
          _decide('POST', lookalike, null),
          RouteDecision.unauthorized,
          reason: lookalike,
        );
      }
    });
  });

  group('C24: a certificate that is not paired (rule 1)', () {
    test('is unauthorized on every route of the table, with any method', () {
      for (final path in [..._pairPaths, ApiPaths.unpair]) {
        for (final method in ['POST', 'GET']) {
          expect(
            _decide(method, path, _unpaired),
            RouteDecision.unauthorized,
            reason: '$method $path',
          );
        }
      }
    });

    test('is unauthorized on register and on an unknown route', () {
      expect(
        _decide('POST', ApiPaths.register, _unpaired),
        RouteDecision.unauthorized,
      );
      expect(
        _decide('POST', '$apiPrefix/files', _unpaired),
        RouteDecision.unauthorized,
      );
    });

    test('asks isPaired once with the exact fingerprint', () {
      final asked = <String>[];

      final decision = decideRoute(
        method: 'POST',
        path: ApiPaths.pairStart,
        clientFingerprint: _unpaired,
        isPaired: (fp) {
          asked.add(fp);
          return false;
        },
        routes: _table,
      );

      expect(decision, RouteDecision.unauthorized);
      expect(asked, [_unpaired]);
    });
  });

  group('C24: a paired certificate', () {
    test('on a pair/ route POST is route and another method '
        'methodNotAllowed', () {
      for (final path in _pairPaths) {
        expect(
          _decide('POST', path, _paired),
          RouteDecision.route,
          reason: path,
        );
        expect(
          _decide('GET', path, _paired),
          RouteDecision.methodNotAllowed,
          reason: path,
        );
      }
    });

    test('on an unknown route is notFound with any method', () {
      for (final path in ['$apiPrefix/files', '$apiPrefix/pair', '/', '']) {
        for (final method in ['POST', 'GET']) {
          expect(
            _decide(method, path, _paired),
            RouteDecision.notFound,
            reason: '$method $path',
          );
        }
      }
    });

    test('an unknown route without a certificate is unauthorized', () {
      expect(
        _decide('POST', '$apiPrefix/files', null),
        RouteDecision.unauthorized,
      );
    });
  });

  group('C24: register keeps its own rule', () {
    test('POST is register with and without a paired certificate, and '
        'another method is methodNotAllowed', () {
      expect(_decide('POST', ApiPaths.register, null), RouteDecision.register);
      expect(
        _decide('POST', ApiPaths.register, _paired),
        RouteDecision.register,
      );
      expect(
        _decide('GET', ApiPaths.register, null),
        RouteDecision.methodNotAllowed,
      );
    });

    test('register is decided before the table, whatever the table says', () {
      for (final access in RouteAccess.values) {
        final routes = {ApiPaths.register: access};
        expect(
          _decide('POST', ApiPaths.register, null, routes: routes),
          RouteDecision.register,
          reason: '$access',
        );
        expect(
          _decide('GET', ApiPaths.register, null, routes: routes),
          RouteDecision.methodNotAllowed,
          reason: '$access',
        );
      }
    });
  });

  group('C24: the rules go in the plan order', () {
    test('an anonymous route of the table is decided before asking for a '
        'certificate (rule 3 before rule 4)', () {
      final routes = {'$apiPrefix/probe': RouteAccess.anonymous};

      expect(
        _decide('POST', '$apiPrefix/probe', null, routes: routes),
        RouteDecision.route,
      );
      expect(
        _decide('GET', '$apiPrefix/probe', null, routes: routes),
        RouteDecision.methodNotAllowed,
      );
    });

    test('a paired route without a certificate is unauthorized, not '
        'methodNotAllowed (rule 4 before rule 5)', () {
      expect(_decide('GET', ApiPaths.unpair, null), RouteDecision.unauthorized);
    });

    test('the default table is empty and keeps the rules of spec 001', () {
      expect(
        decideRoute(
          method: 'POST',
          path: ApiPaths.pairStart,
          clientFingerprint: null,
          isPaired: (_) => true,
        ),
        RouteDecision.unauthorized,
      );
      expect(
        decideRoute(
          method: 'POST',
          path: ApiPaths.unpair,
          clientFingerprint: _paired,
          isPaired: (fp) => fp == _paired,
        ),
        RouteDecision.notFound,
      );
    });
  });
}
