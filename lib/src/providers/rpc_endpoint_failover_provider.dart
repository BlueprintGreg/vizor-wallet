import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../main.dart' show log;
import '../core/config/rpc_endpoint_config.dart';
import '../rust/api/wallet.dart' as rust_wallet;
import 'rpc_endpoint_provider.dart';

typedef RpcEndpointChainNameGetter =
    Future<String> Function(String lightwalletdUrl);
typedef RpcEndpointLatestBlockHeightGetter =
    Future<BigInt> Function(String lightwalletdUrl, String network);
typedef RpcEndpointEstimatedHeightGetter =
    Future<BigInt> Function(String lightwalletdUrl, String network);
typedef RpcEndpointNu7ActivationHeightGetter = BigInt? Function(String network);

enum RpcEndpointFailoverEventKind { switchedToFallback, switchedToPrimary }

class RpcEndpointFailoverEvent {
  const RpcEndpointFailoverEvent({
    required this.sequence,
    required this.kind,
    required this.message,
    required this.endpoint,
  });

  final int sequence;
  final RpcEndpointFailoverEventKind kind;
  final String message;
  final RpcEndpointConfig endpoint;
}

class RpcEndpointFailoverSettings {
  const RpcEndpointFailoverSettings({
    this.primaryProbeInterval = const Duration(seconds: 60),
    this.primaryFailureThreshold = 1,
    this.slowHeightWindow = const Duration(minutes: 5),
    this.minHeightIncreaseInSlowWindow = 2,
    this.slowFallbackLeadBlocks = 2,
    this.primaryReturnLagToleranceBlocks = 1,
    this.staleTipCheckInterval = const Duration(seconds: 60),
    this.staleTipLagBlocks = 12,
    this.staleTipFalseAlarmBackoff = const Duration(minutes: 30),
  });

  final Duration primaryProbeInterval;
  final int primaryFailureThreshold;
  final Duration slowHeightWindow;
  final int minHeightIncreaseInSlowWindow;
  final int slowFallbackLeadBlocks;
  final int primaryReturnLagToleranceBlocks;

  /// How often the current endpoint's tip is compared with its node's own
  /// wall-clock height estimate.
  final Duration staleTipCheckInterval;

  /// Lag behind that estimate at which the tip counts as stalled: 15 minutes
  /// of 75-second blocks.
  final int staleTipLagBlocks;

  /// Pause after a fallback disagreed with a stall verdict, so an endpoint
  /// with a poor estimate does not query other operators every minute.
  final Duration staleTipFalseAlarmBackoff;
}

class RpcEndpointHealth {
  const RpcEndpointHealth({required this.chainName, required this.height});

  final String chainName;
  final BigInt height;
}

class RpcEndpointFailoverState {
  const RpcEndpointFailoverState({
    required this.primary,
    required this.current,
    required this.fallbackCandidates,
    this.primaryFailureCount = 0,
    this.lastFailure,
    this.switchedAt,
    this.lastPrimaryProbeAt,
    this.lastEvent,
    this.heightWindowStartedAt,
    this.heightWindowStartHeight,
    this.lastObservedHeight,
    this.lastObservedAt,
    this.nextStaleTipCheckAt,
  });

  final RpcEndpointConfig primary;
  final RpcEndpointConfig current;
  final List<RpcEndpointConfig> fallbackCandidates;
  final int primaryFailureCount;
  final String? lastFailure;
  final DateTime? switchedAt;
  final DateTime? lastPrimaryProbeAt;
  final RpcEndpointFailoverEvent? lastEvent;
  final DateTime? heightWindowStartedAt;
  final BigInt? heightWindowStartHeight;
  final BigInt? lastObservedHeight;
  final DateTime? lastObservedAt;
  final DateTime? nextStaleTipCheckAt;

  RpcEndpointConfig? get fallback =>
      fallbackCandidates.isEmpty ? null : fallbackCandidates.first;

  bool get isUsingFallback =>
      current.normalizedLightwalletdUrl != primary.normalizedLightwalletdUrl;

  RpcEndpointFailoverState copyWith({
    RpcEndpointConfig? primary,
    RpcEndpointConfig? current,
    List<RpcEndpointConfig>? fallbackCandidates,
    int? primaryFailureCount,
    String? lastFailure,
    bool clearLastFailure = false,
    DateTime? switchedAt,
    bool clearSwitchedAt = false,
    DateTime? lastPrimaryProbeAt,
    RpcEndpointFailoverEvent? lastEvent,
    DateTime? heightWindowStartedAt,
    bool clearHeightWindowStartedAt = false,
    BigInt? heightWindowStartHeight,
    bool clearHeightWindowStartHeight = false,
    BigInt? lastObservedHeight,
    bool clearLastObservedHeight = false,
    DateTime? lastObservedAt,
    bool clearLastObservedAt = false,
    DateTime? nextStaleTipCheckAt,
  }) {
    return RpcEndpointFailoverState(
      primary: primary ?? this.primary,
      current: current ?? this.current,
      fallbackCandidates: fallbackCandidates ?? this.fallbackCandidates,
      primaryFailureCount: primaryFailureCount ?? this.primaryFailureCount,
      lastFailure: clearLastFailure ? null : lastFailure ?? this.lastFailure,
      switchedAt: clearSwitchedAt ? null : switchedAt ?? this.switchedAt,
      lastPrimaryProbeAt: lastPrimaryProbeAt ?? this.lastPrimaryProbeAt,
      lastEvent: lastEvent ?? this.lastEvent,
      heightWindowStartedAt: clearHeightWindowStartedAt
          ? null
          : heightWindowStartedAt ?? this.heightWindowStartedAt,
      heightWindowStartHeight: clearHeightWindowStartHeight
          ? null
          : heightWindowStartHeight ?? this.heightWindowStartHeight,
      lastObservedHeight: clearLastObservedHeight
          ? null
          : lastObservedHeight ?? this.lastObservedHeight,
      lastObservedAt: clearLastObservedAt
          ? null
          : lastObservedAt ?? this.lastObservedAt,
      nextStaleTipCheckAt: nextStaleTipCheckAt ?? this.nextStaleTipCheckAt,
    );
  }
}

class _FallbackHealth {
  const _FallbackHealth({required this.endpoint, required this.health});

  final RpcEndpointConfig endpoint;
  final RpcEndpointHealth health;
}

class _FailoverContext {
  const _FailoverContext({
    required this.generation,
    required this.primary,
    required this.current,
    required this.fallbackCandidates,
  });

  final int generation;
  final RpcEndpointConfig primary;
  final RpcEndpointConfig current;
  final List<RpcEndpointConfig> fallbackCandidates;
}

Future<RpcEndpointHealth> checkRpcEndpointHealth({
  required RpcEndpointConfig endpoint,
  required RpcEndpointChainNameGetter getChainName,
  required RpcEndpointLatestBlockHeightGetter getLatestBlockHeight,
}) async {
  final chainName = await getChainName(endpoint.normalizedLightwalletdUrl);
  if (chainName != endpoint.networkName) {
    throw FormatException(
      'Endpoint is for $chainName, but this wallet uses ${endpoint.networkName}.',
    );
  }
  final height = await getLatestBlockHeight(
    endpoint.normalizedLightwalletdUrl,
    endpoint.networkName,
  );
  return RpcEndpointHealth(chainName: chainName, height: height);
}

bool shouldFallbackFromLightwalletdError(Object error) {
  final message = error.toString().toLowerCase();
  if (message.contains('wrong network') ||
      message.contains('endpoint is for') ||
      message.contains('database is locked') ||
      message.contains('proposal not found') ||
      message.contains('send flow mismatch') ||
      message.contains('insufficient') ||
      message.contains('invalid amount') ||
      message.contains('invalid address')) {
    return false;
  }

  return message.contains('network:') ||
      message.contains('deadlineexceeded') ||
      message.contains('deadline exceeded') ||
      message.contains('unavailable') ||
      message.contains('timed out') ||
      message.contains('timeout') ||
      message.contains('grpc connect failed') ||
      message.contains('connect failed') ||
      message.contains('connection refused') ||
      message.contains('connection reset') ||
      message.contains('connection closed') ||
      message.contains('dns') ||
      message.contains('failed to lookup address') ||
      message.contains('tls error') ||
      message.contains('transport error') ||
      message.contains('http2') ||
      message.contains('socket');
}

final rpcEndpointFailoverSettingsProvider =
    Provider<RpcEndpointFailoverSettings>(
      (_) => const RpcEndpointFailoverSettings(),
    );

final rpcEndpointFailoverClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);

final rpcEndpointFailoverChainNameGetterProvider =
    Provider<RpcEndpointChainNameGetter>(
      (_) =>
          (lightwalletdUrl) => rust_wallet.getLightwalletdChainName(
            lightwalletdUrl: lightwalletdUrl,
          ),
    );

final rpcEndpointFailoverLatestBlockHeightGetterProvider =
    Provider<RpcEndpointLatestBlockHeightGetter>(
      (_) =>
          (lightwalletdUrl, network) => rust_wallet.getLatestBlockHeight(
            lightwalletdUrl: lightwalletdUrl,
            network: network,
          ),
    );

/// The endpoint node's own estimate of the chain height from the wall clock,
/// or zero when its lightwalletd does not report one.
final rpcEndpointFailoverEstimatedHeightGetterProvider =
    Provider<RpcEndpointEstimatedHeightGetter>(
      (_) =>
          (lightwalletdUrl, network) async =>
              (await rust_wallet.getChainUpgradeStatus(
                lightwalletdUrl: lightwalletdUrl,
                network: network,
              )).lightwalletdEstimatedHeight,
    );

final rpcEndpointFailoverNu7ActivationHeightGetterProvider =
    Provider<RpcEndpointNu7ActivationHeightGetter>(
      (_) =>
          (network) => rust_wallet
              .getBlockSpacingSchedule(network: network)
              .nu7ActivationHeight,
    );

class RpcEndpointFailoverNotifier extends Notifier<RpcEndpointFailoverState> {
  int _eventSequence = 0;
  int _configGeneration = 0;

  @override
  RpcEndpointFailoverState build() {
    _configGeneration += 1;
    final primary = ref.watch(rpcEndpointProvider);
    return RpcEndpointFailoverState(
      primary: primary,
      current: primary,
      fallbackCandidates: fallbackRpcEndpointCandidatesFor(primary),
    );
  }

  RpcEndpointConfig get currentEndpoint => state.current;

  Future<BigInt> getLatestBlockHeight() async {
    const operation = 'latest block height';
    await maybeProbePrimary();
    final endpoint = state.current;
    final getLatestBlockHeight = ref.read(
      rpcEndpointFailoverLatestBlockHeightGetterProvider,
    );

    try {
      final height = await getLatestBlockHeight(
        endpoint.normalizedLightwalletdUrl,
        endpoint.networkName,
      );
      _recordEndpointSuccess(endpoint);
      final staleFallback = await _maybeSwitchFromStaleTip(
        endpoint,
        height,
        operation: operation,
      );
      if (staleFallback != null) return staleFallback.height;
      final slowFallback = await _maybeSwitchFromSlowHeight(
        endpoint,
        height,
        operation: operation,
      );
      return slowFallback?.height ?? height;
    } catch (e, st) {
      final switched = await switchToFallbackFor(
        e,
        endpoint: endpoint,
        operation: operation,
      );
      if (!switched) {
        Error.throwWithStackTrace(e, st);
      }

      final fallbackEndpoint = state.current;
      try {
        final fallbackHeight = await getLatestBlockHeight(
          fallbackEndpoint.normalizedLightwalletdUrl,
          fallbackEndpoint.networkName,
        );
        _recordEndpointSuccess(fallbackEndpoint);
        _resetHeightWindow(fallbackEndpoint, fallbackHeight);
        return fallbackHeight;
      } catch (fallbackError, fallbackStack) {
        Error.throwWithStackTrace(fallbackError, fallbackStack);
      }
    }
  }

  Future<T> runWithEndpointFallback<T>({
    required String operation,
    required Future<T> Function(RpcEndpointConfig endpoint) action,
    bool allowFallback = true,
    bool Function(Object error) shouldFallback =
        shouldFallbackFromLightwalletdError,
  }) async {
    await maybeProbePrimary();
    final endpoint = state.current;
    try {
      final result = await action(endpoint);
      _recordEndpointSuccess(endpoint);
      return result;
    } catch (e, st) {
      final switched = allowFallback
          ? await switchToFallbackFor(
              e,
              endpoint: endpoint,
              operation: operation,
              shouldFallback: shouldFallback,
            )
          : false;
      if (!switched) {
        Error.throwWithStackTrace(e, st);
      }

      final fallbackEndpoint = state.current;
      try {
        final result = await action(fallbackEndpoint);
        _recordEndpointSuccess(fallbackEndpoint);
        return result;
      } catch (fallbackError, fallbackStack) {
        Error.throwWithStackTrace(fallbackError, fallbackStack);
      }
    }
  }

  Future<bool> switchToFallbackFor(
    Object error, {
    RpcEndpointConfig? endpoint,
    required String operation,
    bool Function(Object error) shouldFallback =
        shouldFallbackFromLightwalletdError,
  }) async {
    final attempted = endpoint ?? state.current;
    final context = _captureContext();
    if (!_sameEndpointIdentity(attempted, context.current) ||
        !shouldFallback(error)) {
      return false;
    }

    final attemptedUrl = attempted.normalizedLightwalletdUrl;
    final failedPrimary = _sameEndpointIdentity(attempted, context.primary);
    final nextFailureCount = failedPrimary
        ? state.primaryFailureCount + 1
        : state.primaryFailureCount;
    final settings = ref.read(rpcEndpointFailoverSettingsProvider);
    if (failedPrimary && nextFailureCount < settings.primaryFailureThreshold) {
      state = state.copyWith(
        primaryFailureCount: nextFailureCount,
        lastFailure: error.toString(),
      );
      return false;
    }

    final fallbackCandidates = context.fallbackCandidates
        .where(
          (candidate) => candidate.normalizedLightwalletdUrl != attemptedUrl,
        )
        .toList(growable: false);
    if (fallbackCandidates.isEmpty) {
      log(
        'RpcEndpointFailover: no fallback endpoint for '
        '${attempted.hostPort} after $operation failure: $error',
      );
      state = state.copyWith(
        primaryFailureCount: nextFailureCount,
        lastFailure: error.toString(),
      );
      return false;
    }

    RpcEndpointConfig? fallback;
    RpcEndpointHealth? fallbackHealth;
    Object? lastFallbackError;
    for (final candidate in fallbackCandidates) {
      try {
        final health = await _checkHealth(candidate);
        fallback = candidate;
        fallbackHealth = health;
        break;
      } catch (fallbackError) {
        lastFallbackError = fallbackError;
        log(
          'RpcEndpointFailover: fallback ${candidate.hostPort} failed health '
          'check after $operation failure: $fallbackError',
        );
      }
    }

    if (fallback == null) {
      if (!_isCurrentContext(context)) return false;
      log(
        'RpcEndpointFailover: all fallback endpoints failed health checks '
        'after $operation failure: $lastFallbackError',
      );
      state = state.copyWith(
        primaryFailureCount: nextFailureCount,
        lastFailure: error.toString(),
      );
      return false;
    }

    if (!_isCurrentContext(context)) {
      log(
        'RpcEndpointFailover: ignored stale fallback result for '
        '${attempted.hostPort} after endpoint settings changed',
      );
      return false;
    }

    final selectedFallbackHealth = fallbackHealth!;
    final now = ref.read(rpcEndpointFailoverClockProvider)();
    final event = RpcEndpointFailoverEvent(
      sequence: ++_eventSequence,
      kind: RpcEndpointFailoverEventKind.switchedToFallback,
      message: 'Selected endpoint is unstable. Switched to fallback endpoint.',
      endpoint: fallback,
    );
    log(
      'RpcEndpointFailover: switched ${attempted.hostPort} -> '
      '${fallback.hostPort} after $operation failure: $error',
    );
    state = state.copyWith(
      current: fallback,
      primaryFailureCount: nextFailureCount,
      lastFailure: error.toString(),
      switchedAt: now,
      lastPrimaryProbeAt: failedPrimary ? now : state.lastPrimaryProbeAt,
      lastEvent: event,
      heightWindowStartedAt: now,
      heightWindowStartHeight: selectedFallbackHealth.height,
      lastObservedHeight: selectedFallbackHealth.height,
      lastObservedAt: now,
    );
    return true;
  }

  Future<bool> maybeProbePrimary({bool force = false}) async {
    if (!state.isUsingFallback) return false;

    final context = _captureContext();
    final primary = context.primary;
    final currentEndpoint = context.current;
    final now = ref.read(rpcEndpointFailoverClockProvider)();
    final settings = ref.read(rpcEndpointFailoverSettingsProvider);
    final lastProbe = state.lastPrimaryProbeAt;
    if (!force &&
        lastProbe != null &&
        now.difference(lastProbe) < settings.primaryProbeInterval) {
      return false;
    }

    state = state.copyWith(lastPrimaryProbeAt: now);
    late final RpcEndpointHealth primaryHealth;
    try {
      primaryHealth = await _checkHealth(primary);
    } catch (e) {
      log('RpcEndpointFailover: primary ${primary.hostPort} probe failed: $e');
      return false;
    }
    if (!_isCurrentContext(context)) {
      log(
        'RpcEndpointFailover: ignored stale primary probe for '
        '${primary.hostPort} after endpoint settings changed',
      );
      return false;
    }

    var currentHeight = state.lastObservedHeight;
    try {
      final currentHealth = await _checkHealth(currentEndpoint);
      if (!_isCurrentContext(context)) {
        log(
          'RpcEndpointFailover: ignored stale fallback probe for '
          '${currentEndpoint.hostPort} after endpoint settings changed',
        );
        return false;
      }
      currentHeight = _maxHeight(currentHeight, currentHealth.height);
      state = state.copyWith(
        lastObservedHeight: currentHeight,
        lastObservedAt: now,
      );
    } catch (e) {
      if (!_isCurrentContext(context)) return false;
      log(
        'RpcEndpointFailover: current fallback ${currentEndpoint.hostPort} '
        'probe failed while checking primary recovery: $e',
      );
    }

    final tolerance = BigInt.from(
      ref
          .read(rpcEndpointFailoverSettingsProvider)
          .primaryReturnLagToleranceBlocks,
    );
    if (currentHeight != null &&
        primaryHealth.height + tolerance < currentHeight) {
      log(
        'RpcEndpointFailover: primary ${primary.hostPort} probe lagging '
        'at height ${primaryHealth.height}; current height is $currentHeight',
      );
      return false;
    }
    if (!_isCurrentContext(context)) return false;

    final event = RpcEndpointFailoverEvent(
      sequence: ++_eventSequence,
      kind: RpcEndpointFailoverEventKind.switchedToPrimary,
      message: 'Selected endpoint recovered. Switched back.',
      endpoint: primary,
    );
    log(
      'RpcEndpointFailover: primary ${primary.hostPort} recovered; '
      'leaving fallback ${currentEndpoint.hostPort}',
    );
    state = state.copyWith(
      current: primary,
      primaryFailureCount: 0,
      clearLastFailure: true,
      clearSwitchedAt: true,
      lastPrimaryProbeAt: now,
      lastEvent: event,
      heightWindowStartedAt: now,
      heightWindowStartHeight: primaryHealth.height,
      lastObservedHeight: primaryHealth.height,
      lastObservedAt: now,
    );
    return true;
  }

  Future<RpcEndpointHealth?> _maybeSwitchFromSlowHeight(
    RpcEndpointConfig endpoint,
    BigInt height, {
    required String operation,
  }) async {
    if (!_isCurrentEndpoint(endpoint)) return null;

    final context = _captureContext();
    final now = ref.read(rpcEndpointFailoverClockProvider)();
    final windowStartedAt = state.heightWindowStartedAt;
    final windowStartHeight = state.heightWindowStartHeight;
    if (windowStartedAt == null ||
        windowStartHeight == null ||
        height < windowStartHeight) {
      _resetHeightWindow(endpoint, height, now: now);
      return null;
    }

    state = state.copyWith(lastObservedHeight: height, lastObservedAt: now);

    final settings = ref.read(rpcEndpointFailoverSettingsProvider);
    if (now.difference(windowStartedAt) < settings.slowHeightWindow) {
      return null;
    }

    final heightIncrease = height - windowStartHeight;
    if (heightIncrease >= BigInt.from(settings.minHeightIncreaseInSlowWindow)) {
      _resetHeightWindow(endpoint, height, now: now);
      return null;
    }

    final fallback = await _findFallbackAheadOf(
      endpoint,
      candidates: context.fallbackCandidates,
      currentHeight: height,
      operation: operation,
    );
    if (fallback == null) {
      if (!_isCurrentContext(context)) return null;
      log(
        'RpcEndpointFailover: ${endpoint.hostPort} height increased by '
        '$heightIncrease blocks in ${settings.slowHeightWindow.inSeconds}s, '
        'but no fallback endpoint is ahead enough; keeping current endpoint',
      );
      _resetHeightWindow(endpoint, height, now: now);
      return null;
    }

    if (!_isCurrentContext(context)) {
      log(
        'RpcEndpointFailover: ignored stale slow-height fallback for '
        '${endpoint.hostPort} after endpoint settings changed',
      );
      return null;
    }

    log(
      'RpcEndpointFailover: switched ${endpoint.hostPort} -> '
      '${fallback.endpoint.hostPort} because height only increased '
      'by $heightIncrease blocks in ${settings.slowHeightWindow.inSeconds}s '
      'during $operation and fallback is at height ${fallback.health.height}',
    );
    _switchToFallbackAhead(
      endpoint,
      fallback,
      context: context,
      now: now,
      failure:
          'Endpoint height increased by $heightIncrease blocks in '
          '${settings.slowHeightWindow.inSeconds}s.',
    );
    return fallback.health;
  }

  /// Leaves an endpoint whose node has stopped receiving blocks without
  /// waiting out the slow-height window, which restarts on every launch.
  /// The check asks only the current endpoint; fallbacks are contacted once
  /// its tip looks stalled.
  Future<RpcEndpointHealth?> _maybeSwitchFromStaleTip(
    RpcEndpointConfig endpoint,
    BigInt height, {
    required String operation,
  }) async {
    if (!_isCurrentEndpoint(endpoint)) return null;
    final context = _captureContext();
    if (context.fallbackCandidates.isEmpty) return null;

    final settings = ref.read(rpcEndpointFailoverSettingsProvider);
    final now = ref.read(rpcEndpointFailoverClockProvider)();
    final nextCheck = state.nextStaleTipCheckAt;
    if (nextCheck != null && now.isBefore(nextCheck)) return null;
    state = state.copyWith(
      nextStaleTipCheckAt: now.add(settings.staleTipCheckInterval),
    );

    final stalled = await _tipLooksStalled(endpoint, height, settings);
    if (stalled == null || !_isCurrentContext(context)) return null;

    // A healthy fallback at the same height overrules the verdict. Ask
    // another operator first: one operator's hosts tend to stall together.
    final operator = _operatorDomain(endpoint);
    final fallback = await _findFallbackAheadOf(
      endpoint,
      candidates: [
        ...context.fallbackCandidates.where(
          (candidate) => _operatorDomain(candidate) != operator,
        ),
        ...context.fallbackCandidates.where(
          (candidate) => _operatorDomain(candidate) == operator,
        ),
      ],
      currentHeight: height,
      operation: operation,
      stopAtFirstHealthy: true,
    );
    if (!_isCurrentContext(context)) return null;
    if (fallback == null) {
      log(
        'RpcEndpointFailover: ${endpoint.hostPort} looks stalled '
        '(${stalled.reason}), but no fallback endpoint is ahead enough; '
        'keeping current endpoint',
      );
      // A healthy chain also waits there for its activation block, which is
      // due within minutes, so that verdict is checked again next interval.
      if (!stalled.atActivation) {
        state = state.copyWith(
          nextStaleTipCheckAt: now.add(settings.staleTipFalseAlarmBackoff),
        );
      }
      return null;
    }

    log(
      'RpcEndpointFailover: switched ${endpoint.hostPort} -> '
      '${fallback.endpoint.hostPort} during $operation because '
      '${stalled.reason}; fallback is at height ${fallback.health.height}',
    );
    _switchToFallbackAhead(
      endpoint,
      fallback,
      context: context,
      now: now,
      failure: 'Endpoint tip looks stalled: ${stalled.reason}.',
    );
    return fallback.health;
  }

  /// Why the tip at [height] looks stalled, or null when it does not.
  /// [atActivation] marks a tip one block before NU7 activation.
  Future<({String reason, bool atActivation})?> _tipLooksStalled(
    RpcEndpointConfig endpoint,
    BigInt height,
    RpcEndpointFailoverSettings settings,
  ) async {
    try {
      final estimated = await ref.read(
        rpcEndpointFailoverEstimatedHeightGetterProvider,
      )(endpoint.normalizedLightwalletdUrl, endpoint.networkName);
      // zcashd reports its own height once out of initial download, so an
      // estimate that is not ahead says nothing about a stall.
      if (estimated > height) {
        final lag = estimated - height;
        return lag > BigInt.from(settings.staleTipLagBlocks)
            ? (
                reason:
                    'its node estimates height $estimated, $lag blocks ahead',
                atActivation: false,
              )
            : null;
      }
    } catch (e) {
      log(
        'RpcEndpointFailover: ${endpoint.hostPort} height estimate '
        'unavailable: $e',
      );
    }
    // Without an estimate ahead of the tip, catch the commonest stall: a node
    // that missed a network upgrade stops one block before activation.
    try {
      final activation = ref.read(
        rpcEndpointFailoverNu7ActivationHeightGetterProvider,
      )(endpoint.networkName);
      return activation != null && height + BigInt.one == activation
          ? (
              reason: 'it stopped one block before NU7 activation',
              atActivation: true,
            )
          : null;
    } catch (e) {
      log('RpcEndpointFailover: NU7 activation height unavailable: $e');
      return null;
    }
  }

  void _switchToFallbackAhead(
    RpcEndpointConfig endpoint,
    _FallbackHealth fallback, {
    required _FailoverContext context,
    required DateTime now,
    required String failure,
  }) {
    final failedPrimary = _sameEndpointIdentity(endpoint, context.primary);
    final event = RpcEndpointFailoverEvent(
      sequence: ++_eventSequence,
      kind: RpcEndpointFailoverEventKind.switchedToFallback,
      message: 'Selected endpoint is unstable. Switched to fallback endpoint.',
      endpoint: fallback.endpoint,
    );
    state = state.copyWith(
      current: fallback.endpoint,
      lastFailure: failure,
      switchedAt: now,
      lastPrimaryProbeAt: failedPrimary ? now : state.lastPrimaryProbeAt,
      lastEvent: event,
      heightWindowStartedAt: now,
      heightWindowStartHeight: fallback.health.height,
      lastObservedHeight: fallback.health.height,
      lastObservedAt: now,
    );
  }

  Future<_FallbackHealth?> _findFallbackAheadOf(
    RpcEndpointConfig attempted, {
    required List<RpcEndpointConfig> candidates,
    required BigInt currentHeight,
    required String operation,
    bool stopAtFirstHealthy = false,
  }) async {
    final settings = ref.read(rpcEndpointFailoverSettingsProvider);
    final requiredHeight =
        currentHeight + BigInt.from(settings.slowFallbackLeadBlocks);
    final attemptedUrl = attempted.normalizedLightwalletdUrl;
    for (final candidate in candidates) {
      if (candidate.normalizedLightwalletdUrl == attemptedUrl) continue;
      try {
        final health = await _checkHealth(candidate);
        if (health.height >= requiredHeight) {
          return _FallbackHealth(endpoint: candidate, health: health);
        }
        log(
          'RpcEndpointFailover: fallback ${candidate.hostPort} is not ahead '
          'enough for slow $operation; height=${health.height}, '
          'required>=$requiredHeight',
        );
        if (stopAtFirstHealthy) return null;
      } catch (fallbackError) {
        log(
          'RpcEndpointFailover: fallback ${candidate.hostPort} failed health '
          'check during slow $operation fallback: $fallbackError',
        );
      }
    }
    return null;
  }

  void _resetHeightWindow(
    RpcEndpointConfig endpoint,
    BigInt height, {
    DateTime? now,
  }) {
    if (!_isCurrentEndpoint(endpoint)) return;
    final observedAt = now ?? ref.read(rpcEndpointFailoverClockProvider)();
    state = state.copyWith(
      heightWindowStartedAt: observedAt,
      heightWindowStartHeight: height,
      lastObservedHeight: height,
      lastObservedAt: observedAt,
    );
  }

  bool _isCurrentEndpoint(RpcEndpointConfig endpoint) {
    return _sameEndpointIdentity(endpoint, state.current);
  }

  _FailoverContext _captureContext() {
    return _FailoverContext(
      generation: _configGeneration,
      primary: state.primary,
      current: state.current,
      fallbackCandidates: state.fallbackCandidates,
    );
  }

  bool _isCurrentContext(_FailoverContext context) {
    return _configGeneration == context.generation &&
        _sameEndpointIdentity(state.primary, context.primary) &&
        _sameEndpointIdentity(state.current, context.current);
  }

  bool _sameEndpointIdentity(RpcEndpointConfig a, RpcEndpointConfig b) {
    return a.networkName == b.networkName &&
        a.effectivePresetId == b.effectivePresetId &&
        a.normalizedLightwalletdUrl == b.normalizedLightwalletdUrl;
  }

  /// The last two labels of the endpoint host, standing in for its operator.
  String _operatorDomain(RpcEndpointConfig endpoint) {
    final host = endpoint.hostPort.split(':').first.toLowerCase();
    final labels = host.split('.');
    return labels.length <= 2
        ? host
        : labels.sublist(labels.length - 2).join('.');
  }

  BigInt _maxHeight(BigInt? a, BigInt b) {
    if (a == null || b > a) return b;
    return a;
  }

  Future<RpcEndpointHealth> _checkHealth(RpcEndpointConfig endpoint) {
    return checkRpcEndpointHealth(
      endpoint: endpoint,
      getChainName: ref.read(rpcEndpointFailoverChainNameGetterProvider),
      getLatestBlockHeight: ref.read(
        rpcEndpointFailoverLatestBlockHeightGetterProvider,
      ),
    );
  }

  void _recordEndpointSuccess(RpcEndpointConfig endpoint) {
    if (endpoint.normalizedLightwalletdUrl ==
            state.primary.normalizedLightwalletdUrl &&
        state.primaryFailureCount != 0) {
      state = state.copyWith(primaryFailureCount: 0, clearLastFailure: true);
    }
  }
}

/// The endpoint row label: the server actually in use, which is a fallback
/// after the selected one stalled or failed.
String rpcEndpointInUseLabel(
  RpcEndpointConfig selected,
  RpcEndpointFailoverState failover,
) {
  if (!failover.isUsingFallback ||
      failover.primary.normalizedLightwalletdUrl !=
          selected.normalizedLightwalletdUrl) {
    return selected.hostPort;
  }
  return '${failover.current.hostPort} (fallback)';
}

final rpcEndpointFailoverProvider =
    NotifierProvider<RpcEndpointFailoverNotifier, RpcEndpointFailoverState>(
      RpcEndpointFailoverNotifier.new,
    );
