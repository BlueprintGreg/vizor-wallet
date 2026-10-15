import 'package:flutter/widgets.dart';

import '../../../../core/layout/mobile/app_mobile_sheet.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../home/widgets/mobile/shield/shield_hardware_motion.dart';

/// Mobile-only content. The host owns the scrim and MobileModalCard.
class MobileLedgerSheetContent extends StatelessWidget {
  const MobileLedgerSheetContent({
    required this.title,
    required this.onClose,
    required this.children,
    this.actions = const [],
    this.titleHeight,
    super.key,
  });
  final String title;
  final VoidCallback? onClose;
  final List<Widget> children;
  final List<Widget> actions;
  final double? titleHeight;

  @override
  Widget build(BuildContext context) {
    final presentation = context
        .dependOnInheritedWidgetOfExactType<LedgerInlinePresentation>();
    final inline = presentation != null;
    final motion = inline ? ShieldHardwarePresentation.maybeOf(context) : null;
    final heading = Text(
      title,
      textAlign: TextAlign.center,
      style: AppTypography.headlineSmall.copyWith(
        color: const Color(0xFFFFFFFF),
      ),
    );
    final header = motion == null
        ? heading
        : SizedBox(
            height: titleHeight,
            child: Center(
              child: ShieldStageTransition(identity: title, child: heading),
            ),
          );
    final buttons = <Widget>[
      ...actions,
      if (inline && onClose != null) ...[
        const SizedBox(height: AppSpacing.md),
        MobileLedgerAction(presentation.closeLabel, onPressed: onClose),
      ],
    ];
    if (motion != null) {
      return Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, bounds) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: bounds.maxWidth,
                    minHeight: bounds.maxHeight,
                  ),
                  child: Center(
                    child: Opacity(
                      opacity: motion.mix,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          header,
                          const SizedBox(height: AppSpacing.md),
                          ...children,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          ExcludeSemantics(
            excluding: !motion.interactive,
            child: ExcludeFocus(
              excluding: !motion.interactive,
              child: IgnorePointer(
                ignoring: !motion.interactive,
                child: Opacity(
                  opacity: motion.footerOpacity,
                  child: Transform.translate(
                    offset: Offset(0, motion.footerDy),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: buttons,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: inline
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.stretch,
      children: [
        if (inline) ...[header, const SizedBox(height: AppSpacing.md)],
        ...children,
        ...actions,
        if (inline && onClose != null) ...[
          const SizedBox(height: AppSpacing.md),
          MobileLedgerAction(presentation.closeLabel, onPressed: onClose),
        ],
      ],
    );
    if (inline) return body;
    return MobileModalScaffold(
      title: title,
      titleMaxLines: 3,
      showClose: onClose != null,
      onClose: onClose ?? () {},
      constrainBody: true,
      child: SingleChildScrollView(child: body),
    );
  }
}

class MobileLedgerMessage extends StatelessWidget {
  const MobileLedgerMessage(this.message, {super.key});
  final String message;
  @override
  Widget build(BuildContext context) => Text(
    message,
    style: AppTypography.bodyMedium.copyWith(
      color: context.colors.text.secondary,
    ),
  );
}

class MobileLedgerStatus extends StatelessWidget {
  const MobileLedgerStatus(this.label, {this.active = true, super.key});
  final String label;
  final bool active;
  @override
  Widget build(BuildContext context) {
    final motion = ShieldHardwarePresentation.maybeOf(context);
    final labelWidget = Text(
      label,
      textAlign: TextAlign.center,
      style: AppTypography.bodySmall.copyWith(
        color: context.colors.text.accent,
      ),
    );
    return Semantics(
      liveRegion: true,
      label: label,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(top: AppSpacing.md),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: motion == null
                      ? labelWidget
                      : ShieldStageTransition(
                          identity: label,
                          child: labelWidget,
                        ),
                ),
                if (active) ...[
                  const SizedBox(width: AppSpacing.xs),
                  AppIcon(
                    AppIcons.loader,
                    animated: true,
                    size: 20,
                    color: context.colors.icon.regular,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MobileLedgerIdentity extends StatelessWidget {
  const MobileLedgerIdentity(this.label, {super.key});
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: AppSpacing.md),
    child: Row(
      children: [
        AppIcon(AppIcons.ledger, size: 20, color: context.colors.icon.regular),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(
            label,
            style: AppTypography.bodyMediumStrong.copyWith(
              color: context.colors.text.accent,
            ),
          ),
        ),
      ],
    ),
  );
}

class MobileLedgerAction extends StatelessWidget {
  const MobileLedgerAction(this.label, {required this.onPressed, super.key});
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: AppSpacing.md),
    child: AppButton(
      expand: true,
      constrainContent: true,
      growWithContent: true,
      size: AppButtonSize.large,
      onPressed: onPressed,
      child: Text(label),
    ),
  );
}

/// Keeps existing connection and recovery owners mounted while their content
/// is presented inside the shielding scene instead of a separate sheet.
class LedgerInlinePresentation extends InheritedWidget {
  const LedgerInlinePresentation({
    required super.child,
    this.closeLabel = 'Cancel shielding',
    super.key,
  });

  final String closeLabel;

  @override
  bool updateShouldNotify(LedgerInlinePresentation oldWidget) =>
      closeLabel != oldWidget.closeLabel;
}
