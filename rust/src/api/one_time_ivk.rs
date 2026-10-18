//! Private NEAR swap addresses over the wallet's one-time IVKs: reservations, quote
//! records, provider statuses and swap history checks. Provider polling stays in Dart;
//! allocation is durable in Rust.
use super::sync::parse_network_and_migrate;
use crate::wallet::db::open_wallet_db_with_timeout;
use crate::wallet::one_time_ivk::{self, with_db};
use crate::wallet::{db::WALLET_DB_BUSY_TIMEOUT, keys};
use zakura_near_intents::near_observation;
use zakura_one_time_ivk::{swap::Observation, Purpose};
use zcash_client_sqlite::{
    error::SqliteClientError,
    wallet::one_time_ivk::swap::{OperationOutcome, ProviderSeen, ReservationPolicy},
};

/// Why a private swap call failed, for the app to act on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReceiveErrorKind {
    /// Any failure the app only shows.
    Other,
    /// The provider's seen set could not be read fresh, so no new swap address can be
    /// issued. Private swaps stay paused until it can, or until the user turns NEAR swap
    /// privacy off.
    SeenUnavailable,
    /// The reservation expired or was retired: prepare a new address.
    Stale,
}

/// A private swap failure. `message` is display text, never a parsing protocol; `kind`
/// says what the app should do about it.
#[derive(Clone, Debug)]
pub struct ReceiveError {
    pub message: String,
    pub kind: ReceiveErrorKind,
}
impl std::fmt::Display for ReceiveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}
impl std::error::Error for ReceiveError {}
impl From<String> for ReceiveError {
    fn from(message: String) -> Self {
        Self {
            message,
            kind: ReceiveErrorKind::Other,
        }
    }
}
impl From<&str> for ReceiveError {
    fn from(message: &str) -> Self {
        message.to_owned().into()
    }
}
impl From<SqliteClientError> for ReceiveError {
    fn from(error: SqliteClientError) -> Self {
        error.to_string().into()
    }
}
/// The wording Vizor shows for each reason issuance or an operation must wait.
impl From<ReservationPolicy> for ReceiveError {
    fn from(policy: ReservationPolicy) -> Self {
        let (message, kind) = match policy {
            ReservationPolicy::Gap => (
                "Restored swap addresses are still being checked. \
                 Try again after the wallet finishes syncing.",
                ReceiveErrorKind::Other,
            ),
            ReservationPolicy::Limit => (
                "No swap address is free. Wait for a swap in progress to finish.",
                ReceiveErrorKind::Other,
            ),
            ReservationPolicy::Stale => (
                "This swap address is no longer available. Request a new quote.",
                ReceiveErrorKind::Stale,
            ),
            ReservationPolicy::Coverage => (
                "Finish syncing to the chain tip before requesting a quote.",
                ReceiveErrorKind::Other,
            ),
            ReservationPolicy::SeenUnavailable => (
                "Private swaps are paused because we can't confirm which addresses \
                 are free right now. Turn off NEAR swap privacy to swap now.",
                ReceiveErrorKind::SeenUnavailable,
            ),
        };
        Self {
            message: message.into(),
            kind,
        }
    }
}

/// A durably reserved swap address. A refund address carries its refund key index; an
/// incoming one, its reservation's index.
pub struct SwapAddress {
    pub address: String,
    pub refund_index: Option<u64>,
    pub reservation_index: Option<u64>,
}

/// The NEAR 1Click status fields that decide when a swap key stops scanning.
/// Amounts are base-unit decimal strings, as the provider reports them.
pub struct SwapProviderStatus {
    pub status: String,
    pub swap_type: Option<String>,
    pub refunded_amount: Option<String>,
    pub amount_out: Option<String>,
}

/// An incoming quote's deposit instructions, as the provider issued them.
pub struct ReceiveDeposit {
    pub address: String,
    pub memo: Option<String>,
    pub deadline_seconds: i64,
}

/// Reserves a swap address on a software account, skipping any the swap provider's seen
/// set from the receiver directory holds, so an address another device of the same seed
/// gave the provider is not issued again. `incoming` resumes the account's draft or
/// reserves the lowest eligible incoming index (see `prepare_receive_reservation`); its
/// key scans from the next unscanned block until it closes. Otherwise it reserves the
/// next refund index (see `reserve_refund_key`), whose key starts scanning when the
/// wallet stores the swap's funding transaction. `live_tip` is the chain tip the quote
/// flow fetched. Without a fresh seen set, only a quoted incoming draft can be resumed;
/// anything else fails as [`ReceiveErrorKind::SeenUnavailable`]. Does not start or
/// restart ordinary wallet sync.
pub fn reserve_swap_address(
    db_path: String,
    network_name: String,
    account_uuid: String,
    incoming: bool,
    live_tip: u64,
) -> Result<SwapAddress, ReceiveError> {
    let network = parse_network_and_migrate(&db_path, &network_name)?;
    one_time_ivk::require_new_address(network)?;
    let tip = one_time_ivk::network_tip(live_tip)?;
    // Fetched before taking the wallet lock, so a slow directory never holds it.
    let seen = runtime()?.block_on(crate::wallet::sync_engine::fetch_seen(network));
    let key = with_seen(seen, |view| {
        with_db(&db_path, network, &account_uuid, |db, a| {
            one_time_ivk::require_software_account(db, a)?;
            let now = one_time_ivk::now()?;
            Ok::<_, ReceiveError>(if incoming {
                db.prepare_receive_reservation(a, now, tip, view)??
            } else {
                db.reserve_refund_key(a, now, tip, view)??
            })
        })
    })?;
    let index = key.key_id().index();
    Ok(SwapAddress {
        address: one_time_ivk::encode_address(&key, network)?,
        refund_index: (!incoming).then_some(index),
        reservation_index: incoming.then_some(index),
    })
}

/// A runtime for the receiver directory requests issuance makes.
fn runtime() -> Result<tokio::runtime::Runtime, ReceiveError> {
    Ok(tokio::runtime::Runtime::new().map_err(|e| format!("tokio: {e}"))?)
}

/// Runs `action` with `seen` as the library takes it, or with none if it could not be
/// read. The library then refuses whatever needs a fresh set as `SeenUnavailable`.
fn with_seen<T>(
    seen: Result<std::sync::Arc<zakura_pir_receiver::Seen>, String>,
    action: impl FnOnce(Option<&ProviderSeen<'_>>) -> T,
) -> T {
    let seen = seen.inspect_err(|e| log::warn!("{e}")).ok();
    let contains = |receivers: &[[u8; 43]]| {
        seen.as_ref()
            .map_or_else(|| vec![true; receivers.len()], |s| s.contains(receivers))
    };
    let view = seen.as_ref().map(|s| ProviderSeen {
        since: s.since(),
        until: s.until(),
        contains: &contains,
    });
    action(view.as_ref())
}

/// Persists an unknown outcome and scan watch just before a provider quote request
/// leaves the device, and returns the request's identity. `reservation_index` is the
/// incoming reservation [`reserve_swap_address`] returned, and `deadline_seconds` the
/// deposit deadline the request sends. A reservation's first request checks the seen
/// set issuance read, if it is still current, or else a new one. Fails as
/// [`ReceiveErrorKind::Stale`] once the reservation's latest quote has expired or it was
/// retired, so the app prepares a new address, and as
/// [`ReceiveErrorKind::SeenUnavailable`] when a first request has no fresh set.
pub fn begin_receive_quote(
    db_path: String,
    network_name: String,
    account_uuid: String,
    reservation_index: u64,
    deadline_seconds: i64,
) -> Result<String, ReceiveError> {
    let network = parse_network_and_migrate(&db_path, &network_name)?;
    one_time_ivk::require_new_address(network)?;
    let now = one_time_ivk::now()?;
    let seen = runtime()?.block_on(crate::wallet::sync_engine::current_seen(network, now));
    with_seen(seen, |view| {
        with_db(&db_path, network, &account_uuid, |db, a| {
            Ok(db.begin_receive_operation(
                a,
                reservation_index,
                deadline_seconds,
                one_time_ivk::now()?,
                view,
            )??)
        })
    })
}

/// Records how quote request `request_id` ended, even if the requesting UI has changed:
/// `accepted` with its deposit instructions, or, without them, definitively rejected,
/// which releases the request's hold on the address. Never call it for a timeout or a
/// malformed response.
pub fn finish_receive_quote(
    db_path: String,
    network_name: String,
    account_uuid: String,
    request_id: String,
    accepted: Option<ReceiveDeposit>,
) -> Result<(), ReceiveError> {
    let network = parse_network_and_migrate(&db_path, &network_name)?;
    let outcome = match accepted {
        Some(deposit) => OperationOutcome::Accepted(
            zcash_client_sqlite::wallet::one_time_ivk::swap::ReceiveDeposit {
                address: deposit.address,
                memo: deposit.memo,
                deadline: deposit.deadline_seconds,
            },
        ),
        None => OperationOutcome::Rejected,
    };
    with_db(&db_path, network, &account_uuid, |db, a| {
        Ok(db.finish_receive_operation(a, &request_id, &outcome)?)
    })
}

/// Locks the accepted quote's reservation before exposing provider funding
/// instructions, and returns the instructions to show. Refuses as stale once the
/// deposit deadline has passed by the earlier of this device's clock and the latest
/// block time, or once another request on the same reservation has started.
pub fn start_receive_quote(
    db_path: String,
    network_name: String,
    account_uuid: String,
    request_id: String,
) -> Result<ReceiveDeposit, ReceiveError> {
    let network = parse_network_and_migrate(&db_path, &network_name)?;
    with_db(&db_path, network, &account_uuid, |db, a| {
        let deposit = db.start_receive_operation(a, &request_id, one_time_ivk::now()?)??;
        Ok(ReceiveDeposit {
            address: deposit.address,
            memo: deposit.memo,
            deadline_seconds: deposit.deadline,
        })
    })
}

/// Binds an accepted refund quote's deposit address to the refund key reserved for
/// it, before the quote is shown. Funding requires this record.
pub fn record_swap_refund_quote(
    db_path: String,
    network_name: String,
    account_uuid: String,
    refund_index: u64,
    deposit_address: String,
    deadline_seconds: i64,
) -> Result<(), ReceiveError> {
    let network = parse_network_and_migrate(&db_path, &network_name)?;
    with_db(&db_path, network, &account_uuid, |db, a| {
        Ok(db.record_refund_operation(
            a,
            refund_index,
            &deposit_address,
            deadline_seconds,
            one_time_ivk::now()?,
        )?)
    })
}

/// Records a provider status, requested at `checked_at_seconds`, on the account's swap
/// operations with this deposit address and memo, and reclaims what that makes
/// reclaimable. `incoming` says the swap pays ZEC into the wallet; otherwise it is the
/// refund side of a ZEC deposit. `funded` says the app has its own evidence that the
/// provider saw a deposit, which the status alone implies only from `KNOWN_DEPOSIT_TX`
/// on (see `near_observation`). Swaps without a private address are ignored. Do not call
/// it for a failed status request.
pub fn observe_swap_status(
    db_path: String,
    network_name: String,
    account_uuid: String,
    incoming: bool,
    deposit_address: String,
    deposit_memo: Option<String>,
    status: SwapProviderStatus,
    funded: bool,
    checked_at_seconds: i64,
) -> Result<(), ReceiveError> {
    let network = parse_network_and_migrate(&db_path, &network_name)?;
    if !one_time_ivk::supported(network) {
        return Ok(());
    }
    let purpose = if incoming {
        Purpose::Receive
    } else {
        Purpose::Refund
    };
    let observation = near_observation(purpose, &one_time_ivk::near_status(&status));
    let observation = Observation {
        funded: observation.funded || funded,
        ..observation
    };
    with_db(&db_path, network, &account_uuid, |db, a| {
        db.record_operation_status(
            a,
            &deposit_address,
            deposit_memo.as_deref(),
            observation,
            checked_at_seconds,
        )?;
        Ok(())
    })
}

/// Whether the wallet still scans the one-time key behind `account_uuid`'s swap address
/// `address`. False once the key closed, as when an unpaid incoming reservation is
/// reclaimed, and for any other address. Lets the app stop polling a finished swap's
/// status.
pub fn is_swap_address_scanning(
    db_path: String,
    network_name: String,
    account_uuid: String,
    address: String,
) -> Result<bool, ReceiveError> {
    let network = parse_network_and_migrate(&db_path, &network_name)?;
    if !one_time_ivk::supported(network) {
        return Ok(false);
    }
    with_db(&db_path, network, &account_uuid, |db, a| {
        Ok(one_time_ivk::is_address_scanning(db, network, a, &address)?)
    })
}

/// "Check swap history": ends every software account's discovery pass, so the next
/// sync starts a new one against the directory's current publication and finds a
/// second refund or a late payout that arrived after its key stopped scanning. Once
/// discovery is complete nothing else starts a pass. A discovery run in progress is
/// stopped first, and the call waits for it. The caller then syncs, and
/// [`is_swap_history_checking`] says when the check is done.
pub fn check_swap_history(db_path: String, network_name: String) -> Result<(), ReceiveError> {
    // Without a wallet there is nothing to check; do not create its database.
    if !keys::wallet_exists(&db_path) {
        return Ok(());
    }
    let network = parse_network_and_migrate(&db_path, &network_name)?;
    // Only supported networks run discovery.
    if !one_time_ivk::supported(network) {
        return Ok(());
    }
    Ok(one_time_ivk::recheck_history(&db_path, network)?)
}

/// Whether a swap history check, or a restored wallet's first one, is still running:
/// some software account's discovery is incomplete or has lookups or late payments
/// left. Sync continues it.
pub fn is_swap_history_checking(
    db_path: String,
    network_name: String,
) -> Result<bool, ReceiveError> {
    if !keys::wallet_exists(&db_path) {
        return Ok(false);
    }
    let network = parse_network_and_migrate(&db_path, &network_name)?;
    if !one_time_ivk::supported(network) {
        return Ok(false);
    }
    let db = open_wallet_db_with_timeout(&db_path, network, WALLET_DB_BUSY_TIMEOUT)?;
    Ok(one_time_ivk::history_pending(&db)?)
}
