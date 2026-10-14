import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/storage/app_secure_store.dart';
import 'package:zcash_wallet/src/core/storage/wallet_paths.dart';

class _UnreadableStorage extends FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw StateError('storage unavailable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final name in <String?>[null, '']) {
    test('a missing recorded wallet ($name) never generates a path', () async {
      FlutterSecureStorage.setMockInitialValues({kWalletDbNameKey: ?name});
      final store = AppSecureStore.testing(
        storage: const FlutterSecureStorage(),
      );
      var directoryReads = 0;
      final path = await getExistingWalletDbPath(
        secureStore: store,
        resolveSupportDirectory: () async {
          directoryReads++;
          return Directory('/unused');
        },
      );
      expect(path, isNull);
      expect(directoryReads, 0);
      expect(await store.readPlain(kWalletDbNameKey), name);
    });
  }

  test('the recorded path is used without creating wallet storage', () async {
    FlutterSecureStorage.setMockInitialValues({kWalletDbNameKey: 'wallet.db'});
    final store = AppSecureStore.testing(storage: const FlutterSecureStorage());
    final directory = await Directory.systemTemp.createTemp('wallet-path-');
    addTearDown(() => directory.delete(recursive: true));
    final path = await getExistingWalletDbPath(
      secureStore: store,
      resolveSupportDirectory: () async => directory,
    );
    expect(path, '${directory.path}${Platform.pathSeparator}wallet.db');
    expect(await directory.list().toList(), isEmpty);
    expect(await store.readPlain(kWalletDbNameKey), 'wallet.db');
  });

  test(
    'an unreadable recorded wallet never becomes an absent wallet',
    () async {
      final store = AppSecureStore.testing(storage: _UnreadableStorage());
      var directoryReads = 0;
      await expectLater(
        getExistingWalletDbPath(
          secureStore: store,
          resolveSupportDirectory: () async {
            directoryReads++;
            return Directory('/unused');
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(directoryReads, 0);
    },
  );

  group('findWalletDbsWithoutRecord', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('wallet-record-');
      addTearDown(() => directory.delete(recursive: true));
      for (final name in [
        'zcash_wallet_0123456789abcdef01234567.db',
        'zcash_wallet_0123456789abcdef01234567.db-wal',
        'zcash_wallet_0123456789abcdef01234567.db.voting',
        'shared_preferences.json',
      ]) {
        await File('${directory.path}/$name').writeAsString('data');
      }
      await Directory(
        '${directory.path}/zcash_wallet_0123456789abcdef01234567.db.tpir',
      ).create();
      await Directory('${directory.path}/zcash_wallet_dir.db').create();
    });

    test('lists wallet databases when no name is recorded', () async {
      final store = AppSecureStore.testing(
        storage: const FlutterSecureStorage(),
      );

      final paths = await findWalletDbsWithoutRecord(
        secureStore: store,
        resolveSupportDirectory: () async => directory,
      );

      expect(paths, [
        '${directory.path}${Platform.pathSeparator}'
            'zcash_wallet_0123456789abcdef01234567.db',
      ]);
    });

    test('reports nothing while a wallet name is recorded', () async {
      FlutterSecureStorage.setMockInitialValues({
        kWalletDbNameKey: 'zcash_wallet_fedcba9876543210fedcba98.db',
      });
      final store = AppSecureStore.testing(
        storage: const FlutterSecureStorage(),
      );

      final paths = await findWalletDbsWithoutRecord(
        secureStore: store,
        resolveSupportDirectory: () async => directory,
      );

      expect(paths, isEmpty);
    });
  });
}
