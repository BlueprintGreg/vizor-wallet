import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../providers/swap_history_check_provider.dart';

/// What the swap history check says for each state.
String swapHistoryCheckStatus(SwapHistoryCheck check) => switch (check) {
  SwapHistoryCheck.idle => 'Check older addresses for repeat payments. Refund recovery also needs the original funding transaction in wallet history.',
  SwapHistoryCheck.checking => 'Checking swap history…',
  SwapHistoryCheck.done => 'The selected swap history check is complete.',
  SwapHistoryCheck.continuing => 'The check will continue in the background.',
  SwapHistoryCheck.paused => 'Paused. Check again to resume.',
  SwapHistoryCheck.failed =>
    'The check was interrupted. Saved work may continue. Pause or try again.',
};

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
    final check = ref.watch(swapHistoryCheckProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppButton(
            key: const ValueKey('settings_check_swap_history'),
            onPressed: check == SwapHistoryCheck.checking ? null : _check,
            variant: AppButtonVariant.secondary,
            size: AppButtonSize.small,
            child: const Text('Check swap history'),
          ),
          if (check == SwapHistoryCheck.checking ||
              check == SwapHistoryCheck.continuing ||
              check == SwapHistoryCheck.failed)
            AppButton(
              key: const ValueKey('settings_cancel_swap_history'),
              onPressed: () => unawaited(
                ref.read(swapHistoryCheckProvider.notifier).cancel(),
              ),
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.small,
              child: const Text('Pause check'),
            ),
          const SizedBox(height: AppSpacing.xs),
          AppTextField(
            key: const ValueKey('settings_swap_history_bound'),
            label: 'Receive addresses to check (optional)',
            controller: _bound,
            enabled: check != SwapHistoryCheck.checking,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            hintText: 'Known addresses',
            messageText: _error ?? 'Leave blank to check known addresses. A count extends the search when restoring missing history.',
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
