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
/// Software and hardware accounts recover from their stored birthday.
const kPrivateTransparentRecoverySettingsCopy =
    'Also recovers transparent funds privately from the account birthday. '
    'The birthday must be before the account’s first transparent or shielded '
    'activity. Transparent funds stay unavailable until private recovery '
    'completes.';

/// Includes transparent recovery in the private queries disclosure.
String privateQueriesDescription(String description) =>
    '$description $kPrivateTransparentRecoverySettingsCopy';
