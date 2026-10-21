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

    setUp(() {
      printed = [];
      previous = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => printed.add(message);
    });
    tearDown(() => debugPrint = previous);

    test('log() redacts before it prints', () {
      log('sync: tx $_txid stored in $_path at height 3201456');

      expect(printed, [
        '[zcash] sync: tx <txid> stored in <path> at height 3201456',
      ]);
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
  });
}
