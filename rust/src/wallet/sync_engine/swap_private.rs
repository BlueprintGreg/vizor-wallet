//! Bounded Receiver PIR work, independent of the ordinary sync task.
//! Network requests never own a database handle. The library fences every committed
//! response by account generation, history revision and local chain identity.
use super::enhancement::transport::{RoutedHttpError, RoutedTransport};
use crate::wallet::{
    db::{
        open_existing_wallet_db_with_timeout, with_wallet_db_write_lock, WalletDatabase,
        WALLET_DB_BUSY_TIMEOUT,
    },
    network::WalletNetwork,
    one_time_ivk,
};
use std::{
    collections::BTreeMap,
    sync::atomic::{AtomicBool, AtomicU64, Ordering},
    time::Duration,
};
use zakura_pir_receiver::{
    receiver_directory::blocks::{Batch, Head},
    receiver_pir::{self, transport::DirectoryClient, AcceptedCoverage},
    DirectoryError, Transport, MAINNET_GENESIS,
};
use zcash_client_backend::data_api::{
    one_time_ivk::restore::{DiscoveryWork, RecoveryToken},
    transparent_ledger::ChainPoint,
    WalletRead as _,
};
use zcash_client_sqlite::AccountUuid;
use zcash_primitives::block::BlockHash;
use zcash_protocol::consensus::{NetworkUpgrade, Parameters};

static RUNNING: AtomicBool = AtomicBool::new(false);
static CANCEL: AtomicU64 = AtomicU64::new(0);

/// Cancels the current bounded worker without deleting its durable queue.
pub(crate) fn cancel_recovery() {
    CANCEL.fetch_add(1, Ordering::SeqCst);
}

/// Releases worker admission even when the future is cancelled or times out.
struct Running;
impl Drop for Running {
    /// Allows the next independent check after this worker has stopped.
    fn drop(&mut self) {
        RUNNING.store(false, Ordering::SeqCst);
    }
}

const DEFAULT_RECEIVER_ORIGIN: &str = "https://receiver-pir.valargroup.dev";

/// Selects the normal service or an explicit debug-only test endpoint.
fn receiver_origin() -> String {
    #[cfg(debug_assertions)]
    if let Ok(origin) = std::env::var("VIZOR_RECEIVER_PIR_URL") {
        return origin;
    }
    DEFAULT_RECEIVER_ORIGIN.into()
}

/// The receiver directory uses the same Tor-aware transport as Vizor's other private
/// services.
struct SwapTransport<'a, F> {
    http: RoutedTransport<'a, F>,
}
impl<'a, F> SwapTransport<'a, F> {
    /// A transport that stops when `should_exit` does.
    fn new(should_exit: &'a F) -> Self {
        Self {
            http: RoutedTransport::new(should_exit),
        }
    }
}
/// Maps a receiver directory failure: a session conflict means its publication changed,
/// and anything else, including overload (HTTP 429), is a retryable transport failure.
fn receiver_error(error: RoutedHttpError) -> DirectoryError {
    match error {
        error if error.is_session_conflict() => DirectoryError::Revision,
        RoutedHttpError::HttpStatus(status) => DirectoryError::Transport(format!("HTTP {status}")),
        RoutedHttpError::Cancelled => DirectoryError::Transport("Cancelled".into()),
        RoutedHttpError::Failed(error) => DirectoryError::Transport(error.to_string()),
    }
}
impl<F: Fn() -> bool> Transport for SwapTransport<'_, F> {
    async fn get(&self, url: &str, limit: usize) -> Result<Vec<u8>, DirectoryError> {
        self.http
            .bytes(http::Method::GET, url, vec![], limit)
            .await
            .map_err(receiver_error)
    }
    async fn post(
        &self,
        url: &str,
        body: Vec<u8>,
        limit: usize,
    ) -> Result<Vec<u8>, DirectoryError> {
        self.http
            .bytes(http::Method::POST, url, body, limit)
            .await
            .map_err(receiver_error)
    }
}

/// Opens an existing wallet only for a short read/commit. A reset cannot recreate it.
fn wallet<T>(
    path: &str,
    network: WalletNetwork,
    generation: u64,
    action: impl FnOnce(&mut WalletDatabase) -> Result<T, String>,
) -> Result<T, String> {
    with_wallet_db_write_lock("swap.recovery", || {
        if CANCEL.load(Ordering::SeqCst) != generation {
            return Err("Swap recovery was cancelled.".into());
        }
        let mut db = open_existing_wallet_db_with_timeout(path, network, WALLET_DB_BUSY_TIMEOUT)?;
        action(&mut db)
    })
}

/// Compares estimated remaining filter bodies with the actual unfinished address set.
/// Setup is needed only when a route expects lookups. Receipt proofs and enhancement
/// are required by either route and are not avoided by choosing direct queries.
fn filters_cheaper(
    blocks: u32,
    sample_bytes: usize,
    matches: usize,
    addresses: usize,
    setup: usize,
    query: usize,
) -> bool {
    let filter_bytes = u128::from(blocks) * sample_bytes as u128;
    let likely_queries = (u128::from(blocks) * matches as u128).min(addresses as u128);
    let filtered = filter_bytes
        + likely_queries * query as u128
        + if likely_queries > 0 { setup as u128 } else { 0 };
    let direct = addresses as u128 * query as u128 + if addresses > 0 { setup as u128 } else { 0 };
    filtered < direct
}

/// Runs one bounded account round. The caller schedules it separately from block sync.
/// A timeout leaves durable work pending and cannot be mistaken for an empty history.
pub(crate) async fn recover(
    path: &str,
    network: WalletNetwork,
    manual: Option<Option<u64>>,
) -> Result<(), String> {
    if !one_time_ivk::supported(network) {
        return Ok(());
    }
    if RUNNING
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return Err("A swap recovery check is already running.".into());
    }
    let _running = Running;
    let generation = CANCEL.load(Ordering::SeqCst);
    let stop = || {
        CANCEL.load(Ordering::SeqCst) != generation
            || crate::wallet::sync::proposal_locks::is_shutting_down()
    };
    let transport = SwapTransport::new(&stop);
    tokio::time::timeout(
        Duration::from_secs(45),
        recover_with_transport(
            path,
            network,
            manual,
            &receiver_origin(),
            &transport,
            generation,
        ),
    )
    .await
    .map_err(|_| {
        "Swap recovery is still pending. It will continue on the next check.".to_string()
    })?
}

/// Fetches shared public material once, then keeps each account's queue and progress separate.
async fn recover_with_transport<T: Transport>(
    path: &str,
    network: WalletNetwork,
    manual: Option<Option<u64>>,
    origin: &str,
    transport: &T,
    generation: u64,
) -> Result<(), String> {
    let accounts = wallet(path, network, generation, |db| {
        one_time_ivk::reconcile_enabled(db, network)?;
        one_time_ivk::software_accounts(db)
    })?;
    let mut active = Vec::new();
    let mut discovery_enabled = false;
    for account in accounts {
        let state = wallet(path, network, generation, |db| {
            db.one_time_recovery(account, one_time_ivk::now()?)
                .map_err(|e| e.to_string())
        })?;
        if state.enabled || !state.lookups.is_empty() || !state.witnesses.is_empty() {
            discovery_enabled |= state.enabled;
            active.push(account);
        }
    }
    if active.is_empty() {
        return Ok(());
    }
    let manifest = DirectoryClient::fetch_manifest(origin, &transport)
        .await
        .map_err(|e| e.to_string())?;
    let publication = zakura_pir_receiver::publication(&manifest).map_err(|e| e.to_string())?;
    let required_start = network
        .activation_height(NetworkUpgrade::Nu6_3)
        .ok_or("Ironwood is unavailable")?;
    let accepted = AcceptedCoverage {
        genesis: MAINNET_GENESIS,
        required_start: required_start.into(),
        height: publication.end.height.into(),
        hash: publication.end.hash,
    };
    accepted
        .check(&manifest.directory)
        .map_err(|e| e.to_string())?;
    let head = if discovery_enabled {
        tokio::time::timeout(
            Duration::from_secs(2),
            DirectoryClient::fetch_block_head(origin, &transport, &MAINNET_GENESIS),
        )
        .await
        .ok()
        .and_then(Result::ok)
    } else {
        None
    };
    let rows = manifest.directory.rows;
    let setup = receiver_pir::public_bytes(rows).map_err(|e| e.to_string())?;
    let query = receiver_pir::query_bytes(rows)
        .and_then(|n| receiver_pir::response_bytes(rows).map(|m| n + m))
        .map_err(|e| e.to_string())?;
    let mut batches = BTreeMap::new();
    let mut client = None;
    let mut proofs = None;
    let mut failure = None;
    let account_budget = Duration::from_secs(40).div_f64(active.len() as f64);
    let hint_timeout = (account_budget / 4).min(Duration::from_secs(2));
    for account in active {
        let result = tokio::time::timeout(account_budget, async {
            let accepted_locally = wallet(path, network, generation, |db| {
                db.begin_one_time_recovery(account, publication, false, one_time_ivk::now()?)
                    .map_err(|e| e.to_string())
            })?;
            if !accepted_locally {
                return if manual.is_some() {
                    Err("Swap history check has not started. Wait for wallet sync to catch up and try again.".into())
                } else {
                    Ok(())
                };
            }
            if let Some(bound) = manual {
                wallet(path, network, generation, |db| {
                    db.check_one_time_history(account, publication, bound, one_time_ivk::now()?)
                        .map(|_| ())
                        .map_err(|e| e.to_string())
                })?;
            }
            let (state, (token, receivers), count, scanned) =
                wallet(path, network, generation, |db| {
                    Ok((
                        db.one_time_recovery(account, one_time_ivk::now()?)
                            .map_err(|e| e.to_string())?,
                        db.one_time_receivers(account).map_err(|e| e.to_string())?,
                        db.one_time_direct_query_count(account)
                            .map_err(|e| e.to_string())?,
                        db.block_fully_scanned()
                            .map_err(|e| e.to_string())?
                            .map(|b| b.block_height()),
                    ))
                })?;
            if state.enabled {
                let range = head.as_ref().and_then(|head| {
                    let from = u32::from(state.filter_frontier?.height).checked_add(1)?;
                    let to = head.tip.height.min(u32::from(scanned?));
                    (head.revision == token.history_revision && from >= head.first && from <= to)
                        .then_some((head, from, to))
                });
                let mut direct = state.filter_frontier.is_none()
                    || head.as_ref().is_none_or(|h| {
                        h.revision != token.history_revision
                            || state
                                .filter_frontier
                                .is_some_and(|f| u32::from(f.height).saturating_add(1) < h.first)
                    });
                if let Some((head, from, to)) = range {
                    let filtered: Result<bool, String> = async {
                        // Sample bytes are shared by accounts and committed even when direct
                        // queries win. A positive on a completed address must not be lost.
                        if !batches.contains_key(&(from, 1)) {
                            let sample = filter_batch(
                                origin, transport, head, from, 1, hint_timeout,
                            ).await?;
                            batches.insert((from, 1), sample);
                        }
                        let sample = batches.get(&(from, 1)).expect("inserted");
                        let receivers_bytes: Vec<_> =
                            receivers.iter().map(|r| r.receiver).collect();
                        let matches = sample
                            .matches(0, &receivers_bytes)
                            .map_err(|e| e.to_string())?
                            .into_iter()
                            .filter(|hit| *hit)
                            .count();
                        let cost = sample.encode().map_err(|e| e.to_string())?.len();
                        wallet(path, network, generation, |db| {
                            apply_filters(db, account, token, head.revision, sample, &receivers)
                        })?;
                        if !filters_cheaper(to - from + 1, cost, matches, count, setup, query) {
                            return Ok(false);
                        }
                        if from < to {
                            let next = from + 1;
                            let limit = (to - from).min(256);
                            if !batches.contains_key(&(next, limit)) {
                                let batch = filter_batch(
                                    origin, transport, head, next, limit, hint_timeout,
                                ).await?;
                                batches.insert((next, limit), batch);
                            }
                            wallet(path, network, generation, |db| {
                                apply_filters(
                                    db,
                                    account,
                                    token,
                                    head.revision,
                                    batches.get(&(next, limit)).expect("inserted"),
                                    &receivers,
                                )
                            })?;
                        }
                        Ok(true)
                    }
                    .await;
                    direct = match filtered {
                        Ok(used_filters) => !used_filters,
                        Err(error) => {
                            log::debug!(
                                "Receiver filters unavailable, retaining pending work: {error}"
                            );
                            true
                        }
                    };
                }
                if direct {
                    wallet(path, network, generation, |db| {
                        db.begin_one_time_recovery(account, publication, true, one_time_ivk::now()?)
                            .map(|_| ())
                            .map_err(|e| e.to_string())
                    })?;
                }
            }
            for _ in 0..16 {
                let state = wallet(path, network, generation, |db| {
                    db.one_time_recovery(account, one_time_ivk::now()?)
                        .map_err(|e| e.to_string())
                })?;
                if state.lookups.is_empty() && state.witnesses.is_empty() {
                    break;
                }
                if client.is_none() {
                    client = Some(
                        DirectoryClient::connect_manifest(
                            origin,
                            transport,
                            accepted,
                            manifest.clone(),
                        )
                        .await
                        .map_err(|e| e.to_string())?,
                    );
                }
                let client = client.as_ref().expect("connected");
                if let Some(work) = state.lookups.first() {
                    if work.through > publication.end.height {
                        break;
                    }
                    match zakura_pir_receiver::lookup(client, work).await {
                        Ok(page) => {
                            wallet(path, network, generation, |db| {
                                db.record_one_time_lookup(
                                    account,
                                    work,
                                    &page,
                                    one_time_ivk::now()?,
                                )
                                .map(|_| ())
                                .map_err(|e| e.to_string())
                            })?;
                        }
                        Err(error) => {
                            wallet(path, network, generation, |db| {
                                db.defer_one_time_lookup(account, work, one_time_ivk::now()?)
                                    .map_err(|e| e.to_string())
                            })?;
                            return Err(error.to_string());
                        }
                    }
                } else if let Some(request) = state.witnesses.first() {
                    if proofs.is_none() {
                        proofs = Some(
                            zakura_pir_receiver::witnesses(client)
                                .await
                                .map_err(|e| e.to_string())?,
                        );
                    }
                    let siblings = proofs
                        .as_ref()
                        .expect("loaded")
                        .path(request.position, request.cmx)
                        .map_err(|e| e.to_string())?;
                    wallet(path, network, generation, |db| {
                        db.record_one_time_witness(
                            account,
                            state.token,
                            *request,
                            ChainPoint {
                                height: publication.end.height,
                                hash: BlockHash(publication.end.hash),
                            },
                            siblings,
                            one_time_ivk::now()?,
                        )
                        .map(|_| ())
                        .map_err(|e| e.to_string())
                    })?;
                }
            }
            Ok::<(), String>(())
        })
        .await
        .unwrap_or_else(|_| Err("Swap account recovery remains pending.".into()));
        if let Err(error) = result {
            failure.get_or_insert(error);
            if CANCEL.load(Ordering::SeqCst) != generation {
                break;
            }
        }
    }
    failure.map_or(Ok(()), Err)
}

/// Commits all matched keys with their contiguous canonical blocks, including old paid keys.
fn apply_filters(
    db: &mut WalletDatabase,
    account: AccountUuid,
    token: RecoveryToken,
    revision: u64,
    batch: &Batch,
    receivers: &[DiscoveryWork],
) -> Result<(), String> {
    let receiver_bytes: Vec<_> = receivers.iter().map(|r| r.receiver).collect();
    let mut hits = Vec::new();
    let mut blocks = Vec::new();
    for (i, filter) in batch.filters().iter().enumerate() {
        blocks.push(ChainPoint {
            height: filter.block().height.into(),
            hash: BlockHash(filter.block().hash),
        });
        for (receiver, hit) in receivers.iter().zip(
            batch
                .matches(i, &receiver_bytes)
                .map_err(|e| e.to_string())?,
        ) {
            if hit && !hits.contains(&receiver.key) {
                hits.push(receiver.key);
            }
        }
    }
    if !db
        .record_one_time_filters(account, token, revision, &blocks, &hits)
        .map_err(|e| e.to_string())?
    {
        return Err(
            "Receiver filters no longer match the wallet's chain or recovery state.".into(),
        );
    }
    Ok(())
}

/// Bounds optional hints independently so an outage leaves time for direct PIR work.
async fn filter_batch<T: Transport>(
    origin: &str,
    transport: &T,
    head: &Head,
    from: u32,
    limit: u32,
    timeout: Duration,
) -> Result<Batch, String> {
    tokio::time::timeout(
        timeout,
        DirectoryClient::fetch_block_batch(origin, &transport, head, from, limit),
    )
    .await
    .map_err(|_| "Receiver filter request timed out.".to_string())?
    .map_err(|e| e.to_string())
}
