import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/storage/app_secure_store.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/rust/api/wallet.dart' as rust_wallet;
import 'package:zcash_wallet/src/rust/frb_generated.dart';

const _orphanName = 'zcash_wallet_0123456789abcdef01234567.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.initMock(api: _BootstrapRustApi()));
  tearDownAll(RustLib.dispose);

  late Directory support;
  late File orphan;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // A keyring that returns nothing, as a passwordless gnome-keyring did.
    FlutterSecureStorage.setMockInitialValues({});
    AppSecureStore.instance.clearSessionPassword();
    support = await Directory.systemTemp.createTemp('vizor-wallet-record-');
    addTearDown(() => support.delete(recursive: true));
    orphan = File('${support.path}/$_orphanName');
    await orphan.writeAsString('wallet DB');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => support.path);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  });

  /// Runs startup against the mocked keyring as the given platform.
  Future<AppBootstrapState> bootstrapAs(TargetPlatform platform) {
    debugDefaultTargetPlatformOverride = platform;
    return loadAppBootstrap(
      secureStore: AppSecureStore.testing(
        storage: const FlutterSecureStorage(),
      ),
    );
  }

  test(
    'Linux blocks startup when the keyring lost its wallet record',
    () async {
      final result = await bootstrapAs(TargetPlatform.linux);

      expect(result.failureKind, AppBootstrapFailureKind.walletRecordMissing);
      expect(result.initialLocation, '/storage-unavailable');
      expect(
        await const FlutterSecureStorage().read(key: kWalletDbNameKey),
        isNull,
      );
      expect(orphan.existsSync(), isTrue);
    },
  );

  test('starting over deletes the old data and opens onboarding', () async {
    final sidecar = File('${orphan.path}-wal');
    await sidecar.writeAsString('wal');
    final companions = await Directory('${orphan.path}.tpir').create();
    final unrelated = File('${support.path}/shared_preferences.json');
    await unrelated.writeAsString('{}');
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;

    await discardWalletDbsWithoutRecord();
    final result = await bootstrapAs(TargetPlatform.linux);

    expect(orphan.existsSync(), isFalse);
    expect(sidecar.existsSync(), isFalse);
    expect(companions.existsSync(), isFalse);
    expect(unrelated.existsSync(), isTrue);
    expect(result.hasBlockingFailure, isFalse);
    expect(result.initialLocation, '/welcome');
  });

  test('a recorded wallet name keeps the normal startup path', () async {
    FlutterSecureStorage.setMockInitialValues({kWalletDbNameKey: _orphanName});

    final result = await bootstrapAs(TargetPlatform.linux);

    expect(result.hasBlockingFailure, isFalse);
    expect(orphan.existsSync(), isTrue);
  });

  test('other platforms keep their existing startup path', () async {
    final result = await bootstrapAs(TargetPlatform.macOS);

    expect(result.hasBlockingFailure, isFalse);
    expect(result.initialLocation, '/welcome');
  });
}

class _BootstrapRustApi implements RustLibApi {
  @override
  bool crateApiWalletWalletExists({required String dbPath}) =>
      File(dbPath).existsSync();

  @override
  Future<void> crateApiWalletEnsureWalletDbMigrated({
    required String dbPath,
    required String network,
  }) async {}

  @override
  Future<List<rust_wallet.AccountInfo>> crateApiWalletListAccounts({
    required String dbPath,
    required String network,
  }) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
