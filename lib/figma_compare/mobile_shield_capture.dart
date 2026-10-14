import 'package:flutter/widgets.dart';
import '../src/features/home/widgets/mobile/shield/mobile_shield_scene.dart';
import '../src/features/ledger/widgets/mobile/mobile_ledger_sheet_content.dart';

Widget buildMobileShieldReview(BuildContext context) => const MobileShieldScene(
  phase: MobileShieldPhase.review,
  amount: '0.9912331',
  resultAmount: '0.9911331',
  title: 'Transparent balance',
  feeText: 'Network fee: 0.0001 ZEC · You receive 0.9911331 ZEC',
  onCommit: _noop,
  onClose: _noop,
);
Widget buildMobileShieldCloud(BuildContext context) => const MobileShieldScene(
  phase: MobileShieldPhase.working,
  amount: '0.9912331',
  title: 'Shielding your balance…',
  canLeave: false,
);
Widget buildMobileShieldResult(BuildContext context) => const MobileShieldScene(
  phase: MobileShieldPhase.succeeded,
  amount: '0.9912331',
  resultAmount: '0.9911331',
  title: 'Shielding transaction sent',
  body: 'Waiting for confirmation. Follow the transaction in Activity.',
  onComplete: _noop,
  onClose: _noop,
);
Widget buildMobileShieldKeystone(BuildContext context) => MobileShieldScene(
  phase: MobileShieldPhase.hardware,
  amount: '0.9912331',
  title: 'Approve with Keystone',
  body:
      'Scan this QR with Keystone, approve on your device, then scan its signed QR.',
  focusBuilder: (context, constraints) => MobileShieldKeystoneQr(
    constraints: constraints,
    urParts: const ['ur:zcash-pczt/hdcxfixture'],
  ),
  onClose: _noop,
);
Widget buildMobileShieldLedger(BuildContext context) => const MobileShieldScene(
  phase: MobileShieldPhase.hardware,
  amount: '0.9912331',
  title: 'Shield with Ledger',
  focusChild: LedgerInlinePresentation(
    child: MobileLedgerSheetContent(
      title: 'Confirm on your Ledger',
      onClose: _noop,
      children: [
        MobileLedgerMessage('Review and approve when prompted on your Ledger.'),
        MobileLedgerStatus('Transaction 1 of 3', active: false),
      ],
    ),
  ),
  onClose: _noop,
);
void _noop() {}
