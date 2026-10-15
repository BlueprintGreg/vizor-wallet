import 'package:flutter/widgets.dart';
import 'dart:math' as math;

import '../../../../core/theme/app_theme.dart';
import '../../../../providers/account_provider.dart';
import '../../ledger_device_label.dart';
import '../../services/ledger_mobile_ble_service.dart';
import 'mobile_ledger_sheet_content.dart';
import '../../../home/widgets/mobile/shield/shield_hardware_motion.dart';
import '../../services/ledger_signing_progress.dart';

/// Mobile presentation of the shared operation status, independent of the
/// desktop signing card and its nested status/prompt panels.
class MobileLedgerSigningContent extends StatelessWidget {
  const MobileLedgerSigningContent({
    required this.title,
    required this.message,
    required this.status,
    required this.active,
    required this.failed,
    required this.onClose,
    required this.onAction,
    this.actionLabel,
    this.account,
    super.key,
  });
  final String title;
  final String message;
  final String status;
  final bool active;
  final bool failed;
  final AccountInfo? account;
  final String? actionLabel;
  final VoidCallback? onClose;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final motion = ShieldHardwarePresentation.maybeOf(context);
    double measure(List<String> texts, TextStyle style, double width) {
      var height = 0.0;
      for (final text in texts) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: math.max(1, width));
        height = math.max(height, painter.height);
        painter.dispose();
      }
      return height;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final messages = [
          message,
          for (final stage in LedgerSigningStage.values)
            stage.messageForDevice(account?.ledgerDeviceModel),
        ];
        final titles = [
          title,
          'Checking your Ledger',
          'Confirm opening Zcash',
          for (final stage in LedgerSigningStage.values) stage.title,
        ];
        return MobileLedgerSheetContent(
          title: title,
          titleHeight: motion == null
              ? null
              : measure(
                  titles,
                  AppTypography.headlineSmall,
                  constraints.maxWidth,
                ),
          onClose: onClose,
          actions: [
            if (failed && actionLabel != null)
              MobileLedgerAction(actionLabel!, onPressed: onAction),
          ],
          children: [
            if (motion == null)
              MobileLedgerMessage(message)
            else
              SizedBox(
                height: measure(
                  messages,
                  AppTypography.bodyMedium,
                  constraints.maxWidth,
                ),
                child: Center(
                  child: ShieldStageTransition(
                    identity: message,
                    child: MobileLedgerMessage(message),
                  ),
                ),
              ),
            if (!failed && account?.ledgerDeviceId != null)
              MobileLedgerIdentity(
                ledgerDeviceLabel(
                  LedgerBleDevice(
                    id: account!.ledgerDeviceId!,
                    name: account!.ledgerDeviceName ?? '',
                    model: account!.ledgerDeviceModel ?? '',
                  ),
                ),
              ),
            if (!failed) MobileLedgerStatus(status, active: active),
            if (failed && status != 'Action needed') ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                status,
                style: AppTypography.bodyMediumStrong.copyWith(
                  color: context.colors.text.accent,
                ),
              ),
            ],
            if (failed && actionLabel == null && onClose == null) ...[
              const SizedBox(height: AppSpacing.sm),
              const MobileLedgerMessage('Keep Vizor open.'),
            ],
          ],
        );
      },
    );
  }
}
