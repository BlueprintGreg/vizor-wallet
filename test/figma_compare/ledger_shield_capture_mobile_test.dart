@Tags(['mobile', 'figma-capture'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/figma_compare/figma_compare_configuration.dart';
import 'package:zcash_wallet/src/core/layout/app_form_factor.dart';
import 'package:zcash_wallet/src/features/home/widgets/mobile/shield/slide_to_shield.dart';
import 'package:zcash_wallet/src/features/home/widgets/mobile/shield/shield_hardware_motion.dart';
import 'figma_compare_capture_support.dart';

Future<void> _advance(WidgetTester tester, double seconds) async {
  for (var i = 0; i < (seconds * 60).round(); i++) {
    await tester.pump(const Duration(microseconds: 16667));
  }
}

void main() {
  const output = String.fromEnvironment('LEDGER_CAPTURE_DIR');
  for (final shot in [
    (name: 'entering', seconds: 0.85, size: const Size(393, 852)),
    (name: 'preparing', seconds: 2.0, size: const Size(393, 852)),
    (name: 'changing', seconds: 3.1, size: const Size(393, 852)),
    (name: 'processing', seconds: 5.0, size: const Size(393, 852)),
    (name: 'approval', seconds: 10.0, size: const Size(393, 852)),
    (name: 'approval-small', seconds: 10.0, size: const Size(320, 568)),
    (name: 'leaving', seconds: 14.13, size: const Size(393, 852)),
    (name: 'returning', seconds: 14.4, size: const Size(393, 852)),
    (name: 'cloud', seconds: 15.0, size: const Size(393, 852)),
    (name: 'result-retarget', seconds: 17.15, size: const Size(393, 852)),
    (name: 'success', seconds: 22.0, size: const Size(393, 852)),
  ]) {
    group(
      shot.name,
      () => runFigmaCompareCaptureTest(
        expectedFormFactor: AppFormFactor.mobile,
        defaultLogicalSize: shot.size,
        defaultPixelRatio: 1,
        overrideConfiguration: FigmaCompareConfiguration(
          scenarioId: 'mobile-ledger-shield-home-flow',
          themeMode: ThemeMode.light,
          logicalSize: shot.size,
          pixelRatio: 1,
          outputPath: output.isEmpty ? '' : '$output/${shot.name}.png',
        ),
        beforeCapture: (tester) async {
          tester.view.padding = FakeViewPadding(
            top: shot.size.width == 320 ? 24 : 59,
            bottom: shot.size.width == 320 ? 0 : 34,
          );
          addTearDown(tester.view.resetPadding);
          await tester.pump();
          await tester.tap(
            find.byKey(const ValueKey('mobile_home_shield_balance_button')),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          for (var i = 0; i < 15; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 17));
          }
          final slider = find.byType(SlideToShield);
          final gesture = await tester.startGesture(
            tester.getTopLeft(slider) + const Offset(30, 25),
          );
          await gesture.moveBy(Offset(tester.getSize(slider).width - 60, 0));
          await gesture.up();
          await tester.pump();
          await _advance(tester, shot.seconds);
          if (shot.seconds >= 17) {
            for (var i = 0; i < 20; i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pump(const Duration(milliseconds: 17));
            }
            if (shot.name == 'success') {
              await _advance(tester, 5);
            }
          }
          if (shot.name == 'approval' || shot.name == 'approval-small') {
            expect(find.text('Confirm on your Ledger'), findsOneWidget);
            final rect = tester.getRect(find.text('Cancel shielding'));
            expect(rect.center.dy, greaterThan(shot.size.height * 0.8));
          }
          if (shot.name == 'leaving') {
            final motion = tester.widget<ShieldHardwarePresentation>(
              find.byType(ShieldHardwarePresentation),
            );
            expect(motion.interactive, isFalse);
            expect(motion.footerOpacity, inExclusiveRange(0.0, 1.0));
          }
          if (shot.name == 'success') {
            expect(
              find.byKey(const ValueKey('mobile_shield_complete')),
              findsOneWidget,
            );
          }
        },
      ),
    );
  }
}
