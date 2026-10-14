//! Exercises the production scheduler with the real v7 client and a scripted
//! service. Storage is faked here: wallet record authentication has its own tests.
use super::super::transport::{receive_response, RoutedHttpError, HTTP_TIMEOUT};
use super::coordinator::{EnhancementEffects, RecoveryWallet, RoutedWork, MAX_LOGICAL_ROWS};
use super::{EnhancePirRunError, RoutedPayloadEnhancement};
use crate::wallet::{network::WalletNetwork, sync_engine::SyncError};
use base64::Engine;
use bytes::Bytes;
use futures::StreamExt;
use http_body_util::Full;
use sha2::{Digest, Sha256};
use std::{
    cell::{Cell, RefCell},
    collections::VecDeque,
    rc::Rc,
    time::Duration,
};
use zakura_pir_enhance::{
    transport::{self, BoundedBody, PendingClient},
    types::*,
    wallet::Acceptance,
    AcceptedAnchor, ClientError, ClientResourceLimits, GenerationAcceptance,
};
use zcash_client_backend::data_api::{
    enhance_pir::{
        EnhancePirRequest, EnhancePirStoreResult, EnhancePirSuspension, EnhancePirWork,
        IronwoodEnhanceDiscoveryRequest, IronwoodEnhanceRequestId,
    },
    PublicTransactionEnhancementRequest,
};
use zcash_primitives::{block::BlockHash, transaction::TxId};
use zcash_protocol::consensus::BlockHeight;

struct Service {
    manifest: RefCell<Manifest>,
    statuses: RefCell<VecDeque<Option<u16>>>,
    init_count: Cell<usize>,
    session_count: Cell<usize>,
    posts: RefCell<Vec<QueryBinding>>,
    cancelled: Cell<bool>,
    cancel_on_refresh: Cell<bool>,
    fail_refresh: Cell<bool>,
    /// Query replies (counted from zero, in the order they are asked) whose
    /// row arrives and decodes, but whose every record carries reserved flag
    /// bits, so none of them decodes as a record.
    unreadable_posts: RefCell<std::collections::BTreeSet<usize>>,
}

/// A reply body after the binding header whose every plaintext coefficient
/// decodes as `0xffff` under the fake's all-zero public material: a whole row
/// of `0xff` bytes, which sets every record's reserved flag bits.
fn unreadable_row(len: usize) -> Vec<u8> {
    let words = (len * 8) / 22;
    let mut body = ipir_sp::bits::u64s_to_contiguous_bytes(&vec![0xffff << 6; words], 22);
    body.resize(len, 0);
    body
}

impl Service {
    fn new(statuses: impl IntoIterator<Item = Option<u16>>) -> Self {
        let coverage = Lifecycle::default()
            .coverage(100, Geometry::default())
            .unwrap();
        let shard = &coverage.shards[0];
        let public = public_params(shard.logical_rows);
        let manifest = Manifest {
            recovery_epoch: 0,
            placement_revision: 1,
            domain_recovery_epochs: [(0, "0".into())].into(),
            schema_version: SCHEMA_VERSION,
            protocol_revision: PROTOCOL_REVISION.into(),
            network: "main".into(),
            pool: "ironwood".into(),
            generation: 1,
            anchor_height: 3428143,
            anchor_block_hash: "42".repeat(32),
            geometry: Geometry::default(),
            sessions: vec![SessionRef {
                shard_id: shard.id,
                public_params_sha256: hex::encode(Sha256::digest(&public)),
                parameter_id: parameter_id(shard.logical_rows).unwrap(),
            }],
            unit_identities: [(
                shard.id,
                shard
                    .units
                    .iter()
                    .map(|unit| UnitIdentity {
                        recovery_epoch: 0,
                        table: "enhance".into(),
                        shard_id: shard.id,
                        local_row_start: unit.local_row_start,
                        allocated_rows: unit.allocated_rows,
                        setup_sha256: hex::encode(Sha256::digest(setup_seed(shard.id))),
                        parameter_id: unit_parameter_id(unit.allocated_rows).unwrap(),
                        content_sha256: "00".repeat(32),
                    })
                    .collect(),
            )]
            .into(),
            coverage,
        };
        manifest.validate().unwrap();
        Self {
            manifest: RefCell::new(manifest),
            statuses: RefCell::new(statuses.into_iter().collect()),
            init_count: Cell::new(0),
            session_count: Cell::new(0),
            posts: RefCell::new(vec![]),
            cancelled: Cell::new(false),
            cancel_on_refresh: Cell::new(false),
            fail_refresh: Cell::new(false),
            unreadable_posts: RefCell::new(Default::default()),
        }
    }
}

fn public_params(rows: u64) -> Vec<u8> {
    vec![0; session_public_len(rows).unwrap()]
}

impl transport::Transport for Service {
    async fn execute(
        &self,
        request: transport::Request,
    ) -> Result<transport::ResponseBody, ClientError> {
        assert!(!self.cancelled.get(), "network dispatch after cancellation");
        let bytes = if request.url.ends_with("/init") {
            self.init_count.set(self.init_count.get() + 1);
            if self.init_count.get() > 1 {
                if self.fail_refresh.get() {
                    return Err(ClientError::HttpStatus(503));
                }
                // Rotate routing while keeping the anchor and coverage unchanged.
                self.manifest.borrow_mut().generation += 1;
                if self.cancel_on_refresh.get() {
                    self.cancelled.set(true);
                }
            }
            serde_json::to_vec(&*self.manifest.borrow()).unwrap()
        } else if request.url.contains("/session/") {
            self.session_count.set(self.session_count.get() + 1);
            let m = self.manifest.borrow();
            let shard = &m.coverage.shards[0];
            assert!(request
                .url
                .ends_with(&hex::encode(m.session_id(shard.id).unwrap())));
            serde_json::to_vec(&ShardSession {
                session_id: hex::encode(m.session_id(shard.id).unwrap()),
                generation: m.generation,
                shard_id: shard.id,
                params: parameters(shard.logical_rows).unwrap(),
                public_params_base64: base64::engine::general_purpose::STANDARD
                    .encode(public_params(shard.logical_rows)),
            })
            .unwrap()
        } else {
            assert!(request.url.ends_with("/query"));
            let binding = QueryBinding::decode(&request.body).unwrap();
            self.posts.borrow_mut().push(binding.clone());
            if let Some(Some(status)) = self.statuses.borrow_mut().pop_front() {
                return Err(ClientError::HttpStatus(status));
            }
            let m = self.manifest.borrow();
            assert_eq!(
                binding.generation, m.generation,
                "query did not rebind to refreshed routing"
            );
            let mut response = binding.encode();
            let len = response_len(m.coverage.shards[0].logical_rows).unwrap();
            if self
                .unreadable_posts
                .borrow()
                .contains(&(self.posts.borrow().len() - 1))
            {
                let header = response.len();
                response.extend(unreadable_row(len - header));
            }
            response.resize(len, 0);
            response
        };
        let mut body = request.response_body();
        body.extend(&bytes)?;
        Ok(body.finish())
    }
}

#[derive(Clone, Copy)]
enum Anchor {
    Accepted,
    Waiting,
    Mismatch,
}
const PROTECTED: TxId = TxId::from_bytes([7; 32]);
const ORDINARY: TxId = TxId::from_bytes([8; 32]);

fn public_request(txid: TxId) -> PublicTransactionEnhancementRequest {
    PublicTransactionEnhancementRequest::new(txid)
}

/// Routes like the wallet: a transaction is public or private, never both.
struct Wallet {
    pending: Vec<EnhancePirRequest>,
    /// Rediscovery and suspensions, which are private but not queryable.
    other: Vec<EnhancePirWork>,
    public: Vec<TxId>,
    applied: Vec<u64>,
    reads: Cell<usize>,
    refreshed_anchor: Anchor,
    /// An authenticated positive transparent flag at this position.
    transparent_at: Option<u64>,
    /// Cancellation requested while a record is being applied.
    cancel_on_apply: Option<Rc<Cell<bool>>>,
    /// Each batch of requests reported as unreadable, in order.
    unreadable: Vec<Vec<EnhancePirRequest>>,
    /// Content failures per request; at three the request is suspended, as
    /// the wallet's session does.
    failures: std::collections::BTreeMap<EnhancePirRequest, u32>,
    /// A record at this position fails wallet authentication.
    reject_at: Option<u64>,
}
impl Wallet {
    fn content_failure(&mut self, request: EnhancePirRequest) {
        let count = self.failures.entry(request).or_default();
        *count += 1;
        if *count == 3 {
            self.pending.retain(|r| *r != request);
            self.other
                .push(EnhancePirWork::Suspended(EnhancePirSuspension::Rejected(
                    request,
                )));
        }
    }
}
impl Wallet {
    fn new(positions: &[u64]) -> Self {
        Self {
            pending: positions.iter().map(|&p| request(p)).collect(),
            other: vec![],
            public: vec![],
            applied: vec![],
            reads: Cell::new(0),
            refreshed_anchor: Anchor::Accepted,
            transparent_at: None,
            cancel_on_apply: None,
            unreadable: vec![],
            failures: Default::default(),
            reject_at: None,
        }
    }
}
fn request(position: u64) -> EnhancePirRequest {
    EnhancePirRequest::new(
        position.into(),
        IronwoodEnhanceRequestId::new(PROTECTED, position as u32),
    )
}
impl RecoveryWallet for Wallet {
    fn work(&self) -> Result<RoutedWork, EnhancePirRunError> {
        self.reads.set(self.reads.get() + 1);
        let work = RoutedWork {
            public: self.public.iter().copied().map(public_request).collect(),
            private: self
                .pending
                .iter()
                .copied()
                .map(EnhancePirWork::Query)
                .chain(self.other.iter().copied())
                .collect(),
        };
        for txid in &self.public {
            assert!(
                !self.pending.iter().any(|r| r.request_id().txid() == *txid),
                "fake routed {txid} to both transports"
            );
        }
        Ok(work)
    }
    fn accept(&self, _: WalletNetwork, m: &Manifest) -> Result<Acceptance, EnhancePirRunError> {
        if m.generation > 1 {
            match self.refreshed_anchor {
                Anchor::Waiting => return Ok(Acceptance::WaitingForScanning),
                Anchor::Mismatch => return Ok(Acceptance::Mismatch),
                Anchor::Accepted => (),
            }
        }
        let acceptance = GenerationAcceptance::new(
            "main",
            3428143,
            AcceptedAnchor::new(m.anchor_height, [0x42; 32], m.coverage.records),
            ClientResourceLimits::new(MAX_LOGICAL_ROWS),
        );
        acceptance.validate(m)?;
        Ok(Acceptance::Accepted(acceptance))
    }
    fn apply(
        &mut self,
        request: EnhancePirRequest,
        _: &EnhanceRecord,
    ) -> Result<EnhancePirStoreResult, EnhancePirRunError> {
        assert!(
            self.pending.contains(&request),
            "replayed an already committed request"
        );
        if let Some(cancel) = &self.cancel_on_apply {
            cancel.set(true);
        }
        if self.reject_at == Some(u64::from(request.position())) {
            self.content_failure(request);
            return Ok(EnhancePirStoreResult::Rejected);
        }
        self.applied.push(u64::from(request.position()));
        if self.transparent_at == Some(u64::from(request.position())) {
            // The whole transaction atomically moves to ordinary enhancement.
            let txid = request.request_id().txid();
            self.pending.retain(|r| r.request_id().txid() != txid);
            self.public.push(txid);
            return Ok(EnhancePirStoreResult::LwdRequired);
        }
        self.pending.retain(|r| *r != request);
        Ok(EnhancePirStoreResult::Stored)
    }
    fn record_unreadable(
        &mut self,
        requests: &[EnhancePirRequest],
    ) -> Result<(), EnhancePirRunError> {
        self.unreadable.push(requests.to_vec());
        for request in requests {
            self.content_failure(*request);
        }
        Ok(())
    }
}
/// The scripted wallet's path, one per test: content failures are recorded
/// per wallet, and tests run in parallel.
fn wallet_path() -> String {
    format!("scripted-pir-wallet-{:?}", std::thread::current().id())
}

/// A new block for the scripted wallet: work that failed on content is asked
/// again.
fn next_block(tip: u64) {
    super::super::content_failures::at_tip(&wallet_path(), tip);
}

fn sync() -> RoutedPayloadEnhancement {
    let mut sync = RoutedPayloadEnhancement::new(WalletNetwork::Main, true, &wallet_path());
    sync.endpoint = Some("https://example.test".into());
    sync
}

/// Records lightwalletd-side dispatch instead of performing it.
#[derive(Default)]
struct Effects {
    public: Vec<Vec<TxId>>,
    rediscovered: Vec<IronwoodEnhanceDiscoveryRequest>,
    /// Rediscovery resolves a mixed shape, requiring LWD for this transaction.
    lwd_after_rediscovery: Option<TxId>,
    /// Payload retrieval succeeds and retires the public work.
    complete_public: bool,
    /// Writing the rebuilt enhancement hits a local SQLite failure.
    fail_rediscovery_db: bool,
    /// Public retrieval queues a private query at this position.
    private_after_public: Option<u64>,
}
impl EnhancementEffects<Wallet> for Effects {
    async fn rediscover(
        &mut self,
        db: &mut Wallet,
        request: IronwoodEnhanceDiscoveryRequest,
        _: &impl Fn() -> bool,
    ) -> Result<(), EnhancePirRunError> {
        self.rediscovered.push(request);
        if self.fail_rediscovery_db {
            return Err(SyncError::Db("disk full".into()).into());
        }
        db.other
            .retain(|work| *work != EnhancePirWork::Rediscover(request));
        db.public.extend(self.lwd_after_rediscovery);
        Ok(())
    }
    async fn public(
        &mut self,
        db: &mut Wallet,
        requests: &[PublicTransactionEnhancementRequest],
        _: &impl Fn() -> bool,
    ) {
        self.public
            .push(requests.iter().map(|request| request.txid()).collect());
        if self.complete_public {
            db.public.clear();
        }
        db.pending
            .extend(self.private_after_public.take().map(request));
    }
}

fn rediscovery() -> IronwoodEnhanceDiscoveryRequest {
    IronwoodEnhanceDiscoveryRequest {
        height: BlockHeight::from_u32(3428200),
        block_hash: BlockHash([9; 32]),
    }
}

#[tokio::test]
async fn public_only_work_never_initializes_pir() {
    for enabled in [true, false] {
        let service = Service::new([]);
        let mut wallet = Wallet::new(&[]);
        wallet.public = vec![ORDINARY];
        let mut effects = Effects {
            complete_public: true,
            ..Default::default()
        };
        let mut sync = if enabled {
            sync()
        } else {
            RoutedPayloadEnhancement::new(WalletNetwork::Main, false, "scripted-pir-wallet")
        };
        sync.run(&mut wallet, &service, &mut effects, &|| false)
            .await
            .unwrap();
        assert_eq!(effects.public, [vec![ORDINARY]]);
        assert_eq!(service.init_count.get(), 0);
        assert!(service.posts.borrow().is_empty());
    }
}

#[tokio::test]
async fn pir_failure_never_falls_back_to_public_transport() {
    let service = Service::new([Some(503)]);
    let mut wallet = Wallet::new(&[0]);
    wallet.public = vec![ORDINARY];
    let mut effects = Effects::default();
    let mut sync = sync();
    sync.run(&mut wallet, &service, &mut effects, &|| false)
        .await
        .unwrap();
    assert!(
        sync.private_failed_for_sync,
        "a PIR failure defers private retries"
    );
    assert_eq!(wallet.pending.len(), 1, "protected work stays private");
    assert_eq!(
        effects.public,
        [vec![ORDINARY]],
        "only already-routed work reaches LWD, once per unchanged snapshot"
    );
    assert_eq!(service.posts.borrow().len(), 1);
}

#[tokio::test]
async fn local_database_failure_fails_the_run_instead_of_deferring() {
    let service = Service::new([]);
    let mut wallet = Wallet::new(&[]);
    wallet.other = vec![EnhancePirWork::Rediscover(rediscovery())];
    wallet.public = vec![ORDINARY];
    let mut effects = Effects {
        fail_rediscovery_db: true,
        ..Default::default()
    };
    let mut sync = sync();
    let result = sync
        .run(&mut wallet, &service, &mut effects, &|| false)
        .await;
    assert!(
        matches!(result, Err(EnhancePirRunError::Failed(SyncError::Db(_)))),
        "a local write failure must surface, got {result:?}"
    );
    assert!(
        !sync.private_failed_for_sync,
        "a local failure is not a service outage"
    );
    assert_eq!(wallet.other.len(), 1, "the unpersisted work stays queued");
    assert!(
        effects.public.is_empty(),
        "the failed pass stops before any lightwalletd dispatch"
    );
    assert_eq!(service.init_count.get(), 0);
}

#[tokio::test]
async fn private_service_failure_still_defers() {
    let service = Service::new([]);
    let mut wallet = Wallet::new(&[]);
    wallet.other = vec![EnhancePirWork::Rediscover(rediscovery())];
    let mut sync = sync();
    // A rediscovery that cannot fetch its block is a transport failure.
    struct NetFail;
    impl EnhancementEffects<Wallet> for NetFail {
        async fn rediscover(
            &mut self,
            _: &mut Wallet,
            _: IronwoodEnhanceDiscoveryRequest,
            _: &impl Fn() -> bool,
        ) -> Result<(), EnhancePirRunError> {
            Err(SyncError::Network("unreachable".into()).into())
        }
        async fn public(
            &mut self,
            _: &mut Wallet,
            _: &[PublicTransactionEnhancementRequest],
            _: &impl Fn() -> bool,
        ) {
        }
    }
    sync.run(&mut wallet, &service, &mut NetFail, &|| false)
        .await
        .unwrap();
    assert!(
        sync.private_failed_for_sync,
        "a transport failure defers PIR"
    );
}

#[tokio::test]
async fn authenticated_transparent_flag_reroutes_after_snapshot_reread() {
    let service = Service::new([]);
    let mut wallet = Wallet::new(&[0]);
    wallet.transparent_at = Some(0);
    let mut effects = Effects {
        complete_public: true,
        ..Default::default()
    };
    sync()
        .run(&mut wallet, &service, &mut effects, &|| false)
        .await
        .unwrap();
    assert_eq!(wallet.applied, [0]);
    assert_eq!(effects.public, [vec![PROTECTED]]);
    assert!(wallet.pending.is_empty() && wallet.public.is_empty());
}

#[tokio::test]
async fn suspended_work_stays_private_and_needs_no_network() {
    let service = Service::new([]);
    let mut wallet = Wallet::new(&[]);
    wallet.other = vec![
        EnhancePirWork::Suspended(EnhancePirSuspension::OutgoingNotRecoverable(request(5))),
        EnhancePirWork::Suspended(EnhancePirSuspension::Rejected(request(6))),
    ];
    let mut effects = Effects::default();
    sync()
        .run(&mut wallet, &service, &mut effects, &|| false)
        .await
        .unwrap();
    assert!(effects.public.is_empty());
    assert_eq!(service.init_count.get(), 0);
    assert_eq!(wallet.other.len(), 2);
}

#[tokio::test]
async fn rediscovery_can_change_the_route_before_the_public_dispatch() {
    let service = Service::new([]);
    let mut wallet = Wallet::new(&[]);
    wallet.other = vec![EnhancePirWork::Rediscover(rediscovery())];
    let mut effects = Effects {
        lwd_after_rediscovery: Some(PROTECTED),
        complete_public: true,
        ..Default::default()
    };
    sync()
        .run(&mut wallet, &service, &mut effects, &|| false)
        .await
        .unwrap();
    assert_eq!(effects.rediscovered, [rediscovery()]);
    assert_eq!(effects.public, [vec![PROTECTED]]);
    assert_eq!(service.init_count.get(), 0);
}

#[tokio::test]
async fn cancellation_during_private_work_prevents_the_public_dispatch() {
    let service = Service::new([]);
    let cancelled = Rc::new(Cell::new(false));
    let mut wallet = Wallet::new(&[0]);
    wallet.public = vec![ORDINARY];
    wallet.cancel_on_apply = Some(cancelled.clone());
    let mut effects = Effects::default();
    let result = sync()
        .run(&mut wallet, &service, &mut effects, &|| cancelled.get())
        .await;
    assert!(matches!(result, Err(EnhancePirRunError::ExitRequested)));
    assert!(effects.public.is_empty());
}

/// One position in each of three rows.
const THREE_ROWS: [u64; 3] = [0, 40, 70];

/// A record that arrives in a decoded row but does not decode itself fails
/// only its own requests: they are reported once, and the rest of the batch
/// is asked exactly as an honest service's reply would have it.
#[tokio::test]
async fn an_unreadable_record_is_reported_and_the_rest_of_the_batch_is_asked() {
    let honest = Service::new([]);
    let mut wallet = Wallet::new(&THREE_ROWS);
    let mut drain = sync();
    drain
        .run(&mut wallet, &honest, &mut Effects::default(), &|| false)
        .await
        .unwrap();
    assert_eq!(wallet.applied, THREE_ROWS);

    let corrupting = Service::new([]);
    corrupting.unreadable_posts.borrow_mut().insert(0);
    let mut wallet = Wallet::new(&THREE_ROWS);
    let mut drain = sync();
    drain
        .run(&mut wallet, &corrupting, &mut Effects::default(), &|| false)
        .await
        .unwrap();
    assert_eq!(wallet.applied, [40, 70]);
    assert_eq!(wallet.unreadable, [vec![request(0)]]);
    assert_eq!(
        wallet.pending,
        [request(0)],
        "the request waits for a later sync"
    );
    assert!(
        !drain.private_failed_for_sync,
        "a content failure is not an outage"
    );
    // The failed request waits for the next block: another sync at this tip
    // asks nothing, as after the honest run.
    drain
        .run(&mut wallet, &corrupting, &mut Effects::default(), &|| false)
        .await
        .unwrap();
    assert_eq!(wallet.unreadable.len(), 1);
    assert_eq!(
        corrupting.posts.borrow().len(),
        honest.posts.borrow().len(),
        "the same queries as the honest run"
    );
    assert_eq!(corrupting.init_count.get(), honest.init_count.get());
    assert_eq!(corrupting.session_count.get(), honest.session_count.get());
}

/// A position whose replies fail on content three times is suspended by the
/// wallet and never asked again.
#[tokio::test]
async fn three_unreadable_replies_suspend_the_position_for_good() {
    let service = Service::new([]);
    service.unreadable_posts.borrow_mut().extend(0..10);
    let mut wallet = Wallet::new(&[0]);
    for sync_number in 1..=5 {
        next_block(sync_number as u64);
        sync()
            .run(&mut wallet, &service, &mut Effects::default(), &|| false)
            .await
            .unwrap();
        assert_eq!(service.posts.borrow().len(), sync_number.min(3));
    }
    assert_eq!(wallet.unreadable.len(), 3);
    assert!(wallet.pending.is_empty());
    assert_eq!(
        wallet.other,
        [EnhancePirWork::Suspended(EnhancePirSuspension::Rejected(
            request(0)
        ))]
    );
}

/// A drain that ends a checkpoint asks only the private queries that existed
/// when the checkpoint began: a query that a status or history reply
/// unlocked during it waits for the next drain point.
#[tokio::test]
async fn queries_unlocked_during_a_checkpoint_wait_for_the_next() {
    let service = Service::new([]);
    let mut wallet = Wallet::new(&[0, 40]);
    let mut drain = sync();
    drain.snapshot = Some([request(0)].into());
    drain
        .run(&mut wallet, &service, &mut Effects::default(), &|| false)
        .await
        .unwrap();
    assert_eq!(wallet.applied, [0]);
    assert_eq!(wallet.pending, [request(40)]);
    assert_eq!(service.posts.borrow().len(), 1);

    drain.snapshot = None;
    drain
        .run(&mut wallet, &service, &mut Effects::default(), &|| false)
        .await
        .unwrap();
    assert_eq!(wallet.applied, [0, 40]);
}

/// A record the wallet rejects is counted by the wallet and no longer stops
/// the batch: the other rows are still asked and applied.
#[tokio::test]
async fn a_rejected_record_no_longer_stops_the_batch() {
    let service = Service::new([]);
    let mut wallet = Wallet::new(&THREE_ROWS);
    wallet.reject_at = Some(0);
    let mut drain = sync();
    drain
        .run(&mut wallet, &service, &mut Effects::default(), &|| false)
        .await
        .unwrap();
    assert_eq!(wallet.applied, [40, 70]);
    assert_eq!(wallet.pending, [request(0)]);
    assert!(!drain.private_failed_for_sync);
    assert_eq!(service.posts.borrow().len(), 3);
}

/// Work one drain unlocks waits for the next drain point: whether another
/// private round runs now never depends on what a reply said.
#[tokio::test]
async fn work_a_drain_unlocks_waits_for_the_next_drain() {
    let service = Service::new([]);
    let mut wallet = Wallet::new(&[0]);
    wallet.public = vec![ORDINARY];
    let mut effects = Effects {
        complete_public: true,
        private_after_public: Some(40),
        ..Default::default()
    };
    let mut drain = sync();
    drain
        .run(&mut wallet, &service, &mut effects, &|| false)
        .await
        .unwrap();
    assert_eq!(wallet.applied, [0]);
    assert_eq!(service.posts.borrow().len(), 1);
    assert_eq!(wallet.pending, [request(40)], "queued for the next drain");

    drain
        .run(&mut wallet, &service, &mut effects, &|| false)
        .await
        .unwrap();
    assert_eq!(wallet.applied, [0, 40]);
}

/// A retry after stale routing asks only what an honest reply would have
/// left: a row whose record failed on content is not asked again, and its
/// failure counts once.
#[tokio::test]
async fn a_stale_routing_retry_skips_rows_that_failed_on_content() {
    let run = |corrupt: bool| async move {
        // The second row's query meets stale routing; the retry succeeds.
        let service = Service::new([None, Some(409), None]);
        if corrupt {
            service.unreadable_posts.borrow_mut().insert(0);
        }
        let mut wallet = Wallet::new(&[0, 40]);
        sync()
            .run_queries(&mut wallet, &service, &|| false)
            .await
            .unwrap();
        let posts = service.posts.borrow().len();
        (posts, service.init_count.get(), wallet)
    };
    let (honest_posts, honest_inits, honest) = run(false).await;
    assert_eq!(honest.applied, [0, 40]);
    let (posts, inits, forged) = run(true).await;
    assert_eq!(forged.applied, [40]);
    assert_eq!((posts, inits), (honest_posts, honest_inits));
    assert_eq!(forged.unreadable, [vec![request(0)]], "counted once");
}

#[tokio::test]
async fn stale_routing_refreshes_equal_coverage_and_retries_only_unfinished_work() {
    for status in [409, 410] {
        let service = Service::new([None, Some(status), None]);
        let mut wallet = Wallet::new(&[0, 33]);
        let mut sync = sync();
        sync.run_queries(&mut wallet, &service, &|| false)
            .await
            .unwrap();
        assert!(wallet.pending.is_empty());
        assert_eq!(wallet.applied, [0, 33]);
        assert_eq!(service.init_count.get(), 2);
        assert_eq!(service.posts.borrow().len(), 3);
        assert_eq!(
            service.session_count.get(),
            1,
            "unchanged material should be reused"
        );
        assert_eq!(
            sync.accepted_routing
                .as_ref()
                .unwrap()
                .generation()
                .generation,
            2
        );
        assert!(wallet.reads.get() >= 3);
        let posts = service.posts.borrow();
        assert_ne!(
            posts[1].request_id, posts[2].request_id,
            "retry must have a fresh binding"
        );
    }
}

#[tokio::test]
async fn repeated_stale_routing_stops_after_one_retry_and_keeps_work() {
    let service = Service::new([Some(409), Some(410)]);
    let mut wallet = Wallet::new(&[0]);
    assert!(sync()
        .run_queries(&mut wallet, &service, &|| false)
        .await
        .is_err());
    assert_eq!(service.posts.borrow().len(), 2);
    assert_eq!(service.init_count.get(), 2);
    assert_eq!(wallet.pending.len(), 1);
    assert!(wallet.applied.is_empty());
}

#[tokio::test]
async fn unaccepted_refresh_never_dispatches_a_retry() {
    for anchor in [Anchor::Waiting, Anchor::Mismatch] {
        let service = Service::new([Some(409)]);
        let mut wallet = Wallet::new(&[0]);
        wallet.refreshed_anchor = anchor;
        let result = sync().run_queries(&mut wallet, &service, &|| false).await;
        assert_eq!(result.is_ok(), matches!(anchor, Anchor::Waiting));
        assert_eq!(service.posts.borrow().len(), 1);
        assert_eq!(wallet.pending.len(), 1);
    }
}

#[tokio::test]
async fn cancellation_during_refresh_prevents_rebinding_and_retry() {
    let service = Service::new([Some(409)]);
    service.cancel_on_refresh.set(true);
    let mut wallet = Wallet::new(&[0]);
    let mut sync = sync();
    assert!(matches!(
        sync.run_queries(&mut wallet, &service, &|| service.cancelled.get())
            .await,
        Err(EnhancePirRunError::ExitRequested)
    ));
    assert_eq!(service.posts.borrow().len(), 1);
    assert_eq!(wallet.pending.len(), 1);
    assert_eq!(
        sync.accepted_routing
            .as_ref()
            .unwrap()
            .generation()
            .generation,
        1
    );
}

#[tokio::test]
async fn failed_refresh_keeps_unfinished_work_without_another_query() {
    let service = Service::new([Some(409)]);
    service.fail_refresh.set(true);
    let mut wallet = Wallet::new(&[0]);
    assert!(sync()
        .run_queries(&mut wallet, &service, &|| false)
        .await
        .is_err());
    assert_eq!(service.posts.borrow().len(), 1);
    assert_eq!(wallet.pending.len(), 1);
}

// Obtain the opaque protocol body collector through its supported Request API.
async fn collector() -> BoundedBody {
    struct Capture(RefCell<Option<BoundedBody>>);
    impl transport::Transport for Capture {
        async fn execute(
            &self,
            request: transport::Request,
        ) -> Result<transport::ResponseBody, ClientError> {
            self.0.replace(Some(request.response_body()));
            Err(ClientError::Cancelled)
        }
    }
    let capture = Capture(RefCell::new(None));
    let _ = PendingClient::fetch(&capture, "https://example.test").await;
    capture.0.into_inner().unwrap()
}

#[tokio::test(start_paused = true)]
async fn error_status_does_not_read_truncated_or_stalled_body() {
    for status in [409, 410] {
        for stalled in [false, true] {
            let polled = Cell::new(false);
            let stream = futures::stream::poll_fn(|_| {
                polled.set(true);
                if stalled {
                    std::task::Poll::Pending
                } else {
                    std::task::Poll::Ready(Some(Err::<hyper::body::Frame<Bytes>, _>("truncated")))
                }
            });
            let response = http::Response::builder()
                .status(status)
                .body(http_body_util::StreamBody::new(stream))
                .unwrap();
            let started = tokio::time::Instant::now();
            let result = receive_response(
                std::future::ready(Ok::<_, SyncError>(response)),
                collector().await,
                &|| false,
            )
            .await;
            assert!(matches!(result, Err(RoutedHttpError::HttpStatus(s)) if s == status));
            assert!(!polled.get());
            assert_eq!(tokio::time::Instant::now(), started);
        }
    }
}

#[tokio::test(start_paused = true)]
async fn headers_and_body_share_one_deadline() {
    let collector = collector().await;
    let request = async {
        tokio::time::sleep(Duration::from_secs(100)).await; // response headers
        let stream = futures::stream::once(async {
            tokio::time::sleep(Duration::from_secs(100)).await;
            Ok::<_, std::convert::Infallible>(hyper::body::Frame::data(Bytes::from_static(b"ok")))
        })
        .boxed();
        Ok::<_, SyncError>(http::Response::new(http_body_util::StreamBody::new(stream)))
    };
    let started = tokio::time::Instant::now();
    assert!(matches!(
        receive_response(request, collector, &|| false).await,
        Err(RoutedHttpError::Failed(_))
    ));
    assert_eq!(tokio::time::Instant::now() - started, HTTP_TIMEOUT);
}

#[tokio::test]
async fn cancellation_wins_over_an_available_error_status() {
    let response = http::Response::builder()
        .status(409)
        .body(Full::new(Bytes::new()))
        .unwrap();
    assert!(matches!(
        receive_response(
            std::future::ready(Ok::<_, SyncError>(response)),
            collector().await,
            &|| true,
        )
        .await,
        Err(RoutedHttpError::Cancelled)
    ));
}

#[tokio::test]
async fn successful_bodies_are_collected_and_invalid_bodies_are_rejected() {
    let response = http::Response::new(Full::new(Bytes::from_static(b"response")));
    let result = receive_response(
        std::future::ready(Ok::<_, SyncError>(response)),
        collector().await,
        &|| false,
    )
    .await
    .unwrap();
    assert_eq!(result.as_ref(), b"response");

    let oversized = http::Response::new(Full::new(Bytes::from(vec![
        0;
        transport::MAX_MANIFEST_BYTES
            + 1
    ])));
    assert!(receive_response(
        std::future::ready(Ok::<_, SyncError>(oversized)),
        collector().await,
        &|| false
    )
    .await
    .is_err());
    let truncated =
        http_body_util::StreamBody::new(futures::stream::iter([
            Err::<hyper::body::Frame<Bytes>, _>("truncated successful response"),
        ]));
    assert!(receive_response(
        std::future::ready(Ok::<_, SyncError>(http::Response::new(truncated))),
        collector().await,
        &|| false
    )
    .await
    .is_err());
}

#[tokio::test(start_paused = true)]
async fn cancellation_interrupts_a_stalled_success_body() {
    let cancelled = Cell::new(false);
    let body = http_body_util::StreamBody::new(futures::stream::pending::<
        Result<hyper::body::Frame<Bytes>, &'static str>,
    >());
    let collector = collector().await;
    let started = tokio::time::Instant::now();
    let should_exit = || cancelled.get();
    let request = receive_response(
        std::future::ready(Ok::<_, SyncError>(http::Response::new(body))),
        collector,
        &should_exit,
    );
    let cancel = async {
        tokio::time::sleep(Duration::from_secs(1)).await;
        cancelled.set(true);
    };
    let (result, ()) = tokio::join!(request, cancel);
    assert!(matches!(result, Err(RoutedHttpError::Cancelled)));
    assert!(tokio::time::Instant::now() - started < HTTP_TIMEOUT);
}
