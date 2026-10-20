import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/providers/swap_history_check_provider.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';

/// Counts the syncs a check asks for; these tests have no wallet.
class _Sync extends SyncNotifier {
  int starts = 0;
  @override
  Future<SyncState> build() async => SyncState();
  @override
  void continueSwapRecovery() => starts++;
}

void main() {
  /// A container whose wallet reports `checking` until it runs out, and whose
  /// check fails to start when `failBegin`.
  (ProviderContainer, _Sync, List<String>) setup({
    required List<bool> checking,
    bool failBegin = false,
    Duration maxWait = const Duration(minutes: 1),
  }) {
    final sync = _Sync();
    final calls = <String>[];
    final container = ProviderContainer(
      overrides: [
        syncProvider.overrideWith(() => sync),
        swapHistoryApiProvider.overrideWithValue(
          SwapHistoryApi(
            cancel: () async {},
            begin: (_) async {
              calls.add('begin');
              if (failBegin) throw StateError('wallet busy');
            },
            isChecking: () async {
              calls.add('poll');
              return checking.isEmpty ? false : checking.removeAt(0);
            },
            pollInterval: Duration.zero,
            maxWait: maxWait,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return (container, sync, calls);
  }

  test(
    'starts once and continues recovery until the wallet finishes it',
    () async {
      final (container, sync, calls) = setup(checking: [true, true, false]);
      final notifier = container.read(swapHistoryCheckProvider.notifier);
      expect(container.read(swapHistoryCheckProvider), SwapHistoryCheck.idle);
      final running = notifier.check();
      expect(
        container.read(swapHistoryCheckProvider),
        SwapHistoryCheck.checking,
      );
      // A second tap while it runs does nothing.
      await notifier.check();
      await running;
      expect(container.read(swapHistoryCheckProvider), SwapHistoryCheck.done);
      expect(calls, ['begin', 'poll', 'poll', 'poll']);
      expect(sync.starts, 3);
    },
  );

  test('leaves a long check to later recovery rounds', () async {
    final (container, _, _) = setup(
      checking: [true, true, true],
      maxWait: Duration.zero,
    );
    await container.read(swapHistoryCheckProvider.notifier).check();
    expect(
      container.read(swapHistoryCheckProvider),
      SwapHistoryCheck.continuing,
    );
  });

  test('reports a check the wallet could not start', () async {
    final (container, sync, calls) = setup(checking: [], failBegin: true);
    await container.read(swapHistoryCheckProvider.notifier).check();
    expect(container.read(swapHistoryCheckProvider), SwapHistoryCheck.failed);
    expect(calls, ['begin']);
    expect(sync.starts, 0);
  });

  test(
    'passes the explicit receive bound without starting ordinary sync',
    () async {
      BigInt? requested;
      final sync = _Sync();
      final container = ProviderContainer(
        overrides: [
          syncProvider.overrideWith(() => sync),
          swapHistoryApiProvider.overrideWithValue(
            SwapHistoryApi(
              begin: (end) async => requested = end,
              cancel: () async {},
              isChecking: () async => false,
              pollInterval: Duration.zero,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container
          .read(swapHistoryCheckProvider.notifier)
          .check(receiveEnd: BigInt.from(50));
      expect(requested, BigInt.from(50));
      expect(container.read(swapHistoryCheckProvider), SwapHistoryCheck.done);
      expect(sync.starts, 1);
    },
  );

  test('a held start cannot resume recovery after pause', () async {
    final start = Completer<void>();
    final sync = _Sync();
    var cancelled = false;
    final container = ProviderContainer(
      overrides: [
        syncProvider.overrideWith(() => sync),
        swapHistoryApiProvider.overrideWithValue(
          SwapHistoryApi(
            begin: (_) => start.future,
            cancel: () async {
              cancelled = true;
            },
            isChecking: () async => false,
            pollInterval: Duration.zero,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(swapHistoryCheckProvider.notifier);
    final running = notifier.check();
    await notifier.cancel();
    start.complete();
    await running;
    expect(cancelled, isTrue);
    expect(sync.starts, 0);
    expect(container.read(swapHistoryCheckProvider), SwapHistoryCheck.paused);
  });

  test('a held completion cannot overwrite pause', () async {
    final pollStarted = Completer<void>();
    final poll = Completer<bool>();
    final container = ProviderContainer(
      overrides: [
        syncProvider.overrideWith(_Sync.new),
        swapHistoryApiProvider.overrideWithValue(
          SwapHistoryApi(
            begin: (_) async {},
            cancel: () async {},
            isChecking: () {
              pollStarted.complete();
              return poll.future;
            },
            pollInterval: Duration.zero,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(swapHistoryCheckProvider.notifier);
    final running = notifier.check();
    await pollStarted.future;
    await notifier.cancel();
    poll.complete(false);
    await running;
    expect(container.read(swapHistoryCheckProvider), SwapHistoryCheck.paused);
  });
}
