import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';

/// A quote error under the swap or pay composer. When `privateSwapsPaused`, the
/// error explains that private swaps are paused, so it shows in full with a
/// button to Settings, where NEAR swap privacy can be turned off.
class SwapQuoteErrorText extends StatelessWidget {
  const SwapQuoteErrorText({
    required this.message,
    required this.textKey,
    this.privateSwapsPaused = false,
    this.maxLines,
    super.key,
  });

  final String message;
  final Key textKey;
  final bool privateSwapsPaused;

  /// Lines an ordinary error may take; a paused message is never cut short.
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Text(
      message,
      key: textKey,
      maxLines: privateSwapsPaused ? null : maxLines,
      overflow: privateSwapsPaused || maxLines == null
          ? null
          : TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: AppTypography.bodySmall.copyWith(color: colors.text.destructive),
    );
    if (!privateSwapsPaused) return text;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        text,
        const SizedBox(height: AppSpacing.xs),
        AppButton(
          key: const ValueKey('swap_private_swaps_paused_settings'),
          onPressed: () => context.go('/settings'),
          variant: AppButtonVariant.secondary,
          size: AppButtonSize.small,
          child: const Text('Open settings'),
        ),
      ],
    );
  }
}
