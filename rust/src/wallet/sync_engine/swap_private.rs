//! One-time key discovery and swap provider seen sets through the receiver directory.
//! Discovery's rules, chain acceptance and note mutation live in `zakura_pir_receiver`
//! and the wallet library; this module supplies Vizor's routed transport, service
//! origin, write lock and run budgets.
use super::enhancement::transport::{RoutedHttpError, RoutedTransport};
use super::WalletDatabase;
use crate::wallet::{db::with_wallet_db_write_lock, network::WalletNetwork};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;
use zakura_one_time_ivk::swap::provider_read_is_current;
use zakura_pir_receiver::{DirectoryError, Seen, Transport, WriteLock, MAINNET_GENESIS};
use zcash_client_backend::data_api::one_time_ivk::restore::{
    DiscoveryStatus, OneTimeIvkRestoreRead as _,
};

/// The receiver directory's default origin. Use explicit HTTPS origins and never follow
/// service redirects.
const DEFAULT_RECEIVER_ORIGIN: &str = "https://receiver-pir.valargroup.dev";
/// Debug builds only: overrides [`DEFAULT_RECEIVER_ORIGIN`], like Enhance's
/// `VIZOR_ENHANCE_PIR_URL`. Release builds never read it.
#[cfg(debug_assertions)]
const RECEIVER_ORIGIN_ENV: &str = "VIZOR_RECEIVER_PIR_URL";
/// Time discovery may take before the scan's first batch. What it does not reach runs
/// after the sync.
pub(super) const BEFORE_SCAN_BUDGET: Duration = Duration::from_secs(60);
/// Time discovery may take after a sync. What it does not reach runs next sync.
pub(super) const AFTER_SYNC_BUDGET: Duration = Duration::from_secs(180);
/// Time the seen set download before an issuance may take.
const SEEN_BUDGET: Duration = Duration::from_secs(20);
/// Debug builds only: the genesis block hash of the regtest end-to-end tests' chain, as
/// `getblockhash 0` displays it, which their receiver directory commits to. Release
/// builds never read it.
const RECEIVER_GENESIS_ENV: &str = "VIZOR_RECEIVER_PIR_GENESIS";
/// The receiver directory's origin: [`DEFAULT_RECEIVER_ORIGIN`], or in a debug build
/// a configured override.
fn receiver_origin() -> String {
    #[cfg(debug_assertions)]
    if let Ok(origin) = std::env::var(RECEIVER_ORIGIN_ENV) {
        return origin;
    }
    DEFAULT_RECEIVER_ORIGIN.into()
}
/// The genesis block hash, in internal byte order, that receiver directory publications
/// must commit to: mainnet's, or on regtest in a debug build, the configured chain's
/// (see [`RECEIVER_GENESIS_ENV`]).
fn receiver_genesis(network: WalletNetwork) -> Result<[u8; 32], String> {
    if cfg!(debug_assertions) && network == WalletNetwork::Regtest {
        if let Ok(displayed) = std::env::var(RECEIVER_GENESIS_ENV) {
            let mut genesis: [u8; 32] = hex::decode(displayed.trim())
                .ok()
                .and_then(|bytes| bytes.try_into().ok())
                .ok_or("Invalid receiver directory genesis")?;
            genesis.reverse();
            return Ok(genesis);
        }
    }
    Ok(MAINNET_GENESIS)
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
/// Debug builds only: a plaintext transport for a receiver directory on the loopback
/// interface, which the regtest end-to-end tests serve in process. Every other origin,
/// and every release build, uses [`SwapTransport`].
#[cfg(debug_assertions)]
struct LoopbackTransport {
    client: hyper_util::client::legacy::Client<
        hyper_util::client::legacy::connect::HttpConnector,
        http_body_util::Full<bytes::Bytes>,
    >,
}
#[cfg(debug_assertions)]
impl LoopbackTransport {
    /// A transport for `origin` if it is a plaintext loopback origin.
    fn for_origin(origin: &str) -> Option<Self> {
        let loopback = ["http://127.0.0.1:", "http://localhost:"]
            .iter()
            .any(|prefix| origin.starts_with(prefix));
        loopback.then(|| Self {
            client: hyper_util::client::legacy::Client::builder(
                hyper_util::rt::TokioExecutor::new(),
            )
            .build_http(),
        })
    }
    /// Sends one request, failing like [`SwapTransport`] does.
    async fn send(
        &self,
        method: http::Method,
        url: &str,
        body: Vec<u8>,
        limit: usize,
    ) -> Result<Vec<u8>, DirectoryError> {
        use http_body_util::BodyExt as _;
        let request = http::Request::builder()
            .method(method)
            .uri(url)
            .body(http_body_util::Full::new(bytes::Bytes::from(body)))
            .map_err(|e| DirectoryError::Transport(e.to_string()))?;
        let response = self
            .client
            .request(request)
            .await
            .map_err(|e| DirectoryError::Transport(e.to_string()))?;
        if !response.status().is_success() {
            return Err(receiver_error(RoutedHttpError::HttpStatus(
                response.status().as_u16(),
            )));
        }
        let body = http_body_util::Limited::new(response.into_body(), limit)
            .collect()
            .await
            .map_err(|e| DirectoryError::Transport(e.to_string()))?;
        Ok(body.to_bytes().to_vec())
    }
}
/// The receiver directory's transport: [`SwapTransport`], or in a debug build a
/// [`LoopbackTransport`] for a loopback origin.
enum ReceiverTransport<'a, F> {
    Routed(SwapTransport<'a, F>),
    #[cfg(debug_assertions)]
    Loopback(LoopbackTransport),
}
impl<'a, F> ReceiverTransport<'a, F> {
    /// The transport to `origin`, stopping when `should_exit` does.
    fn new(origin: &str, should_exit: &'a F) -> Self {
        #[cfg(debug_assertions)]
        if let Some(loopback) = LoopbackTransport::for_origin(origin) {
            return Self::Loopback(loopback);
        }
        #[cfg(not(debug_assertions))]
        let _ = origin;
        Self::Routed(SwapTransport::new(should_exit))
    }
}
impl<F: Fn() -> bool> Transport for ReceiverTransport<'_, F> {
    async fn get(&self, url: &str, limit: usize) -> Result<Vec<u8>, DirectoryError> {
        match self {
            Self::Routed(transport) => transport.get(url, limit).await,
            #[cfg(debug_assertions)]
            Self::Loopback(transport) => {
                transport.send(http::Method::GET, url, vec![], limit).await
            }
        }
    }
    async fn post(
        &self,
        url: &str,
        body: Vec<u8>,
        limit: usize,
    ) -> Result<Vec<u8>, DirectoryError> {
        match self {
            Self::Routed(transport) => transport.post(url, body, limit).await,
            #[cfg(debug_assertions)]
            Self::Loopback(transport) => transport.send(http::Method::POST, url, body, limit).await,
        }
    }
}
/// Holds the wallet write lock for each of discovery's writes.
struct WalletWriteLock;
impl WriteLock for WalletWriteLock {
    fn write<T>(&self, label: &'static str, write: impl FnOnce() -> T) -> T {
        with_wallet_db_write_lock(label, write)
    }
}

/// The last seen sets [`fetch_seen`] downloaded, with the network and origin they came
/// from, so a quote request soon after an issuance checks the same sets.
static LAST_SEEN: Mutex<Option<(WalletNetwork, String, Arc<Seen>)>> = Mutex::new(None);

/// Downloads the receiver directory's swap provider seen sets, which issuance checks
/// (see `prepare_receive_reservation` and `reserve_refund_key`). Fails where one-time
/// IVKs are not `supported`, or when the directory does not answer within
/// [`SEEN_BUDGET`]. The caller then passes no set, and the wallet refuses whatever
/// needs one as `SeenUnavailable`.
pub(crate) async fn fetch_seen(network: WalletNetwork) -> Result<Arc<Seen>, String> {
    if !crate::wallet::one_time_ivk::supported(network) {
        return Err("Private swaps are not available on this network".into());
    }
    let genesis =
        receiver_genesis(network).map_err(|e| format!("Swap seen set unavailable: {e}"))?;
    let should_exit = || false;
    let origin = receiver_origin();
    let transport = ReceiverTransport::new(&origin, &should_exit);
    let fetch = zakura_pir_receiver::fetch_seen(&origin, &transport, genesis);
    let seen = match tokio::time::timeout(SEEN_BUDGET, fetch).await {
        Ok(Ok(seen)) => Arc::new(seen),
        Ok(Err(e)) => return Err(format!("Swap seen set unavailable: {e}")),
        Err(_) => return Err("Swap seen set unavailable: timed out".into()),
    };
    if let Ok(mut last) = LAST_SEEN.lock() {
        *last = Some((network, origin, seen.clone()));
    }
    Ok(seen)
}

/// The seen sets [`fetch_seen`] last downloaded for `network`, if the wallet still
/// counts them as current at `now`, or else a new download.
pub(crate) async fn current_seen(network: WalletNetwork, now: i64) -> Result<Arc<Seen>, String> {
    let origin = receiver_origin();
    let cached = LAST_SEEN.lock().ok().and_then(|last| {
        last.as_ref()
            .filter(|(n, o, s)| {
                *n == network && *o == origin && provider_read_is_current(s.until(), now)
            })
            .map(|(_, _, s)| s.clone())
    });
    match cached {
        Some(seen) => Ok(seen),
        None => fetch_seen(network).await,
    }
}

/// Orders one wallet's discovery runs against "Check swap history" resets. A run holds
/// its wallet's gate from its first read to its last write. A reset that landed in
/// between would let the run write back the pass it read, finish it, and report the
/// check done without the newer publication. A reset asks the run to stop and waits.
struct DiscoveryGate {
    lock: Arc<tokio::sync::Mutex<()>>,
    /// Resets waiting for or holding the gate. A run stops while any is.
    rechecks: AtomicUsize,
}

/// Each wallet's [`DiscoveryGate`], by database path.
static GATES: Mutex<BTreeMap<String, Arc<DiscoveryGate>>> = Mutex::new(BTreeMap::new());

/// The [`DiscoveryGate`] of the wallet at `db_path`.
fn gate(db_path: &str) -> Arc<DiscoveryGate> {
    GATES
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .entry(db_path.to_owned())
        .or_insert_with(|| {
            Arc::new(DiscoveryGate {
                lock: Arc::new(tokio::sync::Mutex::new(())),
                rechecks: AtomicUsize::new(0),
            })
        })
        .clone()
}

/// A discovery run's hold on its wallet's [`DiscoveryGate`].
pub(crate) struct DiscoveryRun {
    gate: Arc<DiscoveryGate>,
    _held: tokio::sync::OwnedMutexGuard<()>,
}

impl DiscoveryRun {
    /// Waits until no reset or other run holds the gate of the wallet at `db_path`.
    pub(crate) async fn start(db_path: &str) -> Self {
        let gate = gate(db_path);
        let held = gate.lock.clone().lock_owned().await;
        Self { gate, _held: held }
    }

    /// Whether a reset is waiting for this run, which should then stop.
    pub(crate) fn preempted(&self) -> bool {
        self.gate.rechecks.load(Ordering::SeqCst) > 0
    }
}

/// Runs `reset` while no discovery run holds the gate of the wallet at `db_path`,
/// first asking a running one to stop (see [`DiscoveryGate`]). Blocks the calling
/// thread, so never call it from async code.
pub(crate) fn exclusive_of_discovery<T>(db_path: &str, reset: impl FnOnce() -> T) -> T {
    /// Withdraws a reset's stop request when dropped, even on a panic.
    struct Waiting<'a>(&'a AtomicUsize);
    impl Drop for Waiting<'_> {
        fn drop(&mut self) {
            self.0.fetch_sub(1, Ordering::SeqCst);
        }
    }
    let gate = gate(db_path);
    gate.rechecks.fetch_add(1, Ordering::SeqCst);
    let waiting = Waiting(&gate.rechecks);
    let held = gate.lock.blocking_lock();
    let result = reset();
    // Withdrawn before release, so a run queued behind this reset is not stopped.
    drop(waiting);
    drop(held);
    result
}

/// Whether a discovery run for an account in `status` would do anything: the same test
/// `zakura_pir_receiver::discover` makes before its first request.
fn due(status: &Option<DiscoveryStatus>) -> bool {
    status.as_ref().is_some_and(|s| {
        s.publication.is_none()
            || s.enumeration.is_some()
            || !s.lookups.is_empty()
            || !s.witnesses.is_empty()
    })
}

/// Runs discovery once for every software account, for at most `budget`, and returns
/// whether any account had work due, so wallet data may have changed. Sync runs it
/// before the scan's first batch, so lookups become scan hints, and again after the
/// sync, for late payments, and only where one-time IVKs are `supported`. An account
/// with nothing due makes no request. Every step commits on its own, so stopping at the
/// budget or on `should_exit` is safe; failures are logged and retried on a later run.
/// The run holds the wallet's [`DiscoveryGate`] and stops early, reporting a possible
/// change, when a swap history check needs it.
pub(super) async fn discover(
    db: &mut WalletDatabase,
    db_path: &str,
    network: WalletNetwork,
    budget: Duration,
    should_exit: &impl Fn() -> bool,
) -> bool {
    let run = tokio::select! {
        biased;
        _ = super::watch_for_exit(should_exit) => return false,
        run = DiscoveryRun::start(db_path) => run,
    };
    let stop = || should_exit() || run.preempted();
    let result = tokio::select! {
        biased;
        _ = super::watch_for_exit(&stop) => return !should_exit(),
        result = tokio::time::timeout(budget, discover_accounts(db, network, &stop)) => {
            result.unwrap_or_else(|_| Err("time budget reached".to_owned()))
        }
    };
    match result {
        Ok(worked) => worked,
        Err(e) => {
            log::warn!("One-time key discovery deferred: {e}");
            true
        }
    }
}

/// The body of [`discover`]. An account whose run fails does not stop the others.
async fn discover_accounts(
    db: &mut WalletDatabase,
    network: WalletNetwork,
    should_exit: &impl Fn() -> bool,
) -> Result<bool, String> {
    let origin = receiver_origin();
    let transport = ReceiverTransport::new(&origin, should_exit);
    let genesis = receiver_genesis(network)?;
    let mut worked = false;
    for account in crate::wallet::one_time_ivk::software_accounts(db)? {
        let now = crate::wallet::one_time_ivk::now()?;
        let status = db
            .one_time_discovery(account, now)
            .map_err(|e| e.to_string())?;
        if !due(&status) {
            continue;
        }
        worked = true;
        let found = zakura_pir_receiver::discover(
            db,
            &network,
            account,
            genesis,
            &origin,
            &transport,
            &WalletWriteLock,
            now,
        )
        .await;
        match found {
            Ok(found) => {
                // Keys identify the wallet's swaps, so only the reasons are logged.
                for (_, e) in &found.failed {
                    log::warn!("One-time key lookup deferred: {e}");
                }
                if !found.complete || found.lookups > 0 || found.witnesses > 0 {
                    log::info!(
                        "One-time key discovery continues: {} lookups, {} late payments left",
                        found.lookups,
                        found.witnesses
                    );
                }
            }
            Err(e) => log::warn!("One-time key discovery deferred: {e}"),
        }
    }
    Ok(worked)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn receiver_overload_is_retryable_and_conflicts_mean_a_new_publication() {
        assert!(matches!(
            receiver_error(RoutedHttpError::HttpStatus(429)),
            DirectoryError::Transport(_)
        ));
        for status in [409, 410] {
            assert!(matches!(
                receiver_error(RoutedHttpError::HttpStatus(status)),
                DirectoryError::Revision
            ));
        }
    }

    /// Reads the live directory's seen sets, as issuance does, and reuses them while
    /// they are current.
    #[tokio::test]
    #[ignore = "requires the live receiver directory"]
    async fn issuance_reads_the_live_seen_sets() {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let seen = fetch_seen(WalletNetwork::Main).await.unwrap();
        assert!(seen.since() < seen.until());
        assert_eq!(seen.contains(&[[0; 43]]).len(), 1);
        let again = current_seen(WalletNetwork::Main, seen.until())
            .await
            .unwrap();
        assert!(Arc::ptr_eq(&seen, &again));
    }
}
