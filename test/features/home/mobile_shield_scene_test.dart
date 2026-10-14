@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/home/widgets/mobile/shield/mobile_shield_scene.dart';
import 'package:zcash_wallet/src/features/home/widgets/mobile/shield/slide_to_shield.dart';
import 'package:zcash_wallet/src/features/ledger/widgets/mobile/mobile_ledger_sheet_content.dart';

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
      final heading = tester.getRect(
        find.byKey(const ValueKey('mobile_shield_heading')),
      );
      final amount = tester.getRect(
        find.byKey(const ValueKey('mobile_shield_amount')),
      );
      expect(heading.bottom, lessThanOrEqualTo(amount.top));
      expect(amount.bottom, lessThan(tester.getRect(slider).top));
      final start = tester.getTopLeft(slider) + const Offset(35, 30);
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(Offset(tester.getSize(slider).width - 60, 0));
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
  testWidgets('future result digits do not change the review amount size', (
    tester,
  ) async {
    Widget scene(String result) => host(
      MobileShieldScene(
        phase: MobileShieldPhase.review,
        amount: '14.12',
        resultAmount: result,
        title: 'Transparent Balance',
      ),
    );
    await tester.pumpWidget(scene('14.12'));
    await tester.pump();
    final original = tester
        .widget<CustomPaint>(find.byKey(const ValueKey('mobile_shield_amount')))
        .size;
    await tester.pumpWidget(scene('14.1199'));
    await tester.pump();
    expect(
      tester
          .widget<CustomPaint>(
            find.byKey(const ValueKey('mobile_shield_amount')),
          )
          .size,
      original,
    );
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
    expect(qr.top, greaterThanOrEqualTo(40));
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
  testWidgets('review cancellation uses the owner and disappears during work', (
    tester,
  ) async {
    var closes = 0;
    await tester.pumpWidget(
      host(
        MobileShieldScene(
          phase: MobileShieldPhase.review,
          amount: '14.12',
          title: 'Transparent Balance',
          onClose: () => closes++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('Cancel'));
    expect(closes, 1);
    await tester.pumpWidget(
      host(
        MobileShieldScene(
          phase: MobileShieldPhase.working,
          amount: '14.12',
          title: 'Shielding your balance…',
          canLeave: false,
          onClose: () => closes++,
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Cancel'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'success reuses the review action position and delays its heading',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(393, 852);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        host(
          const MobileShieldScene(
            phase: MobileShieldPhase.review,
            amount: '14.12',
            title: 'Transparent Balance',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      final actionTop = tester
          .getTopLeft(find.byKey(const ValueKey('mobile_shield_slide')))
          .dy;
      await tester.pumpWidget(
        host(
          MobileShieldScene(
            phase: MobileShieldPhase.succeeded,
            amount: '14.12',
            title: 'Shielded successfully',
            onComplete: () {},
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Shielded successfully'), findsNothing);
      expect(find.text('Shielding your balance…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('mobile_shield_complete')))
            .dy,
        actionTop,
      );
      final heading = tester.getRect(
        find.byKey(const ValueKey('mobile_shield_heading')),
      );
      final amount = tester.getRect(
        find.byKey(const ValueKey('mobile_shield_result_amount')),
      );
      expect(heading.bottom, lessThan(amount.top));
      expect(amount.bottom, lessThan(actionTop));
      expect(find.text('Cancel'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'long Ledger recovery content scrolls without duplicate labels or actions',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        host(
          MobileShieldScene(
            phase: MobileShieldPhase.hardware,
            amount: '1',
            title: 'Shield with Ledger',
            focusChild: LedgerInlinePresentation(
              child: MobileLedgerSheetContent(
                title: 'Confirm on your Ledger',
                onClose: () {},
                children: [
                  for (var i = 0; i < 15; i++)
                    const MobileLedgerMessage(
                      'Review and approve on your Ledger.',
                    ),
                ],
              ),
            ),
            onClose: () {},
          ),
          textScale: 2,
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Confirm on your Ledger'), findsOneWidget);
      expect(find.text('Shield with Ledger'), findsNothing);
      expect(find.text('Cancel'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Back to wallet'),
        200,
        scrollable: find.byType(Scrollable),
      );
      await tester.pump();
      expect(
        tester.getRect(find.text('Back to wallet')).bottom,
        lessThanOrEqualTo(568 - 48),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
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
                title: 'Shielded successfully',
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
