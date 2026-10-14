import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import '../../../../../core/theme/app_theme.dart';
import '../../../../../core/widgets/app_button.dart';
import '../../../../../core/widgets/app_icon.dart';
import 'balance_art.dart';
import 'particles/particle_field.dart';
import 'shield_background.dart';
import 'shield_haptics.dart';
import 'shield_icon.dart';
import 'shield_motion.dart';
import 'shield_particle_art.dart';
import 'shield_timeline.dart';
import 'slide_to_shield.dart';
import '../../../../keystone/widgets/keystone_pczt_qr_stage.dart';

// Transaction owners supply real states. This presentation never starts a
// transaction, guesses its progress, or treats a pending broadcast as success.
enum MobileShieldPhase { review, working, hardware, succeeded, pending, failed }

class MobileShieldScene extends StatefulWidget {
  const MobileShieldScene({
    required this.phase,
    required this.amount,
    required this.title,
    this.resultAmount,
    this.body,
    this.focusChild,
    this.focusBuilder,
    this.footer,
    this.onCommit,
    this.onClose,
    this.onComplete,
    this.canLeave = true,
    super.key,
  });
  final MobileShieldPhase phase;
  final String amount;
  final String? resultAmount;
  final String title;
  final String? body;
  final Widget? focusChild;
  final Widget Function(BuildContext, BoxConstraints)? focusBuilder;
  final Widget? footer;
  final VoidCallback? onCommit;
  final VoidCallback? onClose;
  final VoidCallback? onComplete;
  final bool canLeave;

  @override
  State<MobileShieldScene> createState() => _MobileShieldSceneState();
}

class _MobileShieldSceneState extends State<MobileShieldScene>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker = createTicker(_tick);
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: ShieldTimeline.entrance,
  )..forward();
  final _clock = ValueNotifier<double>(0);
  final _drag = ValueNotifier<double>(0);
  ShieldParticleArt? _art;
  ParticleField? _field;
  Duration _elapsed = Duration.zero;
  double? _assemblyAt;
  bool _successHaptic = false;
  bool _landHaptic = false;
  bool _reduce = false;
  bool _focusRevealed = false;
  int _preparation = 0;
  late double _fontSize;

  bool get _review => widget.phase == MobileShieldPhase.review;
  double? get _a => _assemblyAt == null ? null : _clock.value - _assemblyAt!;
  String get _result => widget.resultAmount ?? widget.amount;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _prepare();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce != _reduce) {
      _reduce = reduce;
      _field?.dispose();
      _field = null;
    }
    if (!_ticker.isActive && !_review) _ticker.start();
  }

  @override
  void didUpdateWidget(MobileShieldScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.amount != widget.amount ||
        oldWidget.resultAmount != widget.resultAmount) {
      _prepare();
    }
    if (oldWidget.phase == MobileShieldPhase.review && !_review) {
      if (!_ticker.isActive) _ticker.start();
    }
    if (oldWidget.phase != widget.phase &&
        widget.phase == MobileShieldPhase.succeeded) {
      _assemblyAt = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _elapsed = Duration.zero;
      if (!_review && !_ticker.isActive) _ticker.start();
    } else {
      _ticker.stop();
    }
  }

  double _fitFont(String text) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: VText.display.copyWith(
          fontSize: 56,
          fontWeight: FontWeight.w700,
          height: 1,
          letterSpacing: -2.24,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final size = math.min(56.0, 56 * 345 / math.max(1, painter.width));
    painter.dispose();
    return size;
  }

  Future<void> _prepare() async {
    final generation = ++_preparation;
    _fontSize = math.min(_fitFont(widget.amount), _fitFont(_result));
    try {
      final art = await ShieldParticleArt.load(
        widget.amount,
        resultAmount: _result,
        count: shieldCloudDots.length,
        random: math.Random(7),
        fontSize: _fontSize,
      );
      if (!mounted || generation != _preparation) {
        art.dispose();
        return;
      }
      _field?.dispose();
      _field = null;
      final old = _art;
      setState(() => _art = art);
      old?.dispose();
    } catch (error, stack) {
      debugPrint('Shield artwork preparation failed: $error\n$stack');
      // Keep the readable amounts and real operation controls usable even if
      // decorative assets cannot be prepared.
    }
  }

  FieldGeometry _geometry(ShieldParticleArt art) {
    final before = _balance(widget.amount, false);
    final after = _balance(_result, true);
    const center = Offset(196.5, 200);
    final textRect = Rect.fromLTWH(
      196.5 - before.size.width / 2,
      200,
      before.size.width,
      before.size.height,
    );
    final resultRect = Rect.fromLTWH(
      196.5 - after.size.width / 2,
      200,
      after.size.width,
      after.size.height,
    );
    final shieldRect = Rect.fromCenter(
      center: center,
      width: art.shieldSize.width,
      height: art.shieldSize.height,
    );
    return FieldGeometry(
      cloudCenter: center,
      cloudSlots: [
        for (final dot in shieldCloudDots) dot.p + const Offset(0.5, -186.7),
      ],
      cloudSizes: [for (final dot in shieldCloudDots) dot.size],
      cloudAlphas: [for (final dot in shieldCloudDots) dot.alpha],
      textRect: textRect,
      textPoints: art.textPoints,
      shieldRect: shieldRect,
      shieldSlots: [
        for (final slot in art.shieldCells) shieldRect.topLeft + slot,
      ],
      balancePoints: [
        for (final p in art.balancePoints) resultRect.topLeft + p,
      ],
      iconPoints: [
        for (final p in art.iconPoints)
          p +
              Offset(
                196.5 - ShieldParticleArt.iconWidth / 2,
                30 - ShieldParticleArt.iconHeight / 2,
              ),
      ],
      textDimFrom: BalanceArt.pillFrom,
      balanceDimFrom: resultRect.top + BalanceArt.pillFrom,
      screen: const Size(393, 450),
      emitter: center,
    );
  }

  BalanceArt _balance(String amount, bool shielded) => BalanceArt(
    amount,
    look: shielded ? BalanceLook.shielded : BalanceLook.transparent,
    pillTop: shielded
        ? BalanceArt.shieldedPillTop
        : BalanceArt.transparentPillTop,
    fontSize: _fontSize,
  );

  void _tick(Duration elapsed) {
    // Ticker.start resets its elapsed time; retain scene time across resume.
    final step = (elapsed - _elapsed).inMicroseconds / 1e6;
    _elapsed = elapsed;
    final t = _clock.value + math.max(0.0, step);
    if (_art != null && _field == null) {
      _field = ParticleField(
        geometry: _geometry(_art!),
        atlas: _art!.atlas,
        reduceMotion: _reduce,
      );
    }
    if (widget.phase == MobileShieldPhase.succeeded &&
        _assemblyAt == null &&
        t >= 3) {
      _assemblyAt = t;
    }
    final a = _assemblyAt == null ? null : t - _assemblyAt!;
    _field?.hapticsEnabled =
        widget.phase == MobileShieldPhase.working ||
        widget.phase == MobileShieldPhase.succeeded;
    _field?.update(t, a);
    if (a != null && a >= ShieldTimeline.lock && !_successHaptic) {
      _successHaptic = true;
      Haptics.success();
    }
    if (a != null && a >= ShieldTimeline.land && !_landHaptic) {
      _landHaptic = true;
      Haptics.impact(ImpactStyle.soft);
    }
    _clock.value = t;
    if (!_focusRevealed && t >= ShieldTimeline.fall.end) {
      setState(() => _focusRevealed = true);
    }
    if (_reduce && a != null && a >= ShieldTimeline.done) _ticker.stop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _entrance.dispose();
    _clock.dispose();
    _drag.dispose();
    _field?.dispose();
    _art?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppTheme(
    data: AppThemeData.dark,
    child: AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: const Color(0x00000000),
        systemNavigationBarColor: const Color(0xFF000000),
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: PopScope(
        canPop: widget.onClose == null && widget.canLeave,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && widget.canLeave) widget.onClose?.call();
        },
        child: Scaffold(
          backgroundColor: const Color(0xFF000000),
          body: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedBuilder(
                animation: _clock,
                builder: (_, _) => CustomPaint(
                  painter: ShieldScrimPainter(
                    _a == null
                        ? 0
                        : ShieldTimeline.backgroundShift.eased(
                            _a!,
                            VMotion.ease,
                          ),
                    drag: _drag,
                  ),
                ),
              ),
              FadeTransition(
                opacity: CurvedAnimation(
                  parent: _entrance,
                  curve: VMotion.easeOut,
                ),
                child: SafeArea(
                  child: Column(
                    children: [
                      SizedBox(
                        height: 56,
                        child: Row(
                          children: [
                            const SizedBox(width: 16),
                            const Spacer(),
                            if (widget.onClose != null)
                              Semantics(
                                button: true,
                                label: 'Back to wallet',
                                child: GestureDetector(
                                  onTap: widget.canLeave
                                      ? widget.onClose
                                      : null,
                                  child: const SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: Center(
                                      child: AppIcon(
                                        AppIcons.cross,
                                        color: Color(0xFFFFFFFF),
                                        size: 24,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            const SizedBox(width: 8),
                          ],
                        ),
                      ),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final requestedFocus =
                                widget.focusBuilder?.call(
                                  context,
                                  BoxConstraints(
                                    maxWidth: math.max(
                                      0,
                                      math.min(360, constraints.maxWidth - 48),
                                    ),
                                    maxHeight: constraints.maxHeight,
                                  ),
                                ) ??
                                widget.focusChild;
                            final focus = _focusRevealed
                                ? requestedFocus
                                : null;
                            return Stack(
                              fit: StackFit.expand,
                              children: [
                                AnimatedBuilder(
                                  animation: _clock,
                                  builder: (_, _) => _visual(focus != null),
                                ),
                                if (focus != null)
                                  Center(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 24,
                                      ),
                                      child: ConstrainedBox(
                                        constraints: BoxConstraints(
                                          maxWidth: 360,
                                          maxHeight: constraints.maxHeight,
                                        ),
                                        child: SingleChildScrollView(
                                          child: focus,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: MediaQuery.sizeOf(context).height * 0.26,
                          ),
                          child: SingleChildScrollView(
                            child: Semantics(
                              liveRegion: true,
                              child: Column(
                                children: [
                                  if (!_review)
                                    Text(
                                      widget.title,
                                      textAlign: TextAlign.center,
                                      style: AppTypography.bodyLarge.copyWith(
                                        color: const Color(0xFFFFFFFF),
                                      ),
                                    ),
                                  if (widget.body != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                        widget.body!,
                                        textAlign: TextAlign.center,
                                        style: AppTypography.bodySmall.copyWith(
                                          color: const Color(0xCCFFFFFF),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
                        child: _footer(),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _footer() {
    if (widget.footer != null) return widget.footer!;
    if (_review) {
      return LayoutBuilder(
        builder: (_, c) => Center(
          child: SlideToShield(
            key: const ValueKey('mobile_shield_slide'),
            width: math.min(329, c.maxWidth),
            progress: _drag,
            onCommitted: () => widget.onCommit?.call(),
          ),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _clock,
      builder: (_, _) {
        final ready =
            widget.phase == MobileShieldPhase.succeeded &&
            (_a ?? 0) >= ShieldTimeline.completeIn.end;
        if (!ready) return const SizedBox(height: 50);
        return SizedBox(
          width: 230,
          child: AppButton(
            key: const ValueKey('mobile_shield_complete'),
            onPressed: widget.onComplete,
            expand: true,
            constrainContent: true,
            variant: AppButtonVariant.secondary,
            enabledBackgroundColor: const Color(0xFFFFFFFF),
            enabledLabelColor: const Color(0xFF141818),
            child: const Text('Complete'),
          ),
        );
      },
    );
  }

  Widget _visual(bool hasFocus) {
    final a = _a;
    final t = _clock.value;
    final before = _balance(widget.amount, false);
    final after = _balance(_result, true);
    return Semantics(
      label: '${_review ? widget.amount : _result} ZEC',
      child: ExcludeSemantics(
        child: Center(
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: 393,
              height: 450,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (a != null)
                    Positioned.fill(
                      child: CustomPaint(
                        painter: ShieldBubblePainter(
                          clock: _clockForAssembly,
                          center: const Offset(196.5, 200),
                          reduceMotion: _reduce,
                        ),
                      ),
                    ),
                  if (_field != null && !hasFocus)
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: CustomPaint(painter: ParticlePainter(_field!)),
                      ),
                    ),
                  if (hasFocus && _field != null)
                    Positioned.fill(
                      child: Opacity(
                        opacity: 0.25,
                        child: CustomPaint(
                          painter: _PeripheralParticles(_field!),
                        ),
                      ),
                    ),
                  if ((_review || t < ShieldTimeline.fall.end) &&
                      !hasFocus) ...[
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 10,
                      child: const Center(
                        child: ShieldIcon(
                          'overlay_transparent',
                          box: Size.square(40),
                          width: 36.6667,
                          height: 36.6667,
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 145,
                      child: Text(
                        _review ? widget.title : 'Transparent balance',
                        textAlign: TextAlign.center,
                        style: AppTypography.headlineSmall.copyWith(
                          color: const Color(0xFFFFFFFF),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 196.5 - before.size.width / 2,
                      top:
                          200 +
                          (_review || _reduce ? 0 : ShieldTimeline.fallDy(t)),
                      child: Opacity(
                        opacity: _review || !_reduce
                            ? 1
                            : 1 - ShieldTimeline.dissolve(t),
                        child: Transform.scale(
                          scale: _review || _reduce
                              ? 1
                              : ShieldTimeline.fallScale(t),
                          child: _AmountDissolve(
                            progress: _review || _reduce
                                ? 0
                                : ShieldTimeline.dissolve(t),
                            child: CustomPaint(
                              size: before.size,
                              painter: _BalancePainter(before),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (a != null && a >= ShieldTimeline.textIn.start) ...[
                    Positioned(
                      left: 176.5,
                      top: 10,
                      child: Opacity(
                        opacity: ShieldTimeline.iconIn.eased(a),
                        child: const ShieldIcon(
                          'success_shield_fill',
                          box: Size.square(40),
                          width: 32,
                          height: 37,
                        ),
                      ),
                    ),
                    Positioned(
                      left: 196.5 - after.size.width / 2,
                      top: 200,
                      child: Opacity(
                        opacity: ShieldTimeline.textIn.eased(a),
                        child: CustomPaint(
                          size: after.size,
                          painter: _BalancePainter(after),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  ValueListenable<double> get _clockForAssembly =>
      _AssemblyClock(_clock, () => _assemblyAt);
}

class _AssemblyClock extends ChangeNotifier implements ValueListenable<double> {
  _AssemblyClock(this.clock, this.start);
  final ValueNotifier<double> clock;
  final double? Function() start;
  @override
  double get value => clock.value - (start() ?? clock.value);
  @override
  void addListener(VoidCallback listener) => clock.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => clock.removeListener(listener);
}

class _BalancePainter extends CustomPainter {
  _BalancePainter(this.art);
  final BalanceArt art;
  @override
  void paint(Canvas canvas, Size size) => art.paint(canvas);
  @override
  bool shouldRepaint(_BalancePainter old) => true;
}

class _PeripheralParticles extends CustomPainter {
  _PeripheralParticles(this.field) : super(repaint: field);
  final ParticleField field;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(8, 10, 377, 420),
            const Radius.circular(24),
          ),
        ),
    );
    canvas.translate(196.5, 200);
    canvas.scale(2.0);
    canvas.translate(-196.5, -200);
    field.paint(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PeripheralParticles old) => old.field != field;
}

class MobileShieldKeystoneQr extends StatelessWidget {
  const MobileShieldKeystoneQr({
    required this.constraints,
    required this.urParts,
    super.key,
  });
  final BoxConstraints constraints;
  final List<String> urParts;
  @override
  Widget build(BuildContext context) {
    final size = math.max(
      1.0,
      math.min(
        280.0,
        math.min(constraints.maxWidth - 32, constraints.maxHeight - 32),
      ),
    );
    return Center(
      child: Container(
        key: const ValueKey('mobile_shield_keystone_qr'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFFFF),
          borderRadius: BorderRadius.circular(AppRadii.large),
        ),
        child: KeystonePcztQrStage(
          phase: KeystonePcztQrStagePhase.ready,
          urParts: urParts,
          error: null,
          size: size,
          scanOptimized: true,
        ),
      ),
    );
  }
}

class _AmountDissolve extends StatelessWidget {
  const _AmountDissolve({required this.progress, required this.child});

  final double progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (progress <= 0) return child;
    if (progress >= 1) return const SizedBox.shrink();
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final edge = bounds.height * 0.08;
        final front =
            bounds.height + edge - (bounds.height + 2 * edge) * progress;
        return ui.Gradient.linear(
          Offset(0, front - edge),
          Offset(0, front + edge),
          const [Color(0xFFFFFFFF), Color(0x00FFFFFF)],
        );
      },
      child: child,
    );
  }
}

/// Status-text sheen: a brighter band gliding left to right on a loop.
