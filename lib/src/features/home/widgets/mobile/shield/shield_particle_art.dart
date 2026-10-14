import 'dart:math' as math;
import 'package:flutter/painting.dart';
import 'balance_art.dart';
import 'particles/cloud_layout.dart';
import 'particles/shape_sampler.dart';
import 'particles/sprite_atlas.dart';
import 'shield_timeline.dart';

final List<({Offset p, double size, double alpha})> shieldCloudDots = () {
  const scale = 1.2;
  const center = Offset(196.0, 386.7);
  String at(int r, int c) => r < kCloudRows.length && c < kCloudRows[r].length
      ? kCloudRows[r][c]
      : ' ';
  ({Offset p, double size, double alpha}) dot(double r, double c, String k) {
    final p = Offset(
      kCloudOriginX + c * kCloudPitchX,
      kCloudOriginY + r * kCloudPitchY,
    );
    return (
      p: center + (p - center) * scale,
      size: switch (k) {
        '.' => 1.146,
        ':' => 2.292,
        'o' => 3.438,
        _ => 4.584,
      },
      alpha: switch (k) {
        '.' => 1.0,
        ':' => 0.75,
        'o' => 0.5,
        _ => 0.25,
      },
    );
  }

  return [
    for (var r = 0; r < kCloudRows.length; r++)
      for (var c = 0; c < kCloudRows[r].length; c++)
        if (at(r, c) != ' ') dot(r.toDouble(), c.toDouble(), at(r, c)),
    for (var r = 0; r < kCloudRows.length - 1; r++)
      for (var c = 0; c < kCloudRows[r].length - 1; c++)
        if (at(r, c) != ' ' &&
            at(r, c + 1) != ' ' &&
            at(r + 1, c) != ' ' &&
            at(r + 1, c + 1) != ' ')
          // Borrow a neighbor's size class, picked by a fixed hash.
          dot(
            r + 0.5,
            c + 0.5,
            at(r + (r * 7 + c * 3) % 2, c + (r * 5 + c * 11) % 2),
          ),
  ];
}();

class ShieldParticleArt {
  ShieldParticleArt({
    required this.atlas,
    required this.textPoints,
    required this.shieldCells,
    required this.shieldSize,
    required this.balancePoints,
    required this.iconPoints,
    required this.glowText,
    required this.glowSize,
  });

  final SpriteAtlas atlas;
  final List<Offset> textPoints;
  final List<Offset> shieldCells;
  final Size shieldSize;
  final List<Offset> balancePoints;
  final List<Offset> iconPoints;
  final BakedImage glowText;
  final Size glowSize;
  static const _shieldAsset = 'assets/icons/shielding_success_shield_fill.svg';
  static const iconWidth = 31.7234;
  static const iconHeight = 36.6677;

  static Future<ShieldParticleArt> load(
    String amount, {
    required String resultAmount,
    required int count,
    required math.Random random,
    required double fontSize,
  }) async {
    final atlas = await SpriteAtlas.build();
    // Solid stand-ins with each look's geometry: the dots crumble from the
    // amount, the pill's outline and its letters, and pour back into them.
    final before = BalanceArt(
      amount,
      look: BalanceLook.solid,
      pillTop: BalanceArt.transparentPillTop,
      fontSize: fontSize,
    );
    final after = BalanceArt(
      resultAmount,
      look: BalanceLook.solid,
      pillTop: BalanceArt.shieldedPillTop,
      fontSize: fontSize,
    );
    final textPoints = await ShapeSampler.picture(
      before.size,
      before.paint,
      count: count,
      random: random,
    );
    final balancePoints = await ShapeSampler.picture(
      after.size,
      after.paint,
      count: count - ShieldTimeline.iconParticles - ShieldTimeline.strays,
      random: random,
    );
    final iconPoints = await ShapeSampler.svgPoints(
      _shieldAsset,
      height: iconHeight,
      count: ShieldTimeline.iconParticles,
      random: random,
    );

    // Size the shield so it holds one particle per halftone cell. The grid
    // tightens with the particle count so the shield grows only a little
    // (about 15% over the 718-dot original) and stays inside the field.
    final pitch = kCloudPitchX * 1.15 * math.sqrt(718 / count);
    var height = 286.0 * 1.15;
    var cells = <Offset>[];
    for (var i = 0; i < 4; i++) {
      cells = await ShapeSampler.svgCells(
        _shieldAsset,
        height: height,
        pitch: pitch,
        solid: true,
      );
      final ratio = cells.length / count;
      if ((ratio - 1).abs() < 0.04) break;
      height /= math.sqrt(ratio);
    }

    // Blurred ghost of the balance, a touch larger, behind the cloud.
    const glowScale = 1.05;
    final glowSize = before.size * glowScale;
    return ShieldParticleArt(
      atlas: atlas,
      textPoints: textPoints,
      shieldCells: cells,
      shieldSize: Size(height * iconWidth / iconHeight, height),
      balancePoints: balancePoints,
      iconPoints: iconPoints,
      glowText: await ShapeSampler.blurred(glowSize, (canvas) {
        canvas.scale(glowScale);
        before.paint(canvas);
      }, sigma: 48.859),
      glowSize: glowSize,
    );
  }

  void dispose() {
    atlas.dispose();
    glowText.dispose();
  }
}
