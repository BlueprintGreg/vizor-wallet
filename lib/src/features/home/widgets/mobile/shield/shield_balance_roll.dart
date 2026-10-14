import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';

import 'shield_motion.dart';

/// Text that rolls to a new value like an odometer: the two values are lined
/// up on the decimal point, and only the characters that differ roll (old
/// glyph lifts out, new one rises in, staggered left to right). Unchanged
/// characters stay put, sliding sideways only if the widths around them
/// change. The box width glides between the two measurements so trailing
/// content never jumps.
class ShieldBalanceRoll extends StatefulWidget {
  const ShieldBalanceRoll(
    this.text, {
    super.key,
    required this.style,
    this.delay = Duration.zero,
    this.fromText,
  });

  final String text;
  final String? fromText;
  final TextStyle style;

  /// Hold before the roll starts (lets a covering overlay clear first).
  final Duration delay;

  @override
  State<ShieldBalanceRoll> createState() => _ShieldBalanceRollState();
}

class _ShieldBalanceRollState extends State<ShieldBalanceRoll>
    with SingleTickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 720);
  static const _stagger = 0.06; // of the timeline, per character
  static const _window = 0.5; // of the timeline, per character

  late String _from = widget.fromText ?? widget.text;
  late String _to = widget.text;
  late final AnimationController _roll = AnimationController(
    vsync: this,
    duration: _duration,
    value: widget.fromText != null && widget.fromText != widget.text ? 0 : 1,
  );
  Timer? _start;

  @override
  void initState() {
    super.initState();
    if (_roll.value == 0) _start = Timer(widget.delay, () => _roll.forward());
  }

  @override
  void didUpdateWidget(ShieldBalanceRoll old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _from = _to;
      _to = widget.text;
      _roll.value = 0;
      _start?.cancel();
      _start = Timer(widget.delay, () => _roll.forward(from: 0));
    }
  }

  @override
  void dispose() {
    _start?.cancel();
    _roll.dispose();
    super.dispose();
  }

  List<double> _advances(String s) {
    return [
      for (final ch in s.characters)
        (TextPainter(
          text: TextSpan(text: ch, style: widget.style),
          textDirection: TextDirection.ltr,
        )..layout()).width,
    ];
  }

  /// Left edge of each glyph.
  static List<double> _offsets(List<double> adv) {
    final out = <double>[];
    var x = 0.0;
    for (final a in adv) {
      out.add(x);
      x += a;
    }
    return out;
  }

  /// Where the values line up: the decimal point, or the end.
  static int _anchor(List<String> chars) {
    final i = chars.indexOf('.');
    return i < 0 ? chars.length : i;
  }

  /// Progress of the [rank]th rolling glyph; only changed glyphs count, so
  /// the first one that changes starts right away.
  double _local(double t, int rank, {double lag = 0}) {
    final start = (rank * _stagger + lag).clamp(0.0, 1 - _window);
    return VMotion.easeOut.transform(((t - start) / _window).clamp(0.0, 1.0));
  }

  Widget _rolling(String ch, double x, double p, {required bool out}) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    final lift = (widget.style.fontSize ?? 16) * 0.42;
    final visible = out ? 1 - p : p;
    final dy = reduce ? 0.0 : (out ? -lift * p : lift * (1 - p));
    Widget glyph = Text(ch, style: widget.style, softWrap: false);
    final blur = reduce ? 0.0 : 3 * (1 - visible);
    if (blur > 0.05) {
      glyph = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: glyph,
      );
    }
    return Positioned(
      left: x,
      top: 0,
      child: Opacity(
        opacity: visible.clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset(0, dy), child: glyph),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fromAdv = _advances(_from);
    final toAdv = _advances(_to);
    final from = _from.characters.toList();
    final to = _to.characters.toList();
    final fromX = _offsets(fromAdv);
    final toX = _offsets(toAdv);
    final shift = _anchor(to) - _anchor(from);
    final fromW = fromAdv.fold(0.0, (a, b) => a + b);
    final toW = toAdv.fold(0.0, (a, b) => a + b);
    final height = (TextPainter(
      text: TextSpan(text: _to, style: widget.style),
      textDirection: TextDirection.ltr,
    )..layout()).height;

    return AnimatedBuilder(
      animation: _roll,
      builder: (context, _) {
        final t = _roll.value;
        if (t >= 1) return Text(_to, style: widget.style, softWrap: false);
        final glide = VMotion.easeInOut.transform(t);
        final width = lerpDouble(fromW, toW, glide)!;
        final children = <Widget>[];
        // Outgoing: only glyphs whose partner in the new value differs.
        var rank = 0;
        for (var j = 0; j < from.length; j++) {
          final i = j + shift;
          if (i >= 0 && i < to.length && to[i] == from[j]) continue;
          children.add(
            _rolling(from[j], fromX[j], _local(t, rank++), out: true),
          );
        }
        // Incoming: unchanged glyphs hold still (gliding sideways with the
        // width); changed ones rise in.
        rank = 0;
        for (var i = 0; i < to.length; i++) {
          final j = i - shift;
          if (j >= 0 && j < from.length && from[j] == to[i]) {
            children.add(
              Positioned(
                left: lerpDouble(fromX[j], toX[i], glide)!,
                top: 0,
                child: Text(to[i], style: widget.style, softWrap: false),
              ),
            );
          } else {
            children.add(
              _rolling(to[i], toX[i], _local(t, rank++, lag: 0.08), out: false),
            );
          }
        }
        return SizedBox(
          width: width,
          height: height,
          child: Stack(clipBehavior: Clip.none, children: children),
        );
      },
    );
  }
}
