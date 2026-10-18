# NEAR swap receiving

Software accounts receive NEAR swap refunds and incoming swap payouts at per-swap
Ironwood addresses derived from the account's viewing key, so swaps cannot be
linked through a shared address. Every address is recoverable from the seed. A
software account is one Vizor derives from a seed, including accounts added from
another seed; hardware and view-only accounts keep their existing swap addresses.

The addresses come from the wallet library's one-time IVKs
(`zcash_client_sqlite::wallet::one_time_ivk`). Vizor's policy is in
`rust/src/wallet/one_time_ivk.rs`, its bridge in `rust/src/api/one_time_ivk.rs`, and
the swap flows in `lib/src/features/swap/providers/swap_receive_reservation_service.dart`.

## Settings

On mainnet, turn on **Private queries**, then **NEAR swap privacy** in Settings. Both
default off and are saved for this installation. A new swap address needs both on.
Turning Private queries off also turns NEAR swap privacy off, and turning Private
queries back on does not re-enable it. Desktop and mobile share the preference.

Turning NEAR swap privacy off only stops new addresses. Existing reservations,
funding memos, keys, notes and status tracking remain, received notes stay
spendable, and discovery runs for every software account with either setting off.

Below NEAR swap privacy, software accounts get **Check swap history** (see
[Closing](#closing)).

## Issuing addresses

The first quote fetches the live chain height without updating the wallet tip or
starting sync. Issuance requires the wallet scanned contiguously to within ten
blocks of that height. Refund and incoming addresses use independent index
sequences.

- **Refund address** (sending ZEC). Reserving first recovers confirmed funding
  records, and waits while one still lacks its memo, so an index the seed already
  used is never issued again. It also skips any address NEAR's seen set holds (see
  [Incoming reservations](#incoming-reservations)), which covers one another device
  on the seed quoted but never funded. An accepted quote records its deposit address
  against the refund key before it is shown, and funding requires that record. The
  funding transaction carries the refund index in a binary memo on ordinary
  internal Ironwood change and pays only the transparent deposit address; a
  zero-value change note is valid. Funding spends only Ironwood notes, so the
  change stays in Ironwood; Orchard or Sapling funds must be moved to Ironwood
  first. Quotes whose deposit needs a memo, and
  multi-step funding, are rejected. A refund can only follow a deposit, so the
  refund key starts scanning when the wallet stores the funding transaction, and a
  quote never funded never scans.
- **Incoming address** (receiving ZEC). The key scans from the first unscanned
  block until its swap closes. Missing outgoing enhancement metadata does not
  block it. See [Incoming reservations](#incoming-reservations).

Every new address needs NEAR's seen set read within the last fifteen minutes (see
[Incoming reservations](#incoming-reservations)). Without one, issuance fails
closed: the swap screen says private swaps are paused and links to Settings, where
NEAR swap privacy can be turned off.

The app keeps one prepared incoming address per account and direction across
amount edits, cancels, direction switches and quote errors, and the wallet
resumes that draft until its latest quote's deadline passes. It is dropped when
NEAR swap privacy changes, when the wallet refuses it as stale (the quote is then
retried once with a new address), or once a swap starts with it. A refund address
serves one quote. Errors never roll back a key that may already have been sent to
the provider.

Received notes keep their derived key for reconstruction and software spending,
and change returns to the ordinary internal key.

## Closing

Keys issued on this device are trial-decrypted, with no key-count cap, until their
swap closes. A key closes as soon as every provider status on it is final and its
expected Zcash receipts are in. Refunds, positive `refundedAmount` values and
exact-output `SUCCESS` leftovers are expected receipts for a refund key; an
incoming key expects `amountOut`. A source-chain refund of an incoming swap is not
a Zcash receipt, and `FAILED` is inconclusive. A key also closes 30 days after its
quote deadline, whatever the provider reports, except an incoming key with an open
reservation. An abandoned incoming address stops scanning when its reservation is
reclaimed. Either way, no key closes while a receipt is unmined
and unexpired or has fewer than 10 confirmations (ZIP 315's untrusted depth), so a
reorg cannot strand a receipt. A rewind that un-mines a closed key's receipt, such
as Vizor's own repair rewinds, reopens the key until the receipt is confirmed
again. Incoming payouts show as pending as soon as they reach the mempool.

Statuses are recorded as they are fetched, by the activity refresh and by deposit
submission; cached UI status and failed polls record nothing. Swap receiving makes
no status requests of its own, so NEAR sees the same polling as without it. Keys
close only at the end of a sync, once the tip is revalidated and scanned, so blocks
mined while the app was offline are checked first. Closing uses the earlier of the
device clock and the tip's block time, so a clock that runs fast cannot close a key
early.

A payment after its key closed, such as a second refund, is found by **Check swap
history**, which starts a new discovery pass (see [Restore](#restore)) and syncs
until it is done, or by a seed restore. Nothing else starts a pass once discovery
is complete. Swap addresses are not permanent receive addresses.

## Restore

A restored account finds its swap keys through discovery
(`zakura_pir_receiver::discover`) instead of trial-decrypting history for every
index. An account the app created from a seed it generated is marked fresh and
has nothing to discover.

1. Every sync runs discovery for each software account after updating the chain
   tip and before the first scan batch, and again as its last follow-up. A run
   with nothing due makes no request.
2. A pass checks each purpose's keys from index zero against the publication's
   filters, which every wallet downloads alike: always the first 100, then on
   until 30 consecutive keys are in no seen set and not in the paid filter, then
   every closed key past that. The wallet accepts a publication only once its scan
   stores the publication's last block.
3. Only a key the paid filter holds is looked up over PIR. A payment the wallet has
   not scanned yet becomes a scan hint that the same sync scans. A payment it has
   already scanned past becomes a late candidate, credited once its inclusion path
   from the publication's common witness file checks against the wallet's own
   chain. The wallet authenticates every payment with the derived key first.
4. A key only discovery found closes 24 hours after the block its lookup finished
   at, catching a payout or refund from a swap in flight at restore. A key the
   seen set holds is marked quoted, so this device does not hand out the old
   device's addresses again. New addresses wait for a restored account's
   discovery to register what its filters mark.
5. Refund keys recovered from funding memos after discovery finished are looked up
   by the first run whose publication reaches the blocks scanned without them.

Restore makes no NEAR status request and cannot recreate a swap's activity record
or an incoming swap's provider association. A payment before the account birthday
is not tracked, as with any note.

Every discovery step commits on its own, so a run stopped by its budget (one
minute before the scan, three minutes after it), cancellation or a failure resumes
where it stopped. Failed lookups back off, and none of this fails ordinary sync.
Background preparation syncs skip discovery. After a seed import, once the first
sync ends, the app starts a quiet sync every 10 seconds for five minutes, so a
restore's discovery continues without waiting for a new block.

## Incoming reservations

Incoming swaps persist a reservation separately from notes and activity. Each quote
request is recorded with its deposit deadline just before it is sent, and each
accepted deposit instruction is kept even if the user leaves the review screen. An
explicit quote rejection releases the request; an uncertain outcome holds the
address until its deadline is two hours past. Starting a swap locks the draft whose
quote matches the deposit address and memo, and the next swap gets another address.

- Before issuing, Vizor downloads NEAR's seen set from the receiver directory, the
  same small file for every wallet: every address NEAR was given in a quote, funded
  or not, since its feed started. An address the set holds, one NEAR accepted a
  quote for, or one with a quote newer than the set's last read (less an hour for
  clock differences) is never issued again. A reservation's first quote request
  checks the same set while it is still current, or a new one. A set read more than
  fifteen minutes ago, or none at all, refuses issuance as `SeenUnavailable`.
- Issuance takes the lowest address never quoted and reuses the lowest abandoned
  one, such as a request NEAR never received, only when nothing else fits. Seen
  addresses move the 30-index recovery gap like received ones, since a restore walks
  past them, so issuance never goes more than 30 indices past the highest receipt
  with 10 confirmations or the highest seen address. It waits for a restored
  account's discovery, which may reveal paid or seen indices.
- An unpaid reservation is reclaimed two hours after its creation and every
  quote's deposit deadline, with the wallet scanned to its tip and no payment to the
  address. A started one also needs a fresh conclusive status from the activity
  refresh, and a funded one `REFUNDED`. A reservation never started needs no
  status: its deposit instructions were never shown. A reclaimed key stops
  scanning. Reserving an address, recording a status and closing keys at the end
  of a sync each reclaim what has become reclaimable.
- Quoting requires the address unpaid, with no queued restore candidate, and the
  wallet scanned to its tip. A paid address is permanently excluded.

Installations of the same seed do not share pending reservations.

## Services

Swap recovery uses the receiver directory (`https://receiver-pir.valargroup.dev`;
in a debug build, `VIZOR_RECEIVER_PIR_URL` overrides it). It uses the route-aware
HTTPS transport of Vizor's other private services, honoring Tor and cancellation,
with bounded requests, no redirects and no direct or public fallback. Receiver
discovery always uses PIR, whatever the Private queries setting; ordinary
transaction and memo retrieval follows that setting.

A publication must commit to mainnet's genesis and cover history from Ironwood
activation. It is provisional until the wallet's scan stores its last block, which
must match the wallet's chain. The common witness file holds deduplicated sibling
hashes for every published payment; each wallet downloads the same bytes, only
when a late candidate needs a path, and verifies every path against its own chain.

Inclusion authenticates a note and its position; transaction IDs and action indices
remain directory assertions, checked against local data. Directory omission
detection, production sizing and hardware qualification remain release work.

## Building

Dependencies are pinned in `rust/Cargo.toml` and `rust/Cargo.lock`. Regenerate the
bridge with `scripts/generate-rust-bridge.sh` after API changes. For a test install,
use an isolated bundle, wallet database and secure-store service, the same in Dart
and Rust, and do not reuse an installed app's wallet identity.

## Tests

The shared library covers derivation, funding records, scanning, closing,
discovery and reservations. In this repository:

```sh
cargo test --manifest-path rust/Cargo.toml --lib -- swap one_time_ivk
fvm flutter test test/features/swap
```

Manual checks use a disposable software wallet. Live funding is a separate,
explicitly authorized exercise.

- Run an outgoing swap that refunds and an incoming swap. Close the app before
  settlement and reopen after it; catch-up must find each payment.
- Restore the seed into a fresh wallet with a birthday before funding, once with
  Private queries on and once off, both with NEAR swap privacy off. Both runs must
  recover the same notes without duplicates, and following the tip must not repeat
  finished lookups. Interrupt one restore once; it must resume without duplicates.
- Spend recovered notes together with ordinary funds; the change must belong to
  the ordinary internal key.
- Check that both settings default off and persist across a restart, and that
  disabling Private queries keeps NEAR swap privacy off after re-enabling it.
- Turn NEAR swap privacy off during a pending swap; its refund must still be found.
  After a key closes, run **Check swap history**; it must look up closed keys once
  and add no duplicate notes.
- Confirm hardware accounts keep their existing address flow, and that quote
  refreshes keep the same incoming address.
