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
    required this.status,
    required this.cancel,
    this.pollInterval = const Duration(seconds: 5),
    this.maxWait = const Duration(minutes: 3),
  });

  /// Starts or resumes the durable explicit history job for eligible accounts.
  final Future<void> Function(BigInt? receiveEnd) begin;

  /// Cancels the job without discarding its durable position.
  final Future<void> Function() cancel;

  /// Whether manual recovery or a restored wallet's seed walk is unfinished, and
  /// whether the receiver service needs a newer app.
  final Future<rust_swap.SwapRecoveryStatus> Function() status;

  /// How often a running check asks the wallet whether it is done.
  final Duration pollInterval;

  /// How long the check waits before leaving the rest to later syncs.
  final Duration maxWait;
}

final swapHistoryApiProvider = Provider<SwapHistoryApi>((ref) {
  String network() => ref.read(rpcEndpointFailoverProvider).current.networkName;
  return SwapHistoryApi(
    begin: (end) =>
        ref.read(syncProvider.notifier).checkSwapHistory(receiveEnd: end),
    cancel: () => ref.read(syncProvider.notifier).cancelSwapHistory(),
    status: () async => rust_swap.getSwapRecoveryStatus(
      dbPath: await getWalletDbPath(),
      networkName: network(),
    ),
  );
});

/// Where the user's "Check swap history" stands.
enum SwapHistoryCheck {
  /// Not run since launch.
  idle,

  /// Waiting for receiver recovery to finish the check.
  checking,

  /// The check finished.
  done,

  /// The check outlasted [SwapHistoryApi.maxWait]; later recovery rounds finish it.
  continuing,

  /// The user paused the durable job.
  paused,

  /// A round failed. A previously saved job may still need pausing or resuming.
  failed,

  /// The receiver service needs a newer app. The saved job resumes after an update.
  updateRequired,
}

/// Tracks the explicit check for older repeat payments that automatic catch-up skips.
class SwapHistoryCheckNotifier extends Notifier<SwapHistoryCheck> {
  @override
  SwapHistoryCheck build() => SwapHistoryCheck.idle;

  int _generation = 0;

  /// Starts a check and polls until the wallet reports it done, or until
  /// [SwapHistoryApi.maxWait] passes. Does nothing while one is running.
  Future<void> check({BigInt? receiveEnd}) async {
    if (state == SwapHistoryCheck.checking) return;
    final generation = ++_generation;
    state = SwapHistoryCheck.checking;
    final api = ref.read(swapHistoryApiProvider);
    try {
      await api.begin(receiveEnd);
      if (!ref.mounted || generation != _generation) return;
      final deadline = DateTime.now().add(api.maxWait);
      while (true) {
        // Receiver work has its own lifecycle and never occupies ordinary sync.
        ref.read(syncProvider.notifier).continueSwapRecovery();
        await Future<void>.delayed(api.pollInterval);
        if (!ref.mounted || generation != _generation) return;
        final status = await api.status();
        if (!ref.mounted || generation != _generation) return;
        if (status.upgradeRequired) {
          state = SwapHistoryCheck.updateRequired;
          return;
        }
        if (!status.checkingHistory) {
          state = SwapHistoryCheck.done;
          return;
        }
        if (!ref.mounted || generation != _generation) return;
        if (!DateTime.now().isBefore(deadline)) {
          state = SwapHistoryCheck.continuing;
          return;
        }
      }
    } catch (error) {
      log('Swap history check failed: $error');
      if (ref.mounted && generation == _generation) {
        state =
            error is rust_swap.ReceiveError &&
                error.kind == rust_swap.ReceiveErrorKind.upgradeRequired
            ? SwapHistoryCheck.updateRequired
            : SwapHistoryCheck.failed;
      }
    }
  }

  /// Pauses the current job and prevents a late poll from overwriting that state.
  Future<void> cancel() async {
    final generation = ++_generation;
    try {
      await ref.read(swapHistoryApiProvider).cancel();
      if (ref.mounted && generation == _generation) {
        state = SwapHistoryCheck.paused;
      }
    } catch (error) {
      log('Could not pause swap history check: $error');
      if (ref.mounted && generation == _generation) {
        state = SwapHistoryCheck.failed;
      }
    }
  }
}

final swapHistoryCheckProvider =
    NotifierProvider<SwapHistoryCheckNotifier, SwapHistoryCheck>(
      SwapHistoryCheckNotifier.new,
    );
