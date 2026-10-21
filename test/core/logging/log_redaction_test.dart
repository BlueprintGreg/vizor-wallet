import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/app.dart' show log;
import 'package:zcash_wallet/src/core/logging/log_redaction.dart';

/// Shared with `rust/src/log_redaction.rs`, which runs the same cases.
List<({String name, String input, String expected})> _sharedCases() {
  final json =
      jsonDecode(
            File('test/fixtures/log_redaction_vectors.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  return [
    for (final entry
        in (json['cases'] as List<dynamic>).cast<Map<String, dynamic>>())
      (
        name: entry['name'] as String,
        input: entry['input'] as String,
        expected: entry['expected'] as String,
      ),
  ];
}

const _txid =
    '9f1c2b3a4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8';
const _path =
    '/Users/alice/Library/Containers/com.keplr.vizor/Data/Library/'
    'Application Support/com.keplr.vizor/zcash_wallet_main.db';

void main() {
  final cases = _sharedCases();

  test('the shared vectors cover every token', () {
    final expected = cases.map((c) => c.expected).join(' ');
    for (final token in [
      '<address>',
      '<key>',
      '<txid>',
      '<hex>',
      '<uuid>',
      '<path>',
      '<payment-uri>',
      '<ur>',
    ]) {
      expect(expected, contains(token));
    }
  });

  for (final c in cases) {
    test('redacts: ${c.name}', () {
      expect(redactLogText(c.input), c.expected);
    });
  }

  test('redaction is idempotent', () {
    for (final c in cases) {
      final once = redactLogText(c.input);
      expect(redactLogText(once), once, reason: c.name);
      expect(redactLogText(c.expected), c.expected, reason: c.name);
    }
  });

  group('sinks', () {
    late List<String?> printed;
    late DebugPrintCallback previous;
    late bool Function(Object, StackTrace)? previousOnError;

    setUp(() {
      printed = [];
      previous = debugPrint;
      previousOnError = PlatformDispatcher.instance.onError;
      debugPrint = (String? message, {int? wrapWidth}) => printed.add(message);
    });
    tearDown(() {
      debugPrint = previous;
      PlatformDispatcher.instance.onError = previousOnError;
    });

    test('log() redacts before it prints', () {
      log('sync: tx $_txid stored in $_path at height 3201456');

      expect(printed, [
        '[zcash] sync: tx <txid> stored in <path> at height 3201456',
      ]);
    });

    test('log() redacts through the installed output', () {
      installLogRedaction();

      log('sync: tx $_txid stored in $_path at height 3201456');

      expect(printed, [
        '[zcash] sync: tx <txid> stored in <path> at height 3201456',
      ]);
    });

    test(
      'deduplication preserves cascading matches across both pass budgets',
      () {
        // Each preceding address masks the next address's left boundary until
        // the following pass. The old caller + wrapper had eight passes total.
        final address = 't1${List.filled(33, 'Z').join()}';
        final adjacent = List.filled(6, address).join();
        final masked = List.filled(6, '<address>').join();
        installLogRedaction();

        log('receivers=$adjacent');
        reportUncaughtError(
          StateError('receivers=$adjacent'),
          StackTrace.empty,
        );

        expect(printed.first, '[zcash] receivers=$masked');
        expect(printed.last, contains('receivers=$masked'));
        expect(printed.join(), isNot(contains(address)));
      },
    );

    test(
      'a replacement output receives redacted logs without reinstalling',
      () {
        installLogRedaction();
        final replacement = <String?>[];
        debugPrint = (message, {wrapWidth}) => replacement.add(message);

        log('tx $_txid');

        expect(printed, isEmpty);
        expect(replacement, ['[zcash] tx <txid>']);

        installLogRedaction();
        debugPrint('direct tx $_txid');
        log('after reinstall: $_path');
        expect(printed, isEmpty);
        expect(replacement, [
          '[zcash] tx <txid>',
          'direct tx <txid>',
          '[zcash] after reinstall: <path>',
        ]);
      },
    );

    test('repeated installation keeps a single wrapper', () {
      installLogRedaction();
      final installed = debugPrint;

      installLogRedaction();

      expect(debugPrint, same(installed));
      expect(redactingDebugPrint(installed), same(installed));
      debugPrint('tx $_txid');
      expect(printed, ['tx <txid>']);
    });

    test('an opaque forwarding output still runs and retains redaction', () {
      installLogRedaction();
      final installed = debugPrint;
      final forwarded = <String?>[];
      debugPrint = (message, {wrapWidth}) {
        forwarded.add(message);
        installed('$message nested=$_txid', wrapWidth: wrapWidth);
      };

      log('outer=$_path');

      expect(forwarded, ['[zcash] outer=<path>']);
      expect(printed, ['[zcash] outer=<path> nested=<txid>']);
    });

    test('redacted-looking tokens do not exempt the rest of a message', () {
      installLogRedaction();

      log('<txid> raw=$_txid');
      debugPrint('<path> raw=$_path');

      expect(printed, ['[zcash] <txid> raw=<txid>', '<path> raw=<path>']);
    });

    test('null, multiline text and wrapWidth reach the current output', () {
      final widths = <int?>[];
      debugPrint = (message, {wrapWidth}) {
        printed.add(message);
        widths.add(wrapWidth);
      };
      installLogRedaction();

      printRedactedLog('tx $_txid\npath $_path', wrapWidth: 42);
      printRedactedLog(null, wrapWidth: 17);
      debugPrint(null, wrapWidth: 23);

      expect(printed, ['tx <txid>\npath <path>', null, null]);
      expect(widths, [42, 17, 23]);
    });

    test('logs emitted by the output are independently redacted', () {
      var reentered = false;
      debugPrint = (message, {wrapWidth}) {
        printed.add(message);
        if (!reentered) {
          reentered = true;
          debugPrint('nested direct tx $_txid');
          log('nested path $_path');
        }
      };
      installLogRedaction();

      log('outer tx $_txid');

      expect(printed, [
        '[zcash] outer tx <txid>',
        'nested direct tx <txid>',
        '[zcash] nested path <path>',
      ]);
    });

    test('logs scheduled by the output remain redacted', () async {
      Future<void>? nested;
      debugPrint = (message, {wrapWidth}) {
        printed.add(message);
        nested ??= Future<void>.microtask(() => debugPrint('later tx $_txid'));
      };
      installLogRedaction();

      log('outer path $_path');
      await nested;

      expect(printed, ['[zcash] outer path <path>', 'later tx <txid>']);
    });

    test('the installed debugPrint wrapper redacts direct calls', () {
      final wrapped = redactingDebugPrint(debugPrint);

      wrapped(
        'Voting: pre-sync nodeUrl=https://vote.example.org/api/round?id=7',
      );
      wrapped(null);

      expect(printed, [
        'Voting: pre-sync nodeUrl=https://vote.example.org/<path>',
        null,
      ]);
    });

    test('uncaught errors are reported redacted', () {
      final handled = reportUncaughtError(
        FileSystemException('Cannot open file', _path),
        StackTrace.empty,
      );

      expect(handled, isTrue);
      expect(printed.single, startsWith('Unhandled Exception: '));
      expect(printed.single, contains("path = '<path>'"));
      expect(printed.single, isNot(contains('alice')));
    });

    test('the installed uncaught-error handler redacts its report', () {
      PlatformDispatcher.instance.onError = null;
      installLogRedaction();
      final handled = PlatformDispatcher.instance.onError!(
        StateError('tx $_txid'),
        StackTrace.fromString('at $_path:459:5'),
      );

      expect(handled, isTrue);
      expect(printed.single, contains('tx <txid>'));
      expect(printed.single, contains('at <path>:459:5'));
      expect(printed.single, isNot(contains(_txid)));
      expect(printed.single, isNot(contains('alice')));
    });

    test('installation preserves an existing uncaught-error handler', () {
      bool existing(Object error, StackTrace stack) => false;
      PlatformDispatcher.instance.onError = existing;

      installLogRedaction();

      expect(PlatformDispatcher.instance.onError, same(existing));
    });

    test('framework error dumps are redacted through debugPrint', () {
      installLogRedaction();

      FlutterError.dumpErrorToConsole(
        FlutterErrorDetails(
          exception: StateError('tx $_txid in /Users/alice/wallet.db'),
          stack: StackTrace.empty,
        ),
        forceReport: true,
      );

      final report = printed.join('\n');
      expect(report, contains('tx <txid>'));
      expect(report, contains('<path>'));
      expect(report, isNot(contains(_txid)));
      expect(report, isNot(contains('alice')));
    });
  });
}
