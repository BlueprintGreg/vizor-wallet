import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/chain_upgrade_provider.dart';
import 'package:zcash_wallet/src/providers/enhance_pir_provider.dart';
import 'package:zcash_wallet/src/providers/rpc_endpoint_failover_provider.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';
import 'package:zcash_wallet/src/rust/api/sync.dart' as rust_sync;
import 'package:zcash_wallet/src/rust/frb_generated.dart';

const _accountUuid = 'account-1';
const _delay = Duration(milliseconds: 20);

/// Rust as the sync loop sees it: one guard, held from `startFullSync` until
/// the test closes that sync's stream.
class _Api extends RustLibApi {
  bool running = false;
  int statusReads = 0;
  final syncs = <StreamController<rust_sync.ApiSyncProgressEvent>>[];

  @override
  bool crateApiSyncIsSyncRunning() => running;

  @override
  bool crateApiSyncIsSyncCancelRequested() => false;

  @override
  bool crateApiSyncIsMempoolObserverRunning() => false;

  @override
  void crateApiSyncSetActiveSyncAccount({String? accountUuid}) {}

  @override
  void crateApiSyncSetSyncMode({required int mode}) {}

  @override
  void crateApiSyncCancelFullSync() {}

  @override
  void crateApiSyncStopMempoolObserver() {}

  @override
  Stream<rust_sync.ApiMempoolTxEvent> crateApiSyncStartMempoolObserver({
    required String dbPath,
    required String network,
    required String lightwalletdUrl,
  }) => const Stream.empty();

  @override
  Stream<rust_sync.ApiSyncProgressEvent> crateApiSyncStartFullSync({
    required String dbPath,
    required String lightwalletdUrl,
    required String network,
    required int mode,
  }) {
    if (running) throw StateError('an unowned concurrent sync was spawned');
    running = true;
    final controller = StreamController<rust_sync.ApiSyncProgressEvent>();
    syncs.add(controller);
    return controller.stream;
  }

  /// No recovery work remains; the pass must run anyway, without asking.
  @override
  Future<rust_sync.EnhanceRecoveryStatus> crateApiSyncGetEnhanceRecoveryStatus({
    required String dbPath,
    required String network,
  }) async {
    statusReads++;
    return const rust_sync.EnhanceRecoveryStatus(
      queries: 0,
      rediscovery: 0,
      suspended: 0,
      status: 0,
      serviceState: '',
    );
  }

  @override
  Future<rust_sync.WalletBalance> crateApiSyncGetBalance({
    required String dbPath,
    required String network,
    required String accountUuid,
  }) async => rust_sync.WalletBalance(
    availability: rust_sync.WalletBalanceAvailability.available,
    transparentAuthority: rust_sync.TransparentBalanceAuthority.current,
    transparentPrivate: false,
    transparent: BigInt.zero,
    sapling: BigInt.zero,
    orchard: BigInt.one,
    ironwood: BigInt.zero,
    transparentLocked: BigInt.zero,
    saplingLocked: BigInt.zero,
    orchardLocked: BigInt.zero,
    ironwoodLocked: BigInt.zero,
    transparentPending: BigInt.zero,
    saplingPending: BigInt.zero,
    orchardPending: BigInt.zero,
    ironwoodPending: BigInt.zero,
    changePendingConfirmation: BigInt.zero,
    valuePendingSpendability: BigInt.zero,
    uneconomicValue: BigInt.zero,
    spendable: BigInt.one,
    locked: BigInt.zero,
    total: BigInt.one,
  );

  @override
  Future<List<rust_sync.TransactionInfo>> crateApiSyncGetTransactionHistory({
    required String dbPath,
    required String network,
    int? limit,
    required String accountUuid,
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Account extends AccountNotifier {
  @override
  AccountState build() => const AccountState(
    accounts: [AccountInfo(uuid: _accountUuid, name: 'Account 1', order: 0)],
    activeAccountUuid: _accountUuid,
  );
}

class _Tip extends RpcEndpointFailoverNotifier {
  @override
  RpcEndpointFailoverState build() => RpcEndpointFailoverState(
    primary: defaultRpcEndpointConfig('main'),
    current: defaultRpcEndpointConfig('main'),
    fallbackCandidates: const [],
  );

  @override
  Future<BigInt> getLatestBlockHeight() async => BigInt.from(100);
}

class _Upgrade extends ChainUpgradeStatusNotifier {
  @override
  Future<ChainUpgradeStatusState> build() async =>
      ChainUpgradeStatusState.cachedActive(defaultRpcEndpointConfig('main'));

  @override
  Future<void> refreshAtTip(BigInt tipHeight) async {}
}

class _PrivateQueries extends EnhancePirNotifier {
  @override
  bool build() => true;

  /// Turns Private queries off without the settings transition.
  void turnOff() => state = false;
}

class _Sync extends SyncNotifier {
  _Sync()
    : super(
        walletDbPathResolver: () async => 'wallet.db',
        excludeCompanionsFromBackup: (_) async {},
        recoveryPassDelay: _delay,
      );

  @override
  Future<SyncState> build() async {
    await super.build();
    return SyncState(
      accountUuid: _accountUuid,
      hasAccountScopedData: true,
      isSyncComplete: true,
      scannedHeight: 100,
      chainTipHeight: 100,
    );
  }
}

rust_sync.ApiSyncProgressEvent _complete() => rust_sync.ApiSyncProgressEvent(
  kind: rust_sync.ApiSyncEventKind.completed,
  scannedHeight: BigInt.from(100),
  chainTipHeight: BigInt.from(100),
  percentage: 1,
  displayTargetPercentage: 1,
  displayTargetBlocks: BigInt.zero,
  isSyncing: false,
  hasNewTx: false,
  phaseCompletedUnits: BigInt.zero,
  phaseTotalUnits: BigInt.zero,
  phase: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  tearDownAll(RustLib.dispose);
  setUp(() {
    api.running = false;
    api.statusReads = 0;
    api.syncs.clear();
  });
  late ProviderContainer container;
  late _Sync sync;

  /// Waits past the injected recovery-pass delay.
  Future<void> pastDelay() async {
    await Future<void>.delayed(_delay * 3);
    await pumpEventQueue();
  }

  /// Completes sync [index] and closes its stream, as Rust does.
  Future<void> finish(int index) async {
    api.syncs[index].add(_complete());
    await pumpEventQueue();
    sync.stopTipChecksForTesting();
    api.running = false;
    await api.syncs[index].close();
    await pumpEventQueue();
  }

  /// A wallet whose launch sync is running.
  Future<void> launch() async {
    sync = _Sync();
    container = ProviderContainer(
      overrides: [
        appBootstrapProvider.overrideWithValue(AppBootstrapState.empty),
        accountProvider.overrideWith(_Account.new),
        rpcEndpointFailoverProvider.overrideWith(_Tip.new),
        chainUpgradeStatusProvider.overrideWith(_Upgrade.new),
        enhancePirProvider.overrideWith(_PrivateQueries.new),
        syncProvider.overrideWith(() => sync),
      ],
    );
    addTearDown(container.dispose);
    container.listen(syncProvider, (_, _) {});
    await container.read(syncProvider.future);
    await pumpEventQueue();
    sync.stopTipChecksForTesting();
    expect(api.syncs, hasLength(1));
  }

  /// A wallet whose block-driven sync just ended.
  Future<void> afterBlockDrivenSync() async {
    await launch();
    await finish(0);
  }

  test('a block-driven sync arms one pass, which runs without reading '
      'recovery status and arms no other', () async {
    await afterBlockDrivenSync();
    expect(sync.recoveryPassArmedForTesting, isTrue);

    await pastDelay();
    expect(api.syncs, hasLength(2), reason: 'the pass is a sync');
    expect(sync.state.requireValue.chainTipHeight, 100);
    expect(api.statusReads, 0, reason: 'the pass runs unconditionally');

    await finish(1);
    expect(sync.recoveryPassArmedForTesting, isFalse);
    await pastDelay();
    expect(api.syncs, hasLength(2));
  });

  test('a failed block-driven sync also arms the pass', () async {
    await launch();
    api.running = false;
    api.syncs[0].addError(StateError('scan failed'));
    await pumpEventQueue();
    sync.stopTipChecksForTesting();
    expect(sync.state.requireValue.failure, isNotNull);
    expect(sync.recoveryPassArmedForTesting, isTrue);
  });

  test('a new block-driven sync replaces the pending pass and re-arms '
      'after it ends', () async {
    await afterBlockDrivenSync();
    sync.startSync(latestTipHeight: 102);
    await pumpEventQueue();
    expect(api.syncs, hasLength(2));
    expect(sync.recoveryPassArmedForTesting, isFalse);

    await finish(1);
    expect(sync.recoveryPassArmedForTesting, isTrue);
    await pastDelay();
    expect(api.syncs, hasLength(3), reason: 'one pass for the newer sync');
  });

  final cancellations = <String, Future<void> Function()>{
    'lock': () => sync.clearSensitiveStateForLock(),
    'backgrounding': () async => sync.handleAppHideForTesting(),
    'turning Private queries off': () async =>
        (container.read(enhancePirProvider.notifier) as _PrivateQueries)
            .turnOff(),
  };
  for (final MapEntry(key: cause, value: cancel) in cancellations.entries) {
    test('$cause cancels the pending pass', () async {
      await afterBlockDrivenSync();
      await cancel();
      expect(sync.recoveryPassArmedForTesting, isFalse);
      await pastDelay();
      expect(api.syncs, hasLength(1));
    });
  }

  test('no pass is armed with Private queries off', () async {
    await afterBlockDrivenSync();
    (container.read(enhancePirProvider.notifier) as _PrivateQueries).turnOff();
    sync.startSync(latestTipHeight: 102);
    await pumpEventQueue();
    await finish(1);
    expect(sync.recoveryPassArmedForTesting, isFalse);
    await pastDelay();
    expect(api.syncs, hasLength(2));
  });
}
