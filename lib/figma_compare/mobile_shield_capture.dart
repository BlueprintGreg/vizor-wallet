import 'package:flutter/widgets.dart';
import '../src/features/home/widgets/mobile/shield/mobile_shield_scene.dart';
import '../src/features/ledger/widgets/mobile/mobile_ledger_sheet_content.dart';

Widget buildMobileShieldReview(BuildContext context) => const MobileShieldScene(
  phase: MobileShieldPhase.review,
  amount: '0.9912331',
  resultAmount: '0.9911331',
  title: 'Transparent Balance',
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
  title: 'Shielded successfully',
  onComplete: _noop,
  onClose: _noop,
);
Widget buildMobileShieldKeystone(BuildContext context) => MobileShieldScene(
  phase: MobileShieldPhase.hardware,
  amount: '0.9912331',
  title: 'Approve with Keystone',
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

Widget buildMobileShieldReferenceReview(BuildContext context) =>
    _referenceViewport(
      context,
      const MobileShieldScene(
        phase: MobileShieldPhase.review,
        amount: '14.12',
        resultAmount: '14.12',
        title: 'Transparent Balance',
        onCommit: _noop,
        onClose: _noop,
      ),
    );
Widget buildMobileShieldReferenceResult(BuildContext context) =>
    _referenceViewport(
      context,
      const MobileShieldScene(
        phase: MobileShieldPhase.succeeded,
        amount: '14.12',
        resultAmount: '14.12',
        title: 'Shielded successfully',
        onComplete: _noop,
        onClose: _noop,
      ),
    );

Widget _referenceViewport(BuildContext context, Widget child) => MediaQuery(
  data: MediaQuery.of(
    context,
  ).copyWith(padding: const EdgeInsets.only(top: 59, bottom: 34)),
  child: child,
);
