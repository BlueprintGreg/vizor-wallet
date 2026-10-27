import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/send/services/recent_send_recipients.dart';
import 'package:zcash_wallet/src/features/swap/models/swap_models.dart';
import 'package:zcash_wallet/src/providers/account_models.dart';
import 'package:zcash_wallet/src/rust/api/sync.dart' as rust_sync;

const _activeAccount = 'account-1';
const _otherAccount = 'account-2';
const _deposit = 't1depositaddress000000000000000000';
const _giftCard = 'u1giftcard00000000000000000000000000000000';
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

  group('loadSendRecentRecipients', () {
    List<SendRecentRecipient> rows(int count, {String prefix = 'u1other'}) => [
      for (var index = 0; index < count; index++)
        SendRecentRecipient(address: '$prefix$index', isShielded: true),
    ];

    test('fetches every candidate when filters thin a full page', () async {
      final limits = <int>[];
      final ownActive = {
        for (var index = 0; index < 12; index++)
          'u1self$index': const AccountInfo(
            uuid: _activeAccount,
            name: 'Main',
            order: 0,
          ),
      };

      final selected = await loadSendRecentRecipients(
        fetch: (limit) async {
          limits.add(limit);
          return [...rows(10, prefix: 'u1self'), ...rows(limit - 10)];
        },
        accountUuid: _activeAccount,
        ownAccounts: ownActive,
        intents: const [],
        giftCardAddresses: const {},
      );

      expect(limits, [12, 100]);
      expect(selected, hasLength(kSendRecentRecipientLimit));
      expect(selected.first.address, 'u1other0');
    });

    test('stops after one fetch when it returned every candidate', () async {
      final limits = <int>[];

      final selected = await loadSendRecentRecipients(
        fetch: (limit) async {
          limits.add(limit);
          return rows(3);
        },
        accountUuid: _activeAccount,
        ownAccounts: const {},
        intents: const [],
        giftCardAddresses: const {},
      );

      expect(limits, [12]);
      expect(selected, hasLength(3));
    });
  });

  group('selectSendRecentRecipients', () {
    test('drops the active account, swap deposit and Gift Card addresses', () {
      final selected = selectSendRecentRecipients(
        rows: const [
          SendRecentRecipient(address: _deposit, isShielded: false),
          SendRecentRecipient(address: _giftCard, isShielded: true),
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
        giftCardAddresses: const {_giftCard},
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
        giftCardAddresses: const {},
      );

      expect(selected, hasLength(kSendRecentRecipientLimit));
      expect(selected.first.address, _friend);
      expect(selected.first.isShielded, isTrue);
      expect(selected[1].address, 'u1other0');
    });
  });

  group('recentSendHistoryKey', () {
    test('changes when a pending send expires', () {
      final pending = recentSendHistoryKey([_sent(expiredUnmined: false)]);

      expect(recentSendHistoryKey([_sent(expiredUnmined: false)]), pending);
      expect(
        recentSendHistoryKey([_sent(expiredUnmined: true)]),
        isNot(pending),
      );
    });
  });
}

rust_sync.TransactionInfo _sent({required bool expiredUnmined}) {
  return rust_sync.TransactionInfo(
    txidHex: _txid,
    minedHeight: BigInt.zero,
    expiredUnmined: expiredUnmined,
    accountBalanceDelta: -1,
    fee: BigInt.zero,
    feeState: rust_sync.TransactionFeeState.notApplicable,
    detailsComplete: true,
    provisional: false,
    amountIncludesFee: false,
    blockTime: BigInt.zero,
    isTransparent: false,
    txKind: 'sent',
    displayAmount: BigInt.one,
    displayPool: 'shielded',
    createdTime: BigInt.from(1800000000),
  );
}
