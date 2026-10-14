@Tags(['mobile'])
library;

// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/home/widgets/ledger_shield_signing_overlay.dart';
import 'package:zcash_wallet/src/features/ledger/services/ledger_signed_operation_service.dart';
import 'package:zcash_wallet/src/features/ledger/services/ledger_signing_service.dart';
import 'package:zcash_wallet/src/providers/account_models.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';
import 'package:zcash_wallet/src/providers/wallet_provider.dart';
import 'package:zcash_wallet/src/rust/api/sync.dart';

void main() {
  testWidgets(
    'an empty Ledger round never celebrates an unsubmitted transaction',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('vizor-shield-test'),
      ))!;
      final original = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(dir.path);
      addTearDown(() async {
        PathProviderPlatform.instance = original;
        await dir.delete(recursive: true);
      });
      var completed = 0;
      final container = ProviderContainer(
        overrides: [
          appBootstrapProvider.overrideWithValue(_bootstrap()),
          syncProvider.overrideWith(_Sync.new),
          walletProvider.overrideWith(_Wallet.new),
          ledgerOperationCancellerProvider.overrideWithValue(() async {}),
          ledgerSignedOperationServiceProvider.overrideWithValue(_Operations()),
          ledgerShieldingProgressReaderProvider.overrideWithValue(
            ({required dbPath, required network, required accountUuid}) async =>
                LedgerShieldingProgress(
                  inputCount: 0,
                  inputLimit: 32,
                  belowThreshold: false,
                ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(syncProvider.future);
      await container.read(walletProvider.future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: AppTheme(
            data: AppThemeData.light,
            child: MaterialApp(
              home: LedgerShieldSigningOverlay(
                mobile: true,
                onCancel: () {},
                onComplete: () => completed++,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      final slide = find.byKey(const ValueKey('mobile_shield_slide'));
      await tester.dragFrom(
        tester.getTopLeft(slide) + const Offset(35, 30),
        const Offset(280, 0),
      );
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Shielding paused'), findsOneWidget);
      expect(
        find.textContaining('No spendable transparent funds remain'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 10));
      expect(
        find.byKey(const ValueKey('mobile_shield_complete')),
        findsNothing,
      );
      expect(completed, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _Operations extends Fake implements LedgerSignedOperationService {
  @override
  Future<List<LedgerSignedOperationMetadata>> list() async => [];
}

class _Paths extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _Sync extends SyncNotifier {
  @override
  Future<SyncState> build() async => SyncState(
    accountUuid: 'account-1',
    hasAccountScopedData: true,
    transparentBalance: BigInt.from(1000000),
  );
}

class _Wallet extends WalletNotifier {
  @override
  FutureOr<WalletState> build() => const WalletState(
    hasWallet: true,
    unifiedAddress: 'u1test',
    network: 'main',
    activeAccountUuid: 'account-1',
  );
}

AppBootstrapState _bootstrap() => AppBootstrapState(
  initialLocation: '/home/ledger-shield',
  initialAccountState: const AccountState(
    accounts: [
      AccountInfo(
        uuid: 'account-1',
        name: 'Ledger',
        order: 0,
        isHardware: true,
        hardwareSignerKind: HardwareSignerKind.ledger,
      ),
    ],
    activeAccountUuid: 'account-1',
    activeAddress: 'u1test',
  ),
  initialSyncSnapshot: AppSyncSnapshot.empty,
  network: 'main',
  rpcEndpointConfig: defaultRpcEndpointConfig('main'),
  themeMode: ThemeMode.light,
  privacyModeEnabled: false,
  isPasswordConfigured: true,
  isUnlocked: true,
  passwordRotationRecoveryFailed: false,
);
