@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/home/widgets/mobile/shield/mobile_shield_scene.dart';
import 'package:zcash_wallet/src/features/home/widgets/mobile/shield/slide_to_shield.dart';

void main() {
  Widget host(Widget child, {double textScale = 1}) => AppTheme(
    data: AppThemeData.light,
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: const EdgeInsets.only(top: 24, bottom: 48),
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: child,
    ),
  );
  for (final size in [
    const Size(320, 568),
    const Size(360, 640),
    const Size(393, 852),
    const Size(430, 932),
  ]) {
    testWidgets('review is centered and operable at $size', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var calls = 0;
      await tester.pumpWidget(
        host(
          MobileShieldScene(
            phase: MobileShieldPhase.review,
            amount: '12345.12345678',
            resultAmount: '12345.12335678',
            title: 'Transparent balance',
            feeText: 'Network fee: 0.0001 ZEC · You receive 12345.12335678 ZEC',
            onCommit: () => calls++,
          ),
          textScale: 1.5,
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      final slider = find.byKey(const ValueKey('mobile_shield_slide'));
      expect(tester.getRect(slider).right, lessThanOrEqualTo(size.width));
      expect(tester.getCenter(slider).dx, closeTo(size.width / 2, 0.5));
      expect(tester.getRect(slider).bottom, lessThan(size.height - 48));
      final start = tester.getTopLeft(slider) + const Offset(35, 30);
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(Offset(tester.getSize(slider).width - 70, 0));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(calls, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('system back delegates to the owner before leaving', (
    tester,
  ) async {
    var requests = 0;
    await tester.pumpWidget(
      host(
        MobileShieldScene(
          phase: MobileShieldPhase.hardware,
          amount: '1',
          title: 'Approve with Ledger',
          onClose: () => requests++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    final pop = tester.widget<PopScope>(
      find.byWidgetPredicate((widget) => widget is PopScope),
    );
    expect(pop.canPop, isFalse);
    pop.onPopInvokedWithResult!(false, null);
    expect(requests, 1);
    await tester.pumpWidget(
      host(
        MobileShieldScene(
          phase: MobileShieldPhase.working,
          amount: '1',
          title: 'Sending',
          canLeave: false,
          onClose: () => requests++,
        ),
      ),
    );
    tester
        .widget<PopScope>(
          find.byWidgetPredicate((widget) => widget is PopScope),
        )
        .onPopInvokedWithResult!(false, null);
    expect(requests, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('hardware QR fits the remaining height with large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      host(
        MobileShieldScene(
          phase: MobileShieldPhase.hardware,
          amount: '1',
          title: 'Approve with Keystone',
          body:
              'Scan this QR with Keystone, approve on your device, then scan its signed QR.',
          focusBuilder: (context, c) => MobileShieldKeystoneQr(
            constraints: c,
            urParts: const ['ur:zcash-pczt/fixture'],
          ),
          footer: const SizedBox(height: 80),
          onClose: () {},
        ),
        textScale: 2,
      ),
    );
    await tester.pump(const Duration(milliseconds: 900));
    final qr = tester.getRect(
      find.byKey(const ValueKey('mobile_shield_keystone_qr')),
    );
    expect(qr.top, greaterThanOrEqualTo(80));
    expect(
      qr.bottom,
      lessThanOrEqualTo(
        tester.getTopLeft(find.text('Approve with Keystone').last).dy,
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('a cancelled drag never starts shielding', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        MobileShieldScene(
          phase: MobileShieldPhase.review,
          amount: '1',
          title: 'Transparent balance',
          onCommit: () => calls++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    final slider = find.byType(SlideToShield);
    final gesture = await tester.startGesture(
      tester.getTopLeft(slider) + const Offset(35, 30),
    );
    await gesture.moveBy(const Offset(259, 0));
    await gesture.cancel();
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('pending broadcast never exposes success or a new commit', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const MobileShieldScene(
          phase: MobileShieldPhase.pending,
          amount: '1',
          title: 'Shielding queued',
          body: 'Check Activity.',
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 12));
    expect(find.byKey(const ValueKey('mobile_shield_complete')), findsNothing);
    expect(find.byType(SlideToShield), findsNothing);
    expect(find.text('Shielding queued'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'success waits for the result choreography and honors Reduce Motion',
    (tester) async {
      await tester.pumpWidget(
        AppTheme(
          data: AppThemeData.light,
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(393, 852),
                disableAnimations: true,
              ),
              child: MobileShieldScene(
                phase: MobileShieldPhase.succeeded,
                amount: '1',
                resultAmount: '0.9999',
                title: 'Shielding transaction sent',
                onComplete: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(
        find.byKey(const ValueKey('mobile_shield_complete')),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 4));
      expect(
        find.byKey(const ValueKey('mobile_shield_complete')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      final system = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
        find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
      );
      expect(system.value.statusBarIconBrightness, Brightness.light);
      expect(system.value.statusBarBrightness, Brightness.dark);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
