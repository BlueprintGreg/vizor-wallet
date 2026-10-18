import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../providers/swap_history_check_provider.dart';

/// What the swap history check says for each state.
String swapHistoryCheckStatus(SwapHistoryCheck check) => switch (check) {
  SwapHistoryCheck.idle =>
    'Look for refunds or payouts that arrived after a swap finished.',
  SwapHistoryCheck.checking => 'Checking swap history…',
  SwapHistoryCheck.done => 'Swap history is up to date.',
  SwapHistoryCheck.continuing =>
    'Still checking. This continues while your wallet syncs.',
  SwapHistoryCheck.failed => "Couldn't check swap history. Try again.",
};

/// The "Check swap history" button and its progress, under NEAR swap privacy
/// in desktop and mobile Settings.
class SwapHistoryCheckControl extends ConsumerWidget {
  const SwapHistoryCheckControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final check = ref.watch(swapHistoryCheckProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppButton(
            key: const ValueKey('settings_check_swap_history'),
            onPressed: check == SwapHistoryCheck.checking
                ? null
                : () => unawaited(
                    ref.read(swapHistoryCheckProvider.notifier).check(),
                  ),
            variant: AppButtonVariant.secondary,
            size: AppButtonSize.small,
            child: const Text('Check swap history'),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            swapHistoryCheckStatus(check),
            key: const ValueKey('settings_check_swap_history_status'),
            style: AppTypography.bodyMedium.copyWith(
              color: colors.text.secondary,
            ),
          ),
        ],
      ),
    );
  }
}
