import 'package:flutter/foundation.dart';

/// Debug builds only, for the transparent history harness
/// (`scripts/e2e/transparent-history-cases.sh --profile private --flutter
/// desktop`): --dart-define=ZCASH_E2E_PRIVATE_TRANSPARENT_REGTEST=true makes
/// "Private queries" available on regtest, where the harness runs its own
/// transparent PIR service. Off without the define, and constant `false` in
/// profile and release builds. Rust selects private recovery on regtest only
/// under its own debug-only switch, `ZCASH_E2E_REGTEST_PRIVATE_TRANSPARENT`.
const kZcashE2ePrivateTransparentRegtestEnvKey =
    'ZCASH_E2E_PRIVATE_TRANSPARENT_REGTEST';
const kZcashE2ePrivateTransparentRegtest =
    kDebugMode &&
    bool.fromEnvironment(
      kZcashE2ePrivateTransparentRegtestEnvKey,
      defaultValue: false,
    );

/// What private queries adds to supported mainnet transparent recovery.
/// Transparent funds are unavailable until recovery completes; Ledger
/// accounts are paused rather than recovered privately.
const kPrivateTransparentRecoverySettingsCopy =
    'Also recovers transparent funds privately. Transparent funds stay '
    'unavailable until private recovery completes; Ledger transparent funds '
    'are not recovered privately.';

/// Includes transparent recovery in the private queries disclosure.
String privateQueriesDescription(String description) =>
    '$description $kPrivateTransparentRecoverySettingsCopy';
