//! Read-only transaction / balance / pending-tx query surface.
//!
//! Everything in this module is an "ask the wallet a question"
//! helper that the FRB layer in `api/sync.rs` or the C FFI layer in
//! `ffi.rs` calls per user action:
//!
//! - Balance queries (`get_wallet_balance`).
//! - Transaction list + on-chain enhancement requests
//!   (`get_transaction_history`, `get_transaction_data_requests`,
//!   `decrypt_and_store_transaction`, `set_transaction_status`).
//!
//! None of these belong to the orchestration loop — the loop lives
//! in `sync_engine/mod.rs`. They're one-shot lookups the UI drives
//! directly, so extracting them into their own submodule keeps
//! `sync/mod.rs` focused on per-wallet infrastructure (DB open,
//! chain-tip update, scan range management) and the shared
//! PROPOSAL_STORE used by both the software and PCZT send paths.

use std::{
    borrow::Cow,
    collections::{HashMap, HashSet},
    ops::Range,
};

use rusqlite::OptionalExtension;
use zcash_client_backend::data_api::{
    transparent_ledger::{
        AccountActivity, ActivityOutputs, Attribution, DetailCompleteness, FeeState,
        FundingStepEvidence, HistoryClassification, OutputRef, RecoveryBlocker, SourcePool,
        TransactionHistoryDetails, TransactionReceipt, TransparentAuthority, TransparentDetailRead,
        TransparentDisplayOmission, TransparentDisplaySource, TransparentDisplayView,
        TransparentLedgerBalance, TransparentLedgerMode, TransparentLedgerRead,
        TransparentLedgerSnapshot,
    },
    Account as _, Balance, WalletRead, WalletWrite,
};
use zcash_client_sqlite::{wallet::history::TransactionSummary, AccountUuid};
use zcash_primitives::transaction::TxId;
use zcash_protocol::{
    consensus::BlockHeight,
    memo::{Memo, MemoBytes},
    value::Zatoshis,
    PoolType,
};

use crate::wallet::block_times::{self, BlockTimePoint};
use crate::wallet::db::{wallet_db_on, with_wallet_db_write_lock, WalletDatabase};
use crate::wallet::keys::{hardware_signer_kind, parse_account_uuid, HardwareSignerKind};
use crate::wallet::network::WalletNetwork;
use crate::wallet::sync_engine::enhancement::selects_private_recovery;
use crate::wallet::sync_engine::transparent_ledger::{recovery_hold, HoldCause};

use super::{open_readonly_conn, open_wallet_db, open_wallet_db_for_read};

const TRANSPARENT_POOL: i64 = 0;
const SAPLING_POOL: i64 = 2;
const ORCHARD_POOL: i64 = 3;
const IRONWOOD_POOL: i64 = 4;

// ======================== Balance ========================

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum WalletBalanceAvailability {
    Available,
    SummaryUnavailable,
    AccountUnavailable,
}

/// What the transparent fields of a [`WalletBalance`] represent.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum TransparentBalanceAuthority {
    /// Current authorized amounts, from public discovery or an active private
    /// ledger complete through the chain tip.
    Current,
    /// No current authority. The transparent fields are zero because nothing
    /// is spendable; `transparent_last_known` holds the prior amount, which is
    /// informational only.
    LastKnown,
    /// No current authority and no prior amount. Unknown, not zero.
    Unavailable,
    /// No current authority, and private recovery will not restore it on its
    /// own: `transparent_stop` says why. The transparent fields are zero, and
    /// `transparent_last_known` holds the prior amount, if any.
    Stopped,
}

/// Why private transparent recovery cannot restore an account's authority.
///
/// Reported only while the account has no current authority. The first that
/// applies wins, in this order.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum TransparentStopReason {
    /// An integrity failure quarantined the account or a source of its
    /// evidence. Nothing clears a quarantine yet.
    Quarantined,
    /// A Ledger account under `PrivateRequired`. Recovery from its birthday
    /// would miss earlier history, so it is not recovered privately.
    Ledger,
    /// Legacy public evidence that the complete private ledger cannot explain
    /// blocks promotion. The account is held.
    LegacyDiscrepancy,
    /// The source withdrew a publication it had answered from. The account is
    /// held.
    Withdrawn,
    /// Recovery stalled in consecutive runs. The account is held.
    Stalled,
    /// The wallet durably requires private recovery, which this build does
    /// not run. Turning off private queries restores public lookups.
    NotSelected,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct WalletBalance {
    pub availability: WalletBalanceAvailability,
    pub transparent_authority: TransparentBalanceAuthority,
    /// The prior transparent total when `transparent_authority` is `LastKnown`
    /// or `Stopped`.
    pub transparent_last_known: Option<u64>,
    /// Why recovery is stopped, present only when `transparent_authority` is
    /// `Stopped`.
    pub transparent_stop: Option<TransparentStopReason>,
    /// The wallet durably requires private transparent authority, so a current
    /// amount lasts only while the private ledger covers the chain tip.
    pub transparent_private: bool,
    pub transparent: u64,
    pub sapling: u64,
    pub orchard: u64,
    pub ironwood: u64,
    pub transparent_locked: u64,
    pub sapling_locked: u64,
    pub orchard_locked: u64,
    pub ironwood_locked: u64,
    pub transparent_pending: u64,
    pub sapling_pending: u64,
    pub orchard_pending: u64,
    pub ironwood_pending: u64,
    pub change_pending_confirmation: u64,
    pub value_pending_spendability: u64,
    pub uneconomic_value: u64,
}

impl WalletBalance {
    fn unavailable(availability: WalletBalanceAvailability, private: bool) -> Self {
        debug_assert_ne!(availability, WalletBalanceAvailability::Available);
        Self::from_pools(
            availability,
            TransparentStatus {
                authority: TransparentBalanceAuthority::Unavailable,
                last_known: None,
                stop: None,
                private,
            },
            PoolBalance::default(),
            [PoolBalance::default(); 3],
        )
    }

    /// Assembles a balance from one transparent and three shielded pools
    /// (Sapling, Orchard, Ironwood), deriving the cross-pool totals.
    fn from_pools(
        availability: WalletBalanceAvailability,
        status: TransparentStatus,
        transparent: PoolBalance,
        [sapling, orchard, ironwood]: [PoolBalance; 3],
    ) -> Self {
        let pools = [transparent, sapling, orchard, ironwood];
        Self {
            availability,
            transparent_authority: status.authority,
            transparent_last_known: status.last_known,
            transparent_stop: status.stop,
            transparent_private: status.private,
            transparent: transparent.spendable,
            sapling: sapling.spendable,
            orchard: orchard.spendable,
            ironwood: ironwood.spendable,
            transparent_locked: transparent.locked,
            sapling_locked: sapling.locked,
            orchard_locked: orchard.locked,
            ironwood_locked: ironwood.locked,
            transparent_pending: transparent.change + transparent.pending,
            sapling_pending: sapling.change + sapling.pending,
            orchard_pending: orchard.change + orchard.pending,
            ironwood_pending: ironwood.change + ironwood.pending,
            change_pending_confirmation: pools.iter().map(|p| p.change).sum(),
            value_pending_spendability: pools.iter().map(|p| p.pending).sum(),
            uneconomic_value: pools.iter().map(|p| p.uneconomic).sum(),
        }
    }
}

/// The transparent status fields of a [`WalletBalance`].
#[derive(Clone, Copy, Debug)]
struct TransparentStatus {
    authority: TransparentBalanceAuthority,
    last_known: Option<u64>,
    stop: Option<TransparentStopReason>,
    private: bool,
}

/// One pool's balance categories, in zatoshis.
#[derive(Clone, Copy, Debug, Default)]
struct PoolBalance {
    spendable: u64,
    locked: u64,
    change: u64,
    pending: u64,
    uneconomic: u64,
}

impl PoolBalance {
    fn of(balance: &Balance) -> Self {
        Self {
            spendable: u64::from(balance.spendable_value()),
            locked: u64::from(balance.locked_value()),
            change: u64::from(balance.change_pending_confirmation()),
            pending: u64::from(balance.value_pending_spendability()),
            uneconomic: u64::from(balance.uneconomic_value()),
        }
    }

    fn of_transparent(balance: &TransparentLedgerBalance) -> Self {
        let (regular, coinbase) = (Self::of(&balance.regular), Self::of(&balance.coinbase));
        Self {
            spendable: regular.spendable + coinbase.spendable,
            locked: regular.locked + coinbase.locked,
            change: regular.change + coinbase.change,
            pending: regular.pending + coinbase.pending,
            uneconomic: regular.uneconomic + coinbase.uneconomic,
        }
    }
}

pub(crate) fn get_wallet_balance(
    db_path: &str,
    network: WalletNetwork,
    account_uuid: &str,
) -> Result<WalletBalance, String> {
    let mut balances = get_wallet_balances(db_path, network, std::slice::from_ref(&account_uuid))?;
    Ok(balances
        .pop()
        .expect("get_wallet_balances returns one entry per requested account"))
}

/// Balances for several accounts from a single `get_wallet_summary`.
///
/// `get_wallet_summary` computes every account's balance regardless of
/// which one the caller wants, so asking it once per account is
/// quadratic in account count. Callers that need more than one account
/// — the Ironwood migration coordinator sweeps all of them every poll —
/// must use this instead of looping over `get_wallet_balance`.
///
/// Returns one entry per requested uuid, in the order given. An account
/// missing from the summary yields `AccountUnavailable` rather than an
/// error, matching the single-account behaviour, so one unknown account
/// cannot fail the whole batch.
///
/// Under a private transparent ledger mode the summary carries no
/// transparent funds, so the transparent fields come from each account's
/// ledger snapshot: its authorized amounts, or none with the last-known
/// amount when authority is unavailable, and why recovery is stopped when it
/// will not restore authority on its own. Durable private policy is respected
/// even when this build opens a Public handle after restart.
pub(crate) fn get_wallet_balances(
    db_path: &str,
    network: WalletNetwork,
    account_uuids: &[&str],
) -> Result<Vec<WalletBalance>, String> {
    let target_ids = account_uuids
        .iter()
        .map(|uuid| parse_account_uuid(uuid))
        .collect::<Result<Vec<_>, _>>()?;

    let mut db = open_wallet_db_for_read(db_path, network)?;
    read_wallet_balances(&mut db, db_path, network, &target_ids)
}

/// [`get_wallet_balances`] on `db`, a handle on the wallet at `db_path`.
pub(crate) fn read_wallet_balances(
    db: &mut WalletDatabase,
    db_path: &str,
    network: WalletNetwork,
    target_ids: &[AccountUuid],
) -> Result<Vec<WalletBalance>, String> {
    // Read durable policy, summary, and authority from one snapshot. The
    // library resolves this handle under a policy another connection applied
    // since `db` was opened, so a private-policy summary's suppressed zero is
    // never labeled as current funds.
    db.transactionally(|db| {
        let durable = db.applied_transparent_policy()?.mode;
        let private = durable == TransparentLedgerMode::PrivateRequired;
        // No run recovers a private wallet in a build that does not select
        // private recovery.
        let not_selected = private && !selects_private_recovery(db_path, network);
        let summary = db.get_wallet_summary(crate::wallet::confirmations_policy())?;

        let Some(summary) = summary else {
            return Ok(target_ids
                .iter()
                .map(|_| {
                    WalletBalance::unavailable(
                        WalletBalanceAvailability::SummaryUnavailable,
                        private,
                    )
                })
                .collect());
        };

        target_ids
            .iter()
            .map(|target_id| {
                let Some(b) = summary.account_balances().get(target_id) else {
                    return Ok(WalletBalance::unavailable(
                        WalletBalanceAvailability::AccountUnavailable,
                        private,
                    ));
                };
                let shielded = [
                    PoolBalance::of(b.sapling_balance()),
                    PoolBalance::of(b.orchard_balance()),
                    PoolBalance::of(b.ironwood_balance()),
                ];
                let snapshot = db.transparent_ledger_snapshot(
                    *target_id,
                    crate::wallet::confirmations_policy(),
                )?;
                let (mut status, transparent) = ledger_transparent_balance(&snapshot, private);
                if status.authority != TransparentBalanceAuthority::Current {
                    if let Some(reason) =
                        transparent_stop_reason(&*db, db_path, &snapshot, not_selected)?
                    {
                        status.authority = TransparentBalanceAuthority::Stopped;
                        status.stop = Some(reason);
                    }
                }
                Ok(WalletBalance::from_pools(
                    WalletBalanceAvailability::Available,
                    status,
                    transparent,
                    shielded,
                ))
            })
            .collect::<Result<Vec<_>, zcash_client_sqlite::error::SqliteClientError>>()
    })
    .map_err(|e| format!("Failed to read wallet balances: {e}"))
}

/// The transparent part of a balance under a private ledger mode.
fn ledger_transparent_balance<A>(
    snapshot: &TransparentLedgerSnapshot<A>,
    private: bool,
) -> (TransparentStatus, PoolBalance) {
    let status = |authority, last_known| TransparentStatus {
        authority,
        last_known,
        stop: None,
        private,
    };
    match (snapshot.authority, &snapshot.authorized) {
        (TransparentAuthority::Public | TransparentAuthority::Private, Some(authorized)) => (
            status(TransparentBalanceAuthority::Current, None),
            PoolBalance::of_transparent(authorized),
        ),
        _ => match &snapshot.last_known {
            Some(last_known) => (
                status(
                    TransparentBalanceAuthority::LastKnown,
                    Some(
                        u64::from(last_known.balance.regular.total())
                            + u64::from(last_known.balance.coinbase.total()),
                    ),
                ),
                PoolBalance::default(),
            ),
            None => (
                status(TransparentBalanceAuthority::Unavailable, None),
                PoolBalance::default(),
            ),
        },
    }
}

/// Why private recovery will not restore authority to the account of
/// `snapshot`, which has none, or `None` while recovery may still restore it.
/// `not_selected` is whether this build leaves the durably private wallet
/// unrecovered.
fn transparent_stop_reason<W>(
    db: &W,
    db_path: &str,
    snapshot: &TransparentLedgerSnapshot<AccountUuid>,
    not_selected: bool,
) -> Result<Option<TransparentStopReason>, W::Error>
where
    W: WalletRead<AccountId = AccountUuid>,
{
    if snapshot
        .blockers
        .contains(&RecoveryBlocker::RecoverySuspended)
    {
        return Ok(Some(TransparentStopReason::Quarantined));
    }
    // The coordinator pauses Ledger accounts under `PrivateRequired`.
    if snapshot.mode == TransparentLedgerMode::PrivateRequired
        && db.get_account(snapshot.account)?.is_some_and(|account| {
            hardware_signer_kind(account.source()) == Some(HardwareSignerKind::Ledger)
        })
    {
        return Ok(Some(TransparentStopReason::Ledger));
    }
    if let Some(cause) = recovery_hold(db_path, snapshot.account) {
        return Ok(Some(match cause {
            HoldCause::Withdrawn(_) | HoldCause::Unreconciled => TransparentStopReason::Withdrawn,
            HoldCause::LegacyDiscrepancy => TransparentStopReason::LegacyDiscrepancy,
            HoldCause::Stalled => TransparentStopReason::Stalled,
        }));
    }
    Ok(not_selected.then_some(TransparentStopReason::NotSelected))
}

// ======================== Transaction Enhancement Requests ========================

pub(crate) struct TxDataRequest {
    pub request_type: String, // "address_txids"
    pub txid: Option<String>,
    pub address: Option<String>,
    pub block_range_start: Option<u64>,
    pub block_range_end: Option<u64>,
}

pub(crate) fn get_transaction_data_requests(
    db_path: &str,
    network: WalletNetwork,
) -> Result<Vec<TxDataRequest>, String> {
    use zcash_client_backend::data_api::TransactionDataRequest;

    let db = open_wallet_db_for_read(db_path, network)?;
    let requests = db.transaction_data_requests().map_err(|e| format!("{e}"))?;

    Ok(requests
        .into_iter()
        .map(|r| match r {
            TransactionDataRequest::TransactionsInvolvingAddress(req) => {
                let addr =
                    zcash_keys::encoding::encode_transparent_address_p(&network, &req.address());
                TxDataRequest {
                    request_type: "address_txids".into(),
                    txid: None,
                    address: Some(addr),
                    block_range_start: Some(u32::from(req.block_range_start()) as u64),
                    block_range_end: req.block_range_end().map(|h| u32::from(h) as u64),
                }
            }
        })
        .collect())
}

/// Returns unmined transactions that the wallet previously discovered in a
/// compact block and that a pending scan range could still restore as mined.
/// A shielded note only receives a commitment-tree position when it is scanned
/// as mined; truncation retains that position even after it clears the
/// transaction's mined height. A local history record also preserves mined
/// evidence for transactions without received notes.
pub(crate) fn get_unmined_txids_with_mined_output_evidence(
    db_path: &str,
    pending_ranges: &[Range<BlockHeight>],
) -> Result<HashSet<Vec<u8>>, String> {
    if pending_ranges.is_empty() {
        return Ok(HashSet::new());
    }

    let conn = open_readonly_conn(db_path)?;
    unmined_txids_with_mined_output_evidence(&conn, pending_ranges)
}

/// Reads the same rescan guard inside a caller-owned SQLite snapshot.
pub(super) fn unmined_txids_with_mined_output_evidence(
    conn: &rusqlite::Connection,
    pending_ranges: &[Range<BlockHeight>],
) -> Result<HashSet<Vec<u8>>, String> {
    if pending_ranges.is_empty() {
        return Ok(HashSet::new());
    }
    let mut stmt = conn
        .prepare(&format!(
            "SELECT DISTINCT t.txid, t.min_observed_height, t.expiry_height
             FROM transactions t
             WHERE t.mined_height IS NULL AND {MINED_TRANSACTION_EVIDENCE}"
        ))
        .map_err(|e| format!("SQL error: {e}"))?;
    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, Vec<u8>>(0)?,
                row.get::<_, u32>(1)?,
                row.get::<_, Option<u32>>(2)?,
            ))
        })
        .map_err(|e| format!("Query error: {e}"))?;

    rows.filter_map(|row| match row {
        Ok((txid, min_observed_height, expiry_height))
            if pending_ranges.iter().any(|range| {
                let range_start = u32::from(range.start);
                let range_end = u32::from(range.end);
                let known_expiry = expiry_height.filter(|height| *height > 0);
                range_end > min_observed_height
                    && known_expiry.is_none_or(|height| range_start < height)
            }) =>
        {
            Some(Ok(txid))
        }
        Ok(_) => None,
        Err(error) => Some(Err(error)),
    })
    .collect::<Result<HashSet<_>, _>>()
    .map_err(|e| format!("Row error: {e}"))
}

pub fn decrypt_and_store_transaction(
    db_path: &str,
    network: WalletNetwork,
    tx_bytes: &[u8],
    mined_height: Option<u64>,
) -> Result<(), String> {
    use zcash_client_backend::data_api::wallet::decrypt_and_store_transaction;
    use zcash_primitives::transaction::Transaction;
    use zcash_protocol::consensus::BranchId;

    let tx = Transaction::read(tx_bytes, BranchId::Sapling)
        .map_err(|e| format!("Failed to read transaction: {e}"))?;
    let height = mined_height.map(|h| BlockHeight::from_u32(h as u32));

    with_wallet_db_write_lock("transactions.decrypt_and_store_transaction", || {
        let mut db = open_wallet_db(db_path, network)?;
        decrypt_and_store_transaction(&network, &mut db, &tx, height)
            .map_err(|e| format!("Failed to decrypt/store transaction: {e}"))
    })
}

pub fn set_transaction_status(
    db_path: &str,
    network: WalletNetwork,
    txid_hex: &str,
    status: i64,
) -> Result<(), String> {
    use zcash_client_backend::data_api::TransactionStatus;

    let txid_bytes = hex::decode(txid_hex).map_err(|e| format!("Bad txid hex: {e}"))?;
    let txid = zcash_primitives::transaction::TxId::from_bytes(
        txid_bytes.try_into().map_err(|_| "TxId must be 32 bytes")?,
    );

    let tx_status = match status {
        -2 => TransactionStatus::TxidNotRecognized,
        -1 => TransactionStatus::NotInMainChain,
        h => TransactionStatus::Mined(BlockHeight::from_u32(h as u32)),
    };

    with_wallet_db_write_lock("transactions.set_transaction_status", || {
        let mut db = open_wallet_db(db_path, network)?;
        db.set_transaction_status(txid, tx_status)
            .map_err(|e| format!("Failed to set status: {e}"))
    })
}

// ======================== Transaction History ========================

pub(crate) struct TransactionInfo {
    pub txid_hex: String,
    pub mined_height: u64,
    pub expired_unmined: bool,
    pub account_balance_delta: i64,
    /// The network fee shown for the transaction. Zero unless `fee_state` is
    /// `Known`. Display only: it is never subtracted from `display_amount`
    /// or `account_balance_delta`.
    pub fee: u64,
    pub fee_state: TransactionFeeState,
    pub block_time: u64,
    pub is_transparent: bool,
    pub tx_kind: String,
    pub display_amount: u64,
    pub display_pool: String,
    pub activity_pool: Option<String>,
    pub funding_parent_txid: Option<String>,
    pub funding_parent_mined_height: Option<u64>,
    pub funding_parent_expired: Option<bool>,
    pub created_time: u64,
    /// Whether the recipients, payment amounts, and memos are known. A
    /// missing recipient row does not mean there was no payment.
    pub details_complete: bool,
    /// Whether later discovery or enhancement can still change this row. A
    /// provisional net debit is not a payment amount.
    pub provisional: bool,
    /// Whether `display_amount` is a balance movement that retains its fee,
    /// rather than an established payment. Show it as a net change, including
    /// when the account's fee share is unknown.
    pub amount_includes_fee: bool,
}

/// The network fee shown for a transaction. Unknown, zero, and not
/// applicable stay distinct.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TransactionFeeState {
    /// The account's attributed fee is known.
    Known,
    /// The account spent funds, or may have, but its fee share is unknown.
    Unknown,
    /// The account spent nothing, so it paid no fee.
    NotApplicable,
}

pub(crate) struct TransactionDetail {
    pub txid_hex: String,
    pub tx_kind: String,
    pub primary_address: Option<String>,
    pub source_address: Option<String>,
    pub source_pool: Option<String>,
    /// For a receive: the wallet account its `sent_notes` record as having
    /// sent every received output shown, when they all name the same one.
    /// It names an account, never an address, and does not say that account
    /// was the transaction's only funder.
    pub source_account_uuid: Option<String>,
    pub memo: Option<String>,
    pub outputs: Vec<TransactionDetailOutput>,
    /// See [`TransactionInfo::details_complete`]: `outputs` may be partial.
    pub details_complete: bool,
    /// Whether the transaction's payment classification or owned effects remain
    /// provisional. An established Activity row can still have incomplete receipt details.
    pub provisional: bool,
    /// Whether the account's side of the transaction is settled
    /// (`ReceiptAttribution::effects_settled`): every owned effect is
    /// settled, the transaction is mined, and no owned transparent output has
    /// an unknown key scope. The library's receipt read decided from it, and
    /// from the movement and fee below, what `primary_address`,
    /// `details_complete` and `provisional` show; the app does not read them.
    #[cfg_attr(not(test), allow(dead_code))]
    pub effects_settled: bool,
    /// Transparent txid enhancement's view of the transaction: `None` when
    /// it has no transparent part the account recorded.
    pub transparent_details: Option<TransparentDetailsView>,
    /// The account's net balance change, and the fee when it is known (the
    /// account's, or the whole transaction's).
    #[cfg_attr(not(test), allow(dead_code))]
    pub account_balance_delta: i64,
    #[cfg_attr(not(test), allow(dead_code))]
    pub fee: Option<u64>,
    /// Exact whole-transaction fee for receipt display; never an account fee share.
    pub network_fee: Option<u64>,
}

/// What loop 4 knows about a transparent or mixed transaction's outputs.
pub(crate) enum TransparentDetailsView {
    /// The shown transparent outputs, in order: every output of a stored raw
    /// transaction, or the first two of the private details.
    Available {
        rows: Vec<TransparentRecipientRow>,
        /// Every transparent output, including any `rows` leaves out.
        output_count: u32,
        /// What the private details leave out, by name, deduplicated; empty
        /// when the details came from the raw transaction.
        omissions: Vec<String>,
    },
    /// No lookup has answered yet.
    Pending,
    /// The last lookup failed; a later sync retries.
    Unavailable,
    /// The private publication does not cover the transaction.
    NotCovered,
}

pub(crate) struct TransparentRecipientRow {
    pub output_index: u32,
    pub address: Option<String>,
    pub amount_zatoshi: u64,
    /// Whether the account recorded this output as its own.
    pub is_own: bool,
}

pub(crate) struct TransactionDetailOutput {
    pub address: Option<String>,
    pub amount_zatoshi: u64,
    pub pool: String,
    /// Exact output pool for activity and Gift Card destination metadata.
    pub activity_pool: Option<String>,
    pub uses_orchard_receiver: bool,
}

pub(crate) struct ExportBirthdayAnchor {
    pub block_height: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct TxBase {
    txid: Vec<u8>,
    transaction_id: i64,
    /// The mined height the Activity list shows: the library's, or the Gift
    /// Card claim record's for a claim (see [`read_transaction_history`]).
    mined_height: Option<u32>,
    expired_unmined: bool,
    account_balance_delta: i64,
    block_time: u64,
    total_spent: u64,
    total_received: u64,
    expiry_height: Option<i64>,
    tx_index: i64,
    created: Option<String>,
    created_time: u64,
    history: HistoryView,
}

/// A fee, as far as a row shows it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Fee {
    Known(u64),
    Unknown,
    NotApplicable,
}

impl Fee {
    /// The fee the account is attributed. A whole-transaction fee whose share
    /// is not established is not the account's, so it shows as unknown.
    fn shown(fee: FeeState) -> Self {
        match fee {
            FeeState::Known(fee) => Fee::Known(fee.into_u64()),
            FeeState::Unattributed { .. } | FeeState::Unknown => Fee::Unknown,
            FeeState::NotApplicable => Fee::NotApplicable,
        }
    }

    /// The fee of a transaction and of a funding step shown as part of it.
    fn plus(self, other: Fee) -> Fee {
        match (self, other) {
            (Fee::Known(a), Fee::Known(b)) => Fee::Known(a.saturating_add(b)),
            (Fee::Unknown, _) | (_, Fee::Unknown) => Fee::Unknown,
            (Fee::NotApplicable, fee) | (fee, Fee::NotApplicable) => fee,
        }
    }

    fn known_or_zero(self) -> u64 {
        match self {
            Fee::Known(fee) => fee,
            Fee::Unknown | Fee::NotApplicable => 0,
        }
    }

    fn state(self) -> TransactionFeeState {
        match self {
            Fee::Known(_) => TransactionFeeState::Known,
            Fee::Unknown => TransactionFeeState::Unknown,
            Fee::NotApplicable => TransactionFeeState::NotApplicable,
        }
    }
}

/// The library's history view of the account's side of a transaction, as the
/// Activity list uses it.
#[derive(Clone, Debug, PartialEq, Eq)]
struct HistoryView {
    /// Transaction-wide Enhance shape assertion, independent of payment completeness.
    has_transparent_outputs: Option<bool>,
    details_complete: bool,
    /// The classification is provisional or an owned effect is not settled.
    provisional: bool,
    fee: FeeState,
    /// What the transaction shows in the account's activity list.
    activity: AccountActivity,
    /// What it contributes to pairing a TEX funding step with its payment.
    funding_step: FundingStepEvidence,
    /// Whether the library read the transaction as mined.
    mined: bool,
}

impl HistoryView {
    fn of(details: &TransactionHistoryDetails) -> Self {
        let effects_settled = details
            .effects
            .iter()
            .all(|effect| effect.completeness.is_settled());
        Self {
            has_transparent_outputs: details.has_transparent_outputs,
            details_complete: details.payment_details == DetailCompleteness::Complete,
            provisional: details.classification == HistoryClassification::Provisional
                || !effects_settled,
            fee: details.fee,
            activity: details.activity.clone(),
            funding_step: details.funding_step,
            mined: details.mined_height.is_some(),
        }
    }

    /// Assumed until the history read reports on a transaction, which it does
    /// for every transaction the summaries list: nothing is known.
    fn unread(mined: bool) -> Self {
        Self {
            has_transparent_outputs: None,
            details_complete: false,
            provisional: true,
            fee: FeeState::Unknown,
            activity: AccountActivity::Unknown,
            funding_step: FundingStepEvidence::default(),
            mined,
        }
    }

    fn shown_fee(&self) -> Fee {
        Fee::shown(self.fee)
    }

    /// Whether a movement amount retains a whole fee whose share the account
    /// is not attributed.
    fn movement_retains_fee(&self) -> bool {
        matches!(self.fee, FeeState::Unattributed { .. })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct TxOutput {
    output_pool: i64,
    output_index: i64,
    from_account_uuid: Option<Vec<u8>>,
    to_address: Option<String>,
    sent_to_address: Option<String>,
    transparent_receiver_address: Option<String>,
    value: u64,
    memo: Option<Vec<u8>>,
}

impl TxOutput {
    fn detail_address(&self, tx_kind: &str) -> Option<String> {
        if tx_kind == "migration" {
            // A migration moves value between pools owned by the same account.
            // Its internal receiver is implementation detail, not a
            // counterparty address that should be exposed in Activity.
            None
        } else if tx_kind == "sent" {
            if self.output_pool == 0 {
                return self
                    .transparent_receiver_address
                    .clone()
                    .or_else(|| self.sent_to_address.clone())
                    .or_else(|| self.to_address.clone());
            }

            self.sent_to_address
                .clone()
                .or_else(|| self.to_address.clone())
        } else if self.output_pool == 0 {
            // Received transparent outputs: surface the bare t-address. The
            // wallet stores the account UA in `to_address`, so without this
            // recovery the UA leaks into the receiving-address line and the
            // desktop receipt's address-prefix heuristic mislabels a
            // transparent->transparent receive as shielded (crimson shield +
            // u1 address). Mirrors the `sent` pool-0 branch above.
            self.transparent_receiver_address
                .clone()
                .or_else(|| self.to_address.clone())
        } else {
            self.to_address.clone()
        }
    }

    /// Whether this is the output `key` names.
    fn is(&self, key: &OutputRef) -> bool {
        self.output_index == i64::from(key.index) && Some(self.output_pool) == pool_code(key.pool)
    }
}

/// The wallet database's code of `pool`.
fn pool_code(pool: PoolType) -> Option<i64> {
    match pool {
        PoolType::Transparent => Some(TRANSPARENT_POOL),
        pool if pool == PoolType::SAPLING => Some(SAPLING_POOL),
        pool if pool == PoolType::ORCHARD => Some(ORCHARD_POOL),
        pool if pool == PoolType::IRONWOOD => Some(IRONWOOD_POOL),
        _ => None,
    }
}

/// Which pools a row's outputs are in.
#[derive(Default)]
struct RowPools {
    transparent: bool,
    sapling: bool,
    orchard: bool,
    ironwood: bool,
}

impl RowPools {
    fn of(outputs: &[OutputRef]) -> Self {
        let mut pools = Self::default();
        for output in outputs {
            match pool_code(output.pool) {
                Some(TRANSPARENT_POOL) => pools.transparent = true,
                Some(SAPLING_POOL) => pools.sapling = true,
                Some(ORCHARD_POOL) => pools.orchard = true,
                Some(IRONWOOD_POOL) => pools.ironwood = true,
                _ => {}
            }
        }
        pools
    }

    fn display_pool(&self) -> &'static str {
        // Preserve the legacy grouping used by Gift Card activity.
        match (
            self.transparent,
            self.sapling || self.orchard,
            self.ironwood,
        ) {
            (true, false, false) => "transparent",
            (false, true, false) => "shielded",
            (false, false, true) => "ironwood",
            (false, false, false) => "unknown",
            _ => "mixed",
        }
    }

    fn activity_pool(&self) -> &'static str {
        match (self.transparent, self.sapling, self.orchard, self.ironwood) {
            (true, false, false, false) => "transparent",
            (false, true, false, false) => "sapling",
            (false, false, true, false) => "orchard",
            (false, false, false, true) => "ironwood",
            (false, false, false, false) => "unknown",
            _ => "mixed",
        }
    }
}

type FundingStepMatchKey = (String, i64, u64);

#[derive(Default)]
struct SuppressedFundingStepFees {
    suppressed_funding_txids: HashSet<i64>,
    extra_fee_by_external_txid: HashMap<i64, Fee>,
    funding_parent_by_external_txid: HashMap<i64, i64>,
}

struct ClassifiedTx {
    info: TransactionInfo,
    sort_pending_rank: u8,
    sort_timestamp: u64,
    sort_mined_height: u64,
    tx_index: i64,
    row_order: u8,
}

pub(crate) fn get_transaction_history(
    db_path: &str,
    network: WalletNetwork,
    limit: Option<u32>,
    account_uuid: &str,
) -> Result<Vec<TransactionInfo>, String> {
    let account = parse_account_uuid(account_uuid)?;
    let conn = open_readonly_conn(db_path)?;
    read_transaction_history(&conn, db_path, network, limit, account)
}

fn read_transaction_history(
    conn: &rusqlite::Connection,
    db_path: &str,
    network: WalletNetwork,
    limit: Option<u32>,
    account: AccountUuid,
) -> Result<Vec<TransactionInfo>, String> {
    // Both library reads borrow this connection, keeping one WAL snapshot
    // across concurrent sync.
    let read_tx = conn
        .unchecked_transaction()
        .map_err(|e| format!("SQL error: {e}"))?;
    let mut bases = read_history_bases(&read_tx, db_path, network, account)?;
    if bases.is_empty() {
        return Ok(Vec::new());
    }
    attach_history_details(&read_tx, db_path, network, account, &mut bases)?;
    // A Gift Card claim shows the mined height Vizor recorded for it. The
    // library does not know these records, so only its rows that depend on
    // the mined height are re-derived ([`TxBase::activity`]).
    if let Some(state) = crate::wallet::sync_engine::gift_card_claim::snapshot_from_conn(&read_tx)?
    {
        for base in &mut bases {
            if base.created.is_some() {
                base.mined_height = read_tx
                    .query_row(
                        "SELECT height FROM vizor_giftcard_mined WHERE txid=?1",
                        [&base.txid],
                        |r| r.get(0),
                    )
                    .optional()
                    .map_err(|e| e.to_string())?;
                base.expired_unmined = state.complete
                    && base.mined_height.is_none()
                    && base
                        .expiry_height
                        .is_some_and(|h| h > 0 && h as u64 + 5 <= state.checked_height as u64);
            }
        }
    }
    drop(read_tx);

    Ok(assemble_history(&bases, limit))
}

/// How many transactions one library history read covers.
const HISTORY_DETAILS_BATCH: usize = 256;

/// Attaches the library's history view of each base. It is read through a
/// configured handle over `conn`, inside the transaction the bases were read
/// in, so both describe the same database state.
fn attach_history_details(
    conn: &rusqlite::Connection,
    db_path: &str,
    network: WalletNetwork,
    account: AccountUuid,
    bases: &mut [TxBase],
) -> Result<(), String> {
    let db = wallet_db_on(conn, db_path, network);
    let txids = bases
        .iter()
        .map(|base| txid_of(&base.txid))
        .collect::<Result<Vec<_>, _>>()?;
    let mut read = HashMap::with_capacity(bases.len());
    for batch in txids.chunks(HISTORY_DETAILS_BATCH) {
        for details in db
            .transaction_history_details(account, batch)
            .map_err(|e| format!("Failed to read history details: {e}"))?
        {
            read.insert(details.txid.as_ref().to_vec(), HistoryView::of(&details));
        }
    }
    for base in bases {
        if let Some(history) = read.remove(&base.txid) {
            base.history = history;
        }
    }
    Ok(())
}

fn txid_of(bytes: &[u8]) -> Result<TxId, String> {
    <[u8; 32]>::try_from(bytes)
        .map(TxId::from_bytes)
        .map_err(|_| "Invalid txid length".to_string())
}

/// Turn history rows into the display list: pair funding steps, build each
/// transaction's rows from its library activity, sort and truncate. No
/// database access.
fn assemble_history(bases: &[TxBase], limit: Option<u32>) -> Vec<TransactionInfo> {
    let external_send_keys = build_external_send_keys(bases);
    let suppressed_funding_step_fees =
        build_suppressed_funding_step_fees(bases, &external_send_keys);

    let bases_by_id: HashMap<i64, &TxBase> = bases
        .iter()
        .map(|base| (base.transaction_id, base))
        .collect();
    let mut visible = Vec::new();
    for base in bases {
        if suppressed_funding_step_fees
            .suppressed_funding_txids
            .contains(&base.transaction_id)
        {
            continue;
        }

        let extra_sent_fee = if base.history.funding_step.external_transparent_send {
            suppressed_funding_step_fees
                .extra_fee_by_external_txid
                .get(&base.transaction_id)
                .copied()
                .unwrap_or(Fee::NotApplicable)
        } else {
            Fee::NotApplicable
        };

        let mut rows = activity_rows(base, extra_sent_fee);
        if let Some(parent_id) = suppressed_funding_step_fees
            .funding_parent_by_external_txid
            .get(&base.transaction_id)
        {
            if let Some(parent) = bases_by_id.get(parent_id) {
                for row in &mut rows {
                    if row.info.tx_kind == "sent" {
                        row.info.funding_parent_txid = Some(hex::encode(&parent.txid));
                        row.info.funding_parent_mined_height =
                            Some(parent.mined_height.unwrap_or(0).into());
                        row.info.funding_parent_expired = Some(parent.expired_unmined);
                    }
                }
            }
        }
        visible.extend(rows);
    }

    visible.sort_by(|a, b| {
        b.sort_pending_rank
            .cmp(&a.sort_pending_rank)
            .then_with(|| b.sort_timestamp.cmp(&a.sort_timestamp))
            .then_with(|| b.sort_mined_height.cmp(&a.sort_mined_height))
            .then_with(|| b.tx_index.cmp(&a.tx_index))
            .then_with(|| b.info.txid_hex.cmp(&a.info.txid_hex))
            .then_with(|| a.row_order.cmp(&b.row_order))
    });

    if let Some(limit) = limit {
        visible.truncate(limit as usize);
    }

    visible.into_iter().map(|tx| tx.info).collect()
}

pub fn get_previous_transaction_count_for_address(
    db_path: &str,
    _network: WalletNetwork,
    account_uuid: &str,
    address: &str,
) -> Result<u32, String> {
    let uuid = uuid::Uuid::parse_str(account_uuid).map_err(|e| format!("Invalid UUID: {e}"))?;
    let uuid_bytes = uuid.as_bytes().to_vec();
    let address = address.trim();
    if address.is_empty() {
        return Ok(0);
    }

    let conn = open_readonly_conn(db_path)?;
    let count = conn
        .query_row(
            r#"
        SELECT COUNT(*)
        FROM (
            SELECT DISTINCT tx.txid
            FROM sent_notes sn
            JOIN transactions tx ON tx.id_tx = sn.transaction_id
            JOIN accounts from_acc ON from_acc.id = sn.from_account_id
            JOIN v_transactions vt ON vt.txid = tx.txid
            WHERE from_acc.uuid = ?1
              AND vt.account_uuid = ?1
              AND sn.to_address = ?2
              AND COALESCE(sn.value, 0) > 0

            UNION

            SELECT DISTINCT txo.txid
            FROM v_tx_outputs txo
            JOIN v_transactions vt ON vt.txid = txo.txid
            WHERE txo.from_account_uuid = ?1
              AND vt.account_uuid = ?1
              AND txo.to_address = ?2
              AND COALESCE(txo.value, 0) > 0
        ) matched
        "#,
            rusqlite::params![uuid_bytes.as_slice(), address],
            |row| row.get::<_, i64>(0),
        )
        .map_err(|e| format!("Previous transaction count query error: {e}"))?;

    Ok(u32::try_from(count).unwrap_or(u32::MAX))
}

pub(crate) fn get_oldest_mined_transaction_anchor(
    db_path: &str,
    account_uuid: &str,
) -> Result<Option<ExportBirthdayAnchor>, String> {
    let account_id = parse_account_uuid(account_uuid)?;
    let conn = open_readonly_conn(db_path)?;
    let mut stmt = conn
        .prepare(
            r#"
        SELECT
            mined_height
        FROM v_transactions
        WHERE account_uuid = ?1
          AND mined_height IS NOT NULL
        ORDER BY mined_height ASC, COALESCE(tx_index, -1) ASC
        LIMIT 1
        "#,
        )
        .map_err(|e| format!("SQL error: {e}"))?;

    stmt.query_row(
        rusqlite::params![account_id.expose_uuid().as_bytes().as_slice()],
        |row| {
            let block_height = row.get::<_, u32>(0)?;
            Ok(ExportBirthdayAnchor {
                block_height: u64::from(block_height),
            })
        },
    )
    .optional()
    .map_err(|e| format!("Query error: {e}"))
}

pub(crate) fn get_export_birthday_anchor(
    db_path: &str,
    account_uuid: &str,
) -> Result<ExportBirthdayAnchor, String> {
    if let Some(anchor) = get_oldest_mined_transaction_anchor(db_path, account_uuid)? {
        return Ok(anchor);
    }

    get_account_birthday_height(db_path, account_uuid)?
        .map(|block_height| ExportBirthdayAnchor { block_height })
        .ok_or_else(|| "Account birthday not found".to_string())
}

/// Header time of block `height`, from local data only.
///
/// Returns the exact time when the wallet has scanned that block. Otherwise,
/// where [`block_times::table_covers`] the network (real mainnet), estimates
/// it from the compiled-in block-time table, anchored past the table by the
/// wallet's highest scanned block. Returns `None` elsewhere, including Ironwood
/// masquerade builds, when the block is not stored locally.
///
/// Callers pass the height they already display, so the returned time always
/// belongs to that height even if the wallet's data changes in between.
pub(crate) fn get_local_block_time(
    db_path: &str,
    network: WalletNetwork,
    height: u64,
) -> Result<Option<u64>, String> {
    let conn = open_readonly_conn(db_path)?;
    let exact = conn
        .query_row(
            "SELECT time FROM blocks WHERE height = ?1",
            [height],
            |row| row.get::<_, Option<u32>>(0),
        )
        .optional()
        .map_err(|e| format!("Block time query error: {e}"))?
        .flatten();
    if let Some(time) = exact {
        return Ok(Some(u64::from(time)));
    }
    if !block_times::table_covers(network) {
        return Ok(None);
    }

    let highest_scanned = conn
        .query_row(
            "SELECT height, time FROM blocks
             WHERE time IS NOT NULL
             ORDER BY height DESC
             LIMIT 1",
            [],
            |row| {
                Ok(BlockTimePoint {
                    height: row.get(0)?,
                    time: row.get(1)?,
                })
            },
        )
        .optional()
        .map_err(|e| format!("Highest scanned block query error: {e}"))?;
    Ok(Some(u64::from(block_times::mainnet_time_for_height(
        height,
        highest_scanned,
    ))))
}

fn get_account_birthday_height(db_path: &str, account_uuid: &str) -> Result<Option<u64>, String> {
    let account_id = parse_account_uuid(account_uuid)?;
    let conn = open_readonly_conn(db_path)?;
    let mut stmt = conn
        .prepare("SELECT birthday_height FROM accounts WHERE uuid = ?1")
        .map_err(|e| format!("SQL error: {e}"))?;

    stmt.query_row(
        rusqlite::params![account_id.expose_uuid().as_bytes().as_slice()],
        |row| {
            let block_height = row.get::<_, u32>(0)?;
            Ok(u64::from(block_height))
        },
    )
    .optional()
    .map_err(|e| format!("Query error: {e}"))
}

pub(crate) fn get_transaction_detail(
    db_path: &str,
    network: WalletNetwork,
    account_uuid: &str,
    txid_hex: &str,
    tx_kind: &str,
) -> Result<TransactionDetail, String> {
    let account = parse_account_uuid(account_uuid)?;
    let conn = open_readonly_conn(db_path)?;
    let read_tx = conn
        .unchecked_transaction()
        .map_err(|e| format!("SQL error: {e}"))?;
    read_transaction_detail(&read_tx, db_path, network, account, txid_hex, tx_kind)
}

/// The name a receipt uses for an omission.
fn omission_name(omission: &TransparentDisplayOmission) -> &'static str {
    use TransparentDisplayOmission as O;
    match omission {
        O::NonStandardSender => "non_standard_sender",
        O::MultipleSourceScripts => "multiple_source_scripts",
        O::SharedFunding => "shared_funding",
        O::ShieldedAndTransparentFunding => "shielded_and_transparent_funding",
        O::NonStandardOutput { .. } => "non_standard_output",
        O::MoreThanTwoOutputs => "more_than_two_outputs",
    }
}

/// Loop 4's view of a transaction, as the receipt shows it.
fn transparent_details_view(view: TransparentDisplayView) -> TransparentDetailsView {
    match view {
        TransparentDisplayView::Available(details) => {
            // What the receipt does not show, whatever the source. A raw
            // transaction lists every output, so only display facts can omit
            // outputs; that is the one omission a public load fills in.
            let raw = !matches!(details.source, TransparentDisplaySource::Display(_));
            let mut omissions: Vec<String> = Vec::new();
            for omission in &details.omissions {
                if raw && *omission == TransparentDisplayOmission::MoreThanTwoOutputs {
                    continue;
                }
                let name = omission_name(omission);
                if omissions.iter().any(|known| known == name) {
                    continue;
                }
                omissions.push(name.to_owned());
            }
            let rows = details
                .outputs
                .into_iter()
                .map(|output| TransparentRecipientRow {
                    output_index: output.index,
                    address: output.address.map(|address| address.encoded),
                    amount_zatoshi: output.value.into_u64(),
                    is_own: output.owned,
                })
                .collect();
            TransparentDetailsView::Available {
                rows,
                output_count: details.output_count,
                omissions,
            }
        }
        TransparentDisplayView::Pending => TransparentDetailsView::Pending,
        TransparentDisplayView::Unavailable => TransparentDetailsView::Unavailable,
        TransparentDisplayView::NotCovered => TransparentDetailsView::NotCovered,
    }
}

/// `get_transaction_detail` within an open read transaction: the library's
/// receipt of the transaction, with the outputs its `tx_kind` row counts.
fn read_transaction_detail(
    read_tx: &rusqlite::Connection,
    db_path: &str,
    network: WalletNetwork,
    account: AccountUuid,
    txid_hex: &str,
    tx_kind: &str,
) -> Result<TransactionDetail, String> {
    let uuid_bytes = account.expose_uuid().as_bytes().to_vec();
    let txid = hex::decode(txid_hex).map_err(|e| format!("Invalid txid: {e}"))?;
    let txid_id = txid_of(&txid)?;

    let db = wallet_db_on(read_tx, db_path, network);
    let Some(receipt) = db
        .transaction_receipt(account, txid_id)
        .map_err(|e| format!("Failed to read the receipt: {e}"))?
    else {
        return Err("Transaction not found".to_string());
    };
    let TransactionReceipt {
        details,
        display,
        attribution,
    } = receipt;
    let history = HistoryView::of(&details);

    let mut outputs = read_outputs_for_tx(read_tx, &uuid_bytes, &txid)?;
    outputs.sort_by(|a, b| {
        a.output_index
            .cmp(&b.output_index)
            .then_with(|| a.output_pool.cmp(&b.output_pool))
    });
    // A receipt shows exactly the outputs its Activity row counts.
    let shown = receipt_outputs(&details.activity, tx_kind);
    let visible_outputs = outputs
        .iter()
        .filter(|output| shown.iter().any(|key| output.is(key)))
        .collect::<Vec<_>>();
    let memo = visible_outputs
        .iter()
        .find_map(|output| decode_text_memo(output.memo.as_deref()));
    let received = matches!(tx_kind, "received" | "receiving");
    let mut primary_address = if tx_kind == "sent" {
        visible_outputs
            .iter()
            .find_map(|output| output.detail_address(tx_kind))
    } else {
        None
    };
    let source = (received && !visible_outputs.is_empty()).then_some(&attribution.source);
    let source_account_uuid = if received {
        received_source_account(&visible_outputs)
    } else {
        None
    };
    let detail_outputs = visible_outputs
        .into_iter()
        .map(|output| TransactionDetailOutput {
            address: output.detail_address(tx_kind),
            amount_zatoshi: output.value,
            pool: output_pool_label(output.output_pool).to_string(),
            activity_pool: exact_output_pool_label(output.output_pool).map(str::to_string),
            uses_orchard_receiver: matches!(output.output_pool, ORCHARD_POOL | IRONWOOD_POOL),
        })
        .collect();

    let mut details_complete = history.details_complete;
    let mut provisional = history.provisional;
    // A send the wallet recorded no recipient for: its transparent details
    // can name the recipient, and complete the receipt once its effects are
    // settled (`ReceiptAttribution::recipient`).
    if tx_kind == "sent" && primary_address.is_none() {
        if let Attribution::Established(recipient) = &attribution.recipient {
            primary_address = Some(recipient.encoded.clone());
            if attribution.recipient_completes {
                details_complete = true;
                provisional = false;
            }
        }
    }
    // A settled receive its transparent details account for is complete
    // (`ReceiptAttribution::receive_completes`).
    if tx_kind == "received" && attribution.receive_completes {
        details_complete = true;
        provisional = false;
    }
    let spent = details.account_movement.spent > 0;

    Ok(TransactionDetail {
        txid_hex: hex::encode(&txid),
        tx_kind: tx_kind.to_string(),
        primary_address,
        source_address: source.and_then(|s| s.address.as_ref().map(|a| a.encoded.clone())),
        source_pool: source.map(|s| source_pool_label(s.pool).to_string()),
        source_account_uuid,
        memo,
        outputs: detail_outputs,
        details_complete,
        provisional,
        effects_settled: attribution.effects_settled,
        transparent_details: display.map(transparent_details_view),
        account_balance_delta: i64::try_from(details.account_movement.net())
            .map_err(|_| "Invalid account movement".to_string())?,
        network_fee: details
            .whole_fee
            .filter(|_| spent)
            .map(|fee| fee.into_u64()),
        // The account's fee, or the whole transaction's exact fee when the
        // account's share is not attributed (a private recovery).
        fee: match details.fee {
            FeeState::Known(fee) | FeeState::Unattributed { whole: fee } => Some(fee.into_u64()),
            FeeState::Unknown | FeeState::NotApplicable => None,
        },
    })
}

fn source_pool_label(pool: SourcePool) -> &'static str {
    match pool {
        SourcePool::Unknown => "unknown",
        SourcePool::Shielded => "shielded",
        SourcePool::Transparent => "transparent",
    }
}

/// The outputs the row of `tx_kind` counts, which its receipt shows. A role
/// the transaction has no row for shows none; a receive stays itself once it
/// is mined.
fn receipt_outputs<'a>(activity: &'a AccountActivity, tx_kind: &str) -> &'a [OutputRef] {
    let received = matches!(tx_kind, "received" | "receiving");
    match activity {
        AccountActivity::Shielding { outputs, .. } if tx_kind == "shielded" => outputs,
        AccountActivity::PoolMigration { outputs, .. } if tx_kind == "migration" => outputs,
        AccountActivity::Outputs {
            sent: Some(rows), ..
        } if tx_kind == "sent" => &rows.outputs,
        AccountActivity::Outputs {
            received: Some(rows),
            ..
        }
        | AccountActivity::InferredOutgoing {
            received: Some(rows),
            ..
        } if received => &rows.outputs,
        _ => &[],
    }
}

/// The wallet account that sent the received outputs a receipt shows, from
/// the sending account `sent_notes` recorded for each output. `None` unless
/// every output has one and they agree: an output with no recorded sender
/// leaves the source unknown.
fn received_source_account(outputs: &[&TxOutput]) -> Option<String> {
    let mut accounts = outputs
        .iter()
        .map(|output| output.from_account_uuid.as_deref());
    let first = accounts.next()??;
    if !accounts.all(|account| account == Some(first)) {
        return None;
    }
    uuid::Uuid::from_slice(first)
        .ok()
        .map(|uuid| uuid.to_string())
}

/// Read the library-owned accounting projection through the caller's connection.
/// The history details read must stay in the same transaction as this read.
fn read_history_bases(
    conn: &rusqlite::Connection,
    db_path: &str,
    network: WalletNetwork,
    account: AccountUuid,
) -> Result<Vec<TxBase>, String> {
    wallet_db_on(conn, db_path, network)
        .transaction_history_summaries(account)
        .map(|summaries| summaries.into_iter().map(TxBase::from).collect())
        .map_err(|e| format!("Failed to read history summaries: {e}"))
}

impl From<TransactionSummary> for TxBase {
    fn from(summary: TransactionSummary) -> Self {
        Self {
            txid: summary.txid.as_ref().to_vec(),
            transaction_id: summary.transaction_id,
            mined_height: summary.mined_height.map(u32::from),
            expired_unmined: summary.expired_unmined,
            account_balance_delta: summary.account_balance_delta,
            block_time: summary.block_time.unwrap_or(0),
            total_spent: summary.total_spent,
            total_received: summary.total_received,
            expiry_height: summary
                .expiry_height
                .map(|height| i64::from(u32::from(height))),
            tx_index: summary.tx_index.map(i64::from).unwrap_or(-1),
            created: summary.created,
            created_time: summary.created_time.map(i64::unsigned_abs).unwrap_or(0),
            history: HistoryView::unread(summary.mined_height.is_some()),
        }
    }
}

fn read_outputs_for_tx(
    conn: &rusqlite::Connection,
    account_uuid: &[u8],
    txid: &[u8],
) -> Result<Vec<TxOutput>, String> {
    let mut stmt = conn
        .prepare(
            r#"
        SELECT
            txo.output_pool,
            txo.output_index,
            txo.from_account_uuid,
            txo.to_address,
            (
                SELECT sn.to_address
                FROM sent_notes sn
                JOIN transactions st ON st.id_tx = sn.transaction_id
                JOIN accounts from_acc ON from_acc.id = sn.from_account_id
                WHERE st.txid = txo.txid
                  AND from_acc.uuid = ?1
                  AND sn.output_pool = txo.output_pool
                  AND sn.output_index = txo.output_index
                  AND sn.to_address IS NOT NULL
                LIMIT 1
            ) AS sent_to_address,
            (
                SELECT a.cached_transparent_receiver_address
                FROM accounts acc
                JOIN addresses a ON a.account_id = acc.id
                WHERE acc.uuid = txo.to_account_uuid
                  AND txo.output_pool = 0
                  AND (
                      a.address = txo.to_address
                      OR a.cached_transparent_receiver_address = txo.to_address
                  )
                  AND a.cached_transparent_receiver_address IS NOT NULL
                LIMIT 1
            ) AS transparent_receiver_address,
            txo.value,
            txo.memo
        FROM v_tx_outputs txo
        WHERE txo.txid = ?2
          AND (
              txo.from_account_uuid = ?1
              OR txo.to_account_uuid = ?1
          )
        "#,
        )
        .map_err(|e| format!("SQL error: {e}"))?;

    let rows = stmt
        .query_map(rusqlite::params![account_uuid, txid], |row| {
            Ok(TxOutput {
                output_pool: row.get(0)?,
                output_index: row.get(1)?,
                from_account_uuid: row.get(2)?,
                to_address: row.get(3)?,
                sent_to_address: row.get(4)?,
                transparent_receiver_address: row.get(5)?,
                value: row.get::<_, i64>(6)?.unsigned_abs(),
                memo: row.get(7)?,
            })
        })
        .map_err(|e| format!("Query error: {e}"))?;

    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|e| format!("Row error: {e}"))
}

fn exact_output_pool_label(output_pool: i64) -> Option<&'static str> {
    match output_pool {
        TRANSPARENT_POOL => Some("transparent"),
        SAPLING_POOL => Some("sapling"),
        ORCHARD_POOL => Some("orchard"),
        IRONWOOD_POOL => Some("ironwood"),
        _ => None,
    }
}

fn output_pool_label(output_pool: i64) -> &'static str {
    match output_pool {
        TRANSPARENT_POOL => "transparent",
        SAPLING_POOL | ORCHARD_POOL => "shielded",
        IRONWOOD_POOL => "ironwood",
        _ => "unknown",
    }
}

fn decode_text_memo(memo: Option<&[u8]>) -> Option<String> {
    let memo = memo?;
    let memo_bytes = MemoBytes::from_bytes(memo).ok()?;
    match Memo::try_from(&memo_bytes).ok()? {
        Memo::Text(text) => {
            let text = String::from(text);
            if text.trim().is_empty() {
                None
            } else {
                Some(text)
            }
        }
        Memo::Empty | Memo::Future(_) | Memo::Arbitrary(_) => None,
    }
}

// ======================== TEX funding steps ========================

fn build_external_send_keys(bases: &[TxBase]) -> HashSet<FundingStepMatchKey> {
    bases.iter().filter_map(external_send_key).collect()
}

fn build_suppressed_funding_step_fees(
    bases: &[TxBase],
    external_send_keys: &HashSet<FundingStepMatchKey>,
) -> SuppressedFundingStepFees {
    let mut funding_by_key: HashMap<FundingStepMatchKey, Vec<(i64, Fee)>> = HashMap::new();
    let mut external_by_key: HashMap<FundingStepMatchKey, Vec<i64>> = HashMap::new();

    for base in bases {
        if let Some(key) = external_send_key(base) {
            external_by_key
                .entry(key)
                .or_default()
                .push(base.transaction_id);
        }

        if should_suppress_funding_step(base, external_send_keys) {
            if let Some(key) = funding_step_key(base) {
                funding_by_key
                    .entry(key)
                    .or_default()
                    .push((base.transaction_id, base.history.shown_fee()));
            }
        }
    }

    let mut matched = SuppressedFundingStepFees::default();
    for (key, mut funding_steps) in funding_by_key {
        let Some(mut external_sends) = external_by_key.remove(&key) else {
            continue;
        };

        funding_steps.sort_by_key(|(transaction_id, _)| *transaction_id);
        external_sends.sort_unstable();

        let mut external_index = 0;
        for (funding_transaction_id, funding_fee) in funding_steps {
            while external_index < external_sends.len()
                && external_sends[external_index] <= funding_transaction_id
            {
                external_index += 1;
            }

            let Some(external_transaction_id) = external_sends.get(external_index).copied() else {
                continue;
            };
            external_index += 1;

            matched
                .funding_parent_by_external_txid
                .insert(external_transaction_id, funding_transaction_id);
            matched
                .suppressed_funding_txids
                .insert(funding_transaction_id);
            let entry = matched
                .extra_fee_by_external_txid
                .entry(external_transaction_id)
                .or_insert(Fee::NotApplicable);
            *entry = entry.plus(funding_fee);
        }
    }

    matched
}

fn external_send_key(base: &TxBase) -> Option<FundingStepMatchKey> {
    if !base.history.funding_step.external_transparent_send
        || base.total_spent == 0
        || base.transaction_id < 0
    {
        return None;
    }

    base.created
        .as_ref()
        .map(|created| (created.clone(), base.expiry_key(), base.total_spent))
}

fn funding_step_key(base: &TxBase) -> Option<FundingStepMatchKey> {
    let own = base
        .history
        .funding_step
        .own_transparent_outputs
        .map_or(0, |value| value.into_u64());
    if own == 0 || base.transaction_id < 0 {
        return None;
    }

    base.created
        .as_ref()
        .map(|created| (created.clone(), base.expiry_key(), own))
}

/// The values of the visible outputs a transaction's sent and received rows
/// count. Activity without such rows counts none.
fn visible_output_amounts(activity: &AccountActivity) -> (u64, u64) {
    let amount = |rows: &Option<ActivityOutputs>| rows.as_ref().map_or(0, |r| r.amount.into_u64());
    match activity {
        AccountActivity::Outputs { sent, received } => (amount(sent), amount(received)),
        AccountActivity::InferredOutgoing { received, .. } => (0, amount(received)),
        _ => (0, 0),
    }
}

fn should_suppress_funding_step(
    base: &TxBase,
    external_send_keys: &HashSet<FundingStepMatchKey>,
) -> bool {
    let activity = &base.history.activity;
    !matches!(activity, AccountActivity::Shielding { .. })
        && base.total_spent > 0
        && base.total_received > 0
        && base.account_balance_delta <= 0
        && base.created.is_some()
        && visible_output_amounts(activity) == (0, 0)
        && base.history.funding_step.own_transparent_outputs.is_some()
        && funding_step_key(base)
            .map(|key| external_send_keys.contains(&key))
            .unwrap_or(false)
}

// ======================== Activity rows ========================

/// The rows a transaction shows, from its library activity: Vizor's labels,
/// received versus receiving, and the split into sent and received rows.
fn activity_rows(base: &TxBase, extra_sent_fee: Fee) -> Vec<ClassifiedTx> {
    let zat = Zatoshis::into_u64;
    match base.activity().as_ref() {
        AccountActivity::Shielding { amount, .. } => vec![build_classified_tx(
            base,
            "shielded",
            zat(*amount),
            "shielded",
            false,
            0,
        )],
        AccountActivity::PoolMigration { amount, .. } => vec![build_classified_tx(
            base,
            "migration",
            zat(*amount),
            "ironwood",
            false,
            1,
        )],
        // The exact payment of a transparent-only debit, without its
        // recipients: the payment went to transparent outputs.
        AccountActivity::InferredPayment { amount } => vec![build_classified_tx(
            base,
            "sent",
            zat(*amount),
            "transparent",
            true,
            1,
        )],
        // A recovered self-transfer shows only its fee.
        AccountActivity::FeeOnly { fee } => {
            let mut row = build_classified_tx(base, "sent", zat(*fee), "transparent", true, 1);
            row.info.amount_includes_fee = true;
            vec![row]
        }
        AccountActivity::HiddenFundingStep | AccountActivity::ChangeOnly => Vec::new(),
        // Activity amounts under the recovered funding convention, not
        // proven payments; missing payment details stay on the receipt.
        AccountActivity::InferredOutgoing {
            outgoing,
            received,
            settled,
        } => {
            let mut sent =
                build_classified_tx(base, "sent", zat(*outgoing), "transparent", true, 1);
            sent.info.provisional = !settled;
            sent.info.activity_pool = Some("transparent".to_string());
            let mut rows = vec![sent];
            if let Some(received) = received {
                let mut row = build_classified_tx(
                    base,
                    receiving_tx_kind(base),
                    zat(received.amount),
                    "transparent",
                    true,
                    2,
                );
                row.info.provisional = !settled;
                row.info.activity_pool = Some("transparent".to_string());
                rows.push(row);
            }
            rows
        }
        // A debit known only as a balance movement: not a payment amount.
        AccountActivity::MovementDebit { amount } => {
            let amount = zat(*amount);
            let tx_kind = if amount > 0 { "sent" } else { "unknown" };
            vec![build_movement_debit_row(base, tx_kind, amount)]
        }
        // A visible output makes a row even at zero value: zero-value outputs
        // are how memo-only payments travel.
        AccountActivity::Outputs { sent, received } => {
            let mut rows = Vec::new();
            if let Some(sent) = sent {
                let pools = RowPools::of(&sent.outputs);
                let mut row = build_classified_tx_with_fee(
                    base,
                    "sent",
                    zat(sent.amount),
                    pools.display_pool(),
                    pools.transparent,
                    1,
                    base.history.shown_fee().plus(extra_sent_fee),
                );
                row.info.activity_pool = Some(pools.activity_pool().to_string());
                rows.push(row);
            }
            if let Some(received) = received {
                let pools = RowPools::of(&received.outputs);
                let mut row = build_classified_tx(
                    base,
                    receiving_tx_kind(base),
                    zat(received.amount),
                    pools.display_pool(),
                    pools.transparent,
                    2,
                );
                row.info.activity_pool = Some(pools.activity_pool().to_string());
                rows.push(row);
            }
            rows
        }
        AccountActivity::MovementCredit { amount } => vec![build_classified_tx(
            base,
            receiving_tx_kind(base),
            zat(*amount),
            "unknown",
            false,
            2,
        )],
        AccountActivity::Unknown => {
            vec![build_classified_tx(base, "unknown", 0, "unknown", false, 3)]
        }
    }
}

fn receiving_tx_kind(base: &TxBase) -> &'static str {
    if base.mined_height.is_none() && !base.expired_unmined {
        "receiving"
    } else {
        "received"
    }
}

fn build_classified_tx(
    base: &TxBase,
    tx_kind: &str,
    display_amount: u64,
    display_pool: &str,
    is_transparent: bool,
    row_order: u8,
) -> ClassifiedTx {
    build_classified_tx_with_fee(
        base,
        tx_kind,
        display_amount,
        display_pool,
        is_transparent,
        row_order,
        base.history.shown_fee(),
    )
}

/// The row of a debit known only as the account's balance movement, less the
/// account's fee when that is known. When it is not, nothing is subtracted,
/// so a shown whole-transaction fee is part of the amount.
fn build_movement_debit_row(base: &TxBase, tx_kind: &str, debit: u64) -> ClassifiedTx {
    let mut row = build_classified_tx(base, tx_kind, debit, "unknown", false, 1);
    // Enhance can establish activity shape before recipients, payment amounts, or the
    // account's fee share are known. Keep that display fact separate from destination
    // classification and completeness; false or missing evidence supplies no new label.
    if base.history.has_transparent_outputs == Some(true) {
        row.info.activity_pool = Some("transparent".to_string());
    }
    row.info.amount_includes_fee = base.history.movement_retains_fee();
    row
}

fn build_classified_tx_with_fee(
    base: &TxBase,
    tx_kind: &str,
    display_amount: u64,
    display_pool: &str,
    is_transparent: bool,
    row_order: u8,
    fee: Fee,
) -> ClassifiedTx {
    let sort_timestamp = base.display_timestamp();
    ClassifiedTx {
        info: TransactionInfo {
            txid_hex: hex::encode(&base.txid),
            mined_height: base.mined_height.unwrap_or(0) as u64,
            expired_unmined: base.expired_unmined,
            account_balance_delta: base.account_balance_delta,
            fee: fee.known_or_zero(),
            fee_state: fee.state(),
            block_time: base.block_time,
            is_transparent,
            tx_kind: tx_kind.to_string(),
            display_amount,
            display_pool: display_pool.to_string(),
            activity_pool: None,
            funding_parent_txid: None,
            funding_parent_mined_height: None,
            funding_parent_expired: None,
            created_time: base.created_time,
            details_complete: base.history.details_complete,
            provisional: base.history.provisional,
            amount_includes_fee: false,
        },
        sort_pending_rank: u8::from(base.mined_height.is_none() && !base.expired_unmined),
        sort_timestamp,
        sort_mined_height: base.mined_height.unwrap_or(0) as u64,
        tx_index: base.tx_index,
        row_order,
    }
}

impl TxBase {
    /// The library's activity, with the one rule that reads the mined height
    /// re-applied where the row's mined height differs from the library's (a
    /// Gift Card claim): an unmined debit with no visible output shows as a
    /// movement debit, a mined one does not.
    fn activity(&self) -> Cow<'_, AccountActivity> {
        let history = &self.history;
        let shown_mined = self.mined_height.is_some();
        if shown_mined == history.mined {
            return Cow::Borrowed(&history.activity);
        }
        let net = self.account_balance_delta;
        let unmined_debit = (net < 0 && self.total_spent > 0)
            .then(|| {
                net.unsigned_abs()
                    .saturating_sub(history.shown_fee().known_or_zero())
            })
            .filter(|amount| *amount > 0)
            .and_then(|amount| Zatoshis::from_u64(amount).ok());
        match (&history.activity, unmined_debit) {
            // The library read the transaction as mined, so it skipped the rule.
            (
                AccountActivity::ChangeOnly
                | AccountActivity::MovementCredit { .. }
                | AccountActivity::Unknown,
                Some(amount),
            ) if !shown_mined => Cow::Owned(AccountActivity::MovementDebit { amount }),
            // The library applied the rule (not the provisional debit rule,
            // which does not read the mined height) to a row shown mined.
            (AccountActivity::MovementDebit { .. }, _)
                if shown_mined && !(history.provisional && net < 0) =>
            {
                Cow::Owned(if self.total_spent > 0 && self.total_received > 0 {
                    AccountActivity::ChangeOnly
                } else {
                    AccountActivity::Unknown
                })
            }
            (activity, _) => Cow::Borrowed(activity),
        }
    }

    fn expiry_key(&self) -> i64 {
        self.expiry_height.unwrap_or(-1)
    }

    fn display_timestamp(&self) -> u64 {
        if self.block_time > 0 {
            self.block_time
        } else {
            self.created_time
        }
    }
}

/// A wallet-created transaction that is eligible for automatic
/// resubmit: unmined, not past its expiry height or explicitly
/// no-expiry, and sending value out of the wallet.
///
/// `raw_tx` is the full serialized transaction bytes ready to feed
/// back into `send_transaction` — no re-encoding required. The
/// resubmit path at `sync::send::resubmit_pending_transactions`
/// consumes this struct directly.
pub(crate) struct ResubmittableTx {
    pub txid_bytes: Vec<u8>,
    pub raw_tx: Vec<u8>,
    pub expiry_height: u32,
}

// Correlated to `t` in transactions. Positions survive a rewind that clears
// mined_height; even position zero proves this transaction was scanned as mined.
// The history trigger also retains mined evidence for transactions without change.
const MINED_TRANSACTION_EVIDENCE: &str = "(
    EXISTS (SELECT 1 FROM vizor_mined_transactions m WHERE m.txid = t.txid)
    OR EXISTS (SELECT 1 FROM sapling_received_notes n
            WHERE n.transaction_id = t.id_tx AND n.commitment_tree_position IS NOT NULL)
    OR EXISTS (SELECT 1 FROM orchard_received_notes n
               WHERE n.transaction_id = t.id_tx AND n.commitment_tree_position IS NOT NULL)
    OR EXISTS (SELECT 1 FROM ironwood_received_notes n
               WHERE n.transaction_id = t.id_tx AND n.commitment_tree_position IS NOT NULL)
)";

fn resubmission_candidate_sql(columns: &str) -> String {
    format!(
        "SELECT DISTINCT {columns} FROM v_transactions v
         WHERE v.mined_height IS NULL
           AND (v.expiry_height = 0 OR v.expiry_height > ?1)
           AND v.account_balance_delta < 0 AND v.raw IS NOT NULL
           AND NOT EXISTS (
               SELECT 1 FROM transactions t
               JOIN tx_retrieval_queue q ON q.txid = t.txid AND q.query_type = 0
               WHERE t.txid = v.txid AND {MINED_TRANSACTION_EVIDENCE}
           )"
    )
}

/// Whether a status request protects an outbound transaction with prior mined evidence.
/// This read does not retire the guard; callers retain it until tip validation.
pub(crate) fn has_recovered_status_work(
    conn: &rusqlite::Connection,
    txid: &[u8],
) -> Result<bool, String> {
    conn.query_row(
        &format!(
            "SELECT EXISTS (
            SELECT 1 FROM transactions t
            JOIN tx_retrieval_queue q ON q.txid = t.txid AND q.query_type = 0
            WHERE t.txid = ?1 AND t.mined_height IS NULL AND {MINED_TRANSACTION_EVIDENCE}
              AND EXISTS (SELECT 1 FROM v_transactions v WHERE v.txid = t.txid
                          AND v.account_balance_delta < 0 AND v.raw IS NOT NULL)
        )"
        ),
        [txid],
        |row| row.get(0),
    )
    .map_err(|e| format!("Recovery status evidence: {e}"))
}

/// Complete a conclusive non-mined status observation for the rewind recovery
/// case after tip identity validation. The caller holds the wallet write lock.
/// Rechecking evidence, recording the observation, and completing only status
/// work share one write transaction.
/// Returns false when the normal backend status policy should handle the txid.
pub(crate) fn resolve_recovered_nonmined_status(
    conn: &mut rusqlite::Connection,
    txid: &[u8],
) -> Result<bool, String> {
    let tx = conn
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|e| format!("Recovery status transaction: {e}"))?;
    if !has_recovered_status_work(&tx, txid)? {
        return Ok(false);
    }
    // Match the pinned backend's chain_tip_height: scan ranges are end-exclusive.
    let range_end: Option<u32> = tx
        .query_row("SELECT MAX(block_range_end) FROM scan_queue", [], |row| {
            row.get(0)
        })
        .map_err(|e| format!("Recovery status chain tip: {e}"))?;
    let tip = range_end
        .filter(|end| *end > 0)
        .ok_or("Recovery status requires a known chain tip")?
        - 1;
    tx.execute(
        "UPDATE transactions SET confirmed_unmined_at_height = ?2 WHERE txid = ?1",
        rusqlite::params![txid, tip],
    )
    .map_err(|e| format!("Recovery status observation: {e}"))?;
    tx.execute(
        "DELETE FROM tx_retrieval_queue WHERE txid = ?1 AND query_type = 0",
        [txid],
    )
    .map_err(|e| format!("Recovery status completion: {e}"))?;
    tx.commit()
        .map_err(|e| format!("Recovery status commit: {e}"))?;
    Ok(true)
}

/// Returns whether the base transaction table contains anything the full
/// account-aware resubmission query could accept.
///
/// This may return a false positive for an inbound transaction, because the
/// outbound balance predicate exists only in `v_transactions`. It must not
/// return a false negative. An empty result lets the normal sync case avoid
/// materializing that comparatively expensive aggregate view.
fn has_pending_raw_transaction(
    conn: &rusqlite::Connection,
    current_height: u32,
) -> Result<bool, String> {
    conn.query_row(
        "SELECT EXISTS ( \
             SELECT 1 FROM transactions \
             WHERE mined_height IS NULL \
               AND (expiry_height = 0 OR expiry_height > ?1) \
               AND raw IS NOT NULL \
         )",
        [current_height],
        |row| row.get(0),
    )
    .map_err(|e| format!("Pending transaction preflight error: {e}"))
}

fn should_skip_resubmission_view(conn: &rusqlite::Connection, current_height: u32) -> bool {
    match has_pending_raw_transaction(conn, current_height) {
        Ok(has_candidate) => !has_candidate,
        Err(error) => {
            // This is an optimization only. Preserve resubmission liveness if
            // an old or partially migrated database cannot run the preflight.
            log::warn!("resubmit: {error}; falling back to v_transactions");
            false
        }
    }
}

/// Return every wallet transaction that is eligible for automatic
/// resubmit at `current_height`.
///
/// Mirrors zcash-android-wallet-sdk's `SELECTION_TRX_RESUBMISSION`
/// predicate — see the Phase 3 design notes for why we follow the
/// SDK exactly:
///
///   * `mined_height IS NULL` — the transaction has not yet been
///     confirmed in a block.
///   * `expiry_height = 0 OR expiry_height > ?current_height` — the
///     transaction is still valid to relay. A zero expiry height means
///     no expiry; otherwise, once the current tip passes
///     `expiry_height`, the network will drop it and there is nothing
///     we can do by resubmitting.
///   * `account_balance_delta < 0` — the net balance change for the
///     account is negative, i.e. this is an outbound transaction
///     the wallet originated. Inbound transactions the sync loop
///     merely discovered on-chain (via `get_transaction` enhance
///     calls) should never be "resubmitted".
///   * Pending status work plus durable mined evidence suppresses relay
///     until the previously mined transaction has a conclusive status.
///   * `raw IS NOT NULL` — we actually have the serialized bytes to
///     broadcast. Defense-in-depth on top of the delta filter.
///
/// A transaction that touches more than one of the wallet's own
/// accounts shows up as more than one row in `v_transactions`; we
/// `SELECT DISTINCT` on `(txid, raw, expiry_height)` to collapse
/// that into a single broadcast instead of double-sending the same
/// bytes.
pub(crate) fn get_resubmittable_txs(
    db_path: &str,
    current_height: u32,
) -> Result<Vec<ResubmittableTx>, String> {
    let mut connection = open_readonly_conn(db_path)?;
    let conn = connection
        .transaction()
        .map_err(|e| format!("Read transaction error: {e}"))?;
    if should_skip_resubmission_view(&conn, current_height) {
        return Ok(Vec::new());
    }

    let mut stmt = conn
        .prepare(&resubmission_candidate_sql(
            "v.txid, v.raw, v.expiry_height",
        ))
        .map_err(|e| format!("SQL error: {e}"))?;

    let rows = stmt
        .query_map([current_height], |row| {
            let txid_bytes: Vec<u8> = row.get(0)?;
            let raw_tx: Vec<u8> = row.get(1)?;
            // The WHERE clause rejects NULL expiry heights but still
            // permits 0 as the protocol no-expiry marker.
            let expiry_height: u32 = row
                .get::<_, Option<i64>>(2)?
                .map(|h| h.max(0) as u32)
                .unwrap_or(0);
            Ok(ResubmittableTx {
                txid_bytes,
                raw_tx,
                expiry_height,
            })
        })
        .map_err(|e| format!("Query error: {e}"))?;

    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|e| format!("Row error: {e}"))
}

/// Returns resubmittable transactions after filtering `excluded_txids` before
/// loading raw transaction bytes.
pub(crate) fn get_resubmittable_txs_excluding(
    db_path: &str,
    current_height: u32,
    excluded_txids: &HashSet<Vec<u8>>,
) -> Result<Vec<ResubmittableTx>, String> {
    if excluded_txids.is_empty() {
        return get_resubmittable_txs(db_path, current_height);
    }

    let mut connection = open_readonly_conn(db_path)?;
    let conn = connection
        .transaction()
        .map_err(|e| format!("Read transaction error: {e}"))?;
    if should_skip_resubmission_view(&conn, current_height) {
        return Ok(Vec::new());
    }
    let candidate_metadata = {
        let mut stmt = conn
            .prepare(&resubmission_candidate_sql("v.txid, v.expiry_height"))
            .map_err(|e| format!("SQL error: {e}"))?;
        let rows = stmt
            .query_map([current_height], |row| {
                let txid_bytes: Vec<u8> = row.get(0)?;
                let expiry_height = row
                    .get::<_, Option<i64>>(1)?
                    .map(|h| h.max(0) as u32)
                    .unwrap_or(0);
                Ok((txid_bytes, expiry_height))
            })
            .map_err(|e| format!("Query error: {e}"))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| format!("Row error: {e}"))?
    };

    let mut raw_stmt = conn
        .prepare("SELECT raw FROM transactions WHERE txid = ?1 AND raw IS NOT NULL")
        .map_err(|e| format!("SQL error: {e}"))?;
    candidate_metadata
        .into_iter()
        .filter(|(txid_bytes, _)| !excluded_txids.contains(txid_bytes))
        .map(|(txid_bytes, expiry_height)| {
            let raw_tx = raw_stmt
                .query_row([&txid_bytes], |row| row.get::<_, Vec<u8>>(0))
                .map_err(|e| format!("Raw transaction query error: {e}"))?;
            Ok(ResubmittableTx {
                txid_bytes,
                raw_tx,
                expiry_height,
            })
        })
        .collect()
}

#[cfg(test)]
#[path = "transactions/resubmission_tests.rs"]
pub(super) mod resubmission_tests;

#[cfg(test)]
#[path = "transactions/history_summary_tests.rs"]
mod history_summary_tests;

#[cfg(test)]
#[path = "transactions/private_shielding_tests.rs"]
mod private_shielding_tests;

#[cfg(test)]
#[path = "transactions/private_recovery_tests.rs"]
mod private_recovery_tests;

#[cfg(test)]
mod tests {
    //! SQL-predicate regression tests for `get_resubmittable_txs`.
    //!
    //! `get_resubmittable_txs` is a thin wrapper around a `v_transactions`
    //! SELECT, but the SELECT is the entire contract: it's the piece that
    //! encodes the four resubmit invariants we copied from
    //! `zcash-android-wallet-sdk`'s `SELECTION_TRX_RESUBMISSION`.
    //!
    //! We test against a stand-in schema: a real SQLite DB with a plain
    //! `v_transactions` table mirroring the columns the production view
    //! exposes. That's enough for the WHERE clause to exercise each
    //! filter independently without standing up the whole
    //! `zcash_client_sqlite` migration stack.
    //!
    //! If the production `v_transactions` view ever gains (or loses)
    //! one of the columns we query here (`txid`, `raw`, `mined_height`,
    //! `expiry_height`, `account_balance_delta`), the real build breaks
    //! loudly at the first real query — but these unit tests still
    //! exercise the logic, so a regression in the SQL text shows up here
    //! first.
    use super::*;
    use tempfile::NamedTempFile;
    use transparent::address::TransparentAddress;

    #[test]
    fn unavailable_wallet_balance_is_zero_but_not_available() {
        for availability in [
            WalletBalanceAvailability::SummaryUnavailable,
            WalletBalanceAvailability::AccountUnavailable,
        ] {
            let balance = WalletBalance::unavailable(availability, false);
            assert_eq!(balance.availability, availability);
            assert_eq!(balance.transparent_stop, None);
            assert_eq!(balance.transparent, 0);
            assert_eq!(balance.sapling, 0);
            assert_eq!(balance.orchard, 0);
            assert_eq!(balance.transparent_pending, 0);
            assert_eq!(balance.sapling_pending, 0);
            assert_eq!(balance.orchard_pending, 0);
            assert_eq!(balance.change_pending_confirmation, 0);
            assert_eq!(balance.value_pending_spendability, 0);
            assert_eq!(balance.uneconomic_value, 0);
        }
    }

    /// Build a throwaway SQLite database with a minimal
    /// `v_transactions` table and return its `NamedTempFile`
    /// handle. Tests keep the handle alive for the duration of the
    /// test so the file isn't auto-deleted under them.
    pub(super) fn fresh_db() -> NamedTempFile {
        let file = NamedTempFile::new().unwrap();
        let conn = rusqlite::Connection::open(file.path()).unwrap();
        conn.execute_batch(
            "CREATE TABLE transactions (
                 id_tx INTEGER PRIMARY KEY,
                 txid BLOB UNIQUE,
                 confirmed_unmined_at_height INTEGER,
                 raw BLOB,
                 mined_height INTEGER,
                 expiry_height INTEGER
             );
             CREATE TABLE tx_retrieval_queue (txid BLOB, query_type INTEGER,
                 PRIMARY KEY (txid, query_type));
             CREATE TABLE scan_queue (block_range_end INTEGER);
             INSERT INTO scan_queue VALUES (900001);
             CREATE TABLE sapling_received_notes (transaction_id INTEGER, commitment_tree_position INTEGER);
             CREATE TABLE orchard_received_notes (transaction_id INTEGER, commitment_tree_position INTEGER);
             CREATE TABLE ironwood_received_notes (transaction_id INTEGER, commitment_tree_position INTEGER);
             CREATE TABLE v_transactions (
                 txid BLOB NOT NULL,
                 raw BLOB,
                 mined_height INTEGER,
                 expiry_height INTEGER,
                 account_balance_delta INTEGER NOT NULL
             );",
        )
        .unwrap();
        crate::wallet::db::ensure_mined_transaction_history(&conn).unwrap();
        file
    }

    fn mined_output_evidence_db() -> NamedTempFile {
        let file = NamedTempFile::new().unwrap();
        let conn = rusqlite::Connection::open(file.path()).unwrap();
        conn.execute_batch(
            "CREATE TABLE transactions (
                 id_tx INTEGER PRIMARY KEY,
                 txid BLOB NOT NULL,
                 mined_height INTEGER,
                 min_observed_height INTEGER NOT NULL,
                 expiry_height INTEGER
             );
             CREATE TABLE sapling_received_notes (
                 transaction_id INTEGER NOT NULL,
                 commitment_tree_position INTEGER
             );
             CREATE TABLE orchard_received_notes (
                 transaction_id INTEGER NOT NULL,
                 commitment_tree_position INTEGER
             );
             CREATE TABLE ironwood_received_notes (
                 transaction_id INTEGER NOT NULL,
                 commitment_tree_position INTEGER
             );",
        )
        .unwrap();
        crate::wallet::db::ensure_mined_transaction_history(&conn).unwrap();
        file
    }

    /// Insert one synthetic row into `v_transactions`.
    pub(super) fn insert_row(
        db: &NamedTempFile,
        txid: &[u8],
        raw: Option<&[u8]>,
        mined_height: Option<i64>,
        expiry_height: Option<i64>,
        account_balance_delta: i64,
    ) {
        let conn = rusqlite::Connection::open(db.path()).unwrap();
        conn.execute(
            "INSERT INTO transactions (txid, raw, mined_height, expiry_height)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(txid) DO UPDATE SET
                 raw = excluded.raw,
                 mined_height = excluded.mined_height,
                 expiry_height = excluded.expiry_height",
            rusqlite::params![txid, raw, mined_height, expiry_height],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO v_transactions (txid, raw, mined_height, expiry_height, account_balance_delta)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![txid, raw, mined_height, expiry_height, account_balance_delta],
        )
        .unwrap();
    }

    pub(super) fn fake_txid(byte: u8) -> [u8; 32] {
        [byte; 32]
    }

    #[test]
    fn mined_output_evidence_requires_an_unmined_tx_with_a_positioned_note() {
        let db = mined_output_evidence_db();
        let conn = rusqlite::Connection::open(db.path()).unwrap();
        for (id, mined_height) in [
            (1, None),
            (2, None),
            (3, None),
            (4, None),
            (5, Some(1_000_000)),
            (6, None),
        ] {
            conn.execute(
                "INSERT INTO transactions
                    (id_tx, txid, mined_height, min_observed_height, expiry_height)
                 VALUES (?1, ?2, ?3, 900, 1_100)",
                rusqlite::params![id, fake_txid(id as u8), mined_height],
            )
            .unwrap();
        }
        conn.execute(
            "INSERT INTO sapling_received_notes VALUES (1, 10), (4, NULL), (5, 20)",
            [],
        )
        .unwrap();
        conn.execute("INSERT INTO orchard_received_notes VALUES (2, 30)", [])
            .unwrap();
        conn.execute("INSERT INTO ironwood_received_notes VALUES (3, 40)", [])
            .unwrap();
        drop(conn);

        let pending_ranges = [BlockHeight::from_u32(900)..BlockHeight::from_u32(1_100)];
        let got = get_unmined_txids_with_mined_output_evidence(
            db.path().to_str().unwrap(),
            &pending_ranges,
        )
        .unwrap();
        assert_eq!(
            got,
            HashSet::from([
                fake_txid(1).to_vec(),
                fake_txid(2).to_vec(),
                fake_txid(3).to_vec(),
            ])
        );
    }

    #[test]
    fn mined_output_evidence_stops_deferring_after_restoring_ranges_pass() {
        let db = mined_output_evidence_db();
        let conn = rusqlite::Connection::open(db.path()).unwrap();
        for (id, expiry_height) in [(1, 600), (2, 0)] {
            conn.execute(
                "INSERT INTO transactions
                    (id_tx, txid, mined_height, min_observed_height, expiry_height)
                 VALUES (?1, ?2, NULL, 500, ?3)",
                rusqlite::params![id, fake_txid(id as u8), expiry_height],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO orchard_received_notes VALUES (?1, ?2)",
                rusqlite::params![id, id * 10],
            )
            .unwrap();
        }
        drop(conn);

        let recovery_and_older = [
            BlockHeight::from_u32(500)..BlockHeight::from_u32(600),
            BlockHeight::from_u32(100)..BlockHeight::from_u32(400),
        ];
        assert_eq!(
            get_unmined_txids_with_mined_output_evidence(
                db.path().to_str().unwrap(),
                &recovery_and_older,
            )
            .unwrap(),
            HashSet::from([fake_txid(1).to_vec(), fake_txid(2).to_vec()])
        );

        let older_only = [BlockHeight::from_u32(100)..BlockHeight::from_u32(400)];
        assert!(get_unmined_txids_with_mined_output_evidence(
            db.path().to_str().unwrap(),
            &older_only,
        )
        .unwrap()
        .is_empty());

        let after_expiry = [BlockHeight::from_u32(600)..BlockHeight::from_u32(700)];
        assert_eq!(
            get_unmined_txids_with_mined_output_evidence(
                db.path().to_str().unwrap(),
                &after_expiry,
            )
            .unwrap(),
            HashSet::from([fake_txid(2).to_vec()])
        );
    }

    pub(super) fn fake_raw() -> Vec<u8> {
        vec![0xDE, 0xAD, 0xBE, 0xEF]
    }

    fn transparent_source_test_address() -> String {
        let pubkey =
            hex::decode("02106a2dcaaac2ae3b24358a03f4264e05db420c5b090399bc23885fa02fef7716")
                .unwrap();
        let address = TransparentAddress::PublicKeyHash(transparent::util::hash160::hash(&pubkey));
        zcash_keys::encoding::encode_transparent_address_p(&WalletNetwork::Test, &address)
    }

    fn test_account_uuid() -> uuid::Uuid {
        uuid::Uuid::from_u128(0x7e2b16db08384ddba8026fd48b9e0d02)
    }

    fn second_test_account_uuid() -> uuid::Uuid {
        uuid::Uuid::from_u128(0x3eb4ded306b74bf2a5393f1b78d792a6)
    }

    #[test]
    fn received_transparent_output_detail_returns_bare_t_address() {
        // The wallet stores the account UA in `to_address` for a received
        // transparent output; `transparent_receiver_address` holds the bare
        // t-address recovered from the addresses table. The received detail
        // must surface the t-address, not the UA — otherwise the desktop
        // receipt mislabels a transparent->transparent receive as shielded
        // (crimson shield + u1 address). Regression for that bug.
        let t_addr = transparent_source_test_address();
        let ua = "u1qexampleunifiedaddressexampleunifiedaddress".to_string();

        let transparent_received = TxOutput {
            output_pool: 0,
            output_index: 0,
            from_account_uuid: None,
            to_address: Some(ua.clone()),
            sent_to_address: None,
            transparent_receiver_address: Some(t_addr.clone()),
            value: 1_000_000,
            memo: None,
        };
        assert_eq!(
            transparent_received.detail_address("received"),
            Some(t_addr.clone()),
        );
        assert_eq!(
            transparent_received.detail_address("receiving"),
            Some(t_addr),
        );

        // Shielded receives (pool 2) still surface their stored address.
        let shielded_received = TxOutput {
            output_pool: 2,
            output_index: 0,
            from_account_uuid: None,
            to_address: Some(ua.clone()),
            sent_to_address: None,
            transparent_receiver_address: None,
            value: 1_000_000,
            memo: None,
        };
        assert_eq!(shielded_received.detail_address("received"), Some(ua));
    }

    fn fresh_history_db() -> NamedTempFile {
        let file = NamedTempFile::new().unwrap();
        let conn = rusqlite::Connection::open(file.path()).unwrap();
        conn.execute_batch(
            "CREATE TABLE accounts (
                 id INTEGER PRIMARY KEY AUTOINCREMENT,
                 uuid BLOB NOT NULL UNIQUE,
                 birthday_height INTEGER NOT NULL DEFAULT 0
             );
             CREATE TABLE addresses (
                 id INTEGER PRIMARY KEY AUTOINCREMENT,
                 account_id INTEGER NOT NULL,
                 key_scope INTEGER NOT NULL,
                 address TEXT NOT NULL,
                 cached_transparent_receiver_address TEXT
             );
             CREATE TABLE v_transactions (
                 account_uuid BLOB NOT NULL,
                 txid BLOB NOT NULL,
                 raw BLOB,
                 mined_height INTEGER,
                 expired_unmined INTEGER NOT NULL,
                 account_balance_delta INTEGER NOT NULL,
                 fee_paid INTEGER,
                 block_time INTEGER,
                 total_spent INTEGER,
                 total_received INTEGER,
                 is_shielding INTEGER,
                 expiry_height INTEGER,
                 tx_index INTEGER
             );
             CREATE TABLE transactions (
                 id_tx INTEGER PRIMARY KEY AUTOINCREMENT,
                 txid BLOB NOT NULL UNIQUE,
                 created TEXT
             );
             CREATE TABLE sent_notes (
                 transaction_id INTEGER NOT NULL,
                 output_pool INTEGER NOT NULL,
                 output_index INTEGER NOT NULL,
                 from_account_id INTEGER NOT NULL,
                 to_account_id INTEGER,
                 to_address TEXT,
                 value INTEGER NOT NULL,
                 memo BLOB
             );
             CREATE TABLE orchard_received_notes (
                 id INTEGER PRIMARY KEY AUTOINCREMENT,
                 transaction_id INTEGER NOT NULL,
                 action_index INTEGER NOT NULL,
                 note_version INTEGER NOT NULL
             );
             CREATE TABLE orchard_received_note_spends (
                 orchard_received_note_id INTEGER NOT NULL,
                 transaction_id INTEGER NOT NULL
             );
             CREATE TABLE v_tx_outputs (
                 transaction_id INTEGER NOT NULL,
                 txid BLOB NOT NULL,
                 output_pool INTEGER NOT NULL,
                 output_index INTEGER NOT NULL,
                 from_account_uuid BLOB,
                 to_account_uuid BLOB,
                 to_address TEXT,
                 value INTEGER NOT NULL,
                 is_change INTEGER NOT NULL,
                 memo BLOB
             );",
        )
        .unwrap();
        file
    }

    #[allow(clippy::too_many_arguments)]
    fn insert_history_tx(
        db: &NamedTempFile,
        account: uuid::Uuid,
        txid: &[u8],
        mined_height: Option<i64>,
        tx_index: i64,
        expiry_height: Option<i64>,
        account_balance_delta: i64,
        total_spent: i64,
        total_received: i64,
        is_shielding: bool,
        created: Option<&str>,
    ) {
        let conn = rusqlite::Connection::open(db.path()).unwrap();
        ensure_account_row(&conn, account);
        conn.execute(
            "INSERT INTO transactions (txid, created) VALUES (?1, ?2)",
            rusqlite::params![txid, created],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO v_transactions (
                 account_uuid, txid, raw, mined_height, expired_unmined,
                 account_balance_delta, fee_paid, block_time, total_spent,
                 total_received, is_shielding, expiry_height, tx_index
             ) VALUES (?1, ?2, NULL, ?3, 0, ?4, 0, 0, ?5, ?6, ?7, ?8, ?9)",
            rusqlite::params![
                account.as_bytes().as_slice(),
                txid,
                mined_height,
                account_balance_delta,
                total_spent,
                total_received,
                is_shielding,
                expiry_height,
                tx_index,
            ],
        )
        .unwrap();
    }

    fn ensure_account_row(conn: &rusqlite::Connection, account: uuid::Uuid) -> i64 {
        conn.execute(
            "INSERT OR IGNORE INTO accounts (uuid) VALUES (?1)",
            rusqlite::params![account.as_bytes().as_slice()],
        )
        .unwrap();
        conn.query_row(
            "SELECT id FROM accounts WHERE uuid = ?1",
            rusqlite::params![account.as_bytes().as_slice()],
            |row| row.get(0),
        )
        .unwrap()
    }

    #[allow(clippy::too_many_arguments)]
    fn insert_output_with_address(
        db: &NamedTempFile,
        txid: &[u8],
        output_pool: i64,
        from_account: Option<uuid::Uuid>,
        to_account: Option<uuid::Uuid>,
        value: i64,
        is_change: bool,
        to_address: Option<&str>,
        to_key_scope: Option<i64>,
    ) -> i64 {
        insert_output_with_address_and_memo(
            db,
            txid,
            output_pool,
            from_account,
            to_account,
            value,
            is_change,
            to_address,
            to_key_scope,
            None,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn insert_output_with_address_and_memo(
        db: &NamedTempFile,
        txid: &[u8],
        output_pool: i64,
        from_account: Option<uuid::Uuid>,
        to_account: Option<uuid::Uuid>,
        value: i64,
        is_change: bool,
        to_address: Option<&str>,
        to_key_scope: Option<i64>,
        memo: Option<&[u8]>,
    ) -> i64 {
        let conn = rusqlite::Connection::open(db.path()).unwrap();
        if let Some(account) = from_account {
            ensure_account_row(&conn, account);
        }
        if let Some(account) = to_account {
            let account_id = ensure_account_row(&conn, account);
            if let (Some(address), Some(key_scope)) = (to_address, to_key_scope) {
                conn.execute(
                    "INSERT INTO addresses (
                         account_id, key_scope, address, cached_transparent_receiver_address
                     ) VALUES (?1, ?2, ?3, ?3)",
                    rusqlite::params![account_id, key_scope, address],
                )
                .unwrap();
            }
        }
        let transaction_id = conn
            .query_row(
                "SELECT id_tx FROM transactions WHERE txid = ?1",
                rusqlite::params![txid],
                |row| row.get::<_, i64>(0),
            )
            .unwrap();
        let output_index = conn
            .query_row(
                "SELECT COALESCE(MAX(output_index) + 1, 0)
                 FROM v_tx_outputs
                 WHERE txid = ?1 AND output_pool = ?2",
                rusqlite::params![txid, output_pool],
                |row| row.get::<_, i64>(0),
            )
            .unwrap();
        let from_bytes = from_account.map(|uuid| uuid.as_bytes().to_vec());
        let to_bytes = to_account.map(|uuid| uuid.as_bytes().to_vec());
        conn.execute(
            "INSERT INTO v_tx_outputs (
                 transaction_id, txid, output_pool, output_index, from_account_uuid,
                 to_account_uuid, to_address, value, is_change, memo
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            rusqlite::params![
                transaction_id,
                txid,
                output_pool,
                output_index,
                from_bytes,
                to_bytes,
                to_address,
                value,
                is_change,
                memo,
            ],
        )
        .unwrap();
        output_index
    }

    #[allow(clippy::too_many_arguments)]
    fn insert_sent_note(
        db: &NamedTempFile,
        txid: &[u8],
        output_pool: i64,
        output_index: i64,
        from_account: uuid::Uuid,
        to_account: Option<uuid::Uuid>,
        to_address: Option<&str>,
        value: i64,
        memo: Option<&[u8]>,
    ) {
        let conn = rusqlite::Connection::open(db.path()).unwrap();
        let transaction_id = conn
            .query_row(
                "SELECT id_tx FROM transactions WHERE txid = ?1",
                rusqlite::params![txid],
                |row| row.get::<_, i64>(0),
            )
            .unwrap();
        let from_account_id = ensure_account_row(&conn, from_account);
        let to_account_id = to_account.map(|account| ensure_account_row(&conn, account));
        conn.execute(
            "INSERT INTO sent_notes (
                 transaction_id, output_pool, output_index, from_account_id,
                 to_account_id, to_address, value, memo
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            rusqlite::params![
                transaction_id,
                output_pool,
                output_index,
                from_account_id,
                to_account_id,
                to_address,
                value,
                memo,
            ],
        )
        .unwrap();
    }

    #[test]
    fn previous_transaction_count_for_address_counts_distinct_sent_transactions() {
        let db = fresh_history_db();
        let account = test_account_uuid();
        let other_account = second_test_account_uuid();
        let target = "u1contactaddress";
        let other_target = "u1otheraddress";

        let txid_a = fake_txid(0xC1);
        insert_history_tx(
            &db,
            account,
            &txid_a,
            Some(1_000_000),
            1,
            Some(1_000_100),
            -5_000_000,
            5_000_000,
            0,
            false,
            Some("2026-04-28T14:03:00Z"),
        );
        let output_index = insert_output_with_address(
            &db,
            &txid_a,
            3,
            Some(account),
            None,
            5_000_000,
            false,
            Some(target),
            None,
        );
        insert_sent_note(
            &db,
            &txid_a,
            3,
            output_index,
            account,
            None,
            Some(target),
            5_000_000,
            None,
        );

        let txid_b = fake_txid(0xC2);
        insert_history_tx(
            &db,
            account,
            &txid_b,
            Some(1_000_001),
            2,
            Some(1_000_101),
            -7_000_000,
            7_000_000,
            0,
            false,
            Some("2026-04-28T14:04:00Z"),
        );
        let output_index = insert_output_with_address(
            &db,
            &txid_b,
            3,
            Some(account),
            None,
            7_000_000,
            false,
            Some(target),
            None,
        );
        insert_sent_note(
            &db,
            &txid_b,
            3,
            output_index,
            account,
            None,
            Some(target),
            7_000_000,
            None,
        );

        let txid_c = fake_txid(0xC3);
        insert_history_tx(
            &db,
            account,
            &txid_c,
            Some(1_000_002),
            3,
            Some(1_000_102),
            -9_000_000,
            9_000_000,
            0,
            false,
            Some("2026-04-28T14:05:00Z"),
        );
        let output_index = insert_output_with_address(
            &db,
            &txid_c,
            3,
            Some(account),
            None,
            9_000_000,
            false,
            Some(other_target),
            None,
        );
        insert_sent_note(
            &db,
            &txid_c,
            3,
            output_index,
            account,
            None,
            Some(other_target),
            9_000_000,
            None,
        );

        let txid_d = fake_txid(0xC4);
        insert_history_tx(
            &db,
            other_account,
            &txid_d,
            Some(1_000_003),
            4,
            Some(1_000_103),
            -11_000_000,
            11_000_000,
            0,
            false,
            Some("2026-04-28T14:06:00Z"),
        );
        let output_index = insert_output_with_address(
            &db,
            &txid_d,
            3,
            Some(other_account),
            None,
            11_000_000,
            false,
            Some(target),
            None,
        );
        insert_sent_note(
            &db,
            &txid_d,
            3,
            output_index,
            other_account,
            None,
            Some(target),
            11_000_000,
            None,
        );

        let got = get_previous_transaction_count_for_address(
            db.path().to_str().unwrap(),
            WalletNetwork::Test,
            &account.to_string(),
            &format!(" {target} "),
        )
        .unwrap();

        assert_eq!(got, 2);
    }

    fn set_account_birthday(db: &NamedTempFile, account: uuid::Uuid, birthday_height: i64) {
        let conn = rusqlite::Connection::open(db.path()).unwrap();
        ensure_account_row(&conn, account);
        conn.execute(
            "UPDATE accounts SET birthday_height = ?2 WHERE uuid = ?1",
            rusqlite::params![account.as_bytes().as_slice(), birthday_height],
        )
        .unwrap();
    }

    #[test]
    fn export_birthday_anchor_uses_oldest_mined_tx_for_account() {
        let db = fresh_history_db();
        let account = test_account_uuid();
        let other_account = second_test_account_uuid();
        let newer = fake_txid(0x71);
        let older_late_index = fake_txid(0x72);
        let older_early_index = fake_txid(0x73);
        let other_older = fake_txid(0x74);
        let pending = fake_txid(0x75);

        insert_history_tx(
            &db,
            account,
            &newer,
            Some(300),
            0,
            None,
            1,
            0,
            1,
            false,
            None,
        );

        insert_history_tx(
            &db,
            account,
            &older_late_index,
            Some(200),
            5,
            None,
            1,
            0,
            1,
            false,
            None,
        );

        insert_history_tx(
            &db,
            account,
            &older_early_index,
            Some(200),
            1,
            None,
            1,
            0,
            1,
            false,
            None,
        );

        insert_history_tx(
            &db,
            other_account,
            &other_older,
            Some(100),
            0,
            None,
            1,
            0,
            1,
            false,
            None,
        );

        insert_history_tx(
            &db,
            account,
            &pending,
            None,
            0,
            Some(400),
            1,
            0,
            1,
            false,
            None,
        );

        let got =
            get_oldest_mined_transaction_anchor(db.path().to_str().unwrap(), &account.to_string())
                .unwrap()
                .unwrap();

        assert_eq!(got.block_height, 200);
    }

    #[test]
    fn export_birthday_anchor_returns_none_without_mined_tx() {
        let db = fresh_history_db();
        let account = test_account_uuid();
        let other_account = second_test_account_uuid();
        let pending = fake_txid(0x81);
        let other_mined = fake_txid(0x82);

        insert_history_tx(
            &db,
            account,
            &pending,
            None,
            0,
            Some(400),
            1,
            0,
            1,
            false,
            None,
        );
        insert_history_tx(
            &db,
            other_account,
            &other_mined,
            Some(100),
            0,
            None,
            1,
            0,
            1,
            false,
            None,
        );

        let got =
            get_oldest_mined_transaction_anchor(db.path().to_str().unwrap(), &account.to_string())
                .unwrap();

        assert!(got.is_none());
    }

    #[test]
    fn export_birthday_anchor_falls_back_to_account_birthday_without_mined_tx() {
        let db = fresh_history_db();
        let account = test_account_uuid();
        let other_account = second_test_account_uuid();
        let pending = fake_txid(0x91);
        let other_mined = fake_txid(0x92);

        set_account_birthday(&db, account, 333_100);
        set_account_birthday(&db, other_account, 111_100);
        insert_history_tx(
            &db,
            account,
            &pending,
            None,
            0,
            Some(400),
            1,
            0,
            1,
            false,
            None,
        );
        insert_history_tx(
            &db,
            other_account,
            &other_mined,
            Some(100),
            0,
            None,
            1,
            0,
            1,
            false,
            None,
        );

        let got =
            get_export_birthday_anchor(db.path().to_str().unwrap(), &account.to_string()).unwrap();

        assert_eq!(got.block_height, 333_100);
    }

    fn add_blocks_table(db: &NamedTempFile, rows: &[(u32, u32)]) {
        let conn = rusqlite::Connection::open(db.path()).unwrap();
        conn.execute(
            "CREATE TABLE blocks (height INTEGER PRIMARY KEY, time INTEGER)",
            [],
        )
        .unwrap();
        for (height, time) in rows {
            conn.execute(
                "INSERT INTO blocks (height, time) VALUES (?1, ?2)",
                rusqlite::params![height, time],
            )
            .unwrap();
        }
    }

    #[test]
    fn local_block_time_uses_the_scanned_block_exactly() {
        let db = fresh_history_db();
        add_blocks_table(&db, &[(2_000_000, 1_677_600_000)]);

        for network in [WalletNetwork::Main, WalletNetwork::Test] {
            let got =
                get_local_block_time(db.path().to_str().unwrap(), network, 2_000_000).unwrap();
            assert_eq!(got, Some(1_677_600_000));
        }
    }

    #[test]
    fn local_block_time_answers_for_the_requested_height_only() {
        // The export anchor would now resolve to the mined transaction at
        // 2,500,000, but the caller asks about the height it already shows.
        let db = fresh_history_db();
        let account = test_account_uuid();
        set_account_birthday(&db, account, 2_000_000);
        insert_history_tx(
            &db,
            account,
            &fake_txid(0x93),
            Some(2_500_000),
            0,
            None,
            1,
            0,
            1,
            false,
            None,
        );
        add_blocks_table(
            &db,
            &[(2_000_000, 1_677_600_000), (2_500_000, 1_715_296_781)],
        );

        let got = get_local_block_time(db.path().to_str().unwrap(), WalletNetwork::Main, 2_000_000)
            .unwrap();
        assert_eq!(got, Some(1_677_600_000));
    }

    #[cfg(not(ironwood_masquerade))]
    #[test]
    fn local_block_time_estimates_unscanned_mainnet_blocks() {
        let db = fresh_history_db();
        add_blocks_table(&db, &[]);
        let path = db.path().to_str().unwrap();

        let got = get_local_block_time(path, WalletNetwork::Main, 2_000_000)
            .unwrap()
            .unwrap();
        // Mainnet block 2,000,000 was mined at 1,677,602,242.
        assert!(got.abs_diff(1_677_602_242) <= 6 * 60 * 60, "{got}");

        assert_eq!(
            get_local_block_time(path, WalletNetwork::Test, 2_000_000).unwrap(),
            None
        );
    }

    #[cfg(ironwood_masquerade)]
    #[test]
    fn local_block_time_never_estimates_masquerade_chain_blocks() {
        let db = fresh_history_db();
        add_blocks_table(&db, &[(1_000, 1_790_000_000)]);
        let path = db.path().to_str().unwrap();

        // Unscanned heights fall back to the chain's own endpoint.
        assert_eq!(
            get_local_block_time(path, WalletNetwork::Main, 400).unwrap(),
            None
        );
        // Scanned heights still answer exactly.
        assert_eq!(
            get_local_block_time(path, WalletNetwork::Main, 1_000).unwrap(),
            Some(1_790_000_000)
        );
    }

    #[cfg(not(ironwood_masquerade))]
    #[test]
    fn local_block_time_anchors_past_the_table_on_the_highest_scanned_block() {
        let db = fresh_history_db();
        add_blocks_table(&db, &[(900_000_100, 4_000_000_000)]);

        let got = get_local_block_time(
            db.path().to_str().unwrap(),
            WalletNetwork::Main,
            900_000_000,
        )
        .unwrap()
        .unwrap();
        assert!(got < 4_000_000_000);
        assert!(got > 3_999_000_000, "{got}");
    }

    /// Read `TxBase` from `v_transactions`, to compare with the library's
    /// summaries.
    pub(super) fn read_history_bases_via_v_transactions(
        conn: &rusqlite::Connection,
        account_uuid: &[u8],
    ) -> Result<Vec<TxBase>, String> {
        let mut stmt = conn
            .prepare(
                r#"
            SELECT
                vt.txid,
                COALESCE(tx.id_tx, -1) AS transaction_id,
                vt.mined_height,
                COALESCE(vt.expired_unmined, 0) AS expired_unmined,
                vt.account_balance_delta,
                vt.fee_paid AS fee_paid,
                COALESCE(vt.block_time, 0) AS block_time,
                COALESCE(vt.total_spent, 0) AS total_spent,
                COALESCE(vt.total_received, 0) AS total_received,
                COALESCE(vt.is_shielding, 0) AS is_shielding,
                vt.expiry_height,
                COALESCE(vt.tx_index, -1) AS tx_index,
                tx.created,
                CAST(COALESCE(strftime('%s', tx.created), 0) AS INTEGER) AS created_time,
                EXISTS (
                    SELECT 1
                    FROM transactions spent_tx
                    JOIN orchard_received_note_spends spent
                        ON spent.transaction_id = spent_tx.id_tx
                    JOIN orchard_received_notes spent_note
                        ON spent_note.id = spent.orchard_received_note_id
                    WHERE spent_tx.txid = vt.txid
                      AND spent_note.note_version = ?2
                ) AS spent_orchard_note
            FROM v_transactions vt
            LEFT JOIN transactions tx ON tx.txid = vt.txid
            WHERE vt.account_uuid = ?1
            "#,
            )
            .map_err(|e| format!("SQL error: {e}"))?;

        let rows = stmt
            .query_map(rusqlite::params![account_uuid, 2], |row| {
                let mined_height: Option<u32> = row.get(2)?;
                Ok(TxBase {
                    txid: row.get(0)?,
                    transaction_id: row.get(1)?,
                    mined_height,
                    expired_unmined: row.get(3)?,
                    account_balance_delta: row.get(4)?,
                    block_time: row.get::<_, i64>(6)?.unsigned_abs(),
                    total_spent: row.get::<_, i64>(7)?.unsigned_abs(),
                    total_received: row.get::<_, i64>(8)?.unsigned_abs(),
                    expiry_height: row.get(10)?,
                    tx_index: row.get(11)?,
                    created: row.get(12)?,
                    created_time: row.get::<_, i64>(13)?.unsigned_abs(),
                    history: HistoryView::unread(mined_height.is_some()),
                })
            })
            .map_err(|e| format!("Query error: {e}"))?;

        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| format!("Row error: {e}"))
    }

    /// Pin the batched balance read to the single-account one.
    ///
    /// `get_wallet_balances` exists so a caller wanting several accounts
    /// pays for one `get_wallet_summary` instead of one per account. It
    /// must return exactly what looping over `get_wallet_balance` would,
    /// including order and the unavailable-account fallbacks.
    ///
    /// Needs a real wallet DB, same as the history equivalence check:
    ///
    /// ```text
    /// VIZOR_HISTORY_EQUIV_DB=/path/to/zcash_wallet.db \
    ///   cargo test --lib wallet_balances_batch_matches_single -- --ignored --nocapture
    /// ```
    #[test]
    #[ignore = "requires a librustzcash-built wallet DB via VIZOR_HISTORY_EQUIV_DB"]
    fn wallet_balances_batch_matches_single() {
        let db_path = std::env::var("VIZOR_HISTORY_EQUIV_DB")
            .expect("set VIZOR_HISTORY_EQUIV_DB to a librustzcash-built wallet DB");
        let conn = open_readonly_conn(&db_path).unwrap();
        let uuids: Vec<String> = conn
            .prepare("SELECT uuid FROM accounts ORDER BY id")
            .unwrap()
            .query_map([], |row| row.get::<_, Vec<u8>>(0))
            .unwrap()
            .map(|raw| uuid::Uuid::from_slice(&raw.unwrap()).unwrap().to_string())
            .collect();
        assert!(!uuids.is_empty(), "{db_path} has no accounts");
        drop(conn);

        let network = WalletNetwork::Main;
        let refs: Vec<&str> = uuids.iter().map(String::as_str).collect();
        let batched = get_wallet_balances(&db_path, network, &refs).unwrap();
        assert_eq!(
            batched.len(),
            uuids.len(),
            "batch must return one entry per requested account"
        );

        for (uuid, batch_entry) in uuids.iter().zip(batched.iter()) {
            let single = get_wallet_balance(&db_path, network, uuid).unwrap();
            assert_eq!(
                batch_entry, &single,
                "account {uuid}: batched balance diverged from get_wallet_balance"
            );
        }

        // An account absent from the summary must degrade per entry, not
        // fail the batch, so one stale uuid cannot blank a whole sweep.
        let missing = uuid::Uuid::nil().to_string();
        let mut with_missing: Vec<&str> = refs.clone();
        with_missing.push(&missing);
        let mixed = get_wallet_balances(&db_path, network, &with_missing).unwrap();
        assert_eq!(mixed.len(), with_missing.len());
        assert_eq!(
            mixed.last().unwrap().availability,
            WalletBalanceAvailability::AccountUnavailable
        );
        assert_eq!(
            &mixed[..refs.len()],
            &batched[..],
            "a missing account must not disturb the others"
        );
        println!("compared {} accounts", uuids.len());
    }

    /// Additional equivalence coverage on a synced wallet, beyond the automatic
    /// migrated-schema fixtures in `history_summary_tests`.
    ///
    /// It needs a database built by librustzcash itself. Point it at a
    /// regtest wallet (`./run-regtest-rust-tests.sh` leaves one behind)
    /// or any real wallet DB:
    ///
    /// ```text
    /// VIZOR_HISTORY_EQUIV_DB=/path/to/zcash_wallet.db \
    ///   cargo test --lib history_bases_match_v_transactions -- --ignored --nocapture
    /// ```
    #[test]
    #[ignore = "requires a librustzcash-built wallet DB via VIZOR_HISTORY_EQUIV_DB"]
    fn history_bases_match_v_transactions() {
        let db_path = std::env::var("VIZOR_HISTORY_EQUIV_DB")
            .expect("set VIZOR_HISTORY_EQUIV_DB to a librustzcash-built wallet DB");
        let conn = open_readonly_conn(&db_path).unwrap();

        let accounts: Vec<Vec<u8>> = conn
            .prepare("SELECT uuid FROM accounts ORDER BY id")
            .unwrap()
            .query_map([], |row| row.get::<_, Vec<u8>>(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(
            !accounts.is_empty(),
            "{db_path} has no accounts; point at a synced wallet"
        );

        let read_tx = conn.unchecked_transaction().unwrap();
        let mut compared = 0usize;
        for account in &accounts {
            let sort = |mut rows: Vec<TxBase>| {
                rows.sort_by(|a, b| a.txid.cmp(&b.txid));
                rows
            };
            let account_id = AccountUuid::from_uuid(uuid::Uuid::from_slice(account).unwrap());
            let via_summary = sort(
                read_history_bases(&read_tx, &db_path, WalletNetwork::Main, account_id).unwrap(),
            );
            let via_view = sort(read_history_bases_via_v_transactions(&read_tx, account).unwrap());

            assert_eq!(
                via_summary.len(),
                via_view.len(),
                "account {}: row count differs between library summaries and v_transactions",
                hex::encode(account)
            );
            for (summary, view) in via_summary.iter().zip(via_view.iter()) {
                assert_eq!(
                    summary,
                    view,
                    "account {} tx {}: library summaries diverged from v_transactions; \
                     re-check the summary mapping against the upstream view definition",
                    hex::encode(account),
                    hex::encode(&summary.txid),
                );
            }
            compared += via_summary.len();
        }
        println!(
            "compared {compared} rows across {} accounts",
            accounts.len()
        );
        assert!(compared > 0, "{db_path} has no history rows to compare");
    }

    /// `expired_unmined` is SQL NULL for an unmined transaction whose expiry
    /// cannot be compared to a scanned height: no `blocks` rows yet (a
    /// hardware wallet that broadcasts before its first scan, as the Ledger
    /// Speculos fixtures do) or no recorded expiry height. Such a row is
    /// pending, not expired, and must not fail the whole history read.
    #[test]
    fn history_reads_unmined_rows_without_a_comparable_expiry() {
        use transparent::{address::TransparentAddress, bundle::OutPoint, bundle::TxOut};
        use zcash_client_backend::{data_api::WalletWrite, wallet::WalletTransparentOutput};
        use zcash_keys::encoding::AddressCodec as _;

        let network = WalletNetwork::Regtest;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("wallet.db").to_str().unwrap().to_owned();
        let seed = crate::wallet::keys::mnemonic_to_seed(&crate::wallet::keys::generate_mnemonic())
            .unwrap();
        let (uuid, _) =
            crate::wallet::keys::init_db_and_create_account(&path, network, &seed, Some(100), "a")
                .unwrap();
        let address =
            crate::wallet::keys::software_account_transparent_addresses(network, &seed, 0, 1)
                .unwrap()
                .swap_remove(0);
        let address = TransparentAddress::decode(&network, &address).unwrap();
        let output = WalletTransparentOutput::from_parts(
            OutPoint::new([0x51; 32], 0),
            TxOut::new(
                zcash_protocol::value::Zatoshis::const_from_u64(50_000),
                address.script().into(),
            ),
            None,
            None,
            None,
            None,
        )
        .unwrap();
        let mut db = open_wallet_db(&path, network).unwrap();
        db.put_received_transparent_utxo(&output).unwrap();
        drop(db);
        let conn = rusqlite::Connection::open(&path).unwrap();
        let blocks: i64 = conn
            .query_row("SELECT COUNT(*) FROM blocks", [], |row| row.get(0))
            .unwrap();
        assert_eq!(blocks, 0, "the wallet has not scanned a block");

        for expiry_height in [None, Some(140)] {
            conn.execute(
                "UPDATE transactions SET expiry_height = ?1 WHERE txid = ?2",
                rusqlite::params![expiry_height, [0x51u8; 32].as_slice()],
            )
            .unwrap();
            let history = get_transaction_history(&path, network, None, &uuid).unwrap();
            assert_eq!(history.len(), 1, "expiry {expiry_height:?}");
            assert_eq!(history[0].mined_height, 0);
            assert!(!history[0].expired_unmined, "expiry {expiry_height:?}");
        }
    }

    #[test]
    fn resubmit_excludes_mined_txs() {
        // A tx with `mined_height IS NOT NULL` is already on-chain;
        // resubmitting would be pointless at best and could surface a
        // confusing rejection from lightwalletd.
        let db = fresh_db();
        insert_row(
            &db,
            &fake_txid(0x01),
            Some(&fake_raw()),
            Some(1_000_000), // mined_height set → mined
            Some(1_000_100),
            -5_000,
        );
        let got = get_resubmittable_txs(db.path().to_str().unwrap(), 900_000).unwrap();
        assert!(
            got.is_empty(),
            "mined tx must not be a resubmit candidate, got {got:?}",
            got = got.len(),
        );
    }

    #[test]
    fn resubmit_excludes_expired_txs() {
        // `expiry_height > current_height` is the network's
        // still-relayable check for expiring transactions. A tx whose
        // expiry equals the current height is already past the window.
        let db = fresh_db();
        insert_row(
            &db,
            &fake_txid(0x02),
            Some(&fake_raw()),
            None,
            Some(1_000_000), // expiry == current → expired
            -5_000,
        );
        let got = get_resubmittable_txs(db.path().to_str().unwrap(), 1_000_000).unwrap();
        assert!(got.is_empty(), "tx with expiry==current must be excluded");

        // Walk the boundary: one block below current is definitely expired.
        let db2 = fresh_db();
        insert_row(
            &db2,
            &fake_txid(0x02),
            Some(&fake_raw()),
            None,
            Some(999_999),
            -5_000,
        );
        let got2 = get_resubmittable_txs(db2.path().to_str().unwrap(), 1_000_000).unwrap();
        assert!(got2.is_empty(), "tx with expiry<current must be excluded");
    }

    #[test]
    fn resubmit_excludes_received_txs() {
        // `account_balance_delta >= 0` means the account gained or broke
        // even on this tx — it's an incoming transfer we just happened to
        // have raw bytes for (e.g. re-read from lightwalletd during a
        // rescan). Resubmitting "our" received txs back to the network
        // would be meaningless.
        let db = fresh_db();
        insert_row(
            &db,
            &fake_txid(0x03),
            Some(&fake_raw()),
            None,
            Some(1_000_100),
            5_000, // positive delta → inbound
        );
        let got = get_resubmittable_txs(db.path().to_str().unwrap(), 1_000_000).unwrap();
        assert!(got.is_empty(), "received-only tx must be excluded");

        // Also the zero case: a break-even tx shouldn't show up either
        // (it's still not an "outbound" the wallet needs to keep alive).
        let db2 = fresh_db();
        insert_row(
            &db2,
            &fake_txid(0x03),
            Some(&fake_raw()),
            None,
            Some(1_000_100),
            0,
        );
        let got2 = get_resubmittable_txs(db2.path().to_str().unwrap(), 1_000_000).unwrap();
        assert!(got2.is_empty(), "zero-delta tx must be excluded");
    }

    #[test]
    fn resubmit_excludes_raw_null_txs() {
        // `raw IS NULL` means we don't have bytes to broadcast. This row
        // exists because sync learned about the tx via decrypt-and-store
        // without the raw bundle, and there's nothing we can resubmit.
        let db = fresh_db();
        insert_row(
            &db,
            &fake_txid(0x04),
            None, // raw NULL
            None,
            Some(1_000_100),
            -5_000,
        );
        let got = get_resubmittable_txs(db.path().to_str().unwrap(), 1_000_000).unwrap();
        assert!(got.is_empty(), "raw-null tx must be excluded");
    }

    #[test]
    fn resubmit_includes_valid_outbound_pending() {
        // The happy path: unmined, inside expiry, outbound, raw present.
        let db = fresh_db();
        let txid = fake_txid(0x05);
        let raw = fake_raw();
        insert_row(&db, &txid, Some(&raw), None, Some(1_000_100), -5_000);
        let got = get_resubmittable_txs(db.path().to_str().unwrap(), 1_000_000).unwrap();
        assert_eq!(got.len(), 1, "outbound pending tx must appear exactly once");
        assert_eq!(got[0].txid_bytes, txid.to_vec());
        assert_eq!(got[0].raw_tx, raw);
        assert_eq!(got[0].expiry_height, 1_000_100);
    }

    #[test]
    fn resubmit_falls_back_when_preflight_schema_is_unavailable() {
        let (db, txid) = (fresh_db(), fake_txid(0x08));
        insert_row(&db, &txid, Some(&fake_raw()), None, Some(1_000_100), -5_000);
        let conn = rusqlite::Connection::open(db.path()).unwrap();
        conn.execute("DROP TRIGGER vizor_preserve_mined_transaction", [])
            .unwrap();
        conn.execute("ALTER TABLE transactions DROP COLUMN mined_height", [])
            .unwrap();
        let got = get_resubmittable_txs(db.path().to_str().unwrap(), 1_000_000).unwrap();
        assert_eq!(got[0].txid_bytes, txid);
    }

    #[test]
    fn resubmit_excludes_only_deferred_txids() {
        let db = fresh_db();
        let deferred_txid = fake_txid(0x15);
        let pending_txid = fake_txid(0x16);
        let raw = fake_raw();
        insert_row(
            &db,
            &deferred_txid,
            Some(&raw),
            None,
            Some(1_000_100),
            -5_000,
        );
        insert_row(
            &db,
            &pending_txid,
            Some(&raw),
            None,
            Some(1_000_100),
            -5_000,
        );
        // The metadata query's stand-in view still reports raw bytes, but the
        // backing lookup cannot return them. Exclusion must happen before the
        // raw transaction query.
        rusqlite::Connection::open(db.path())
            .unwrap()
            .execute(
                "UPDATE transactions SET raw = NULL WHERE txid = ?1",
                [&deferred_txid],
            )
            .unwrap();

        let excluded = HashSet::from([deferred_txid.to_vec()]);
        let got =
            get_resubmittable_txs_excluding(db.path().to_str().unwrap(), 1_000_000, &excluded)
                .unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].txid_bytes, pending_txid);
    }

    #[test]
    fn resubmit_includes_no_expiry_outbound_pending() {
        // Expiry height 0 is the protocol no-expiry marker, so these
        // transactions must keep participating in auto-resubmit across
        // restarts and long migration windows.
        let db = fresh_db();
        let txid = fake_txid(0x07);
        let raw = fake_raw();
        insert_row(&db, &txid, Some(&raw), None, Some(0), -5_000);

        let got = get_resubmittable_txs(db.path().to_str().unwrap(), 1_000_000).unwrap();
        assert_eq!(
            got.len(),
            1,
            "no-expiry outbound pending tx must be resubmittable"
        );
        assert_eq!(got[0].txid_bytes, txid.to_vec());
        assert_eq!(got[0].raw_tx, raw);
        assert_eq!(got[0].expiry_height, 0);
    }

    #[test]
    fn resubmit_dedupes_multi_account_rows() {
        // A tx that touches two of the wallet's own accounts shows up as
        // two rows in `v_transactions`. `SELECT DISTINCT txid, raw,
        // expiry_height` should collapse that to one broadcast — double-
        // sending identical bytes would be a regression.
        let db = fresh_db();
        let txid = fake_txid(0x06);
        let raw = fake_raw();
        // Two rows for the same tx, different account-level deltas, both
        // still outbound at the row level (account-internal transfer with
        // a net negative for both of the wallet's participating accounts
        // after fees — contrived but possible).
        insert_row(&db, &txid, Some(&raw), None, Some(1_000_100), -3_000);
        insert_row(&db, &txid, Some(&raw), None, Some(1_000_100), -2_000);

        let got = get_resubmittable_txs(db.path().to_str().unwrap(), 1_000_000).unwrap();
        assert_eq!(
            got.len(),
            1,
            "multi-account rows with same (txid, raw, expiry) must dedupe",
        );
    }

    #[test]
    fn resubmit_returns_empty_when_table_empty() {
        // Baseline: an empty table must return `Ok(vec![])`, not an
        // error. `resubmit_pending_transactions` relies on this to
        // decide the "nothing to do" case.
        let db = fresh_db();
        let got = get_resubmittable_txs(db.path().to_str().unwrap(), 1_000_000).unwrap();
        assert!(got.is_empty());
    }

    // ======================== Rows from the library's activity ========================
    //
    // The library decides what a transaction shows (`AccountActivity`); these
    // cover what Vizor keeps: labels, received versus receiving, the split
    // into rows, TEX funding-step pairing, the Gift Card mined height, and
    // the outputs a receipt lists.

    fn zats(value: u64) -> Zatoshis {
        Zatoshis::from_u64(value).unwrap()
    }

    fn output_ref(pool: PoolType, index: u32) -> OutputRef {
        OutputRef { pool, index }
    }

    fn rows_of(amount: u64, outputs: &[OutputRef]) -> Option<ActivityOutputs> {
        Some(ActivityOutputs {
            amount: zats(amount),
            outputs: outputs.to_vec(),
        })
    }

    /// A settled, complete transaction showing `activity`.
    fn activity_base(
        transaction_id: i64,
        tag: u8,
        account_balance_delta: i64,
        spent: u64,
        received: u64,
        fee: FeeState,
        activity: AccountActivity,
    ) -> TxBase {
        TxBase {
            txid: fake_txid(tag).to_vec(),
            transaction_id,
            mined_height: Some(1_000_000),
            expired_unmined: false,
            account_balance_delta,
            block_time: 1_700_000_000,
            total_spent: spent,
            total_received: received,
            expiry_height: Some(1_000_100),
            tx_index: transaction_id,
            created: None,
            created_time: 0,
            history: HistoryView {
                has_transparent_outputs: None,
                details_complete: true,
                provisional: false,
                fee,
                activity,
                funding_step: FundingStepEvidence::default(),
                mined: true,
            },
        }
    }

    /// A TEX payment as the wallet builds it: a funding step paying the
    /// account's ephemeral transparent address, then the payment spending it.
    /// Both are unmined and created together.
    fn tex_pair(
        funding_id: i64,
        payment_id: i64,
        amount: u64,
        funding_fee: u64,
        payment_fee: u64,
    ) -> [TxBase; 2] {
        let unmined_created = |mut base: TxBase| {
            base.mined_height = None;
            base.history.mined = false;
            base.block_time = 0;
            base.created = Some("2026-04-28T13:03:00Z".to_string());
            base
        };
        let mut funding = unmined_created(activity_base(
            funding_id,
            funding_id as u8,
            -(funding_fee as i64),
            amount + funding_fee,
            amount,
            FeeState::Known(zats(funding_fee)),
            AccountActivity::ChangeOnly,
        ));
        funding.history.funding_step.own_transparent_outputs = Some(zats(amount));
        let mut payment = unmined_created(activity_base(
            payment_id,
            payment_id as u8,
            -(amount as i64),
            amount,
            0,
            FeeState::Known(zats(payment_fee)),
            AccountActivity::Outputs {
                sent: rows_of(
                    amount - payment_fee,
                    &[output_ref(PoolType::Transparent, 0)],
                ),
                received: None,
            },
        ));
        payment.history.funding_step.external_transparent_send = true;
        [funding, payment]
    }

    #[test]
    fn funding_steps_pair_with_their_payment_by_transparent_amount() {
        let [funding_a, payment_a] = tex_pair(1, 2, 10_010_000, 40_000, 10_000);
        let [funding_b, payment_b] = tex_pair(3, 4, 20_015_000, 50_000, 15_000);
        let bases = [
            funding_a.clone(),
            payment_a.clone(),
            funding_b,
            payment_b.clone(),
        ];

        let got = assemble_history(&bases, None);

        assert_eq!(got.len(), 2);
        let row_a = got
            .iter()
            .find(|tx| tx.txid_hex == hex::encode(&payment_a.txid))
            .unwrap();
        assert_eq!(row_a.tx_kind, "sent");
        assert_eq!(row_a.display_amount, 10_000_000);
        assert_eq!(row_a.fee, 50_000);
        assert_eq!(
            row_a.funding_parent_txid.as_deref(),
            Some(hex::encode(&funding_a.txid).as_str())
        );
        let row_b = got
            .iter()
            .find(|tx| tx.txid_hex == hex::encode(&payment_b.txid))
            .unwrap();
        assert_eq!(row_b.display_amount, 20_000_000);
        assert_eq!(row_b.fee, 65_000);
    }

    #[test]
    fn an_unmatched_funding_step_is_not_hidden_by_pairing() {
        let [funding, _] = tex_pair(1, 2, 10_010_000, 40_000, 10_000);
        let mut funding_only = funding.clone();
        // Without its payment, the funding step shows what the library
        // decided for it, here nothing.
        assert!(assemble_history(std::slice::from_ref(&funding_only), None).is_empty());
        funding_only.history.activity = AccountActivity::MovementDebit { amount: zats(1) };
        let got = assemble_history(&[funding_only], None);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].tx_kind, "sent");
    }

    #[test]
    fn a_gift_card_mined_height_reapplies_the_unmined_debit_rule() {
        // The library read the claim as mined: its change-only outputs show no row.
        let mut claim = activity_base(
            1,
            0xC1,
            -5_000,
            105_000,
            100_000,
            FeeState::Known(zats(1_000)),
            AccountActivity::ChangeOnly,
        );
        claim.created = Some("2026-04-28T13:03:00Z".to_string());
        assert!(assemble_history(std::slice::from_ref(&claim), None).is_empty());
        // Vizor's claim record has no mined height: an unmined debit shows
        // its movement less the known fee.
        claim.mined_height = None;
        let got = assemble_history(std::slice::from_ref(&claim), None);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].tx_kind, "sent");
        assert_eq!(got[0].display_amount, 4_000);

        // The reverse: the library applied the rule to an unmined read, and
        // the claim record shows it mined.
        let mut mined = claim.clone();
        mined.history.mined = false;
        mined.history.activity = AccountActivity::MovementDebit {
            amount: zats(4_000),
        };
        mined.mined_height = Some(1_000_000);
        assert!(assemble_history(&[mined.clone()], None).is_empty());
        // A provisional debit's row does not depend on the mined height.
        mined.history.provisional = true;
        assert_eq!(assemble_history(&[mined], None).len(), 1);
    }

    #[test]
    fn activity_variants_map_to_vizor_rows() {
        let base = |activity| {
            activity_base(
                1,
                0xC2,
                -30_000,
                30_000,
                0,
                FeeState::Known(zats(10_000)),
                activity,
            )
        };
        let rows = |activity| assemble_history(&[base(activity)], None);

        let fee_only = rows(AccountActivity::FeeOnly { fee: zats(10_000) });
        assert_eq!(fee_only[0].tx_kind, "sent");
        assert_eq!(fee_only[0].display_amount, 10_000);
        assert!(fee_only[0].amount_includes_fee);

        let inferred = rows(AccountActivity::InferredOutgoing {
            outgoing: zats(20_000),
            received: rows_of(5_000, &[output_ref(PoolType::Transparent, 1)]),
            settled: false,
        });
        assert_eq!(inferred.len(), 2);
        assert_eq!(inferred[0].tx_kind, "sent");
        assert_eq!(inferred[0].display_amount, 20_000);
        assert_eq!(inferred[0].activity_pool.as_deref(), Some("transparent"));
        assert!(inferred[0].provisional);
        assert_eq!(inferred[1].tx_kind, "received");
        assert_eq!(inferred[1].display_amount, 5_000);

        let unknown_debit = rows(AccountActivity::MovementDebit { amount: zats(0) });
        assert_eq!(unknown_debit[0].tx_kind, "unknown");

        let mixed = rows(AccountActivity::Outputs {
            sent: rows_of(
                20_000,
                &[
                    output_ref(PoolType::Transparent, 0),
                    output_ref(PoolType::ORCHARD, 0),
                ],
            ),
            received: rows_of(0, &[output_ref(PoolType::IRONWOOD, 1)]),
        });
        assert_eq!(mixed.len(), 2);
        assert_eq!(mixed[0].display_pool, "mixed");
        assert!(mixed[0].is_transparent);
        assert_eq!(mixed[0].fee, 10_000);
        assert_eq!(mixed[1].tx_kind, "received");
        assert_eq!(mixed[1].display_pool, "ironwood");
        assert_eq!(mixed[1].activity_pool.as_deref(), Some("ironwood"));

        let migration = rows(AccountActivity::PoolMigration {
            amount: zats(20_000),
            outputs: vec![output_ref(PoolType::IRONWOOD, 0)],
        });
        assert_eq!(migration[0].tx_kind, "migration");
        assert_eq!(migration[0].display_pool, "ironwood");

        assert!(rows(AccountActivity::HiddenFundingStep).is_empty());
        assert_eq!(rows(AccountActivity::Unknown)[0].tx_kind, "unknown");
    }

    #[test]
    fn a_receipt_lists_exactly_its_rows_outputs() {
        let sent = [output_ref(PoolType::Transparent, 0)];
        let received = [output_ref(PoolType::ORCHARD, 1)];
        let outputs = AccountActivity::Outputs {
            sent: rows_of(1, &sent),
            received: rows_of(1, &received),
        };
        assert_eq!(receipt_outputs(&outputs, "sent"), &sent);
        assert_eq!(receipt_outputs(&outputs, "received"), &received);
        assert_eq!(receipt_outputs(&outputs, "receiving"), &received);
        assert!(receipt_outputs(&outputs, "shielded").is_empty());

        let inferred = AccountActivity::InferredOutgoing {
            outgoing: zats(1),
            received: rows_of(1, &sent),
            settled: true,
        };
        assert!(receipt_outputs(&inferred, "sent").is_empty());
        assert_eq!(receipt_outputs(&inferred, "received"), &sent);

        let shielding = AccountActivity::Shielding {
            amount: zats(1),
            outputs: received.to_vec(),
        };
        assert_eq!(receipt_outputs(&shielding, "shielded"), &received);
        assert!(receipt_outputs(&shielding, "received").is_empty());
    }
}
