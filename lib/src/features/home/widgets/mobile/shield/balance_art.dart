import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'shield_metal.dart';
import 'shield_motion.dart';

/// How the balance block is dressed.
enum BalanceLook {
  /// Before shielding (Figma 8847:96643): the pill is a 2px outline at 25%
  /// white, "ZEC" at 60%.
  transparent,

  /// Once shielded (Figma 8847:96644): the drag pin's metal pill, "ZEC" with
  /// a soft white gradient (#EBEBEB to 60%, top to bottom).
  shielded,

  /// Everything solid white: what particles sample and the glow is baked
  /// from. Same geometry as the look it stands in for.
  solid,
}

/// The balance block: the amount in Young Serif Bold 56 (Figma 8810:78594)
/// and, below it, "ZEC" in Geist Medium 26 inside a 76x42 pill. Painted
/// with bare [TextPainter]s so the crisp block and the particle targets
/// sampled from it line up pixel for pixel. Origin = top-left of the
/// amount's line box; everything is centered on one vertical axis.
class BalanceArt {
  BalanceArt(
    String amount, {
    required this.look,
    required this.pillTop,
    double fontSize = 56,
  }) : _amount = TextPainter(
         text: TextSpan(
           text: amount,
           style: VText.display.copyWith(
             color: _white,
             fontSize: fontSize,
             fontWeight: FontWeight.w700,
             letterSpacing: -0.04 * fontSize,
             height: 1,
           ),
         ),
         textDirection: TextDirection.ltr,
       )..layout(),
       _zec = TextPainter(
         text: TextSpan(text: 'ZEC', style: _zecStyle(look)),
         textDirection: TextDirection.ltr,
       )..layout();

  final BalanceLook look;

  /// Gap from the amount's line-box top to the pill: 65 before (Figma
  /// y 452), 67 once shielded (y 454).
  final double pillTop;

  final TextPainter _amount;
  final TextPainter _zec;

  static const transparentPillTop = 65.0;
  static const shieldedPillTop = 67.0;
  static const pillSize = Size(76, 42);

  /// Local y where the pill's band begins (halfway into the gap under the
  /// amount). Particles below it belong to the pill and are dimmed.
  static const pillFrom = 60.0;

  static const _white = Color(0xFFFFFFFF);

  static TextStyle _zecStyle(BalanceLook look) {
    const base = TextStyle(
      fontFamily: VText.geist,
      fontSize: 26,
      fontWeight: FontWeight.w500,
      letterSpacing: -1.04,
      height: 1,
      leadingDistribution: TextLeadingDistribution.even,
    );
    return switch (look) {
      BalanceLook.transparent => base.copyWith(color: const Color(0x99FFFFFF)),
      BalanceLook.solid => base.copyWith(color: _white),
      // Vertical only, so the shader can be laid out before the text: it
      // spans the 26pt line box from the glyphs' own origin.
      BalanceLook.shielded => base.copyWith(
        foreground: Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFEBEBEB), Color(0x99EBEBEB)],
          ).createShader(const Rect.fromLTWH(0, 0, 1, 26)),
      ),
    };
  }

  Size get size =>
      Size(math.max(_amount.width, pillSize.width), pillTop + pillSize.height);

  Rect get _pill => Rect.fromLTWH(
    (size.width - pillSize.width) / 2,
    pillTop,
    pillSize.width,
    pillSize.height,
  );

  void paint(Canvas canvas) {
    final w = size.width;
    _amount.paint(canvas, Offset((w - _amount.width) / 2, 0));

    final pill = _pill;
    switch (look) {
      case BalanceLook.shielded:
        Metal.pill(canvas, pill);
      case BalanceLook.transparent:
      case BalanceLook.solid:
        final rrect = RRect.fromRectAndRadius(
          pill,
          Radius.circular(pill.shortestSide / 2),
        ).deflate(1);
        canvas.drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = look == BalanceLook.solid
                ? _white
                : const Color(0x40FFFFFF),
        );
    }

    canvas.save();
    canvas.translate(
      pill.center.dx - _zec.width / 2,
      pill.center.dy - _zec.height / 2,
    );
    _zec.paint(canvas, Offset.zero);
    canvas.restore();
  }
}
