import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import 'shield_icon.dart';
import 'shield_haptics.dart';
import 'shield_metal.dart';
import 'shield_motion.dart';

/// "Drag to shield": a glass track with a metal pin (Figma 8810:78585/78587).
///
/// The pin tracks the finger 1:1 from wherever it was grabbed, rubber-bands
/// past both ends, and on release either springs home with the finger's
/// velocity or — if released near the end or flicked toward it — gets pulled
/// into the end and locks with a rigid haptic.
class SlideToShield extends StatefulWidget {
  const SlideToShield({
    super.key,
    required this.onCommitted,
    this.progress,
    this.width = 329,
  });

  /// Fires on the frame the pin locks in.
  final VoidCallback onCommitted;

  /// Receives the pin's travel, 0..1, every frame it moves (finger, spring
  /// home or magnet), so the page can respond to the drag.
  final ValueNotifier<double>? progress;

  final double width;
  static const height = 60.0;

  @override
  State<SlideToShield> createState() => _SlideToShieldState();
}

class _SlideToShieldState extends State<SlideToShield>
    with TickerProviderStateMixin {
  static const _knob = Size(70, 60);
  double get _maxX => widget.width - _knob.width;
  double get _armAt => _maxX * 0.9;

  late final AnimationController _pos = AnimationController.unbounded(
    vsync: this,
  );
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 100),
    reverseDuration: const Duration(milliseconds: 220),
  );
  late final AnimationController _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  late final AnimationController _squash = AnimationController.unbounded(
    vsync: this,
    value: 0,
  );
  late final AnimationController _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  int? _pointer;
  double _grab = 0;
  VelocityTracker? _tracker;
  bool _armed = false;
  bool _committed = false;

  @override
  void initState() {
    super.initState();
    _pos.addListener(_report);
  }

  void _report() {
    widget.progress?.value = (_x / _maxX).clamp(0.0, 1.0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _shimmer.stop();
    } else if (!_shimmer.isAnimating) {
      _shimmer.repeat();
    }
  }

  @override
  void dispose() {
    _pos.dispose();
    _press.dispose();
    _flash.dispose();
    _squash.dispose();
    _shimmer.dispose();
    super.dispose();
  }

  double get _x => _pos.value;

  void _down(PointerDownEvent e) {
    if (_pointer != null || _committed) return;
    final knob = Rect.fromLTWH(_x, 0, _knob.width, _knob.height).inflate(12);
    if (!knob.contains(e.localPosition)) return;
    _pointer = e.pointer;
    _pos.stop();
    _grab = e.localPosition.dx - _x;
    _tracker = VelocityTracker.withKind(e.kind)
      ..addPosition(e.timeStamp, e.localPosition);
    _press.forward();
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    _tracker?.addPosition(e.timeStamp, e.localPosition);
    final raw = e.localPosition.dx - _grab;
    // Soft walls instead of hard stops.
    final x = raw < 0
        ? VMotion.rubberBand(raw, _knob.width)
        : raw > _maxX
        ? _maxX + VMotion.rubberBand(raw - _maxX, _knob.width)
        : raw;
    _pos.value = x;
    _updateArmed(x >= _armAt);
  }

  void _up(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    _press.reverse();
    final v = e is PointerUpEvent
        ? (_tracker?.getVelocity().pixelsPerSecond.dx ?? 0)
        : 0.0;
    _tracker = null;
    if (e is PointerCancelEvent) {
      _updateArmed(false);
      _pos.animateWith(
        SpringSimulation(VMotion.spring(response: 0.34), _x, 0, 0),
      );
    } else {
      _release(v);
    }
  }

  void _updateArmed(bool armed) {
    if (armed == _armed) return;
    _armed = armed;
    Haptics.selection();
  }

  void _release(double velocity) {
    final x = _x;
    // Commit if it's nearly there, or if the flick would carry it there.
    final projected = x + VMotion.project(velocity);
    if (x >= _armAt || (x >= _maxX * 0.5 && projected >= _maxX)) {
      _commit(velocity);
    } else {
      _updateArmed(false);
      _pos.animateWith(
        SpringSimulation(VMotion.spring(response: 0.34), x, 0, velocity),
      );
    }
  }

  void _commit(double velocity) {
    if (_committed) return;
    _committed = true;
    final x = _x;
    if (x >= _maxX) {
      // Already at (or stretched past) the end: settle back onto it.
      _pos.animateWith(
        SpringSimulation(VMotion.spring(response: 0.2), x, _maxX, velocity),
      );
      _lockIn();
      return;
    }
    // Pulled the rest of the way, like a magnet catching the pin.
    _pos
        .animateWith(GravitySimulation(5200, x, _maxX, math.max(velocity, 450)))
        .whenComplete(() {
          _pos.value = _maxX;
          _lockIn();
        });
  }

  void _lockIn() {
    if (!mounted) return;
    Haptics.impact(ImpactStyle.rigid);
    _flash.forward(from: 0);
    _squash.value = 1;
    _squash.animateWith(
      SpringSimulation(
        VMotion.spring(response: 0.32, dampingRatio: 0.45),
        1,
        0,
        0,
      ),
    );
    widget.onCommitted();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      label: 'Slide to shield',
      enabled: !_committed,
      onTap: _committed ? null : () => _commit(1200),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: AnimatedBuilder(
          animation: Listenable.merge([
            _pos,
            _press,
            _flash,
            _squash,
            _shimmer,
          ]),
          builder: (context, _) {
            final x = _x.clamp(-_knob.width, widget.width);
            final p = (x / _maxX).clamp(0.0, 1.0);
            final flash = _flashCurve(_flash.value);
            return SizedBox.fromSize(
              size: Size(widget.width, SlideToShield.height),
              child: _Track(
                progress: p,
                flash: flash,
                label: _Label(
                  progress: p,
                  shimmer: reduce ? null : _shimmer.value,
                ),
                knob: Positioned(
                  left: x,
                  top: 0,
                  child: Transform(
                    alignment: Alignment.centerRight,
                    transform: Matrix4.diagonal3Values(
                      (1 - 0.04 * _press.value) * (1 + 0.07 * _squash.value),
                      (1 - 0.04 * _press.value) * (1 - 0.07 * _squash.value),
                      1,
                    ),
                    child: const _MetalKnob(),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Flash: near-instant attack, slow release.
  static double _flashCurve(double t) {
    if (t <= 0 || t >= 1) return 0;
    const attack = 0.12;
    if (t < attack) return VMotion.easeOut.transform(t / attack);
    return 1 - VMotion.easeOut.transform((t - attack) / (1 - attack));
  }
}

const _white = Color(0xFFFFFFFF);

class _Track extends StatelessWidget {
  const _Track({
    required this.progress,
    required this.flash,
    required this.label,
    required this.knob,
  });

  final double progress;
  final double flash;
  final Widget label;
  final Widget knob;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    final radius = BorderRadius.circular(99);
    // Black glass at 40%, no edge. Dragging lifts a faint haze around it;
    // the lock flashes it.
    final tint = 0.10 * flash;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Outer haze, fading in with the drag.
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: _OuterGlowPainter(p)),
          ),
        ),
        ClipRRect(
          borderRadius: radius,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 27.5, sigmaY: 27.5),
                  child: ColoredBox(
                    color: Color.alphaBlend(
                      _white.withValues(alpha: tint),
                      const Color(0x66000000),
                    ),
                  ),
                ),
              ),
              Positioned.fill(child: label),
              knob,
            ],
          ),
        ),
      ],
    );
  }
}

/// Track drop shadow drawn only outside the glass (Figma's "show shadow
/// behind node" is off), so the translucent fill stays clean.
class _OuterGlowPainter extends CustomPainter {
  _OuterGlowPainter(this.opacity);

  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0.001) return;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(99));
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(rect.inflate(400))
        ..addRRect(rrect),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = _white.withValues(alpha: 0.22 * opacity)
        // Figma blur radius 125 = Gaussian sigma 62.5.
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 62.5),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OuterGlowPainter old) => old.opacity != opacity;
}

class _Label extends StatelessWidget {
  const _Label({required this.progress, required this.shimmer});

  final double progress;

  /// 0..1 loop phase, or null for a static label (Reduce Motion).
  final double? shimmer;

  @override
  Widget build(BuildContext context) {
    // Clears by halfway and drifts a little with the pin.
    final opacity = (1 - progress / 0.5).clamp(0.0, 1.0);
    Widget text = Text(
      'Slide to shield',
      style: VText.labelL.copyWith(color: _white),
    );
    final phase = shimmer;
    if (phase != null && progress == 0) {
      // Slide-to-unlock sheen: sweep for 60% of the loop, rest for 40%.
      final sweep = (phase / 0.6).clamp(0.0, 1.0);
      text = ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) {
          final w = bounds.width;
          final center = -0.4 * w + sweep * 1.8 * w;
          return LinearGradient(
            colors: const [
              Color(0x9EFFFFFF),
              Color(0xFFFFFFFF),
              Color(0x9EFFFFFF),
            ],
            stops: const [0, 0.5, 1],
          ).createShader(
            Rect.fromLTWH(center - w * 0.35, 0, w * 0.7, bounds.height),
          );
        },
        child: text,
      );
    }
    return IgnorePointer(
      child: Opacity(
        opacity: opacity,
        child: Transform.translate(
          offset: Offset(progress * 24, 0),
          child: Center(child: text),
        ),
      ),
    );
  }
}

/// Metal pin (Figma 8810:78587), in the shared [Metal] finish. Static: it
/// only moves, squashes and dims with the press.
class _MetalKnob extends StatelessWidget {
  const _MetalKnob();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _SlideToShieldState._knob.width,
      height: _SlideToShieldState._knob.height,
      child: const CustomPaint(
        painter: _MetalPainter(),
        child: Center(
          child: Padding(
            padding: EdgeInsets.only(left: 1, top: 1),
            child: ShieldIcon(
              'knob_shield_fill',
              box: Size.square(27),
              width: 21.4133,
              height: 24.7507,
            ),
          ),
        ),
      ),
    );
  }
}

class _MetalPainter extends CustomPainter {
  const _MetalPainter();

  @override
  void paint(Canvas canvas, Size size) =>
      Metal.pill(canvas, Offset.zero & size);

  @override
  bool shouldRepaint(_MetalPainter old) => false;
}
