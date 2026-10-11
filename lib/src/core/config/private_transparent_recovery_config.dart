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
