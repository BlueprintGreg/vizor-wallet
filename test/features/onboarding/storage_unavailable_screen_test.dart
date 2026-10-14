import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/onboarding/storage_unavailable_screen.dart';

import '../../figma_compare/figma_compare_font_loader.dart';

void main() {
  late List<String> calls;
  late Object? discardError;

  // Real fonts, so layout checks match the fixed desktop canvas.
  setUpAll(loadFigmaCompareFonts);

  setUp(() {
    calls = [];
    discardError = null;
  });

  /// Pumps the blocked startup screen for [failureKind] with recorded actions.
  Future<void> pumpScreen(
    WidgetTester tester,
    AppBootstrapFailureKind failureKind,
  ) async {
    tester.view.physicalSize = const Size(1080, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appBootstrapProvider.overrideWithValue(
            AppBootstrapState.blocked(
              failureKind: failureKind,
              failureMessage: 'blocked',
            ),
          ),
          appBootstrapRetryProvider.overrideWithValue(() async {
            calls.add('retry');
          }),
          discardWalletDbsWithoutRecordProvider.overrideWithValue(() async {
            calls.add('discard');
            if (discardError case final error?) throw error;
          }),
        ],
        child: MaterialApp(
          builder: (context, child) =>
              AppTheme(data: AppThemeData.light, child: child!),
          home: const StorageUnavailableScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder startOver() =>
      find.byKey(const ValueKey('storage_unavailable_start_over'));

  testWidgets('a lost wallet record offers to start over', (tester) async {
    await pumpScreen(tester, AppBootstrapFailureKind.walletRecordMissing);

    expect(find.text('Unable to open your wallet'), findsOneWidget);
    expect(startOver(), findsOneWidget);

    await tester.tap(startOver());
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('storage_unavailable_start_over_cancel')),
    );
    await tester.pumpAndSettle();
    expect(calls, isEmpty);

    await tester.tap(startOver());
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('storage_unavailable_start_over_confirm')),
    );
    await tester.pumpAndSettle();
    expect(calls, ['discard', 'retry']);
  });

  testWidgets('a failed delete keeps the screen and explains it', (
    tester,
  ) async {
    discardError = const FileSystemException('busy');
    await pumpScreen(tester, AppBootstrapFailureKind.walletRecordMissing);

    await tester.tap(startOver());
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('storage_unavailable_start_over_confirm')),
    );
    await tester.pumpAndSettle();

    expect(calls, ['discard']);
    expect(
      find.text('Vizor could not delete the old wallet data.'),
      findsOneWidget,
    );
  });

  testWidgets('a locked keyring does not offer to start over', (tester) async {
    await pumpScreen(tester, AppBootstrapFailureKind.secureStorageUnavailable);

    expect(startOver(), findsNothing);
  });
}
