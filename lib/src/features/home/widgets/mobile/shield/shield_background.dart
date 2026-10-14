import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/physics.dart';
import 'shield_motion.dart';
import 'shield_timeline.dart';

class ShieldScrimPainter extends CustomPainter {
  ShieldScrimPainter(this.shift, {required this.drag}) : super(repaint: drag);

  final double shift;

  /// Pin travel: takes the scrim from 90% to fully opaque while dragging.
  final ValueListenable<double> drag;

  static const _grey = Color(0xFF8A8A8A);
  static const _crimson = Color(0xE6AA2455); // 90% fill opacity

  @override
  void paint(Canvas canvas, Size size) {
    final s = shift;
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(
          0xFF000000,
        ).withValues(alpha: 0.9 + 0.1 * math.max(s, drag.value)),
    );
    final matrix = Matrix4.identity()
      ..translateByDouble(
        size.width * 0.5,
        size.height * ui.lerpDouble(1.021713, 1.0, s)!,
        0,
        1,
      )
      ..scaleByDouble(
        size.width * ui.lerpDouble(3.358229, 4.701546, s)!,
        size.height * ui.lerpDouble(0.654342, 0.916080, s)!,
        1,
        1,
      );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset.zero,
          1,
          [Color.lerp(_grey, _crimson, s)!, const Color(0x00000000)],
          [0, ui.lerpDouble(1, 0.7204, s)!],
          TileMode.clamp,
          matrix.storage,
        ),
    );
  }

  @override
  bool shouldRepaint(ShieldScrimPainter old) =>
      old.shift != shift || old.drag != drag;
}

/// The shield field (Figma 8810:78801): a 626pt disc, clear for its inner
/// 56% and deepening to crimson at the rim.
///
/// On the landing beat (dots settle into the amount, soft haptic) it
/// scales up from nothing on a spring
/// (a little overshoot, no fade). After that it never quite holds still:
/// two slow travelling waves ripple its rim, and soft rings of crimson light
/// pulse outward from it (the first one a little brighter). With Reduce
/// Motion it fades in at full size and holds still.
/// Reads [clock] directly, so it repaints alone once the score is over.
class ShieldBubblePainter extends CustomPainter {
  ShieldBubblePainter({
    required this.clock,
    required this.center,
    required this.reduceMotion,
  }) : super(repaint: clock);

  final ValueListenable<double> clock;
  final Offset center;
  final bool reduceMotion;

  static const _radius = 313.0;
  static const _rim = Color(0xFF972851);
  static const _ring = Color(0xFFAA2455);
  static const _segments = 144;

  static final _inflate = SpringSimulation(
    VMotion.spring(response: 0.8, dampingRatio: 0.72),
    0,
    1,
    0,
  );

  // Ripple rings: the first leaves as the scale lands, then one every
  // [_period].
  static const _firstRing = 0.45;
  static const _period = 3.2;
  static const _life = 3.0;
  static const _travel = 130.0;

  @override
  void paint(Canvas canvas, Size size) {
    final since = clock.value - ShieldTimeline.bubble.start;
    if (since <= 0) return;
    final p = ShieldTimeline.bubble.progress(clock.value);
    final opacity = reduceMotion
        ? VMotion.easeOut.transform(math.min(p / 0.45, 1))
        : 1.0;
    final grow = reduceMotion ? 1.0 : _inflate.x(since);
    final r = _radius * grow;
    if (r < 0.5) return;

    if (!reduceMotion) _paintRings(canvas, since, r, opacity);

    final shader = ui.Gradient.radial(
      center,
      r,
      [const Color(0x00211217), _rim.withValues(alpha: opacity)],
      const [0.5597, 1],
    );
    final paint = Paint()..shader = shader;
    if (reduceMotion) {
      canvas.drawCircle(center, r, paint);
      return;
    }

    // Membrane: two waves running opposite ways round the rim, a gentle 2pt
    // swell that grows with the bubble. Past the radius the gradient clamps
    // to the rim colour, so crests simply bulge outward.
    final amp = 2.0 * grow.clamp(0.0, 1.0);
    final path = Path();
    for (var i = 0; i <= _segments; i++) {
      final th = i / _segments * 2 * math.pi;
      final w =
          0.6 * math.sin(5 * th - 1.3 * since) +
          0.4 * math.sin(3 * th + 0.8 * since + 1.3);
      final rr = r + amp * w;
      final pt = center + Offset(math.cos(th) * rr, math.sin(th) * rr);
      if (i == 0) {
        path.moveTo(pt.dx, pt.dy);
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  /// Soft bands of light leaving the rim: a radial gradient that peaks on
  /// the band's radius, added on top so they glow rather than paint.
  void _paintRings(Canvas canvas, double since, double r, double opacity) {
    final t = since - _firstRing;
    if (t < 0) return;
    final last = (t / _period).floor();
    final first = math.max(0, ((t - _life) / _period).ceil());
    for (var k = first; k <= last; k++) {
      final u = (t - k * _period) / _life;
      if (u <= 0 || u >= 1) continue;
      final peak = k == 0 ? 0.6 : 0.4;
      final fade = math.min(u / 0.08, 1) * (1 - u) * (1 - u);
      final alpha = peak * fade * opacity;
      if (alpha < 0.004) continue;
      final rr = r + _travel * VMotion.easeOut.transform(u);
      final half = 16 + 22 * u;
      final outer = rr + half;
      canvas.drawCircle(
        center,
        outer,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = ui.Gradient.radial(
            center,
            outer,
            [
              const Color(0x00AA2455),
              _ring.withValues(alpha: alpha),
              const Color(0x00AA2455),
            ],
            [(rr - half) / outer, rr / outer, 1],
          ),
      );
    }
  }

  @override
  bool shouldRepaint(ShieldBubblePainter old) =>
      old.clock != clock ||
      old.center != center ||
      old.reduceMotion != reduceMotion;
}
