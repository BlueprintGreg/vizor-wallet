/// Masks identifier-shaped values before a line reaches a log sink.
///
/// This is a safety net, not a privacy contract. It recognises values only by
/// their shape: addresses, viewing and spending keys, 32-byte hashes, UUIDs,
/// absolute device paths, URL paths and queries, payment URIs and Keystone URs.
/// Amounts, balances, account names, labels, memos, seed words and other free
/// text pass through unchanged and have to be kept out at the call site.
///
/// The rules and their order are mirrored in `rust/src/log_redaction.rs`, and
/// both test suites run `test/fixtures/log_redaction_vectors.json`.
library;

import 'package:flutter/foundation.dart';

/// Redacts [text] in bounded passes, stopping when it no longer changes.
String redactLogText(String text) => _redactWithPassLimit(text, _maxPasses);

String _redactWithPassLimit(String text, int limit) {
  var current = text;
  for (var pass = 0; pass < limit; pass++) {
    final next = _redactOnce(current);
    if (next == current) break;
    current = next;
  }
  return current;
}

// Track only our own wrappers, without retaining discarded output callbacks
// or any log text. Never infer that a message is safe from its contents.
final _redactingOutputs = Expando<DebugPrintCallback>();

/// Wraps [next] so every message is redacted before it is printed. Wrapping
/// one of our wrappers again returns it unchanged.
DebugPrintCallback redactingDebugPrint(DebugPrintCallback next) {
  if (_redactingOutputs[next] != null) return next;
  void wrapped(String? message, {int? wrapWidth}) => next(
    message == null ? null : redactLogText(message),
    wrapWidth: wrapWidth,
  );
  final DebugPrintCallback callback = wrapped;
  _redactingOutputs[callback] = next;
  return callback;
}

/// Redacts before printing, even before installation or after another caller
/// replaces [debugPrint]. Only bypasses our own wrapper's redundant scan;
/// its downstream output still runs, with the same wrapping and throttling.
void printRedactedLog(String? message, {int? wrapWidth}) {
  final current = debugPrint;
  final downstream = _redactingOutputs[current];
  // The installed wrapper used to add another four passes after the caller.
  // Preserve that budget for cascading matches, but stop as soon as the
  // text is stable instead of starting a redundant second scan.
  final limit = downstream == null ? _maxPasses : 2 * _maxPasses;
  (downstream ?? current)(
    message == null ? null : _redactWithPassLimit(message, limit),
    wrapWidth: wrapWidth,
  );
}

/// Prints an uncaught asynchronous error through the redactor instead of the
/// engine's own unhandled-exception report, which would print it verbatim.
bool reportUncaughtError(Object error, StackTrace stack) {
  printRedactedLog('Unhandled Exception: $error\n$stack');
  return true;
}

/// Routes the app's print paths through [redactLogText] in every build mode:
/// direct `debugPrint` calls, framework error dumps (which print through
/// `debugPrint`), and uncaught asynchronous errors.
void installLogRedaction() {
  debugPrint = redactingDebugPrint(debugPrint);
  PlatformDispatcher.instance.onError ??= reportUncaughtError;
}

// A pass only replaces values with tokens, so a second pass finishes any match
// a token made possible. The bound is a backstop, not an expected depth.
const _maxPasses = 4;

// Zakura protocol HRPs (zakura-protocol 3.0.0 constants/{mainnet,testnet,
// regtest}.rs). Ironwood shares the Orchard receiver, so it has no HRP of its
// own. Longer prefixes come first.
const _keyHrps = [
  'secret-extended-key-regtest',
  'secret-extended-key-main',
  'secret-extended-key-test',
  'zxviewregtestsapling',
  'zxviewtestsapling',
  'uviewregtest',
  'uivkregtest',
  'uviewtest',
  'uivktest',
  'zxviews',
  'uview',
  'uivk',
];
const _addressHrps = [
  'zregtestsapling',
  'ztestsapling',
  'texregtest',
  'uregtest',
  'textest',
  'utest',
  'tex',
  'zs',
  'u',
];
const _bech32Charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
// The shortest encoding above is a TEX address: 20 bytes, 38 characters.
const _bech32MinData = 38;
// Base58Check prefixes 0x1cb8/0x1cbd (mainnet), 0x1d25/0x1cba (test/regtest)
// encode as t1/t3 and tm/t2; every transparent address is 35 characters.
const _transparent = r'(?:t1|t3|tm|t2)[1-9A-HJ-NP-Za-km-z]{33}';

// Explicit ASCII classes keep Dart and Rust matching the same characters.
const _space = r'\t\n\v\f\r ';
const _notAlnum = r'[^0-9A-Za-z]';
const _pathStart = r'(^|file://|[^0-9A-Za-z_.~/\\\-])';
const _pathChar = '[^$_space\'"<>|:;,()\\[\\]{}\\\\]';
const _unixRoots =
    'Users|home|root|private|var|tmp|data|storage|sdcard|mnt|media|Volumes|run';

String _bech32(List<String> hrps) {
  final lower = hrps.join('|');
  final upper = hrps.map((hrp) => hrp.toUpperCase()).join('|');
  final upperCharset = _bech32Charset.toUpperCase();
  return '(?:(?:$lower)1[$_bech32Charset]{$_bech32MinData,}'
      '|(?:$upper)1[$upperCharset]{$_bech32MinData,})';
}

final _url = RegExp(
  '\\b([A-Za-z][A-Za-z0-9+.\\-]*://)'
  '(?:[^$_space/?#@\'"<>]*@)?'
  '([^$_space/?#\'"<>]+)'
  '([/?#][^$_space\'"<>]+)?',
);
final _windowsPath = RegExp(
  '$_pathStart([A-Za-z]:[\\\\/][^$_space\'"<>|:;,()\\[\\]{}]*)',
);
final _unixPath = RegExp(
  '$_pathStart(/(?:$_unixRoots)/(?:/Application Support|$_pathChar)*)',
);
final _uuid = RegExp(
  '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
);
final _hex = RegExp('(?:0[xX])?[0-9a-fA-F]{32,}');
final _paymentUri = RegExp('\\b[zZ][cC][aA][sS][hH]:[^$_space\'"<>]+');
final _ur = RegExp('\\b[uU][rR]:[A-Za-z0-9\\-]+/[^$_space\'"<>]+');
final _key = RegExp('($_notAlnum|^)${_bech32(_keyHrps)}');
final _address = RegExp(
  '($_notAlnum|^)(?:${_bech32(_addressHrps)}|$_transparent)',
);

String _redactOnce(String text) => text
    .replaceAllMapped(
      _url,
      (m) => '${m[1]}${m[2]}${m[3] == null ? '' : '/<path>'}',
    )
    // Drive paths first, so `C:/Users/...` is not read as a POSIX path.
    .replaceAllMapped(_windowsPath, (m) => '${m[1]}<path>')
    .replaceAllMapped(_unixPath, (m) => '${m[1]}<path>')
    .replaceAll(_uuid, '<uuid>')
    .replaceAllMapped(_hex, (m) {
      final value = m[0]!;
      // The pattern only admits an `x` as the second character of `0x`.
      final prefixed = value[1] == 'x' || value[1] == 'X';
      return value.length - (prefixed ? 2 : 0) == 64 ? '<txid>' : '<hex>';
    })
    .replaceAll(_paymentUri, '<payment-uri>')
    .replaceAll(_ur, '<ur>')
    .replaceAllMapped(_key, (m) => '${m[1]}<key>')
    .replaceAllMapped(_address, (m) => '${m[1]}<address>');
