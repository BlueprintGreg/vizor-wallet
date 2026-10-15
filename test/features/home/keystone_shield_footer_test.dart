@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/home/widgets/mobile/shield/keystone_shield_footer.dart';
import 'package:zcash_wallet/src/features/home/widgets/mobile/shield/keystone_shield_morph.dart';
import 'package:zcash_wallet/src/features/home/widgets/mobile/shield/particles/particle_field.dart';
import 'package:zcash_wallet/src/features/home/widgets/mobile/shield/mobile_shield_scene.dart';

void main() {
  testWidgets(
    'hidden footer cannot be tapped or focused and survives a fast success exit',
    (tester) async {
      final phase = ValueNotifier(MobileShieldPhase.hardware);
      addTearDown(phase.dispose);
      final semantics = tester.ensureSemantics();
      try {
        var calls = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: ValueListenableBuilder(
              valueListenable: phase,
              builder: (_, value, _) => MobileShieldScene(
                phase: value,
                amount: '14.12',
                title: 'Approve with Keystone',
                footer: value == MobileShieldPhase.hardware
                    ? KeystoneShieldFooter(
                        showQr: true,
                        onCancel: () => calls++,
                        onNext: () => calls++,
                        onShowQr: null,
                      )
                    : null,
                keystoneFocus: KeystoneShieldFocus(
                  stage: value == MobileShieldPhase.hardware
                      ? KeystoneShieldFocusStage.qr
                      : KeystoneShieldFocusStage.cloud,
                  urParts: const ['ur:zcash-pczt/first-frame'],
                  scannerBuilder: (_, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        );
        final visibility = find.byKey(
          const ValueKey('mobile_keystone_footer_visibility'),
        );
        double opacity() => tester.widget<Opacity>(visibility).opacity;
        final cancel = find.byKey(const ValueKey('mobile_keystone_cancel'));
        expect(opacity(), 0);
        expect(find.semantics.byLabel('Cancel'), findsNothing);
        await tester.tap(cancel, warnIfMissed: false);
        expect(calls, 0);
        for (var i = 0; i < 15; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump(const Duration(seconds: 2));
        expect(opacity(), 1);
        expect(find.semantics.byLabel('Cancel'), findsOneWidget);
        await tester.tap(cancel);
        expect(calls, 1);
        phase.value = MobileShieldPhase.succeeded;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 125));
        expect(opacity(), inExclusiveRange(0.0, 1.0));
        expect(find.semantics.byLabel('Cancel'), findsNothing);
        await tester.tap(cancel, warnIfMissed: false);
        expect(calls, 1);
        await tester.pump(const Duration(milliseconds: 175));
        expect(opacity(), 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        semantics.dispose();
      }
    },
  );

  for (final scale in [1.0, 2.5]) {
    testWidgets(
      '320px footer keeps its bounds and current action at scale $scale',
      (tester) async {
        final qr = ValueNotifier(true);
        addTearDown(qr.dispose);
        final semantics = tester.ensureSemantics();
        try {
          var next = 0, back = 0;
          await tester.pumpWidget(
            MaterialApp(
              home: AppTheme(
                data: AppThemeData.dark,
                child: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: Center(
                    child: SizedBox(
                      width: 272,
                      child: ValueListenableBuilder(
                        valueListenable: qr,
                        builder: (_, value, _) => KeystoneShieldFooter(
                          showQr: value,
                          onCancel: () {},
                          onNext: () => next++,
                          onShowQr: () => back++,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          final action = find.byKey(
            const ValueKey('mobile_keystone_stage_action'),
          );
          final cancel = find.byKey(const ValueKey('mobile_keystone_cancel'));
          final oldAction = tester.getRect(action),
              oldCancel = tester.getRect(cancel);
          qr.value = false;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 90));
          expect(find.text('Next step'), findsOneWidget);
          expect(find.text('Show QR'), findsOneWidget);
          expect(find.bySemanticsLabel('Next step'), findsNothing);
          expect(find.bySemanticsLabel('Show QR'), findsOneWidget);
          expect(tester.getRect(action), oldAction);
          expect(tester.getRect(cancel), oldCancel);
          await tester.tap(action);
          expect(back, 1);
          expect(next, 0);
          // Retarget while the old content is still fading.
          qr.value = true;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));
          expect(tester.getRect(action), oldAction);
          expect(find.text('Show QR'), findsNothing);
          expect(find.bySemanticsLabel('Next step'), findsOneWidget);
          await tester.tap(action);
          expect(next, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  testWidgets(
    'footer follows formation time and exits before the cloud returns',
    (tester) async {
      final morph = KeystoneShieldMorph();
      addTearDown(morph.dispose);
      KeystoneShieldFocus focus(KeystoneShieldFocusStage stage) =>
          KeystoneShieldFocus(
            stage: stage,
            urParts: const ['ur:zcash-pczt/first-frame'],
            scannerBuilder: (_, _) => const SizedBox.shrink(),
          );
      final cloud = [
        const ShieldParticleSample(
          position: Offset(100, 200),
          size: 2,
          alpha: 1,
        ),
      ];
      morph.configure(focus(KeystoneShieldFocusStage.qr));
      morph.setBounds(
        KeystoneShieldAnchorKind.qr,
        const Rect.fromLTWH(20, 120, 280, 280),
      );
      morph.update(0, cloud);
      morph.update(0.4, cloud);
      expect(morph.footerOpacity, 0);
      expect(morph.footerInteractive, isFalse);
      morph.update(0.5, cloud);
      expect(morph.footerOpacity, inExclusiveRange(0.0, 1.0));
      expect(morph.footerDy, inExclusiveRange(0.0, 6.0));
      morph.update(0.61, cloud);
      expect(morph.footerOpacity, 1);
      expect(morph.footerInteractive, isTrue);
      morph.configure(focus(KeystoneShieldFocusStage.cloud));
      expect(morph.footerInteractive, isFalse);
      morph.update(0.62, cloud);
      morph.update(0.8, cloud);
      expect(morph.footerOpacity, 0);
      expect(morph.cloudReady, isFalse);
    },
  );
  testWidgets('Reduce Motion fades the footer without movement', (
    tester,
  ) async {
    final morph = KeystoneShieldMorph()..reduceMotion = true;
    addTearDown(morph.dispose);
    morph.configure(
      KeystoneShieldFocus(
        stage: KeystoneShieldFocusStage.qr,
        urParts: const ['ur:zcash-pczt/first-frame'],
        scannerBuilder: (_, _) => const SizedBox.shrink(),
      ),
    );
    morph.setBounds(
      KeystoneShieldAnchorKind.qr,
      const Rect.fromLTWH(20, 120, 280, 280),
    );
    morph.update(0, const []);
    morph.update(0.1, const []);
    expect(morph.footerOpacity, inExclusiveRange(0.0, 1.0));
    expect(morph.footerDy, 0);
    morph.update(0.2, const []);
    expect(morph.footerOpacity, 1);
    expect(morph.qrReady, isTrue);
  });
}
