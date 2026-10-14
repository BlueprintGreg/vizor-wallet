import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

class ShieldScrimPainter extends CustomPainter {
  ShieldScrimPainter(this.shift, {required this.drag}) : super(repaint: drag);

  final double shift;

  /// Pin travel: takes the scrim from 90% to fully opaque while dragging.
  final ValueListenable<double> drag;

  static const _grey = Color(0xFF252B29);
  static const _crimson = Color(0xFF35232B); // 90% fill opacity

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
