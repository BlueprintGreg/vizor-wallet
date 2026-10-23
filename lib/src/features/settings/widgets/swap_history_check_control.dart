import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../providers/swap_history_check_provider.dart';
import '../../../providers/sync_provider.dart'
    show swapRecoveryUpdateRequiredProvider;

/// What the swap history check says for each state.
String swapHistoryCheckStatus(SwapHistoryCheck check) => switch (check) {
  SwapHistoryCheck.idle => 'Check older addresses for repeat payments.',
  SwapHistoryCheck.checking => 'Checking swap history…',
  SwapHistoryCheck.done => 'The selected swap history check is complete.',
  SwapHistoryCheck.continuing => 'The check will continue in the background.',
  SwapHistoryCheck.paused => 'Paused. Check again to resume.',
  SwapHistoryCheck.failed =>
    'The check was interrupted. Saved work may continue. Pause or try again.',
  SwapHistoryCheck.waitingForSync =>
    'Waiting for wallet sync. Try again in a few minutes.',
  SwapHistoryCheck.updateRequired => kSwapRecoveryUpdateMessage,
};

/// Shown when the receiver service needs a newer app.
const kSwapRecoveryUpdateMessage =
    'Update Vizor to keep checking swap addresses. Your saved progress is kept.';

/// Why the check exists, under the button.
const kSwapHistoryCheckExplanation =
    'Only needed if a swap payment or refund is missing.';

/// The "Check swap history" button and its progress, under NEAR swap privacy
/// in desktop and mobile Settings. The check always covers every address the
/// wallet has enrolled.
class SwapHistoryCheckControl extends ConsumerWidget {
  const SwapHistoryCheckControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final watched = ref.watch(swapHistoryCheckProvider);
    // Automatic rounds can learn of an update first.
    final check =
        ref.watch(swapRecoveryUpdateRequiredProvider) &&
            watched != SwapHistoryCheck.checking
        ? SwapHistoryCheck.updateRequired
        : watched;
    final running = check == SwapHistoryCheck.checking;
    final notifier = ref.read(swapHistoryCheckProvider.notifier);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            kSwapHistoryCheckExplanation,
            key: const ValueKey('settings_swap_history_explanation'),
            style: AppTypography.labelMedium.copyWith(
              color: colors.text.secondary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              AppButton(
                key: const ValueKey('settings_check_swap_history'),
                onPressed: running || check == SwapHistoryCheck.updateRequired
                    ? null
                    : () => unawaited(notifier.check()),
                size: AppButtonSize.medium,
                child: const Text('Check swap history'),
              ),
              // A check waiting for sync may follow a saved job that later
              // rounds resume, so it can still be paused.
              if (running ||
                  check == SwapHistoryCheck.continuing ||
                  check == SwapHistoryCheck.failed ||
                  check == SwapHistoryCheck.waitingForSync)
                AppButton(
                  key: const ValueKey('settings_cancel_swap_history'),
                  onPressed: () => unawaited(notifier.cancel()),
                  variant: AppButtonVariant.ghost,
                  size: AppButtonSize.medium,
                  child: const Text('Pause check'),
                ),
            ],
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
