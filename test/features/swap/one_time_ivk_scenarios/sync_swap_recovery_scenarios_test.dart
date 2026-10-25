// Scenario tests for when the sync notifier schedules one-time IVK recovery
// rounds, complementing sync_swap_recovery_test.dart. See
// `SyncNotifier._startSwapRecovery` and docs/near-swap-receiving.md.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/app_security_provider.dart';
import 'package:zcash_wallet/src/providers/chain_upgrade_provider.dart';
import 'package:zcash_wallet/src/providers/enhance_pir_provider.dart';
import 'package:zcash_wallet/src/providers/rpc_endpoint_failover_provider.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';
import 'package:zcash_wallet/src/rust/api/one_time_ivk.dart' as rust_swap;
import 'package:zcash_wallet/src/rust/api/sync.dart' as rust_sync;
import 'package:zcash_wallet/src/rust/frb_generated.dart';

const _account = 'account-1';

/// The time the notifier's swap recovery backoff reads.
var _clock = DateTime(2026);

/// A round that reached a compatible service and found nothing new.
const _quiet = rust_swap.SwapRecoveryRound(
  active: true,
  changed: false,
  checked: true,
);

/// A round that found no recovery work and contacted no service.
const _idle = rust_swap.SwapRecoveryRound(
  active: false,
  changed: false,
  checked: false,
);

/// Rust as the scheduler sees it: a sync stream the test feeds batch by batch
/// and recovery rounds the test holds and then completes.
class _Api extends RustLibApi {
  bool running = false;
  final syncs = <StreamController<rust_sync.ApiSyncProgressEvent>>[];
  final rounds = <Completer<rust_swap.SwapRecoveryRound>>[];
  final balanceReads = <String>[];

  /// Whether the fake's sync holds the Rust guard.
  @override
  bool crateApiSyncIsSyncRunning() => running;

  /// Reports no pending cancellation.
  @override
  bool crateApiSyncIsSyncCancelRequested() => false;

  /// Reports no mempool observer.
  @override
  bool crateApiSyncIsMempoolObserverRunning() => false;

  /// Ignores the active account hint.
  @override
  void crateApiSyncSetActiveSyncAccount({String? accountUuid}) {}

  /// Ignores the sync mode.
  @override
  void crateApiSyncSetSyncMode({required int mode}) {}

  /// Releases the sync guard.
  @override
  void crateApiSyncCancelFullSync() => running = false;

  /// Accepts the stop of an observer that never runs.
  @override
  void crateApiSyncStopMempoolObserver() {}

  /// Observes nothing.
  @override
  Stream<rust_sync.ApiMempoolTxEvent> crateApiSyncStartMempoolObserver({
    required String dbPath,
    required String network,
    required String lightwalletdUrl,
  }) => const Stream.empty();

  /// Starts a sync whose batches the test adds.
  @override
  Stream<rust_sync.ApiSyncProgressEvent> crateApiSyncStartFullSync({
    required String dbPath,
    required String lightwalletdUrl,
    required String network,
    required int mode,
  }) {
    running = true;
    final controller = StreamController<rust_sync.ApiSyncProgressEvent>();
    syncs.add(controller);
    return controller.stream;
  }

  /// Starts a held recovery round.
  @override
  Future<rust_swap.SwapRecoveryRound> crateApiOneTimeIvkRunSwapRecovery({
    required String dbPath,
    required String networkName,
  }) {
    final round = Completer<rust_swap.SwapRecoveryRound>();
    rounds.add(round);
    return round.future;
  }

  /// Accepts a cancellation; the held round ends when the test completes it.
  @override
  void crateApiOneTimeIvkCancelSwapRecovery() {}

  /// Records which account's balance was read.
  @override
  Future<rust_sync.WalletBalance> crateApiSyncGetBalance({
    required String dbPath,
    required String network,
    required String accountUuid,
  }) async {
    balanceReads.add(accountUuid);
    final zero = BigInt.zero;
    return rust_sync.WalletBalance(
      availability: rust_sync.WalletBalanceAvailability.available,
      transparentAuthority: rust_sync.TransparentBalanceAuthority.current,
      transparentPrivate: false,
      transparent: zero,
      sapling: zero,
      orchard: zero,
      ironwood: zero,
      transparentLocked: zero,
      saplingLocked: zero,
      orchardLocked: zero,
      ironwoodLocked: zero,
      transparentPending: zero,
      saplingPending: zero,
      orchardPending: zero,
      ironwoodPending: zero,
      changePendingConfirmation: zero,
      valuePendingSpendability: zero,
      uneconomicValue: zero,
      spendable: zero,
      locked: zero,
      total: zero,
    );
  }

  /// Returns an empty history.
  @override
  Future<List<rust_sync.TransactionInfo>> crateApiSyncGetTransactionHistory({
    required String dbPath,
    required String network,
    int? limit,
    required String accountUuid,
  }) async => const [];

  /// Fails any Rust call this fake does not expect.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Accounts extends AccountNotifier {
  /// One active software account.
  @override
  AccountState build() => const AccountState(
    accounts: [AccountInfo(uuid: _account, name: 'Account 1', order: 0)],
    activeAccountUuid: _account,
  );
}

class _Security extends AppSecurityNotifier {
  /// An unlocked wallet.
  @override
  AppSecurityState build() =>
      const AppSecurityState(isPasswordConfigured: true, isUnlocked: true);
}

class _Tip extends RpcEndpointFailoverNotifier {
  /// The default Mainnet endpoint.
  @override
  RpcEndpointFailoverState build() => RpcEndpointFailoverState(
    primary: defaultRpcEndpointConfig('main'),
    current: defaultRpcEndpointConfig('main'),
    fallbackCandidates: const [],
  );

  /// The tip the initial state already scanned.
  @override
  Future<BigInt> getLatestBlockHeight() async => BigInt.from(100);
}

class _Upgrade extends ChainUpgradeStatusNotifier {
  /// An active chain upgrade.
  @override
  Future<ChainUpgradeStatusState> build() async =>
      ChainUpgradeStatusState.cachedActive(defaultRpcEndpointConfig('main'));

  /// Skips the refresh.
  @override
  Future<void> refreshAtTip(BigInt tipHeight) async {}
}

class _NoPrivateQueries extends EnhancePirNotifier {
  /// Private queries off.
  @override
  bool build() => false;
}

class _Privacy extends NearSwapPrivacyNotifier {
  /// NEAR swap privacy off until [turn] changes it.
  @override
  bool build() => false;

  /// Changes the setting without the settings store or native calls.
  void turn(bool on) => state = on;
}

class _Sync extends SyncNotifier {
  _Sync()
    : super(
        walletDbPathResolver: () async => 'wallet.db',
        excludeCompanionsFromBackup: (_) async {},
        now: () => _clock,
      );

  /// A completed sync at height 100.
  @override
  Future<SyncState> build() async => SyncState(
    accountUuid: _account,
    hasAccountScopedData: true,
    isSyncComplete: true,
    scannedHeight: 100,
    chainTipHeight: 100,
  );
}

/// One sync batch that scanned through `height`, of kind `kind`.
rust_sync.ApiSyncProgressEvent _scanned(
  int height, {
  rust_sync.ApiSyncEventKind kind = rust_sync.ApiSyncEventKind.progress,
}) => rust_sync.ApiSyncProgressEvent(
  kind: kind,
  scannedHeight: BigInt.from(height),
  chainTipHeight: BigInt.from(height),
  percentage: 1,
  displayTargetPercentage: 1,
  displayTargetBlocks: BigInt.zero,
  isSyncing: kind == rust_sync.ApiSyncEventKind.progress,
  hasNewTx: false,
  phaseCompletedUnits: BigInt.zero,
  phaseTotalUnits: BigInt.zero,
  phase: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Api api;
  setUpAll(() {
    api = _Api();
    RustLib.initMock(api: api);
  });
  tearDownAll(RustLib.dispose);
  setUp(() {
    api.running = false;
    api.syncs.clear();
    api.rounds.clear();
    api.balanceReads.clear();
    _clock = DateTime(2026);
  });

  late ProviderContainer container;
  late _Sync sync;

  /// Runs a sync to block 101. Its batch starts no round, and its completion
  /// starts a held round. The sync then ends, so idle polls run.
  Future<void> recovering() async {
    sync = _Sync();
    container = ProviderContainer(
      overrides: [
        appBootstrapProvider.overrideWithValue(AppBootstrapState.empty),
        accountProvider.overrideWith(_Accounts.new),
        appSecurityProvider.overrideWith(_Security.new),
        rpcEndpointFailoverProvider.overrideWith(_Tip.new),
        chainUpgradeStatusProvider.overrideWith(_Upgrade.new),
        enhancePirProvider.overrideWith(_NoPrivateQueries.new),
        nearSwapPrivacyProvider.overrideWith(_Privacy.new),
        swapRecoveryStatusReaderProvider.overrideWithValue(() async => null),
        syncProvider.overrideWith(() => sync),
      ],
    );
    addTearDown(container.dispose);
    container.listen(syncProvider, (_, _) {});
    container.listen(swapRecoveryUpdateRequiredProvider, (_, _) {});
    await container.read(syncProvider.future);
    sync.stopTipChecksForTesting();
    sync.startSync();
    await pumpEventQueue();
    api.syncs[0].add(_scanned(101));
    await pumpEventQueue();
    expect(api.rounds, isEmpty, reason: 'a batch before completion');
    api.syncs[0].add(_scanned(101, kind: rust_sync.ApiSyncEventKind.completed));
    await pumpEventQueue();
    expect(api.rounds, hasLength(1));
    api.running = false;
    await api.syncs[0].close();
    await pumpEventQueue();
    sync.stopTipChecksForTesting();
  }

  /// Runs one idle poll and returns the round count.
  Future<int> poll() async {
    await sync.checkTipForTesting();
    sync.stopTipChecksForTesting();
    return api.rounds.length;
  }

  /// Stops the sync before the container goes.
  Future<void> settle() async {
    await pumpEventQueue();
    sync.stopTipChecksForTesting();
    sync.stopSync();
    await pumpEventQueue();
  }

  /// A round that reports the service needs a newer app raises the update
  /// request and, like any failed round, refreshes once in case it committed
  /// results first. The retry waits out the first backoff step. A successful
  /// round that never reached the receiver keeps the request, and only one
  /// that checked a supported receiver clears it.
  test('an outdated service asks for an update until a round checks the '
      'receiver', () async {
    await recovering();
    final followups = container.read(syncFollowupProvider);
    api.rounds.last.completeError(
      const rust_swap.ReceiveError(
        message:
            'Update Vizor to keep checking private swap addresses. '
            'Your saved progress is kept.',
        kind: rust_swap.ReceiveErrorKind.upgradeRequired,
      ),
    );
    await pumpEventQueue();
    expect(container.read(swapRecoveryUpdateRequiredProvider), isTrue);
    expect(container.read(syncFollowupProvider), followups + 1);

    expect(await poll(), 1, reason: 'within the 10 second backoff');
    _clock = _clock.add(const Duration(seconds: 10));
    expect(await poll(), 2, reason: 'a failed round is not idle');
    api.rounds.last.complete(
      const rust_swap.SwapRecoveryRound(
        active: true,
        changed: false,
        checked: false,
      ),
    );
    await pumpEventQueue();
    expect(
      container.read(swapRecoveryUpdateRequiredProvider),
      isTrue,
      reason: 'the round never reached the receiver',
    );

    expect(await poll(), 3, reason: 'a successful round ends the backoff');
    api.rounds.last.complete(_quiet);
    await pumpEventQueue();
    expect(container.read(swapRecoveryUpdateRequiredProvider), isFalse);
    expect(
      container.read(syncFollowupProvider),
      followups + 1,
      reason: 'the later rounds changed nothing',
    );
    await settle();
  });

  /// Turning NEAR swap privacy on while the wallet is idle resumes rounds on
  /// the next poll, and turning it back off lets the wallet skip them once
  /// Rust reports no work.
  test('rounds follow NEAR swap privacy changes while idle', () async {
    await recovering();
    api.rounds.last.complete(_idle);
    await pumpEventQueue();
    expect(await poll(), 1, reason: 'idle and off');

    final privacy =
        container.read(nearSwapPrivacyProvider.notifier) as _Privacy;
    privacy.turn(true);
    expect(await poll(), 2, reason: 'on: every poll asks Rust');
    api.rounds.last.complete(_quiet);
    await pumpEventQueue();
    expect(await poll(), 3);
    api.rounds.last.complete(_quiet);
    await pumpEventQueue();

    privacy.turn(false);
    expect(await poll(), 4, reason: 'off, but the last round had work');
    api.rounds.last.complete(_idle);
    await pumpEventQueue();
    expect(await poll(), 4, reason: 'off and the last round was idle');
    await settle();
  });

  /// With NEAR swap privacy off, a round that fails leaves the wallet's work
  /// unknown, so a poll asks Rust again rather than going idle, but only once
  /// a growing backoff passes. A persistently failing feature-off round costs
  /// one Rust call after 10 seconds, another after 10, then 30, then 60, and
  /// one follow-up refresh each, since a failed round may have committed
  /// results first.
  test(
    'a failed round with the feature off is retried after a growing backoff',
    () async {
      await recovering();
      // The completed sync's own balance read lands first.
      await pumpEventQueue();
      for (final wait in [10, 10, 30, 60]) {
        final rounds = api.rounds.length;
        final reads = api.balanceReads.length;
        final followups = container.read(syncFollowupProvider);
        api.rounds.last.completeError(StateError('database is locked'));
        await pumpEventQueue();
        expect(container.read(syncFollowupProvider), followups + 1);
        expect(api.balanceReads.length, reads + 1);
        _clock = _clock.add(Duration(seconds: wait - 1));
        expect(await poll(), rounds, reason: 'within $wait seconds');
        _clock = _clock.add(const Duration(seconds: 1));
        expect(await poll(), rounds + 1, reason: 'after $wait seconds');
      }
      final reads = api.balanceReads.length;
      final followups = container.read(syncFollowupProvider);
      api.rounds.last.complete(_idle);
      await pumpEventQueue();
      expect(container.read(syncFollowupProvider), followups);
      expect(
        api.balanceReads.length,
        reads,
        reason: 'an idle round refreshes nothing',
      );
      expect(await poll(), 5, reason: 'an idle answer stops the retries');
      await settle();
    },
  );
}
