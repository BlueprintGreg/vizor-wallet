// Deterministic presentation fixture; no device, wallet, storage or broadcast.
import 'dart:async';
import 'package:flutter/widgets.dart';
import '../src/features/home/widgets/mobile/shield/mobile_shield_scene.dart';
import '../src/features/home/widgets/mobile/shield/mobile_shield_backdrop.dart';
import '../src/features/ledger/widgets/mobile/mobile_ledger_sheet_content.dart';
import '../src/features/ledger/widgets/mobile/mobile_ledger_signing_content.dart';
import '../src/features/ledger/services/ledger_signing_progress.dart';
import '../src/providers/account_models.dart';

enum _Stage { review, preparing, sending, reviewing, broadcasting, succeeded }

class LedgerShieldMotionPreview extends StatefulWidget {
  const LedgerShieldMotionPreview({
    this.backdrop,
    this.onSubmitted,
    this.onClose,
    super.key,
  });
  final MobileShieldBackdrop? backdrop;
  final VoidCallback? onSubmitted;
  final VoidCallback? onClose;
  @override
  State<LedgerShieldMotionPreview> createState() =>
      _LedgerShieldMotionPreviewState();
}

class _LedgerShieldMotionPreviewState extends State<LedgerShieldMotionPreview> {
  _Stage _stage = _Stage.review;
  Timer? _timer;
  void _after(int seconds, _Stage stage) {
    _timer = Timer(Duration(seconds: seconds), () {
      if (!mounted) return;
      setState(() => _stage = stage);
      switch (stage) {
        case _Stage.sending:
          _after(5, _Stage.reviewing);
        case _Stage.reviewing:
          _after(6, _Stage.broadcasting);
        case _Stage.broadcasting:
          _after(3, _Stage.succeeded);
        case _Stage.succeeded:
          widget.onSubmitted?.call();
        case _Stage.review || _Stage.preparing:
          break;
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hardware =
        _stage == _Stage.preparing ||
        _stage == _Stage.sending ||
        _stage == _Stage.reviewing;
    final stage = _stage == _Stage.sending
        ? LedgerSigningStage.sending
        : _stage == _Stage.reviewing
        ? LedgerSigningStage.reviewing
        : LedgerSigningStage.preparing;
    final done = _stage == _Stage.succeeded;
    return MobileShieldScene(
      animateHardware: true,
      backdrop: widget.backdrop,
      amount: '14.12',
      resultAmount: done ? '14.1199' : '—',
      phase: _stage == _Stage.review
          ? MobileShieldPhase.review
          : done
          ? MobileShieldPhase.succeeded
          : hardware
          ? MobileShieldPhase.hardware
          : MobileShieldPhase.working,
      title: _stage == _Stage.review
          ? 'Transparent Balance'
          : done
          ? 'Shielded successfully'
          : hardware
          ? 'Shield with Ledger'
          : 'Shielding your balance…',
      focusChild: hardware
          ? LedgerInlinePresentation(
              child: MobileLedgerSigningContent(
                title: stage == LedgerSigningStage.reviewing
                    ? 'Confirm on your Ledger'
                    : stage.title,
                message: stage.messageForDevice('stax'),
                status: stage == LedgerSigningStage.reviewing
                    ? 'Waiting for your approval'
                    : stage.status,
                active: stage != LedgerSigningStage.reviewing,
                failed: false,
                account: const AccountInfo(
                  uuid: 'ledger-motion-preview',
                  name: 'Ledger',
                  order: 0,
                  isHardware: true,
                  hardwareSignerKind: HardwareSignerKind.ledger,
                  ledgerDeviceId: 'motion-preview',
                  ledgerDeviceName: 'Ledger Stax',
                  ledgerDeviceModel: 'stax',
                ),
                onClose: widget.onClose,
                onAction: null,
              ),
            )
          : null,
      onCommit: () {
        setState(() => _stage = _Stage.preparing);
        _after(3, _Stage.sending);
      },
      canLeave: _stage != _Stage.broadcasting,
      onClose: widget.onClose,
      onComplete: widget.onClose,
    );
  }
}
