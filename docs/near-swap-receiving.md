# Private swap recovery

Software accounts can receive swap payouts and refunds at derived Ironwood addresses. Each account has its own receive and refund index sequences. Hardware and view-only accounts keep their existing swap addresses.

## Settings

On mainnet, enable Private queries and NEAR swap privacy. The latter opts into new private swap addresses and discovery of their payments. Turning it off pauses discovery, including in-flight swaps. Known payments remain visible and spendable. Repair of already-owned receipts after a reorg still works. Re-enabling resumes the durable queue.

## Receive addresses

The wallet exposes at most four indexes beyond the highest confirmed paid index. Quotes, provider statuses and expiration never move that boundary. It reuses the lowest eligible unpaid hole after its outstanding quote ownership ends. An accepted or possibly funded operation keeps its address reserved. Issuance does not download a provider seen set or query PIR for freshness.

Seed recovery starts at receive index zero and stops after four consecutive complete empty histories at a checked publication. A payment that passes authentication and inclusion resets that gap, including a proven payment before the birthday. Pre-birthday payments are not credited until the birthday is lowered and those blocks are scanned. Newly exposed indexes get a historical check even when live filters already passed their payment blocks.

## Refund addresses

The funding transaction records the refund index in an authenticated memo to the account's ordinary internal Ironwood address. Another device with the same seed recovers that identity by syncing the funding transaction. The app retains local quote ownership and funding safeguards. It does not enumerate arbitrary refund indexes.

An empty funded refund address remains unfinished, even when the provider reports success without a refund. Small surplus refunds can therefore be found later. If the funding transaction predates the wallet birthday, lower the birthday and rescan its history first. Seeing only the later refund is insufficient to derive an unknown refund index.

## Discovery

Ordinary block sync and mempool observation never try this feature's derived keys. The separate Receiver worker uses per-block GCS filters when their estimated cost is lower than querying unfinished addresses directly. A negative hint issues no address query. Positive hints enqueue PIR. A long or pruned gap queries unfinished receive/lookahead and funded refund addresses, plus durable positive obligations. Completed old addresses are intentionally omitted from that catch-up route.

Every returned payment must authenticate with the expected derived key, prove inclusion against the wallet's chain and pass spend reconciliation. Network requests hold no wallet database handle. Responses commit under account cancellation and publication fences. No compact blocks are retained for this feature, and ordinary sync never waits for the receiver service. Public setup, filter batches and proof data can be shared across accounts, while progress and ownership remain separate.

PIR hides the selected address. Query timing remains observable. Direct catch-up can intentionally omit a repeat payment to a completed old address. This is the accepted tradeoff for bounded automatic recovery.

## Manual history

Check swap history explicitly queries older known addresses. An optional receive-address count extends the search beyond the ordinary four-empty stopping rule. Refunds remain restricted to known funded identities. Pause keeps the job's position so another check can resume it. Failures never count as empty histories. Lowering a birthday requeues excluded histories even if discovery is off.

## Implementation

The wallet library owns issuance, the recovery queue, authentication, inclusion and spending. `rust/src/wallet/one_time_ivk.rs` supplies account eligibility and operation conversion. `rust/src/wallet/sync_engine/swap_private.rs` supplies routed network steps. `rust/src/api/one_time_ivk.rs` exposes bounded work and explicit history controls. `SyncNotifier` schedules receiver work independently and cancels and drains it for wallet mutation and locks.

This source cutover still requires regenerated bindings, app behavior tests and review on a compatible voting/Common dependency graph. The dependency upgrade is owned separately by Roman.
