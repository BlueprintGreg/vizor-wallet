@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/figma_compare/figma_compare_app.dart';
import 'package:zcash_wallet/figma_compare/figma_compare_scenarios.dart';
import 'package:zcash_wallet/figma_compare/mobile_passcode_capture.dart';
import 'package:zcash_wallet/src/features/onboarding/mobile/passcode_widgets.dart';

import '../../figma_compare/figma_compare_font_loader.dart';
import 'package:zcash_wallet/src/providers/biometric_unlock_provider.dart';
import 'package:zcash_wallet/src/services/biometric_unlock.dart';

Widget _app(
  PasscodeCaptureScreen screen, {
  double scale = 1,
  double bottomInset = 0,
  BiometricUnlockState biometric = BiometricUnlockState.initial,
}) => FigmaCompareApp(
  scenario: FigmaCompareScenario(
    id: 'passcode-layout',
    description: 'Passcode layout regression',
    allowPointer: true,
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(scale),
        padding: EdgeInsets.only(bottom: bottomInset),
        viewPadding: EdgeInsets.only(bottom: bottomInset),
      ),
      child: MobilePasscodeCapture(screen: screen, biometric: biometric),
    ),
  ),
  themeMode: ThemeMode.light,
  captureBoundaryKey: GlobalKey(),
);

void main() {
  setUpAll(loadFigmaCompareFonts);
  for (final screen in PasscodeCaptureScreen.values) {
    for (final scale in [1.0, 1.5, 2.0]) {
      for (final size in [
        const Size(951, 669),
        const Size(951, 560),
        const Size(568, 320),
      ]) {
        testWidgets('${screen.name} fits $size at text scale $scale', (
          tester,
        ) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(_app(screen, scale: scale, bottomInset: 24));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final keypad = tester.widget<PasscodeNumpad>(
            find.byType(PasscodeNumpad),
          );
          expect(keypad.keySize, lessThan(80));
          expect(
            find.bySemanticsLabel('Passcode help'),
            screen == PasscodeCaptureScreen.unlock
                ? findsOneWidget
                : findsNothing,
          );
          // Scrolling must make the last row reachable even at the shortest height.
          await tester.ensureVisible(find.bySemanticsLabel('Digit 0'));
          await tester.pumpAndSettle();
          final zero = tester.getRect(find.bySemanticsLabel('Digit 0'));
          expect(zero.bottom, lessThanOrEqualTo(size.height - 24));
          await tester.tap(find.bySemanticsLabel('Digit 0'));
          await tester.pumpAndSettle();
          expect(
            tester.widget<PasscodeDots>(find.byType(PasscodeDots)).filled,
            1,
          );
          // All digits stay in the familiar three-column order after shrinking.
          final one = tester.getRect(find.bySemanticsLabel('Digit 1'));
          final two = tester.getRect(find.bySemanticsLabel('Digit 2'));
          final three = tester.getRect(find.bySemanticsLabel('Digit 3'));
          final four = tester.getRect(find.bySemanticsLabel('Digit 4'));
          expect(one.top, two.top);
          expect(two.top, three.top);
          expect(four.left, one.left);
          expect(four.top, greaterThan(one.bottom));
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  for (final screen in [
    PasscodeCaptureScreen.unlock,
    PasscodeCaptureScreen.viewingKey,
    PasscodeCaptureScreen.seedPhrase,
  ]) {
    for (final enabled in [true, false]) {
      testWidgets(
        '${screen.name} biometric footer remains reachable ($enabled)',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(951, 560);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            _app(
              screen,
              scale: 2,
              bottomInset: 24,
              biometric: BiometricUnlockState(
                availability: const BiometricAvailability(
                  supported: true,
                  enrolled: true,
                  kind: BiometricKind.face,
                ),
                enabled: enabled,
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final footer = find.byType(
            enabled ? PasscodeBiometricButton : PasscodeBiometricOptIn,
          );
          if (!enabled && screen != PasscodeCaptureScreen.unlock) {
            expect(find.byType(PasscodeBiometricButton), findsNothing);
            return;
          }
          expect(footer, findsOneWidget);
          await tester.ensureVisible(footer);
          await tester.pumpAndSettle();
          expect(tester.getRect(footer).bottom, lessThanOrEqualTo(536));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('portrait and roomy wide windows retain the original keypad', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final size in [
      const Size(393, 852),
      const Size(669, 951),
      const Size(852, 852),
      const Size(1200, 900),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(_app(PasscodeCaptureScreen.change));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('compact_wide_passcode')), findsNothing);
      expect(
        tester.widget<PasscodeNumpad>(find.byType(PasscodeNumpad)).keySize,
        80,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'rotation preserves entered digits and setup confirmation phase',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(393, 852);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_app(PasscodeCaptureScreen.create));
      await tester.pumpAndSettle();
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.bySemanticsLabel('Digit 1'));
        await tester.pump();
      }
      expect(find.text('Confirm Passcode'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Digit 2'));
      await tester.pump();
      tester.view.physicalSize = const Size(951, 669);
      await tester.pumpAndSettle();
      expect(find.text('Confirm Passcode'), findsOneWidget);
      expect(tester.widget<PasscodeDots>(find.byType(PasscodeDots)).filled, 1);
      await tester.tap(find.bySemanticsLabel('Delete digit'));
      await tester.pump();
      expect(tester.widget<PasscodeDots>(find.byType(PasscodeDots)).filled, 0);
    },
  );

  testWidgets('error clearance is safe at the legacy fit boundary', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(951, 710);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_app(PasscodeCaptureScreen.change));
    await tester.pumpAndSettle();
    expect(
      tester.widget<PasscodeNumpad>(find.byType(PasscodeNumpad)).keySize,
      80,
    );
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.bySemanticsLabel('Digit 1'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Incorrect Passcode'), findsOneWidget);
    expect(
      tester.getRect(find.text('Incorrect Passcode')).bottom,
      lessThan(tester.getRect(find.bySemanticsLabel('Digit 1')).top),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide error text remains above the first key row', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(951, 669);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _app(PasscodeCaptureScreen.change, scale: 1.5, bottomInset: 24),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      await tester.ensureVisible(find.bySemanticsLabel('Digit 1'));
      await tester.tap(find.bySemanticsLabel('Digit 1'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Incorrect Passcode'), findsOneWidget);
    expect(
      tester.getRect(find.text('Incorrect Passcode')).bottom,
      lessThan(tester.getRect(find.bySemanticsLabel('Digit 1')).top),
    );
    expect(tester.takeException(), isNull);
  });
}
