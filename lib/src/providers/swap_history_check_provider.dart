import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/wallet_paths.dart';
import '../rust/api/one_time_ivk.dart' as rust_swap;
import 'rpc_endpoint_failover_provider.dart';
import 'sync_provider.dart';

/// The wallet calls behind "Check swap history". Overridable in tests.
class SwapHistoryApi {
  const SwapHistoryApi({
    required this.begin,
    required this.isChecking,
    this.pollInterval = const Duration(seconds: 5),
    this.maxWait = const Duration(minutes: 3),
  });

  /// Ends every software account's discovery pass, so the next sync starts a
  /// new one against the receiver directory.
  final Future<void> Function() begin;

  /// Whether that pass, or a restored wallet's first one, is still running.
  final Future<bool> Function() isChecking;

  /// How often a running check asks the wallet whether it is done.
  final Duration pollInterval;

  /// How long the check waits before leaving the rest to later syncs.
  final Duration maxWait;
}

final swapHistoryApiProvider = Provider<SwapHistoryApi>((ref) {
  String network() => ref.read(rpcEndpointFailoverProvider).current.networkName;
  return SwapHistoryApi(
    begin: () async => rust_swap.checkSwapHistory(
      dbPath: await getWalletDbPath(),
      networkName: network(),
    ),
    isChecking: () async => rust_swap.isSwapHistoryChecking(
      dbPath: await getWalletDbPath(),
      networkName: network(),
    ),
  );
});

/// Where the user's "Check swap history" stands.
enum SwapHistoryCheck {
  /// Not run since launch.
  idle,

  /// Waiting for sync to finish the check.
  checking,

  /// The check finished.
  done,

  /// The check outlasted [SwapHistoryApi.maxWait]; later syncs finish it.
  continuing,

  /// The wallet could not start the check.
  failed,
}

/// Runs "Check swap history": a new search of the receiver directory for
/// refunds or payouts that reached a swap address after the wallet stopped
/// scanning it. Once a restored wallet's first search is complete nothing else
/// starts one.
class SwapHistoryCheckNotifier extends Notifier<SwapHistoryCheck> {
  @override
  SwapHistoryCheck build() => SwapHistoryCheck.idle;

  /// Starts a check and syncs until the wallet reports it done, or until
  /// [SwapHistoryApi.maxWait] passes. Does nothing while one is running.
  Future<void> check() async {
    if (state == SwapHistoryCheck.checking) return;
    state = SwapHistoryCheck.checking;
    final api = ref.read(swapHistoryApiProvider);
    try {
      await api.begin();
      final deadline = DateTime.now().add(api.maxWait);
      while (true) {
        // A sync already running continues the check; this one no-ops then.
        ref.read(syncProvider.notifier).startSync();
        await Future<void>.delayed(api.pollInterval);
        if (!ref.mounted) return;
        if (!await api.isChecking()) {
          state = SwapHistoryCheck.done;
          return;
        }
        if (!ref.mounted) return;
        if (!DateTime.now().isBefore(deadline)) {
          state = SwapHistoryCheck.continuing;
          return;
        }
      }
    } catch (error) {
      log('Swap history check failed: $error');
      if (ref.mounted) state = SwapHistoryCheck.failed;
    }
  }
}

final swapHistoryCheckProvider =
    NotifierProvider<SwapHistoryCheckNotifier, SwapHistoryCheck>(
      SwapHistoryCheckNotifier.new,
    );
