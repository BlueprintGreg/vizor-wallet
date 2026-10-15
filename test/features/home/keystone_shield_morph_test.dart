@Tags(['mobile'])
library;

import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:zcash_wallet/src/features/home/widgets/mobile/shield/keystone_shield_morph.dart';
import 'package:zcash_wallet/src/features/home/widgets/mobile/shield/particles/particle_field.dart';
import 'package:zcash_wallet/src/features/home/widgets/mobile/shield/mobile_shield_scene.dart';
import 'package:zcash_wallet/src/features/home/widgets/mobile/shield/keystone_shield_scanner_surface.dart';

const _parts = ['ur:zcash-pczt/first-frame', 'ur:zcash-pczt/second-frame'];
final _cloud = List.generate(
  80,
  (i) => ShieldParticleSample(
    position: Offset(125 + i % 10 * 8, 210 + i ~/ 10 * 8),
    velocity: const Offset(2, -1),
    size: 2,
    alpha: 0.6,
  ),
);
KeystoneShieldFocus _focus(KeystoneShieldFocusStage stage) =>
    KeystoneShieldFocus(
      stage: stage,
      urParts: _parts,
      scannerBuilder: (_, _) => const SizedBox.shrink(),
    );

void main() {
  testWidgets(
    'the scene restores blur and finishes a scanner exit before success',
    (tester) async {
      final stage = ValueNotifier(KeystoneShieldFocusStage.qr);
      final phase = ValueNotifier(MobileShieldPhase.hardware);
      addTearDown(stage.dispose);
      addTearDown(phase.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: Listenable.merge([stage, phase]),
            builder: (_, _) => MobileShieldScene(
              phase: phase.value,
              amount: '14.12',
              resultAmount: '14.1199',
              title: phase.value == MobileShieldPhase.succeeded
                  ? 'Shielded successfully'
                  : stage.value == KeystoneShieldFocusStage.qr
                  ? 'Approve with Keystone'
                  : 'Scan your Keystone signature',
              footer: const SizedBox(height: 80),
              keystoneFocus: KeystoneShieldFocus(
                stage: stage.value,
                urParts: _parts,
                scannerBuilder: (constraints, morph) =>
                    KeystoneShieldScannerSurface(
                      constraints: constraints,
                      morph: morph,
                      cameraBuilder: (_) => const ColoredBox(
                        key: ValueKey('camera'),
                        color: Colors.black,
                      ),
                      onToggleTorch: () {},
                    ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.pump(const Duration(seconds: 2));
      Color background() => tester
          .widget<ColoredBox>(
            find.byKey(const ValueKey('mobile_keystone_black_background')),
          )
          .color;
      expect(background(), Colors.black);
      stage.value = KeystoneShieldFocusStage.scanner;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 225));
      expect(background().a, inExclusiveRange(0.0, 1.0));
      await tester.pump(const Duration(seconds: 1));
      expect(background().a, 0);
      expect(find.byKey(const ValueKey('camera')), findsOneWidget);
      stage.value = KeystoneShieldFocusStage.cloud;
      phase.value = MobileShieldPhase.succeeded;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('camera')), findsOneWidget);
      expect(find.text('Shielded successfully'), findsNothing);
      expect(
        find.byKey(const ValueKey('mobile_shield_complete')),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('camera')), findsNothing);
      await tester.pump(const Duration(milliseconds: 17));
      await tester.pump(const Duration(seconds: 5));
      expect(
        find.byKey(const ValueKey('mobile_shield_complete')),
        findsOneWidget,
      );
      expect(background().a, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('short screens with large text fit both QR and scanner anchors', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final stage = ValueNotifier(KeystoneShieldFocusStage.qr);
    addTearDown(stage.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2.5)),
          child: child!,
        ),
        home: ValueListenableBuilder(
          valueListenable: stage,
          builder: (_, value, _) => MobileShieldScene(
            phase: MobileShieldPhase.hardware,
            amount: '14.12',
            title: value == KeystoneShieldFocusStage.qr
                ? 'Approve with Keystone'
                : 'Scan your Keystone signature',
            footer: const SizedBox(height: 80),
            keystoneFocus: KeystoneShieldFocus(
              stage: value,
              urParts: _parts,
              scannerBuilder: (constraints, morph) =>
                  KeystoneShieldScannerSurface(
                    constraints: constraints,
                    morph: morph,
                    cameraBuilder: (_) => const ColoredBox(color: Colors.black),
                    onToggleTorch: () {},
                  ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 20));
    final qr = tester.getRect(
      find.byKey(const ValueKey('mobile_shield_keystone_qr')),
    );
    expect(qr.width, lessThanOrEqualTo(272));
    expect(qr.center.dx, 160);
    stage.value = KeystoneShieldFocusStage.scanner;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('QR settles before frames cycle and uses an exact black hold', (
    tester,
  ) async {
    final morph = KeystoneShieldMorph()
      ..configure(_focus(KeystoneShieldFocusStage.qr));
    addTearDown(morph.dispose);
    morph.setBounds(
      KeystoneShieldAnchorKind.qr,
      const Rect.fromLTWH(40, 160, 280, 280),
    );
    morph.update(0, _cloud);
    morph.update(0.3, _cloud);
    expect(morph.blackMix, inExclusiveRange(0.0, 1.0));
    expect(morph.qrReady, isFalse);
    expect(morph.qrIndex, 0);
    morph.update(0.61, _cloud);
    expect(morph.blackMix, 1);
    expect(morph.qrReady, isTrue);
    morph.update(0.82, _cloud);
    expect(morph.qrIndex, 1);
    expect(morph.blackMix, 1);
    expect(morph.particles.every((p) => p.square == 1 && p.alpha == 1), isTrue);
  });

  testWidgets(
    'the white raster preserves every module and a clear quiet zone',
    (tester) async {
      const bounds = Rect.fromLTWH(0, 0, 280, 280);
      final morph = KeystoneShieldMorph()
        ..configure(_focus(KeystoneShieldFocusStage.qr));
      addTearDown(morph.dispose);
      morph.devicePixelRatio = 3;
      morph.setBounds(KeystoneShieldAnchorKind.qr, bounds);
      morph.update(0, _cloud);
      morph.update(1.2, _cloud);
      morph.update(1.21, _cloud);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..scale(3);
      canvas.drawRect(bounds, Paint()..color = Colors.black);
      morph.paint(canvas);
      final picture = recorder.endRecording();
      final image = await tester.runAsync(() => picture.toImage(840, 840));
      final bytes = (await tester.runAsync(() => image!.toByteData()))!;
      final qr = QrImage(
        QrCode.fromData(
          data: _parts.first,
          errorCorrectLevel: QrErrorCorrectLevel.M,
        ),
      );
      final pitch = 840 / (qr.moduleCount + 8);
      int ink(int x, int y) => bytes.getUint8((y * 840 + x) * 4);
      for (var y = -4; y < qr.moduleCount + 4; y++) {
        for (var x = -4; x < qr.moduleCount + 4; x++) {
          final expected =
              x >= 0 &&
              y >= 0 &&
              x < qr.moduleCount &&
              y < qr.moduleCount &&
              qr.isDark(y, x);
          final px = ((x + 4.5) * pitch).floor();
          final py = ((y + 4.5) * pitch).floor();
          expect(ink(px, py), expected ? 255 : 0, reason: 'QR cell ($x, $y)');
        }
      }
      image!.dispose();
      picture.dispose();
    },
  );

  testWidgets('camera stays mounted while reverse targets are pending', (
    tester,
  ) async {
    final morph = KeystoneShieldMorph()
      ..configure(_focus(KeystoneShieldFocusStage.qr));
    addTearDown(morph.dispose);
    await tester.runAsync(morph.prepare);
    morph.setBounds(
      KeystoneShieldAnchorKind.qr,
      const Rect.fromLTWH(40, 160, 280, 280),
    );
    morph.setBounds(
      KeystoneShieldAnchorKind.frame,
      const Rect.fromLTWH(50, 140, 260, 260),
    );
    morph.setBounds(
      KeystoneShieldAnchorKind.torch,
      const Rect.fromLTWH(168, 450, 24, 24),
    );
    morph.update(0, _cloud);
    morph.update(1.2, _cloud);
    morph.configure(_focus(KeystoneShieldFocusStage.scanner));
    expect(morph.scannerOpacity, 0);
    morph.update(1.3, _cloud);
    morph.update(2.3, _cloud);
    expect(morph.scannerOpacity, 1);
    expect(morph.blackMix, 0);
    morph.configure(_focus(KeystoneShieldFocusStage.qr));
    expect(morph.scannerVisible, isTrue);
    expect(morph.scannerOpacity, 1);
    morph.update(2.31, _cloud);
    morph.update(2.7, _cloud);
    final previous = morph.particles.map((p) => p.position).toList();
    final black = morph.blackMix;
    morph.configure(_focus(KeystoneShieldFocusStage.scanner));
    morph.update(2.7, _cloud);
    expect(morph.blackMix, black);
    for (var i = 0; i < previous.length; i++) {
      expect(
        (morph.particles[i].position - previous[i]).distance,
        lessThan(0.001),
      );
    }
    morph.update(3.7, _cloud);
    morph.configure(_focus(KeystoneShieldFocusStage.cloud));
    expect(morph.scannerVisible, isTrue);
    morph.update(3.8, _cloud);
    expect(morph.cloudReady, isFalse);
    morph.update(4.8, _cloud);
    expect(morph.cloudReady, isTrue);
    expect(morph.blackMix, 0);
    for (var i = 0; i < _cloud.length; i++) {
      expect(morph.particles[i].position, _cloud[i].position);
    }
  });

  testWidgets('QR remains usable without decorative cloud samples', (
    tester,
  ) async {
    final morph = KeystoneShieldMorph()
      ..configure(_focus(KeystoneShieldFocusStage.qr));
    addTearDown(morph.dispose);
    morph.setBounds(
      KeystoneShieldAnchorKind.qr,
      const Rect.fromLTWH(20, 100, 280, 280),
    );
    morph.update(0, const []);
    morph.update(2, const []);
    expect(morph.qrReady, isTrue);
    expect(morph.blackMix, 1);
  });

  testWidgets('Reduce Motion preserves QR readiness and the restored blur', (
    tester,
  ) async {
    final morph = KeystoneShieldMorph()
      ..reduceMotion = true
      ..configure(_focus(KeystoneShieldFocusStage.qr));
    addTearDown(morph.dispose);
    morph.setBounds(
      KeystoneShieldAnchorKind.qr,
      const Rect.fromLTWH(40, 160, 280, 280),
    );
    morph.update(0, _cloud);
    for (var i = 0; i < _cloud.length; i++) {
      expect(morph.particles[i].position, _cloud[i].position);
    }
    morph.update(0.2, _cloud);
    expect(morph.qrReady, isTrue);
    expect(morph.blackMix, 1);
    morph.configure(_focus(KeystoneShieldFocusStage.cloud));
    morph.update(0.3, _cloud);
    morph.update(0.5, _cloud);
    expect(morph.cloudReady, isTrue);
    expect(morph.blackMix, 0);
  });
}
