# Private swap recovery

Software accounts can receive NEAR swap payouts and refunds at derived Ironwood addresses (one-time IVKs). Each account has its own receive and refund index sequences. Hardware and view-only accounts keep their existing swap addresses.

## Settings

The feature runs on mainnet with Private queries and NEAR swap privacy both on (`set_near_swap_privacy_enabled`). Turning it off pauses discovery and issuance, including for swaps in flight. Known payments stay visible and spendable, and repair of already-owned receipts after a reorg keeps working. Turning it back on resumes the saved queue.

## Receive addresses

The wallet hands out at most four indexes past the highest paid receive index. A payment counts from the block that mines it, so the next index opens as soon as a payout lands. Quotes, provider statuses and expiry never move that boundary. Issuance reuses the lowest unpaid hole once its quote ownership ends, and it hands out a new index only after that index's own history check finished. Until then it answers `ReceiveHistory`, and the app runs recovery and asks again. When unresolved quotes hold every eligible index it answers `Limit`. A started quote is released only by a recent provider status, so the app refreshes those statuses and retries.

Seed recovery starts at receive index zero and stops after four consecutive complete empty histories. A payment that passes authentication and inclusion resets that gap, including a proven payment before the birthday, which is not credited until the birthday is lowered and those blocks are rescanned. Newly exposed indexes get their first history check even when the wallet already passed their payment blocks.

## Refund addresses

The funding transaction records the refund index in an authenticated memo to the account's ordinary internal Ironwood address. Another device with the same seed learns that index by syncing the funding transaction. The wallet never sweeps arbitrary refund indexes.

An empty funded refund address stays unfinished, even when the provider reports success without a refund, so a small refund can still be found later. If the funding transaction predates the wallet birthday, restore from an earlier birthday first. Seeing only the later refund isn't enough to derive the refund index.

## Discovery

Ordinary block sync and mempool observation never try this feature's keys. The worker captures the receiver service's shard inventory once per round, accepts it only if its end is a block the wallet scanned, and saves the verified shard descriptors in the wallet database (`ext_vizor_receiver_inventory`) so the next capture downloads only chunks that can have changed.

Near the chain tip the worker matches rolling per-block filters when they cost less than querying unfinished addresses directly. A negative match makes no query and a positive one queues a PIR lookup. After a long or pruned gap it queries unfinished receive and lookahead addresses, funded refund addresses and saved positive matches directly. Lookups read sealed shards through their filters when that costs less than reading them blind, and always read the recent tier. Every candidate then reads its inclusion path from the companion witness table.

Every returned payment must authenticate with its derived key, prove inclusion against the wallet's own tree and pass spend reconciliation. Network requests hold no wallet database handle, and responses commit under account cancellation and publication fences. A failed request is deferred and never counts as an empty history.

Provider statuses carry the Zcash transactions 1Click reports for the swap (`originChainTxHashes` for refunds, `destinationChainTxHashes` for payouts). The wallet uses them only to attribute a recovered payment to its operation, never to find or credit one.

If the receiver service speaks a format this app doesn't support, the worker records that the app needs an update and stops. Pending work is kept and resumes after an update.

## Repeat payments

Each address is meant to be paid once. Automatic catch-up skips a paid address once its history is complete, so a second payment to it is found automatically only while it falls inside the rolling filter window. Outside that window only Check swap history finds it.

## Manual history

Check swap history queries older known addresses too. An optional receive bound extends the search past the four-empty rule. Refunds stay limited to known funded indexes. Pausing keeps the job's position so another check resumes it.

## Implementation

The wallet library owns issuance, the recovery queue, authentication, inclusion and spending. `rust/src/wallet/one_time_ivk.rs` supplies account eligibility. `rust/src/wallet/sync_engine/swap_private.rs` supplies routed network steps, the route choices and the descriptor store. `rust/src/api/one_time_ivk.rs` exposes reservations, provider statuses, bounded recovery rounds and history controls.
