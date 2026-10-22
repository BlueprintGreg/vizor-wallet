import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/app_secure_store.dart';
import '../core/storage/wallet_paths.dart';
import '../rust/api/pir_config.dart' as rust;
import '../services/wallet_pir/wallet_pir_config.dart';
import 'account_provider.dart';
import 'sync_provider.dart';

const kWalletPirConfigSourceKey = 'zcash_wallet_pir_config_source';
const kWalletPirConfigCacheKeyPrefix = 'zcash_wallet_pir_config_v1_';

/// Plain (non-secret) persistence of the config source and, per source, the
/// last good snapshot and the saved selection. Selections carry their scope
/// (source pin, network, attestation policy), and Rust ignores one from
/// another scope, so a source's choice can never leak into another source.
abstract interface class WalletPirConfigStore {
  Future<String?> readSource();
  Future<void> writeSource(String? source);
  Future<WalletPirCachedConfig?> readCached(String network, String source);
  Future<void> writeCached(
    String network,
    String source,
    WalletPirCachedConfig cached,
  );
}

class WalletPirCachedConfig {
  const WalletPirCachedConfig({this.snapshotJson, this.selectionJson});

  final String? snapshotJson;
  final String? selectionJson;

  WalletPirCachedConfig copyWith({
    String? snapshotJson,
    String? selectionJson,
  }) => WalletPirCachedConfig(
    snapshotJson: snapshotJson ?? this.snapshotJson,
    selectionJson: selectionJson ?? this.selectionJson,
  );

  Map<String, Object?> toJson() => {
    'snapshot': snapshotJson,
    'selection': selectionJson,
  };

  static WalletPirCachedConfig fromJson(Object? json) {
    if (json is! Map) return const WalletPirCachedConfig();
    return WalletPirCachedConfig(
      snapshotJson: json['snapshot'] as String?,
      selectionJson: json['selection'] as String?,
    );
  }
}

class AppSecureStoreWalletPirConfigStore implements WalletPirConfigStore {
  const AppSecureStoreWalletPirConfigStore(this._store);

  final AppSecureStore _store;

  @override
  Future<String?> readSource() => _store.readPlain(kWalletPirConfigSourceKey);

  @override
  Future<void> writeSource(String? source) => source == null
      ? _store.delete(kWalletPirConfigSourceKey)
      : _store.writePlain(kWalletPirConfigSourceKey, source);

  @override
  Future<WalletPirCachedConfig?> readCached(
    String network,
    String source,
  ) async {
    final entries = await _readEntries(network);
    final entry = entries[source];
    return entry == null ? null : WalletPirCachedConfig.fromJson(entry);
  }

  @override
  Future<void> writeCached(
    String network,
    String source,
    WalletPirCachedConfig cached,
  ) async {
    final entries = await _readEntries(network);
    entries[source] = cached.toJson();
    await _store.writePlain(
      '$kWalletPirConfigCacheKeyPrefix$network',
      jsonEncode(entries),
    );
  }

  Future<Map<String, Object?>> _readEntries(String network) async {
    final raw = await _store.readPlain(
      '$kWalletPirConfigCacheKeyPrefix$network',
    );
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : {};
    } on FormatException {
      return {};
    }
  }
}

/// Makes `baseUrl` (or no server) the one all four private products use.
typedef WalletPirServerApplier = Future<void> Function(String? baseUrl);

/// Where the settings screen stands. Labels are display text; the base URL is
/// the identity.
@immutable
class WalletPirServerState {
  const WalletPirServerState({
    required this.source,
    required this.sourceIsDefault,
    this.config,
    this.refreshing = false,
    this.refreshError,
  });

  /// The pinned config source, or `null` when none is configured.
  final String? source;
  final bool sourceIsDefault;

  /// The last good config for [source]; kept when a refresh fails.
  final WalletPirConfigView? config;
  final bool refreshing;

  /// Why the latest refresh failed, if it did.
  final String? refreshError;

  List<WalletPirServerOption> get servers => config?.servers ?? const [];
  String? get selectedBaseUrl => config?.selectedBaseUrl;
  bool get needsSelection =>
      config?.selectionState == WalletPirSelectionState.selectionRequired;
  bool get hasNoServers =>
      config?.selectionState == WalletPirSelectionState.noServers;

  WalletPirServerOption? get selectedServer {
    final base = selectedBaseUrl;
    if (base == null) return null;
    for (final server in servers) {
      if (server.baseUrl == base) return server;
    }
    return null;
  }

  WalletPirServerState copyWith({
    WalletPirConfigView? config,
    bool? refreshing,
    String? refreshError,
    bool clearRefreshError = false,
  }) => WalletPirServerState(
    source: source,
    sourceIsDefault: sourceIsDefault,
    config: config ?? this.config,
    refreshing: refreshing ?? this.refreshing,
    refreshError: clearRefreshError ? null : refreshError ?? this.refreshError,
  );
}

final walletPirConfigStoreProvider = Provider<WalletPirConfigStore>(
  (ref) => AppSecureStoreWalletPirConfigStore(AppSecureStore.instance),
);

final walletPirConfigResolverProvider = Provider<WalletPirConfigResolver>(
  (ref) => const RustWalletPirConfigResolver(),
);

final walletPirConfigFetcherProvider = Provider<WalletPirConfigFetcher>(
  (ref) => RoutedWalletPirConfigFetcher(),
);

final walletPirDefaultSourceProvider = Provider<String?>(
  (ref) => defaultWalletPirConfigSource(),
);

final walletPirNetworkProvider = Provider<String>(
  (ref) => walletPirConfigNetworkName(),
);

/// Pauses sync, applies the server in Rust (which cancels the Receiver round
/// and forgets caches tied to the old server), then resumes sync so every
/// product session is rebuilt against the new base.
final walletPirServerApplierProvider = Provider<WalletPirServerApplier>((ref) {
  return (baseUrl) async {
    if (rust.selectedWalletPirServer() == baseUrl) return;
    final hasWallet =
        (ref.read(accountProvider).value?.accounts ?? const []).isNotEmpty;
    if (!hasWallet) {
      await rust.applyWalletPirServer(dbPath: null, baseUrl: baseUrl);
      return;
    }
    final sync = ref.read(syncProvider.notifier);
    final pause = await sync.pauseForWalletMutation();
    try {
      await rust.applyWalletPirServer(
        dbPath: await getWalletDbPath(),
        baseUrl: baseUrl,
      );
    } finally {
      sync.resumeAfterWalletMutation(pause, forceRestart: true);
    }
  };
});

class WalletPirServerNotifier extends AsyncNotifier<WalletPirServerState> {
  /// Bumped by every source change and refresh. Work that awaited checks it
  /// before persisting or applying, so a superseded refresh, or one for a
  /// source the user has since replaced, cannot restore its config.
  int _generation = 0;
  AppLifecycleListener? _lifecycle;

  WalletPirConfigStore get _store => ref.read(walletPirConfigStoreProvider);
  WalletPirConfigResolver get _resolver =>
      ref.read(walletPirConfigResolverProvider);
  String get _network => ref.read(walletPirNetworkProvider);

  @override
  Future<WalletPirServerState> build() async {
    _lifecycle?.dispose();
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(refresh()));
    ref.onDispose(() {
      _generation++;
      _lifecycle?.dispose();
      _lifecycle = null;
    });
    final generation = ++_generation;
    final initial = await _loadCached(await _store.readSource());
    if (generation == _generation) {
      await _apply(initial.config, generation);
      if (initial.source != null) {
        scheduleMicrotask(() => unawaited(refresh()));
      }
    }
    return initial;
  }

  /// Fetches the source's documents again. A failure keeps the last good
  /// config and shows why.
  Future<void> refresh() async {
    final current = state.value;
    final source = current?.source;
    if (current == null || source == null) return;
    final generation = ++_generation;
    state = AsyncData(current.copyWith(refreshing: true));
    try {
      final cached = await _store.readCached(_network, source);
      final view = await fetchWalletPirConfig(
        fetcher: ref.read(walletPirConfigFetcherProvider),
        resolver: _resolver,
        source: source,
        network: _network,
        savedSelectionJson: cached?.selectionJson,
      );
      if (generation != _generation) return;
      await _store.writeCached(
        _network,
        source,
        (cached ?? const WalletPirCachedConfig()).copyWith(
          snapshotJson: view.snapshotJson,
          // A removed selection stays saved, so a restart asks again.
          selectionJson: view.selectionJson,
        ),
      );
      if (generation != _generation) return;
      await _apply(view, generation);
      if (generation != _generation) return;
      state = AsyncData(
        current.copyWith(
          config: view,
          refreshing: false,
          clearRefreshError: true,
        ),
      );
    } catch (error) {
      if (generation != _generation) return;
      state = AsyncData(
        (state.value ?? current).copyWith(
          refreshing: false,
          refreshError: '$error',
        ),
      );
    }
  }

  /// The user's explicit choice of an offered server.
  Future<void> selectServer(String baseUrl) async {
    final current = state.value;
    final source = current?.source;
    final config = current?.config;
    if (current == null || source == null || config == null) return;
    final generation = ++_generation;
    final selectionJson = _resolver.select(
      source: source,
      network: _network,
      snapshotJson: config.snapshotJson,
      baseUrl: baseUrl,
    );
    final view = _resolver.revalidate(
      source: source,
      network: _network,
      snapshotJson: config.snapshotJson,
      savedSelectionJson: selectionJson,
    );
    final cached = await _store.readCached(_network, source);
    if (generation != _generation) return;
    await _store.writeCached(
      _network,
      source,
      (cached ?? const WalletPirCachedConfig()).copyWith(
        snapshotJson: config.snapshotJson,
        selectionJson: selectionJson,
      ),
    );
    if (generation != _generation) return;
    await _apply(view, generation);
    if (generation != _generation) return;
    state = AsyncData(current.copyWith(config: view));
  }

  /// Switches to `source`, or back to the default with `null`. The old
  /// source's server stops being used at once; its cached config and choice
  /// stay saved under that source only.
  Future<void> setSource(String? source) async {
    final trimmed = source?.trim();
    final generation = ++_generation;
    await _store.writeSource(
      trimmed == null || trimmed.isEmpty ? null : trimmed,
    );
    if (generation != _generation) return;
    // No server until the new source's config is accepted.
    await ref.read(walletPirServerApplierProvider)(null);
    if (generation != _generation) return;
    final next = await _loadCached(trimmed);
    if (generation != _generation) return;
    state = AsyncData(next);
    await _apply(next.config, generation);
    await refresh();
  }

  Future<WalletPirServerState> _loadCached(String? savedSource) async {
    final defaultSource = ref.read(walletPirDefaultSourceProvider);
    final source = savedSource ?? defaultSource;
    final base = WalletPirServerState(
      source: source,
      sourceIsDefault: savedSource == null,
    );
    if (source == null) return base;
    final cached = await _store.readCached(_network, source);
    final snapshot = cached?.snapshotJson;
    if (snapshot == null) return base;
    try {
      return WalletPirServerState(
        source: source,
        sourceIsDefault: savedSource == null,
        config: _resolver.revalidate(
          source: source,
          network: _network,
          snapshotJson: snapshot,
          savedSelectionJson: cached?.selectionJson,
        ),
      );
    } catch (error) {
      // A cached config that no longer passes is not used.
      return base;
    }
  }

  Future<void> _apply(WalletPirConfigView? config, int generation) async {
    if (generation != _generation) return;
    await ref.read(walletPirServerApplierProvider)(config?.selectedBaseUrl);
  }
}

final walletPirServerProvider =
    AsyncNotifierProvider<WalletPirServerNotifier, WalletPirServerState>(
      WalletPirServerNotifier.new,
    );

/// Keeps [walletPirServerProvider] alive from app start, so the saved server
/// is applied and refreshed without the app root rebuilding on its changes.
final walletPirServerActivatorProvider = Provider<void>((ref) {
  ref.listen(walletPirServerProvider, (_, _) {});
});
