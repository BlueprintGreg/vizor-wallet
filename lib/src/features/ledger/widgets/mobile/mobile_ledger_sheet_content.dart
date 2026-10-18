import 'package:flutter/material.dart' show Scrollbar;
import 'package:flutter/widgets.dart';

import '../../../../core/layout/mobile/app_mobile_sheet.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';

/// Mobile-only content. The host owns the scrim and MobileModalCard.
class MobileLedgerSheetContent extends StatefulWidget {
  const MobileLedgerSheetContent({
    required this.title,
    required this.onClose,
    required this.children,
    this.action,
    super.key,
  });
  final String title;
  final VoidCallback? onClose;
  final List<Widget> children;
  final Widget? action;

  @override
  State<MobileLedgerSheetContent> createState() =>
      _MobileLedgerSheetContentState();
}

class _MobileLedgerSheetContentState extends State<MobileLedgerSheetContent> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    explicitChildNodes: true,
    child: MobileModalScaffold(
      title: widget.title,
      titleMaxLines: 3,
      showClose: widget.onClose != null,
      onClose: widget.onClose ?? () {},
      constrainBody: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: Scrollbar(
              controller: _scrollController,
              thumbVisibility: true,
              thickness: 3,
              child: SingleChildScrollView(
                controller: _scrollController,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: widget.children,
                ),
              ),
            ),
          ),
          if (widget.action != null) widget.action!,
        ],
      ),
    ),
  );
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
  const MobileLedgerIdentity(
    this.label, {
    this.topPadding = AppSpacing.md,
    super.key,
  });
  final String label;
  final double topPadding;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: topPadding),
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
