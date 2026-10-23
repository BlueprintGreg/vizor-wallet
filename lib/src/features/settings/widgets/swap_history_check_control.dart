import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
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
    'Waiting for wallet sync. Try again in a minute.',
  SwapHistoryCheck.updateRequired => kSwapRecoveryUpdateMessage,
};

/// Shown when the receiver service needs a newer app.
const kSwapRecoveryUpdateMessage =
    'Update Vizor to keep checking swap addresses. Your saved progress is kept.';

/// The "Check swap history" button and its progress, under NEAR swap privacy
/// in desktop and mobile Settings.
class SwapHistoryCheckControl extends ConsumerStatefulWidget {
  const SwapHistoryCheckControl({super.key});

  /// Keeps the optional search bound while job status changes.
  @override
  ConsumerState<SwapHistoryCheckControl> createState() =>
      _SwapHistoryCheckControlState();
}

class _SwapHistoryCheckControlState
    extends ConsumerState<SwapHistoryCheckControl> {
  final _bound = TextEditingController();
  String? _error;

  /// Releases the optional historical address-count input.
  @override
  void dispose() {
    _bound.dispose();
    super.dispose();
  }

  /// Validates the explicit search extent before starting a durable job.
  void _check() {
    final value = _bound.text.trim();
    final end = value.isEmpty ? null : BigInt.tryParse(value);
    if (value.isNotEmpty &&
        (end == null || end <= BigInt.zero || end >= (BigInt.one << 64))) {
      setState(() => _error = 'Enter a positive address count.');
      return;
    }
    setState(() => _error = null);
    unawaited(
      ref.read(swapHistoryCheckProvider.notifier).check(receiveEnd: end),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final watched = ref.watch(swapHistoryCheckProvider);
    // Automatic rounds can learn of an update first.
    final check =
        ref.watch(swapRecoveryUpdateRequiredProvider) &&
            watched != SwapHistoryCheck.checking
        ? SwapHistoryCheck.updateRequired
        : watched;
    final running = check == SwapHistoryCheck.checking;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // The helper sits in its own wrapped text under the field: the
          // field's message slot holds one short line and overlaps what
          // follows it.
          AppTextField(
            key: const ValueKey('settings_swap_history_bound'),
            label: 'Receive addresses to check (optional)',
            controller: _bound,
            enabled: !running,
            // The filled shell stays visible on a settings card in both
            // themes.
            surface: AppTextFieldSurface.secondary,
            tone: _error == null
                ? AppTextFieldTone.neutral
                : AppTextFieldTone.destructive,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            hintText: 'Known addresses',
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            _error ??
                'Leave blank to check known addresses. A count extends the '
                    'search when restoring missing history.',
            key: const ValueKey('settings_swap_history_bound_help'),
            style: AppTypography.labelMedium.copyWith(
              color: _error == null
                  ? colors.text.secondary
                  : colors.text.destructive,
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
                    : _check,
                size: AppButtonSize.medium,
                child: const Text('Check swap history'),
              ),
              if (running ||
                  check == SwapHistoryCheck.continuing ||
                  check == SwapHistoryCheck.failed)
                AppButton(
                  key: const ValueKey('settings_cancel_swap_history'),
                  onPressed: () => unawaited(
                    ref.read(swapHistoryCheckProvider.notifier).cancel(),
                  ),
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
