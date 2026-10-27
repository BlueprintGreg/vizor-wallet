import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/send/services/recent_send_recipients.dart';
import 'package:zcash_wallet/src/features/swap/models/swap_models.dart';
import 'package:zcash_wallet/src/providers/account_models.dart';

const _activeAccount = 'account-1';
const _otherAccount = 'account-2';
const _deposit = 't1depositaddress000000000000000000';
const _friend = 'u1friend0000000000000000000000000000000000';
const _ownActive = 'u1activeaccount00000000000000000000000000';
const _ownOther = 'u1otheraccount000000000000000000000000000';
// Wallet byte order and its reverse.
const _txid =
    '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
const _txidReversed =
    'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100';

SwapIntent _intent({String? depositAddress, String? depositTxHash}) {
  return SwapIntent(
    id: 'intent',
    pair: 'ZEC -> USDC',
    sellAmount: '1 ZEC',
    receiveEstimate: '10 USDC',
    provider: 'NEAR Intents',
    status: SwapIntentStatus.complete,
    nextAction: '',
    depositAddress: depositAddress,
    depositTxHash: depositTxHash,
  );
}

void main() {
  group('oneTimeRecipientTxids', () {
    test('lists swap deposits and Gift Card funding in both byte orders', () {
      final txids = oneTimeRecipientTxids(
        intents: [
          _intent(depositTxHash: '0x${_txid.toUpperCase()}'),
          _intent(),
        ],
        giftCardFundingTxids: const ['gift-funding'],
      );

      expect(txids, {_txid, _txidReversed, 'gift-funding'});
    });
  });

  group('selectSendRecentRecipients', () {
    test('drops the active account and swap deposit addresses', () {
      final selected = selectSendRecentRecipients(
        rows: const [
          SendRecentRecipient(address: _deposit, isShielded: false),
          SendRecentRecipient(address: _ownActive, isShielded: true),
          SendRecentRecipient(address: _friend, isShielded: true),
          SendRecentRecipient(address: _ownOther, isShielded: true),
        ],
        accountUuid: _activeAccount,
        ownAccounts: const {
          _ownActive: AccountInfo(uuid: _activeAccount, name: 'Main', order: 0),
          _ownOther: AccountInfo(
            uuid: _otherAccount,
            name: 'Savings',
            order: 1,
          ),
        },
        intents: [_intent(depositAddress: _deposit)],
      );

      expect(selected.map((recent) => recent.address), [_friend, _ownOther]);
    });

    test('keeps the first occurrence of an address up to the limit', () {
      final selected = selectSendRecentRecipients(
        rows: [
          const SendRecentRecipient(address: _friend, isShielded: true),
          const SendRecentRecipient(address: ' $_friend ', isShielded: false),
          for (var index = 0; index < 8; index++)
            SendRecentRecipient(address: 'u1other$index', isShielded: true),
        ],
        accountUuid: _activeAccount,
        ownAccounts: const {},
        intents: const [],
      );

      expect(selected, hasLength(kSendRecentRecipientLimit));
      expect(selected.first.address, _friend);
      expect(selected.first.isShielded, isTrue);
      expect(selected[1].address, 'u1other0');
    });
  });
}
