@Timeout(Duration(seconds: 10))
library;

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

/// Rust as the sync loop sees it: one guard, held from `startFullSync` until
/// the test closes that sync's stream, follow-ups included.
class _Api extends RustLibApi {
  bool running = false;
  int historyReads = 0;
  int balanceReads = 0;
  bool unavailableFirstBalance = false;
  int gatedHistoryRead = 1;
  int gatedBalanceRead = 2;
  Completer<void>? balanceGate;
  Completer<List<rust_sync.TransactionInfo>>? historyGate;
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

  @override
  Future<rust_sync.WalletBalance> crateApiSyncGetBalance({
    required String dbPath,
    required String network,
    required String accountUuid,
  }) async {
    balanceReads++;
    final unavailable = unavailableFirstBalance && balanceReads == 1;
    if (balanceReads == gatedBalanceRead && balanceGate != null) {
      await balanceGate!.future;
    }
    final amount = unavailable ? BigInt.zero : BigInt.one;
    return rust_sync.WalletBalance(
      availability: unavailable
          ? rust_sync.WalletBalanceAvailability.summaryUnavailable
          : rust_sync.WalletBalanceAvailability.available,
      transparentAuthority: rust_sync.TransparentBalanceAuthority.current,
      transparentPrivate: false,
      transparent: BigInt.zero,
      sapling: BigInt.zero,
      orchard: amount,
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
      spendable: amount,
      locked: BigInt.zero,
      total: amount,
    );
  }

  @override
  Future<List<rust_sync.TransactionInfo>> crateApiSyncGetTransactionHistory({
    required String dbPath,
    required String network,
    int? limit,
    required String accountUuid,
  }) async {
    historyReads++;
    if (historyReads == gatedHistoryRead && historyGate != null) {
      return historyGate!.future;
    }
    return const [];
  }

  /// Ends the sync that holds the guard: Rust releases it, then the stream
  /// closes.
  Future<void> finish(int index) async {
    running = false;
    await syncs[index].close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Account extends AccountNotifier {
  @override
  AccountState build() => const AccountState(
    accounts: [
      AccountInfo(uuid: _accountUuid, name: 'Account 1', order: 0),
      AccountInfo(uuid: 'account-2', name: 'Account 2', order: 1),
    ],
    activeAccountUuid: _accountUuid,
  );

  void select(String uuid) {
    state = AsyncData(state.requireValue.copyWith(activeAccountUuid: uuid));
  }
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

class _NoPrivateQueries extends EnhancePirNotifier {
  @override
  bool build() => false;
}

class _Sync extends SyncNotifier {
  _Sync()
    : super(
        walletDbPathResolver: () async => 'wallet.db',
        excludeCompanionsFromBackup: (_) async {},
      );

  @override
  Future<SyncState> build() async => SyncState(
    accountUuid: _accountUuid,
    hasBalanceData: true,
    hasRecentTransactionsData: false,
    isSyncComplete: true,
    scannedHeight: 100,
    chainTipHeight: 100,
  );
}

rust_sync.ApiSyncProgressEvent _complete({
  rust_sync.ApiSyncEventKind kind = rust_sync.ApiSyncEventKind.completed,
}) => rust_sync.ApiSyncProgressEvent(
  kind: kind,
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
    api.historyReads = 0;
    api.balanceReads = 0;
    api.unavailableFirstBalance = false;
    api.gatedHistoryRead = 1;
    api.historyGate = null;
    api.balanceGate = null;
    api.gatedBalanceRead = 2;
    api.syncs.clear();
  });

  Future<({ProviderContainer container, _Sync sync})> setup({
    bool complete = true,
  }) async {
    final sync = _Sync();
    final container = ProviderContainer(
      overrides: [
        appBootstrapProvider.overrideWithValue(AppBootstrapState.empty),
        accountProvider.overrideWith(_Account.new),
        rpcEndpointFailoverProvider.overrideWith(_Tip.new),
        chainUpgradeStatusProvider.overrideWith(_Upgrade.new),
        enhancePirProvider.overrideWith(_NoPrivateQueries.new),
        syncProvider.overrideWith(() => sync),
      ],
    );
    addTearDown(() {
      sync.stopTipChecksForTesting();
      container.dispose();
    });
    container.listen(syncProvider, (_, _) {});
    await pumpEventQueue();
    sync.startSync();
    await pumpEventQueue();
    expect(api.syncs, hasLength(1));
    expect(sync.state.requireValue.isUsingCompletedSpendableSnapshot, isTrue);
    if (complete) api.syncs.single.add(_complete());
    await pumpEventQueue();
    unawaited(api.finish(0));
    await pumpEventQueue();
    return (container: container, sync: sync);
  }

  test('completed scanning permits a spend operation', () async {
    final (:sync, :container) = await setup();
    expect(
      container.read(syncProvider).requireValue.hasSettledSpendableBalance,
      isTrue,
    );
    expect(
      await sync.runWithAuthoritativeSpendable(
        accountUuid: _accountUuid,
        operation: () async => 'ready',
      ),
      'ready',
    );
  });

  test('slow recovery respects the spend deadline', () async {
    api.unavailableFirstBalance = true;
    api.balanceGate = Completer<void>();
    final (:sync, :container) = await setup();
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(api.balanceReads, 2);
    expect(
      container
          .read(syncProvider)
          .requireValue
          .isUsingCompletedSpendableSnapshot,
      isTrue,
    );
    sync.stopTipChecksForTesting();
    await expectLater(
      sync
          .waitForAuthoritativeSpendable(
            accountUuid: _accountUuid,
            timeout: const Duration(milliseconds: 150),
          )
          .timeout(const Duration(seconds: 2)),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('still finishing'),
        ),
      ),
    );
    api.balanceGate!.complete();
    await pumpEventQueue();
  });

  test('completion and spending do not wait for history', () async {
    api.historyGate = Completer<List<rust_sync.TransactionInfo>>();
    final (:sync, :container) = await setup();
    sync.stopTipChecksForTesting();
    final state = container.read(syncProvider).requireValue;
    expect(state.isSyncComplete, isTrue);
    expect(state.hasSettledSpendableBalance, isTrue);
    expect(state.hasRecentTransactionsData, isFalse);
    expect(api.historyReads, 1);
    expect(api.historyGate!.isCompleted, isFalse);
    expect(
      await sync
          .runWithAuthoritativeSpendable(
            accountUuid: _accountUuid,
            operation: () async => 'ready',
          )
          .timeout(const Duration(seconds: 2)),
      'ready',
    );
    api.historyGate!.complete([]);
    await pumpEventQueue();
    expect(
      container.read(syncProvider).requireValue.hasRecentTransactionsData,
      isTrue,
    );
  });

  test(
    'resume and new blocks coalesce history without invalidating it',
    () async {
      api.historyGate = Completer<List<rust_sync.TransactionInfo>>();
      final (:sync, :container) = await setup();
      sync.stopTipChecksForTesting();
      sync.handleAppHideForTesting();
      sync.handleAppResumeForTesting();
      await pumpEventQueue();
      sync.stopTipChecksForTesting();
      // Another real sync starts before the old history read completes.
      sync.startSync();
      await pumpEventQueue();
      expect(api.syncs, hasLength(2));
      api.syncs[1].add(_complete());
      await pumpEventQueue();
      unawaited(api.finish(1));
      await pumpEventQueue();
      sync.stopTipChecksForTesting();
      expect(api.historyReads, 1);
      expect(
        container.read(syncProvider).requireValue.hasSettledSpendableBalance,
        isTrue,
      );
      final firstHistory = api.historyGate!;
      api.historyGate = Completer<List<rust_sync.TransactionInfo>>();
      api.gatedHistoryRead = 2;
      firstHistory.complete([]);
      await pumpEventQueue();
      expect(api.historyReads, 2);
      expect(api.historyGate!.isCompleted, isFalse);
      // The active result commits even though a newer history request is queued.
      expect(
        container.read(syncProvider).requireValue.hasRecentTransactionsData,
        isTrue,
      );
      api.historyGate!.complete([]);
      await pumpEventQueue();
      expect(api.historyReads, 2);
    },
  );

  test(
    'a resume balance superseding completion recovers without history',
    () async {
      api.balanceGate = Completer<void>();
      api.gatedBalanceRead = 1;
      api.historyGate = Completer<List<rust_sync.TransactionInfo>>();
      final (:sync, :container) = await setup();
      sync.handleAppHideForTesting();
      sync.handleAppResumeForTesting();
      await pumpEventQueue();
      sync.stopTipChecksForTesting();
      expect(api.balanceReads, 2);
      api.balanceGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      sync.stopTipChecksForTesting();
      expect(container.read(syncProvider).requireValue.isSyncComplete, isTrue);
      expect(
        container.read(syncProvider).requireValue.hasSettledSpendableBalance,
        isTrue,
      );
      expect(api.historyGate!.isCompleted, isFalse);
      api.historyGate!.complete([]);
      await pumpEventQueue();
    },
  );

  test(
    'proposal release needs only balance while history is blocked',
    () async {
      api.historyGate = Completer<List<rust_sync.TransactionInfo>>();
      final (:sync, :container) = await setup();
      sync.stopTipChecksForTesting();
      await sync
          .refreshAfterProposalRelease(_accountUuid)
          .timeout(const Duration(seconds: 2));
      expect(
        container.read(syncProvider).requireValue.hasSettledSpendableBalance,
        isTrue,
      );
      expect(api.historyGate!.isCompleted, isFalse);
      api.historyGate!.complete([]);
      await pumpEventQueue();
    },
  );

  test('late history cannot repopulate a locked wallet', () async {
    api.historyGate = Completer<List<rust_sync.TransactionInfo>>();
    final (:sync, :container) = await setup();
    sync.stopTipChecksForTesting();
    await sync.clearSensitiveStateForLock();
    api.historyGate!.complete([]);
    await pumpEventQueue();
    expect(
      container.read(syncProvider).requireValue.hasRecentTransactionsData,
      isFalse,
    );
    expect(container.read(syncProvider).requireValue.accountUuid, isNull);
  });

  test(
    'late history cannot populate another account or a switch back',
    () async {
      api.historyGate = Completer<List<rust_sync.TransactionInfo>>();
      final (:sync, :container) = await setup();
      sync.stopTipChecksForTesting();
      final accounts = container.read(accountProvider.notifier) as _Account;
      accounts.select('account-2');
      sync.handleAccountSwitchForTesting('account-2');
      accounts.select(_accountUuid);
      sync.handleAccountSwitchForTesting(_accountUuid);
      api.historyGate!.complete([]);
      await pumpEventQueue();
      expect(
        container.read(syncProvider).requireValue.hasRecentTransactionsData,
        isFalse,
      );
    },
  );

  test(
    'stream closure without completion does not declare sync complete',
    () async {
      final (:sync, :container) = await setup(complete: false);
      sync.stopTipChecksForTesting();
      expect(container.read(syncProvider).requireValue.isSyncComplete, isFalse);
      expect(
        container.read(syncProvider).requireValue.hasSettledSpendableBalance,
        isFalse,
      );
    },
  );
}
