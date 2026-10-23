import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/providers/enhance_pir_provider.dart';
import 'package:zcash_wallet/src/providers/swap_history_check_provider.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';
import 'package:zcash_wallet/src/rust/api/one_time_ivk.dart';

/// Counts the syncs a check asks for; these tests have no wallet.
class _Sync extends SyncNotifier {
  int starts = 0;
  @override
  Future<SyncState> build() async => SyncState();
  @override
  void continueSwapRecovery() => starts++;
}

/// NEAR swap privacy, on until a test turns it off.
class _Privacy extends NearSwapPrivacyNotifier {
  @override
  bool build() => true;

  /// Turns the setting off, as the Settings toggle does.
  void turnOff() => state = false;
}

/// The setting and a wallet with no saved recovery state, for every container.
List<Override> _wallet() => [
  nearSwapPrivacyProvider.overrideWith(_Privacy.new),
  swapRecoveryStatusReaderProvider.overrideWithValue(() async => null),
];

/// The wallet's recovery state, as the status call reports it.
SwapRecoveryStatus _status({bool checking = false, bool upgrade = false}) =>
    SwapRecoveryStatus(checkingHistory: checking, upgradeRequired: upgrade);

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
        ..._wallet(),
        syncProvider.overrideWith(() => sync),
        swapHistoryApiProvider.overrideWithValue(
          SwapHistoryApi(
            cancel: () async {},
            begin: (_) async {
              calls.add('begin');
              if (failBegin) throw StateError('wallet busy');
            },
            status: () async {
              calls.add('poll');
              return _status(
                checking: checking.isEmpty ? false : checking.removeAt(0),
              );
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
          ..._wallet(),
          syncProvider.overrideWith(() => sync),
          swapHistoryApiProvider.overrideWithValue(
            SwapHistoryApi(
              begin: (end) async => requested = end,
              cancel: () async {},
              status: () async => _status(),
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
        ..._wallet(),
        syncProvider.overrideWith(() => sync),
        swapHistoryApiProvider.overrideWithValue(
          SwapHistoryApi(
            begin: (_) => start.future,
            cancel: () async {
              cancelled = true;
            },
            status: () async => _status(),
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
    final poll = Completer<SwapRecoveryStatus>();
    final container = ProviderContainer(
      overrides: [
        ..._wallet(),
        syncProvider.overrideWith(_Sync.new),
        swapHistoryApiProvider.overrideWithValue(
          SwapHistoryApi(
            begin: (_) async {},
            cancel: () async {},
            status: () {
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
    poll.complete(_status());
    await running;
    expect(container.read(swapHistoryCheckProvider), SwapHistoryCheck.paused);
  });

  test(
    'stops with an update request when the service needs a newer app',
    () async {
      final sync = _Sync();
      final container = ProviderContainer(
        overrides: [
          ..._wallet(),
          syncProvider.overrideWith(() => sync),
          swapHistoryApiProvider.overrideWithValue(
            SwapHistoryApi(
              begin: (_) async {},
              cancel: () async {},
              status: () async => _status(checking: true, upgrade: true),
              pollInterval: Duration.zero,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(swapHistoryCheckProvider.notifier).check();
      expect(
        container.read(swapHistoryCheckProvider),
        SwapHistoryCheck.updateRequired,
      );
    },
  );

  test('a start the service refuses as outdated asks for an update', () async {
    final container = ProviderContainer(
      overrides: [
        ..._wallet(),
        syncProvider.overrideWith(_Sync.new),
        swapHistoryApiProvider.overrideWithValue(
          SwapHistoryApi(
            begin: (_) async => throw const ReceiveError(
              message: 'Update Vizor',
              kind: ReceiveErrorKind.upgradeRequired,
            ),
            cancel: () async {},
            status: () async => _status(),
            pollInterval: Duration.zero,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(swapHistoryCheckProvider.notifier).check();
    expect(
      container.read(swapHistoryCheckProvider),
      SwapHistoryCheck.updateRequired,
    );
  });

  test(
    'turning NEAR swap privacy off between polls pauses the check',
    () async {
      final polls = <Completer<SwapRecoveryStatus>>[];
      final container = ProviderContainer(
        overrides: [
          ..._wallet(),
          syncProvider.overrideWith(_Sync.new),
          swapHistoryApiProvider.overrideWithValue(
            SwapHistoryApi(
              begin: (_) async {},
              cancel: () async {},
              status: () {
                final poll = Completer<SwapRecoveryStatus>();
                polls.add(poll);
                return poll.future;
              },
              pollInterval: Duration.zero,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final running = container.read(swapHistoryCheckProvider.notifier).check();
      await pumpEventQueue();
      polls.single.complete(_status(checking: true));
      await pumpEventQueue();
      expect(polls, hasLength(2));

      (container.read(nearSwapPrivacyProvider.notifier) as _Privacy).turnOff();
      // A disabled account reports no unfinished check.
      polls.last.complete(_status());
      await running;
      expect(container.read(swapHistoryCheckProvider), SwapHistoryCheck.paused);
    },
  );

  test('a round that finds the service compatible ends a manual update '
      'request', () async {
    final container = ProviderContainer(
      overrides: [
        ..._wallet(),
        syncProvider.overrideWith(_Sync.new),
        swapHistoryApiProvider.overrideWithValue(
          SwapHistoryApi(
            begin: (_) async {},
            cancel: () async {},
            status: () async => _status(checking: true, upgrade: true),
            pollInterval: Duration.zero,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(swapHistoryCheckProvider.notifier).check();
    expect(
      container.read(swapHistoryCheckProvider),
      SwapHistoryCheck.updateRequired,
    );
    expect(container.read(swapRecoveryUpdateRequiredProvider), isTrue);

    container.read(swapRecoveryUpdateRequiredProvider.notifier).set(false);
    expect(container.read(swapHistoryCheckProvider), SwapHistoryCheck.idle);
  });
}
