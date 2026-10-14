import 'package:flutter/painting.dart';

/// The brushed-metal finish of the drag pin (Figma 8810:78587), shared by
/// the pin and the shielded "ZEC" pill: a linear fill #8D939E to #1F1F25 and
/// a 2px inside stroke graded white, #44454A at 56%, #ECECEC, both top to
/// bottom.
abstract final class Metal {
  static const _fill = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF8D939E), Color(0xFF1F1F25)],
  );

  static const _stroke = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFFFFFFF), Color(0xFF44454A), Color(0xFFECECEC)],
    stops: [0, 0.558, 1],
  );

  /// Paints a fully rounded metal pill filling [rect].
  static void pill(Canvas canvas, Rect rect) {
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(rect.shortestSide / 2),
    );
    canvas.drawRRect(rrect, Paint()..shader = _fill.createShader(rect));
    canvas.drawDRRect(
      rrect,
      rrect.deflate(2),
      Paint()..shader = _stroke.createShader(rect),
    );
  }
}
