import 'dart:async';
import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/one_time_ivk.dart' as rust_swap;
import 'enhance_pir_provider.dart';
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
  return SwapHistoryApi(
    begin: (end) =>
        ref.read(syncProvider.notifier).checkSwapHistory(receiveEnd: end),
    cancel: () => ref.read(syncProvider.notifier).cancelSwapHistory(),
    // Without a wallet there is no history left to check.
    status: () async =>
        await ref.read(swapRecoveryStatusReaderProvider)() ??
        const rust_swap.SwapRecoveryStatus(
          checkingHistory: false,
          upgradeRequired: false,
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
  /// Starts idle and follows two outside changes. Turning NEAR swap privacy
  /// off pauses discovery, which the wallet then reports as no unfinished
  /// check, so a running or interrupted check ends paused instead of done, and
  /// turning it back on resumes watching that saved work. A round that finds
  /// the service compatible again ends an update request.
  @override
  SwapHistoryCheck build() {
    ref.listen(nearSwapPrivacyProvider, (_, enabled) {
      if (!enabled &&
          (state == SwapHistoryCheck.checking ||
              state == SwapHistoryCheck.continuing ||
              state == SwapHistoryCheck.failed)) {
        _generation++;
        // A failed check may have no saved job left to resume.
        _pausedBySetting = state != SwapHistoryCheck.failed;
        state = SwapHistoryCheck.paused;
      } else if (enabled &&
          _pausedBySetting &&
          state == SwapHistoryCheck.paused) {
        unawaited(_resume());
      }
    });
    ref.listen(swapRecoveryUpdateRequiredProvider, (_, required) {
      if (!required && state == SwapHistoryCheck.updateRequired) {
        state = SwapHistoryCheck.idle;
      }
    });
    return SwapHistoryCheck.idle;
  }

  int _generation = 0;

  /// Whether the shown pause came from turning NEAR swap privacy off, which
  /// keeps the saved job active, rather than from the user pausing it.
  bool _pausedBySetting = false;

  /// Starts a check and polls until the wallet reports it done, or until
  /// [SwapHistoryApi.maxWait] passes. Does nothing while one is running.
  Future<void> check({BigInt? receiveEnd}) async {
    if (state == SwapHistoryCheck.checking) return;
    final generation = ++_generation;
    _pausedBySetting = false;
    state = SwapHistoryCheck.checking;
    final api = ref.read(swapHistoryApiProvider);
    try {
      await api.begin(receiveEnd);
      if (!ref.mounted || generation != _generation) return;
      await _observe(generation, api);
    } catch (error) {
      _fail(generation, error);
    }
  }

  /// Watches the saved job again once NEAR swap privacy is back on, since the
  /// wallet resumes it in later rounds. It shows as checking, with Pause.
  Future<void> _resume() async {
    final generation = ++_generation;
    _pausedBySetting = false;
    state = SwapHistoryCheck.checking;
    try {
      await _observe(generation, ref.read(swapHistoryApiProvider));
    } catch (error) {
      _fail(generation, error);
    }
  }

  /// Polls the wallet for the check started under `generation` until it is
  /// done, needs an update, or outlasts [SwapHistoryApi.maxWait]. It reads no
  /// status while a setting change is still being applied to the wallet,
  /// whose accounts may not yet be enabled again.
  Future<void> _observe(int generation, SwapHistoryApi api) async {
    final deadline = DateTime.now().add(api.maxWait);
    while (true) {
      // Receiver work has its own lifecycle and never occupies ordinary sync.
      ref.read(syncProvider.notifier).continueSwapRecovery();
      await Future<void>.delayed(api.pollInterval);
      if (!ref.mounted || generation != _generation) return;
      if (ref.read(enhancePirTransitionProvider) !=
          kEnhancePirChangingMessage) {
        final status = await api.status();
        if (!ref.mounted || generation != _generation) return;
        if (status.upgradeRequired) {
          _requireUpdate();
          return;
        }
        if (!status.checkingHistory) {
          // Disabled accounts report no check, finished or not.
          state = ref.read(nearSwapPrivacyProvider)
              ? SwapHistoryCheck.done
              : SwapHistoryCheck.paused;
          return;
        }
      }
      if (!DateTime.now().isBefore(deadline)) {
        state = SwapHistoryCheck.continuing;
        return;
      }
    }
  }

  /// Ends the check under `generation` with `error`: an update request when
  /// the service needs a newer app, else failed.
  void _fail(int generation, Object error) {
    log('Swap history check failed: $error');
    if (ref.mounted && generation == _generation) {
      if (error is rust_swap.ReceiveError &&
          error.kind == rust_swap.ReceiveErrorKind.upgradeRequired) {
        _requireUpdate();
      } else {
        state = SwapHistoryCheck.failed;
      }
    }
  }

  /// Shows the update request and records it as the wallet's latest answer,
  /// so the next round that finds the service compatible clears both.
  void _requireUpdate() {
    ref.read(swapRecoveryUpdateRequiredProvider.notifier).set(true);
    state = SwapHistoryCheck.updateRequired;
  }

  /// Pauses the current job and prevents a late poll from overwriting that state.
  Future<void> cancel() async {
    final generation = ++_generation;
    _pausedBySetting = false;
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
