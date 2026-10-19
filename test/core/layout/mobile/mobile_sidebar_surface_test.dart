@Tags(['mobile'])
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/layout/mobile/mobile_sidebar_surface.dart';
import 'package:zcash_wallet/src/core/layout/mobile/mobile_wallet_sidebar.dart';
import 'package:zcash_wallet/src/core/layout/mobile/mobile_sync_status.dart';
import 'package:zcash_wallet/src/core/formatting/sync_status_label.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/services/native_modal_corners.dart';

void main() {
  final calls = <MethodCall>[];
  Future<Object?> Function(MethodCall)? reply;
  const radius = {
    'topLeft': 48.0,
    'topRight': 24.0,
    'bottomLeft': 56.0,
    'bottomRight': 24.0,
  };
  setUp(() {
    reply = (_) async => radius;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeModalCorners.channel, (call) {
          calls.add(call);
          return reply!(call);
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeModalCorners.channel, null),
  );

  Future<void> pump(
    WidgetTester tester, {
    double left = 16,
    double top = 40,
    Widget? panel,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(982, 654);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) =>
            AppTheme(data: AppThemeData.light, child: child!),
        home: Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              width: 256,
              height: 540,
              child:
                  panel ?? const MobileSidebarSurface(child: SizedBox.expand()),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  BorderRadius outline(WidgetTester tester) {
    final decorated = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(MobileSidebarSurface),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is ShapeDecoration &&
              (widget.decoration as ShapeDecoration).shape
                  is RoundedSuperellipseBorder,
        ),
      ),
    );
    final shape = (decorated.decoration as ShapeDecoration).shape;
    expect(shape, isA<RoundedSuperellipseBorder>());
    final clip = tester.widget<ClipPath>(
      find.descendant(
        of: find.byType(MobileSidebarSurface),
        matching: find.byType(ClipPath),
      ),
    );
    expect((clip.clipper! as ShapeBorderClipper).shape, shape);
    return (shape as RoundedSuperellipseBorder).borderRadius as BorderRadius;
  }

  testWidgets(
    'uses actual panel frame for both fill and continuous clipping; updates on movement',
    (tester) async {
      addTearDown(tester.view.reset);
      await pump(tester);
      expect(calls.single.method, 'resolveSidebar');
      expect(calls.single.arguments, containsPair('x', 16.0));
      expect(calls.single.arguments, containsPair('y', 40.0));
      expect(calls.single.arguments, containsPair('height', 540.0));
      expect(outline(tester).topLeft.x, 48);
      expect(outline(tester).bottomLeft.x, 56);
      expect(outline(tester).topRight.x, 24);
      await pump(tester, left: 32, top: 64);
      expect(calls.length, 2);
      expect(calls.last.arguments, containsPair('y', 64.0));
      await tester.pump();
      expect(calls.length, 2); // No per-frame requests from normal rebuilds.
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'sync hugs the left edge and follows the exact native corner used by the panel',
    (tester) async {
      addTearDown(tester.view.reset);
      Widget sidebar({double bottomInset = 18}) => MediaQuery(
        data: MediaQueryData(padding: EdgeInsets.only(bottom: bottomInset)),
        child: MobileWalletSidebar(
          accountName: 'Test account',
          avatar: const SizedBox(width: 40, height: 40),
          status: const SyncStatusLabel(
            kind: SyncStatusKind.synced,
            label: 'Vizor is synced',
            semanticsLabel: 'Vizor is synced',
          ),
          currentPath: '/home',
          swapEnabled: true,
          onSelect: (_) {},
          onAccountTap: () {},
        ),
      );
      void verify(double corner, double gap) {
        final panel = tester.getRect(find.byType(MobileSidebarSurface));
        final sync = tester.getRect(find.byType(MobileSyncStatus));
        final bar = tester.getRect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Container &&
                widget.constraints?.maxWidth == 6 &&
                widget.constraints?.maxHeight == 50,
          ),
        );
        expect(outline(tester).bottomLeft.y, corner);
        expect(bar.left, panel.left);
        expect(panel.bottom - sync.bottom, gap);
        expect(
          tester.getRect(find.text('Vizor is synced')).left,
          panel.left + 6 + AppSpacing.s,
        );
        expect(tester.takeException(), isNull);
      }

      await pump(tester, panel: sidebar());
      verify(56, 56 + AppSpacing.sm);
      reply = (_) async => {...radius, 'bottomLeft': 39.0};
      await pump(tester, left: 32, panel: sidebar());
      verify(39, 39 + AppSpacing.sm);
      // Safety replaces the corner gap when larger; it is never added to it.
      await pump(tester, left: 32, panel: sidebar(bottomInset: 80));
      verify(39, 80);
      reply = (_) async => null;
      await pump(tester, left: 48, panel: sidebar());
      verify(AppRadii.large, AppRadii.large + AppSpacing.sm);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'rejects late results and falls back when current native geometry is invalid',
    (tester) async {
      addTearDown(tester.view.reset);
      final first = Completer<Object?>();
      reply = (_) => calls.length == 1
          ? first.future
          : Future.value({'topLeft': double.nan});
      await pump(tester);
      await pump(tester, left: 32);
      expect(outline(tester), BorderRadius.circular(24));
      first.complete(radius);
      await tester.pumpAndSettle();
      expect(outline(tester), BorderRadius.circular(24));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('Android uses its fallback outline without calling UIKit', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await pump(tester);
    expect(calls, isEmpty);
    final decorated = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(MobileSidebarSurface),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect(
      (decorated.decoration as ShapeDecoration).shape,
      isA<RoundedRectangleBorder>(),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
