import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/config/private_transparent_recovery_config.dart';

void main() {
  test('private queries always describes transparent recovery', () {
    const base = 'Experimental. Looks up supported transactions.';
    expect(
      privateQueriesDescription(base),
      '$base $kPrivateTransparentRecoverySettingsCopy',
    );
    expect(
      kPrivateTransparentRecoverySettingsCopy,
      contains('account birthday'),
    );
    expect(
      kPrivateTransparentRecoverySettingsCopy,
      contains('first transparent or shielded activity'),
    );
    expect(
      kPrivateTransparentRecoverySettingsCopy,
      isNot(contains('not recovered')),
    );
  });
}
