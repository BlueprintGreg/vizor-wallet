import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import '../../../../../core/theme/app_theme.dart';
import '../../../../../core/widgets/app_button.dart';
import '../../../../../core/widgets/app_icon.dart';

/// Keeps the signing controls in the same slots while their content changes.
/// Only the transaction owner supplies actions and their enabled state.
class KeystoneShieldFooter extends StatelessWidget {
  const KeystoneShieldFooter({
    required this.showQr,
    required this.onCancel,
    required this.onNext,
    required this.onShowQr,
    super.key,
  });
  final bool showQr;
  final VoidCallback? onCancel;
  final VoidCallback? onNext;
  final VoidCallback? onShowQr;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final colorDuration = Duration(milliseconds: reduced ? 120 : 180);
    final contentDuration = Duration(milliseconds: reduced ? 120 : 140);
    final enabled = (showQr ? onNext : onShowQr) != null;
    final colors = context.colors.button;
    final labelColor = !enabled
        ? colors.disabled.label
        : showQr
        ? colors.primary.label
        : colors.secondary.label;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.s,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final buttonWidth = (constraints.maxWidth - AppSpacing.s) / 2;
          // Reserve the narrowest interior (primary's border) in both states.
          final labelWidth = math.max(
            1.0,
            buttonWidth - AppSpacing.sm * 2 - AppSpacing.xxs * 2 - 3,
          );
          double measure(String text, double width) {
            final painter = TextPainter(
              text: TextSpan(text: text, style: AppTypography.labelLarge),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout(maxWidth: math.max(1, width));
            final height = painter.height;
            painter.dispose();
            return height;
          }

          const iconSize = 20.0;
          final contentHeight = math.max(
            iconSize,
            math.max(
              measure('Cancel', labelWidth),
              math.max(
                measure('Show QR', labelWidth),
                measure('Next step', labelWidth - iconSize - AppSpacing.xxs),
              ),
            ),
          );
          final height = math.max(
            AppButtonSizing.largeHeight,
            contentHeight + AppSpacing.xs * 2 + 3,
          );
          return Row(
            children: [
              Expanded(
                child: AppButton(
                  key: const ValueKey('mobile_keystone_cancel'),
                  expand: true,
                  constrainContent: true,
                  height: height,
                  variant: AppButtonVariant.ghost,
                  onPressed: onCancel,
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: Color(0xFFFFFFFF)),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.s),
              Expanded(
                child: AppButton(
                  key: const ValueKey('mobile_keystone_stage_action'),
                  expand: true,
                  constrainContent: true,
                  height: height,
                  stateTransitionDuration: colorDuration,
                  variant: showQr
                      ? AppButtonVariant.primary
                      : AppButtonVariant.secondary,
                  onPressed: showQr ? onNext : onShowQr,
                  child: TweenAnimationBuilder<Color?>(
                    tween: ColorTween(end: labelColor),
                    duration: Duration(milliseconds: reduced ? 120 : 160),
                    builder: (context, color, child) => DefaultTextStyle.merge(
                      style: TextStyle(color: color),
                      child: IconTheme.merge(
                        data: IconThemeData(color: color),
                        child: child!,
                      ),
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      height: contentHeight,
                      child: AnimatedSwitcher(
                        duration: contentDuration,
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeOut,
                        layoutBuilder: (current, previous) => Stack(
                          alignment: Alignment.center,
                          children: [
                            for (final child in previous)
                              ExcludeSemantics(
                                child: IgnorePointer(child: child),
                              ),
                            ?current,
                          ],
                        ),
                        child: Row(
                          key: ValueKey(showQr),
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Flexible(
                              child: Text(
                                showQr ? 'Next step' : 'Show QR',
                                textAlign: TextAlign.center,
                              ),
                            ),
                            if (showQr) ...[
                              const SizedBox(width: AppSpacing.xxs),
                              const SizedBox.square(
                                dimension: iconSize,
                                child: AppIcon(AppIcons.chevronForward),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
