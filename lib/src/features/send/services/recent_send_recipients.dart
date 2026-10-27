import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/wallet_paths.dart';
import '../../../providers/account_models.dart';
import '../../../providers/rpc_endpoint_provider.dart';
import '../../../providers/sync_provider.dart';
import '../../../rust/api/sync.dart' as rust_sync;
import '../../activity/gift_card_activity_index.dart';
import '../../payment_links/services/payment_link_transaction_matching.dart'
    as payment_link_matching;
import '../../swap/models/swap_intent.dart';
import '../../swap/models/swap_intent_presentation_mapper.dart'
    show swapIntentsFromRecords;
import '../../swap/providers/swap_activity_store.dart';
import '../widgets/send_recipient_resolver.dart';

/// An address the active account recently sent ZEC to, shown under "Recents"
/// in the mobile Send recipient step.
class SendRecentRecipient {
  const SendRecentRecipient({required this.address, required this.isShielded});

  final String address;
  final bool isShielded;
}

const kSendRecentRecipientLimit = 5;

// Headroom for the rows the Dart-side filters below can still drop.
const _recentRecipientFetchLimit = 12;

// Every candidate: Rust scans the newest 100 Activity rows.
const _recentRecipientScanLimit = 100;

/// Recent recipients of [accountUuid], newest first.
///
/// Swap, Pay and Gift Card funding transactions pay one-time addresses, so
/// they are excluded the way Activity overlays them. Fails closed: when any of
/// those records cannot be read, the provider errors and the step shows no
/// Recents.
final recentSendRecipientsProvider = FutureProvider.autoDispose
    .family<List<SendRecentRecipient>, String>((ref, accountUuid) async {
      ref.watch(
        syncProvider.select(
          (state) =>
              recentSendHistoryKey(state.value?.recentTransactions ?? const []),
        ),
      );
      final network = ref.watch(rpcEndpointProvider).networkName;
      final records = await ref.watch(
        swapActivityRecordsProvider(accountUuid).future,
      );
      // Unreadable swaps are skipped by the records load; their deposit
      // addresses would otherwise pass as recents.
      final swapsComplete = await ref
          .read(swapActivityStoreProvider)
          .recordsAreComplete(accountUuid: accountUuid);
      if (!swapsComplete) {
        throw StateError('Swap activity is not fully readable.');
      }
      final giftCards = await ref.watch(
        giftCardActivityIndexProvider(accountUuid).future,
      );
      final ownAccounts = await ref.watch(ownAccountAddressesProvider.future);
      final intents = swapIntentsFromRecords(records);

      final dbPath = await getWalletDbPath();
      final excludeTxidHexes = oneTimeRecipientTxids(
        intents: intents,
        giftCardFundingTxids: giftCards.createdTxids,
      ).toList();
      return loadSendRecentRecipients(
        fetch: (limit) async => [
          for (final row in await rust_sync.getRecentSendRecipients(
            dbPath: dbPath,
            network: network,
            accountUuid: accountUuid,
            limit: limit,
            excludeTxidHexes: excludeTxidHexes,
          ))
            SendRecentRecipient(
              address: row.address,
              isShielded: row.isShielded,
            ),
        ],
        accountUuid: accountUuid,
        ownAccounts: ownAccounts,
        intents: intents,
      );
    });

/// Changes when a new transaction arrives or one changes in a way that can
/// add or remove it from Recents, such as a pending send expiring.
String recentSendHistoryKey(Iterable<rust_sync.TransactionInfo> transactions) =>
    [
      for (final tx in transactions)
        '${tx.txidHex}:${tx.txKind}:${tx.expiredUnmined}',
    ].join(',');

/// Fetches a few more rows than shown and, when the Dart-side filters leave
/// too few from a full page, fetches every candidate once.
Future<List<SendRecentRecipient>> loadSendRecentRecipients({
  required Future<List<SendRecentRecipient>> Function(int limit) fetch,
  required String accountUuid,
  required Map<String, AccountInfo> ownAccounts,
  required Iterable<SwapIntent> intents,
}) async {
  List<SendRecentRecipient> select(List<SendRecentRecipient> rows) =>
      selectSendRecentRecipients(
        rows: rows,
        accountUuid: accountUuid,
        ownAccounts: ownAccounts,
        intents: intents,
      );
  final rows = await fetch(_recentRecipientFetchLimit);
  final selected = select(rows);
  if (selected.length == kSendRecentRecipientLimit ||
      rows.length < _recentRecipientFetchLimit) {
    return selected;
  }
  return select(await fetch(_recentRecipientScanLimit));
}

/// Txids of the transactions that paid a swap or Pay deposit address or
/// funded a Gift Card, in both byte orders since the stores do not agree on
/// one.
Set<String> oneTimeRecipientTxids({
  required Iterable<SwapIntent> intents,
  required Iterable<String> giftCardFundingTxids,
}) {
  final txids = <String>{};
  void add(String? txid) {
    final normalized = payment_link_matching.normalizePaymentLinkTxid(
      txid ?? '',
    );
    if (normalized.isEmpty) return;
    txids.add(normalized);
    final reversed = payment_link_matching.paymentLinkTxidInOtherByteOrder(
      normalized,
    );
    if (reversed != null) txids.add(reversed);
  }

  for (final intent in intents) {
    add(intent.depositTxHash);
    add(intent.originChainTxHash);
  }
  giftCardFundingTxids.forEach(add);
  return txids;
}

/// Drops the active account's own addresses and any swap deposit address the
/// txid exclusion missed, then keeps the first [limit].
List<SendRecentRecipient> selectSendRecentRecipients({
  required List<SendRecentRecipient> rows,
  required String accountUuid,
  required Map<String, AccountInfo> ownAccounts,
  required Iterable<SwapIntent> intents,
  int limit = kSendRecentRecipientLimit,
}) {
  final depositAddresses = {
    for (final intent in intents)
      if (intent.depositAddress?.trim().isNotEmpty ?? false)
        intent.depositAddress!.trim(),
  };
  final seen = <String>{};
  final result = <SendRecentRecipient>[];
  for (final row in rows) {
    final address = row.address.trim();
    if (address.isEmpty || !seen.add(address)) continue;
    if (ownAccounts[address]?.uuid == accountUuid) continue;
    if (depositAddresses.contains(address)) continue;
    result.add(row);
    if (result.length == limit) break;
  }
  return result;
}
