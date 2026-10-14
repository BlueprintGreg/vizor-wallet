import 'package:flutter/widgets.dart';

import '../../../../core/layout/mobile/app_mobile_sheet.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';

/// Mobile-only content. The host owns the scrim and MobileModalCard.
class MobileLedgerSheetContent extends StatelessWidget {
  const MobileLedgerSheetContent({
    required this.title,
    required this.onClose,
    required this.children,
    super.key,
  });
  final String title;
  final VoidCallback? onClose;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final inline =
        context
            .dependOnInheritedWidgetOfExactType<LedgerInlinePresentation>() !=
        null;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: inline
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.stretch,
      children: [
        if (inline) ...[
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppTypography.headlineSmall.copyWith(
              color: const Color(0xFFFFFFFF),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        ...children,
        if (inline && onClose != null) ...[
          const SizedBox(height: AppSpacing.md),
          MobileLedgerAction('Back to wallet', onPressed: onClose),
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
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: label,
    child: ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.md),
        child: Row(
          children: [
            if (active) ...[
              AppIcon(
                AppIcons.loader,
                animated: true,
                size: 20,
                color: context.colors.icon.regular,
              ),
              const SizedBox(width: AppSpacing.xs),
            ],
            Expanded(
              child: Text(
                label,
                style: AppTypography.bodySmall.copyWith(
                  color: context.colors.text.accent,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
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
  const LedgerInlinePresentation({required super.child, super.key});
  @override
  bool updateShouldNotify(LedgerInlinePresentation oldWidget) => false;
}
