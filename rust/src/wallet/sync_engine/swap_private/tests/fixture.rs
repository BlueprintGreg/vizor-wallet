//! A synthetic Mainnet chain scanned into real app wallets, and a receiver service built
//! from its actual payments with the production snapshot, witness, GCS and PIR code.
use super::super::*;
use orchard::keys::{FullViewingKey, Scope};
use secrecy::SecretVec;
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{mpsc, Arc, Mutex},
};
use zakura_one_time_ivk::{KeyId, Purpose};
use zakura_pir_receiver::{
    receiver_directory::{
        blocks::{BlockFilter, BlockId},
        snapshot::{Manifest, Snapshot, PROFILE},
        RawRecord,
    },
    receiver_pir::{server::Server, MIN_ROWS},
};
use zakura_receiver_crypto::witness::{Publication, WitnessSnapshot};
use zcash_client_backend::{
    data_api::{
        chain::{BlockSource, ChainState},
        one_time_ivk::restore::{DirectoryPayment, LookupWork, RecoveryStatus},
        testing::{AddressType, IronwoodFvk, TestBuilder, TestState},
        WalletRead, WalletWrite,
    },
    proto::compact_formats::CompactBlock,
};
use zcash_client_sqlite::testing::{
    db::{TestDb, TestDbFactory},
    BlockCache,
};
use zcash_primitives::transaction::Transaction;
use zcash_protocol::{consensus::BlockHeight, local_consensus::LocalNetwork, value::Zatoshis};

pub(super) const NETWORK: WalletNetwork = WalletNetwork::Main;
pub(super) const ORIGIN: &str = "https://receiver.test";

/// Ironwood activation on Mainnet, where the synthetic chain starts.
pub(super) fn activation() -> u32 {
    NETWORK
        .activation_height(NetworkUpgrade::Nu6_3)
        .unwrap()
        .into()
}

/// Turns on the process settings the app applies before recovery can run.
pub(super) fn enable_feature() {
    crate::api::sync::set_enhance_pir_enabled(true);
    crate::api::sync::set_near_swap_privacy_enabled(true);
}

/// The Mainnet upgrade heights as a local network the test chain can mine.
fn local_network() -> LocalNetwork {
    let height = |upgrade| NETWORK.activation_height(upgrade);
    LocalNetwork {
        overwinter: height(NetworkUpgrade::Overwinter),
        sapling: height(NetworkUpgrade::Sapling),
        blossom: height(NetworkUpgrade::Blossom),
        heartwood: height(NetworkUpgrade::Heartwood),
        canopy: height(NetworkUpgrade::Canopy),
        nu5: height(NetworkUpgrade::Nu5),
        nu6: height(NetworkUpgrade::Nu6),
        nu6_1: height(NetworkUpgrade::Nu6_1),
        nu6_2: height(NetworkUpgrade::Nu6_2),
        nu6_3: Some(activation().into()),
        nu7: None,
    }
}

/// The independent chain, its tree state after each block, and every payment the
/// receiver directory indexes.
pub(super) struct Chain {
    st: TestState<BlockCache, TestDb, LocalNetwork>,
    states: BTreeMap<u32, ChainState>,
    records: Vec<RawRecord>,
}

impl Chain {
    /// A chain whose first block is Ironwood's activation block.
    pub(super) fn new() -> Self {
        let below = activation() - 1;
        let st = TestBuilder::new()
            .with_network(local_network())
            .with_data_store_factory(TestDbFactory::default())
            .with_block_cache(BlockCache::new())
            .with_initial_chain_state(|_, _| {
                zcash_client_backend::data_api::testing::InitialChainState {
                    chain_state: ChainState::empty(below.into(), BlockHash([0; 32])),
                    prior_sapling_roots: vec![],
                    prior_orchard_roots: vec![],
                }
            })
            .with_account_having_current_birthday()
            .build();
        let mut chain = Self {
            st,
            states: BTreeMap::from([(below, ChainState::empty(below.into(), BlockHash([0; 32])))]),
            records: Vec::new(),
        };
        chain.mine(1);
        chain
    }

    /// Records the tree state of the block just mined.
    fn advance(&mut self) -> u32 {
        let block = self.st.latest_cached_block().unwrap();
        let height = u32::from(block.height());
        self.states.insert(height, block.chain_state().clone());
        height
    }

    /// Mines `n` blocks without shielded outputs.
    pub(super) fn mine(&mut self, n: u32) {
        for _ in 0..n {
            self.st.generate_empty_block();
            self.advance();
        }
    }

    /// The latest block.
    pub(super) fn tip(&self) -> u32 {
        *self.states.keys().next_back().unwrap()
    }

    /// The chain state at the end of block `height`.
    pub(super) fn state(&self, height: u32) -> &ChainState {
        &self.states[&height]
    }

    /// The hash of block `height`.
    pub(super) fn hash(&self, height: u32) -> [u8; 32] {
        self.states[&height].block_hash().0
    }

    /// Mines one block paying `value` to `fvk`'s default address with a real Ironwood
    /// note. `indexed` says the receiver directory lists it, as for NEAR's zero-OVK
    /// payouts.
    pub(super) fn pay(&mut self, fvk: &FullViewingKey, value: u64, indexed: bool) -> u32 {
        let (height, _, _) = self.st.generate_next_block(
            &IronwoodFvk(fvk.clone()),
            AddressType::DefaultExternal,
            Zatoshis::const_from_u64(value),
        );
        let height = u32::from(height);
        self.advance();
        if indexed {
            let record = self.record(height, fvk);
            self.records.push(record);
        }
        height
    }

    /// Mines a block holding only `tx`, which an app wallet built and broadcast.
    pub(super) fn mine_tx(&mut self, tx: &Transaction) -> u32 {
        self.st.generate_next_block_from_tx(1, tx);
        self.advance()
    }

    /// The cached compact block at `height`.
    fn block(&self, height: u32) -> CompactBlock {
        let mut found = None;
        self.st
            .cache()
            .with_blocks::<_, ()>(Some(height.into()), Some(1), |block| {
                found = Some(block);
                Ok(())
            })
            .unwrap();
        found.unwrap()
    }

    /// The directory record of the output in block `height` that `fvk` can decrypt.
    fn record(&self, height: u32, fvk: &FullViewingKey) -> RawRecord {
        use orchard::note_encryption::{CompactAction, IronwoodDomain};
        use zcash_note_encryption::try_compact_note_decryption;
        let block = self.block(height);
        let ivk = fvk.to_ivk(Scope::External).prepare();
        let mut position = self.states[&(height - 1)].final_ironwood_tree().tree_size();
        for tx in &block.vtx {
            for (action_index, compact) in tx.ironwood_actions.iter().enumerate() {
                let action = CompactAction::try_from(compact).unwrap();
                let domain = IronwoodDomain::for_compact_action(&action);
                if try_compact_note_decryption(&domain, &ivk, &action).is_some() {
                    return RawRecord {
                        receiver: fvk.address_at(0u32, Scope::External).to_raw_address_bytes(),
                        page: 0,
                        total: 1,
                        payment: DirectoryPayment {
                            height,
                            block_hash: block.hash().0,
                            txid: *tx.txid().as_ref(),
                            // Fake blocks have no coinbase; the directory refuses index 0.
                            tx_index: u32::try_from(tx.index).unwrap().max(1),
                            action_index: action_index as u32,
                            position,
                            action_nullifier: compact.nullifier.as_slice().try_into().unwrap(),
                            cmx: compact.cmx.as_slice().try_into().unwrap(),
                            ephemeral_key: compact.ephemeral_key.as_slice().try_into().unwrap(),
                            ciphertext_prefix: compact.ciphertext.as_slice().try_into().unwrap(),
                        },
                    };
                }
                position += 1;
            }
        }
        panic!("no output in block {height} pays the key");
    }

    /// Every Ironwood note commitment, in tree order.
    fn commitments(&self) -> Vec<[u8; 32]> {
        let mut commitments = Vec::new();
        self.st
            .cache()
            .with_blocks::<_, ()>(Some(activation().into()), None, |block| {
                for tx in &block.vtx {
                    for action in &tx.ironwood_actions {
                        commitments.push(action.cmx.as_slice().try_into().unwrap());
                    }
                }
                Ok(())
            })
            .unwrap();
        commitments
    }
}

/// Which receiver route a request used, for holds and byte counts.
fn route_class(route: &str) -> &'static str {
    match route {
        "init" => "init",
        "block-filters/head" => "head",
        _ if route.starts_with("block-filters/") => "filters",
        _ if route.starts_with("public/") => "public",
        _ if route.starts_with("witness/") => "witness",
        "query" => "query",
        _ => panic!("unexpected receiver route {route}"),
    }
}

/// A request the service holds until the test releases it.
struct Hold {
    class: &'static str,
    nth: usize,
    arrived: mpsc::Sender<()>,
    release: Arc<tokio::sync::Semaphore>,
}

/// The test's side of a held request: wait for it to arrive, then release it.
pub(super) struct Held {
    arrived: mpsc::Receiver<()>,
    release: Arc<tokio::sync::Semaphore>,
}

impl Held {
    /// Blocks until the worker has sent the held request.
    pub(super) fn wait(&self) {
        self.arrived
            .recv_timeout(Duration::from_secs(30))
            .expect("the held request arrived");
    }

    /// Lets the held response go.
    pub(super) fn release(&self) {
        self.release.add_permits(1);
    }
}

/// One immutable publication: real encrypted PIR over the indexed payments, their
/// witness file and a rolling filter suffix. Counts every request and response body.
pub(super) struct Service {
    server: Server,
    witnesses: Option<Vec<u8>>,
    head: Head,
    filters: Vec<BlockFilter>,
    requests: Mutex<Vec<(&'static str, String, usize, usize)>>,
    holds: Mutex<Vec<Hold>>,
    trace: Mutex<Trace>,
}

/// Which address and history page each encrypted query read, for one account.
#[derive(Default)]
struct Trace {
    wallet: Option<(String, AccountUuid)>,
    /// The work item and page of the previous query, to number pages within a step.
    previous: Option<(LookupWork, u32)>,
    pages: Vec<(bool, u64, u32)>,
}

impl Service {
    /// Publishes payments mined through `pir_end`, and filters for blocks `first` through
    /// `filter_tip`. Each filter lists the receivers paid in its block plus `extra` hits.
    pub(super) fn publish(
        chain: &Chain,
        pir_end: u32,
        first: u32,
        filter_tip: u32,
        extra: &[(u32, [u8; 43])],
    ) -> Arc<Self> {
        let mut records: Vec<_> = chain
            .records
            .iter()
            .filter(|r| r.payment.height <= pir_end)
            .cloned()
            .collect();
        let mut totals = BTreeMap::new();
        for r in &records {
            *totals.entry(r.receiver).or_insert(0u32) += 1;
        }
        let mut pages = BTreeMap::new();
        for r in &mut records {
            let page = pages.entry(r.receiver).or_insert(0u32);
            r.page = *page;
            r.total = totals[&r.receiver];
            *page += 1;
        }
        let end_position = chain.state(pir_end).final_ironwood_tree().tree_size();
        let manifest = Manifest {
            profile: PROFILE.into(),
            history_revision: 0,
            genesis: MAINNET_GENESIS,
            start_height: activation(),
            start_parent: chain.hash(activation() - 1),
            start_position: 0,
            end_height: pir_end,
            end_hash: chain.hash(pir_end),
            end_position,
            rows: MIN_ROWS,
            salt: [5; 32],
            records: 0,
            data_sha256: [0; 32],
        };
        let snapshot = Snapshot::build(manifest, &records).unwrap();
        let m = &snapshot.manifest;
        let witnesses = (end_position > 0).then(|| {
            let positions: BTreeSet<u32> =
                records.iter().map(|r| r.payment.position as u32).collect();
            WitnessSnapshot::build(
                &Publication {
                    genesis: MAINNET_GENESIS,
                    directory_revision: m.revision().unwrap(),
                    end_height: m.end_height,
                    end_hash: m.end_hash,
                    start_position: 0,
                    end_position,
                    records: m.records,
                },
                &chain.commitments()[..end_position as usize],
                &positions,
            )
            .unwrap()
            .encode()
        });
        let filters = (first..=filter_tip)
            .map(|height| {
                let hits: Vec<[u8; 43]> = chain
                    .records
                    .iter()
                    .filter(|r| r.payment.height == height)
                    .map(|r| r.receiver)
                    .chain(extra.iter().filter(|(h, _)| *h == height).map(|(_, r)| *r))
                    .collect();
                BlockFilter::build(
                    &MAINNET_GENESIS,
                    BlockId {
                        height,
                        hash: chain.hash(height),
                    },
                    chain.hash(height - 1),
                    &hits,
                )
                .unwrap()
            })
            .collect();
        Arc::new(Self {
            server: Server::new(snapshot).unwrap(),
            witnesses,
            head: Head {
                genesis: MAINNET_GENESIS,
                revision: 0,
                first,
                tip: BlockId {
                    height: filter_tip,
                    hash: chain.hash(filter_tip),
                },
            },
            filters,
            requests: Mutex::new(Vec::new()),
            holds: Mutex::new(Vec::new()),
            trace: Mutex::new(Trace::default()),
        })
    }

    /// Holds the `nth` (zero-based) request of `class` until released.
    pub(super) fn hold(&self, class: &'static str, nth: usize) -> Held {
        let (arrived, waiting) = mpsc::channel();
        let release = Arc::new(tokio::sync::Semaphore::new(0));
        self.holds.lock().unwrap().push(Hold {
            class,
            nth,
            arrived,
            release: release.clone(),
        });
        Held {
            arrived: waiting,
            release,
        }
    }

    /// Records the address and page of every later query for `account` of `wallet`.
    /// Queries are encrypted, so each one is attributed to the lookup the worker just
    /// read: the first due item of the account's queue, which the worker cannot change
    /// before its request. Only for single-account rounds without concurrent writers.
    pub(super) fn trace(&self, wallet: &Wallet, account: &Account) {
        self.trace.lock().unwrap().wallet = Some((wallet.path.clone(), account.id));
    }

    /// The traced queries as (is a receive key, index, page), in request order.
    pub(super) fn traced(&self) -> Vec<(bool, u64, u32)> {
        self.trace.lock().unwrap().pages.clone()
    }

    /// Attributes one query to the lookup in flight (see [`Self::trace`]).
    fn record_query(&self) {
        let mut trace = self.trace.lock().unwrap();
        let Some((path, account)) = trace.wallet.clone() else {
            return;
        };
        let db =
            open_existing_wallet_db_with_timeout(&path, NETWORK, WALLET_DB_BUSY_TIMEOUT).unwrap();
        let work = db
            .one_time_recovery(account, one_time_ivk::now().unwrap())
            .unwrap()
            .lookups
            .into_iter()
            .next()
            .expect("a query is sent only for a due lookup");
        let page = match &trace.previous {
            Some((previous, page)) if *previous == work => page + 1,
            // A saved cursor is reread first to check it still matches the session.
            _ => work.last.as_ref().map_or(0, |last| last.page),
        };
        trace.pages.push((
            work.work.key.purpose() == Purpose::Receive,
            work.work.key.index(),
            page,
        ));
        trace.previous = Some((work, page));
    }

    /// Answers one request, after any hold on it is released.
    async fn reply(&self, url: &str, body: &[u8], limit: usize) -> Result<Vec<u8>, DirectoryError> {
        let route = url.split("/v1/receiver/").nth(1).unwrap().to_owned();
        let class = route_class(&route);
        if class == "query" {
            self.record_query();
        }
        let gate = {
            let seen = self
                .requests
                .lock()
                .unwrap()
                .iter()
                .filter(|(c, ..)| *c == class)
                .count();
            // Counted on arrival so a later request of the same class gets the next index.
            self.requests
                .lock()
                .unwrap()
                .push((class, route.clone(), body.len(), 0));
            let holds = self.holds.lock().unwrap();
            holds
                .iter()
                .find(|h| h.class == class && h.nth == seen)
                .map(|h| {
                    let _ = h.arrived.send(());
                    h.release.clone()
                })
        };
        if let Some(gate) = gate {
            gate.acquire().await.unwrap().forget();
        }
        let response = match class {
            "init" => serde_json::to_vec(self.server.manifest()).unwrap(),
            "head" => serde_json::to_vec(&self.head).unwrap(),
            "filters" => {
                let range = route.strip_prefix("block-filters/0/").unwrap();
                let (from, count) = range.split_once('/').unwrap();
                let from: u32 = from.parse().unwrap();
                let count: usize = count.parse().unwrap();
                if from < self.head.first {
                    return Err(DirectoryError::Transport("HTTP 410".into()));
                }
                Batch::new(
                    MAINNET_GENESIS,
                    0,
                    self.filters
                        .iter()
                        .filter(|f| f.block().height >= from)
                        .take(count)
                        .cloned()
                        .collect(),
                )
                .unwrap()
                .encode()
                .unwrap()
            }
            "public" => self.server.public().to_vec(),
            "witness" => self.witnesses.clone().expect("the publication has outputs"),
            _ => self.server.respond(body).unwrap(),
        };
        assert!(response.len() <= limit);
        let mut requests = self.requests.lock().unwrap();
        let entry = requests
            .iter_mut()
            .rev()
            .find(|(c, r, req, resp)| {
                *c == class && *r == route && *req == body.len() && *resp == 0
            })
            .unwrap();
        entry.3 = response.len();
        Ok(response)
    }

    /// The number of requests of `class`.
    pub(super) fn count(&self, class: &str) -> usize {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .filter(|(c, ..)| *c == class)
            .count()
    }

    /// Encrypted address lookups, excluding setup, proofs and filters.
    pub(super) fn queries(&self) -> usize {
        self.count("query")
    }

    /// The filter routes requested, as `from/count`.
    pub(super) fn filter_requests(&self) -> Vec<String> {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .filter(|(c, ..)| *c == "filters")
            .map(|(_, r, ..)| r.trim_start_matches("block-filters/0/").to_owned())
            .collect()
    }

    /// The (request, response) body sizes of every request of `class`, in order.
    pub(super) fn requests_of(&self, class: &str) -> Vec<(usize, usize)> {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .filter(|(c, ..)| *c == class)
            .map(|(_, _, req, resp)| (*req, *resp))
            .collect()
    }

    /// Request plus response body bytes of `class`.
    pub(super) fn bytes_of(&self, class: &str) -> usize {
        self.requests_of(class)
            .iter()
            .map(|(req, resp)| req + resp)
            .sum()
    }

    /// Request plus response body bytes over every route.
    pub(super) fn bytes(&self) -> usize {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .map(|(_, _, req, resp)| req + resp)
            .sum()
    }

    /// Request and response bytes per route class, for the evidence log.
    pub(super) fn report(&self, label: &str) -> String {
        let mut by: BTreeMap<&str, (usize, usize, usize)> = BTreeMap::new();
        for (class, _, req, resp) in self.requests.lock().unwrap().iter() {
            let e = by.entry(class).or_default();
            e.0 += 1;
            e.1 += req;
            e.2 += resp;
        }
        let parts: Vec<_> = by
            .iter()
            .map(|(c, (n, req, resp))| format!("{c}: {n} requests, {req} up, {resp} down"))
            .collect();
        let line = format!(
            "{label}: {}; total {} bytes",
            parts.join("; "),
            self.bytes()
        );
        println!("receiver bytes {line}");
        line
    }
}

impl Transport for Service {
    /// Returns a bounded encoded public resource.
    async fn get(&self, url: &str, limit: usize) -> Result<Vec<u8>, DirectoryError> {
        self.reply(url, &[], limit).await
    }
    /// Evaluates a real encrypted query without exposing its receiver to the fixture.
    async fn post(
        &self,
        url: &str,
        body: Vec<u8>,
        limit: usize,
    ) -> Result<Vec<u8>, DirectoryError> {
        self.reply(url, &body, limit).await
    }
}

/// A software account and the seed the app keeps for it in secure storage.
#[derive(Clone)]
pub(super) struct Account {
    pub(super) id: AccountUuid,
    pub(super) uuid: String,
    seed: Vec<u8>,
}

impl Account {
    /// The seed the app would read from secure storage to sign.
    pub(super) fn seed(&self) -> SecretVec<u8> {
        SecretVec::new(self.seed.clone())
    }

    /// The account's Orchard key, which its ordinary Ironwood receivers and one-time
    /// keys derive from.
    pub(super) fn parent(&self) -> FullViewingKey {
        let usk = zcash_keys::keys::UnifiedSpendingKey::from_seed(
            &NETWORK,
            &self.seed,
            zip32::AccountId::ZERO,
        )
        .unwrap();
        FullViewingKey::from(usk.orchard())
    }

    /// One-time key `index` for `purpose`, derived without registering it.
    pub(super) fn key(&self, purpose: Purpose, index: u64) -> FullViewingKey {
        KeyId::new(purpose, index).derive(&self.parent()).unwrap()
    }

    /// The receiver bytes of one-time key `index` for `purpose`.
    pub(super) fn receiver(&self, purpose: Purpose, index: u64) -> [u8; 43] {
        self.key(purpose, index)
            .address_at(0u32, Scope::External)
            .to_raw_address_bytes()
    }
}

/// An app wallet database, scanned like ordinary sync from the shared chain.
pub(super) struct Wallet {
    _dir: tempfile::TempDir,
    pub(super) path: String,
    pub(super) accounts: Vec<Account>,
    scanned: u32,
}

impl Wallet {
    /// Creates the app's first software account from `seed` with the given birthday.
    pub(super) fn new(seed: u8, birthday: u32) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("wallet.db").to_str().unwrap().to_owned();
        let seed = vec![seed; 32];
        let (uuid, _) = crate::wallet::keys::init_db_and_create_account(
            &path,
            NETWORK,
            &SecretVec::new(seed.clone()),
            Some(u64::from(birthday)),
            "Recovery",
        )
        .unwrap();
        Self {
            _dir: dir,
            path,
            accounts: vec![Account {
                id: crate::wallet::keys::parse_account_uuid(&uuid).unwrap(),
                uuid,
                seed,
            }],
            scanned: birthday - 1,
        }
    }

    /// Adds another software account from a different seed, as the app's add flow does.
    pub(super) fn add_account(&mut self, seed: u8, birthday: u32) -> Account {
        let seed = vec![seed; 32];
        let (uuid, _) = crate::wallet::keys::add_account(
            &self.path,
            NETWORK,
            "Second",
            &SecretVec::new(seed.clone()),
            Some(u64::from(birthday)),
        )
        .unwrap();
        let account = Account {
            id: crate::wallet::keys::parse_account_uuid(&uuid).unwrap(),
            uuid,
            seed,
        };
        self.accounts.push(account.clone());
        account
    }

    /// The first account.
    pub(super) fn account(&self) -> &Account {
        &self.accounts[0]
    }

    /// A fresh handle on the app database.
    pub(super) fn db(&self) -> WalletDatabase {
        open_existing_wallet_db_with_timeout(&self.path, NETWORK, WALLET_DB_BUSY_TIMEOUT).unwrap()
    }

    /// Ordinary sync: scans every new block, without the recovery worker, filters or PIR.
    pub(super) fn scan(&mut self, chain: &Chain) {
        let tip = chain.tip();
        if tip <= self.scanned {
            return;
        }
        let mut db = self.db();
        db.update_chain_tip(tip.into()).unwrap();
        zcash_client_backend::data_api::chain::scan_cached_blocks(
            &NETWORK,
            chain.st.cache(),
            &mut db,
            BlockHeight::from(self.scanned + 1),
            chain.state(self.scanned),
            (tip - self.scanned) as usize,
        )
        .unwrap();
        self.scanned = tip;
    }

    /// The last block ordinary sync scanned.
    pub(super) fn scanned(&self) -> u32 {
        u32::from(
            self.db()
                .block_fully_scanned()
                .unwrap()
                .unwrap()
                .block_height(),
        )
    }

    /// The durable queue and progress of `account`.
    pub(super) fn state(&self, account: &Account) -> RecoveryStatus {
        self.db()
            .one_time_recovery(account.id, one_time_ivk::now().unwrap())
            .unwrap()
    }

    /// Every one-time key of `account` with an unfinished queued lookup, as
    /// (is a receive key, index). The status API returns only a bounded batch.
    pub(super) fn queued(&self, account: &Account) -> BTreeSet<(bool, u64)> {
        let conn = rusqlite::Connection::open(&self.path).unwrap();
        let mut statement = conn
            .prepare(
                "SELECT k.purpose, k.key_index FROM ironwood_one_time_lookups l
                 JOIN ironwood_one_time_keys k ON k.id = l.one_time_key_id
                 JOIN accounts a ON a.id = k.account_id
                 WHERE a.uuid = ?1 AND l.target_height IS NOT NULL AND l.reasons != 0
                   AND l.read_complete = 0",
            )
            .unwrap();
        let rows = statement
            .query_map([account.id.expose_uuid().as_bytes()], |r| {
                Ok((
                    r.get::<_, u8>(0)? == 1,
                    u64::from_be_bytes(r.get::<_, [u8; 8]>(1)?),
                ))
            })
            .unwrap();
        rows.collect::<Result<_, _>>().unwrap()
    }

    /// Runs one worker round against `service`, as `recover` does, with a 45 second budget.
    pub(super) fn recover(&self, service: &Service) -> Result<(), String> {
        self.recover_with(service, None, Duration::from_secs(45))
    }

    /// Runs one worker round, optionally manual, under the given overall budget.
    pub(super) fn recover_with(
        &self,
        service: &Service,
        manual: Option<Option<u64>>,
        budget: Duration,
    ) -> Result<(), String> {
        run_worker(&self.path, service, manual, budget)
    }

    /// Starts a worker round on its own thread, as the app schedules it beside sync.
    pub(super) fn spawn(
        &self,
        service: &Arc<Service>,
        manual: Option<Option<u64>>,
        budget: Duration,
    ) -> std::thread::JoinHandle<Result<(), String>> {
        let path = self.path.clone();
        let service = service.clone();
        std::thread::spawn(move || run_worker(&path, &service, manual, budget))
    }

    /// Mined, unspent value of `account`'s one-time-key notes.
    pub(super) fn one_time_unspent(&self, account: &Account) -> u64 {
        self.one_time_value(account, true)
    }

    /// Value of every one-time-key note `account` has admitted, spent or not.
    pub(super) fn one_time_received(&self, account: &Account) -> u64 {
        self.one_time_value(account, false)
    }

    /// Sums `account`'s mined one-time-key notes, optionally excluding spent ones.
    fn one_time_value(&self, account: &Account, unspent: bool) -> u64 {
        let conn = rusqlite::Connection::open(&self.path).unwrap();
        conn.query_row(
            "SELECT COALESCE(SUM(n.value), 0) FROM ironwood_received_notes n
             JOIN transactions r ON r.id_tx = n.transaction_id
             JOIN accounts a ON a.id = n.account_id
             WHERE a.uuid = ?1 AND n.one_time_key_id IS NOT NULL AND r.mined_height IS NOT NULL
               AND (?2 = 0 OR NOT EXISTS(SELECT 1 FROM ironwood_received_note_spends s
                   JOIN transactions t ON t.id_tx = s.transaction_id
                   WHERE s.ironwood_received_note_id = n.id
                     AND (t.mined_height IS NOT NULL OR t.expiry_height = 0
                          OR t.expiry_height > (SELECT MAX(height) FROM blocks))))",
            rusqlite::params![account.id.expose_uuid().as_bytes(), unspent],
            |r| r.get::<_, i64>(0),
        )
        .map(|v| v as u64)
        .unwrap()
    }

    /// Each refund-key receipt of `account` as its nullifier and whether a mined
    /// transaction spends it.
    pub(super) fn refund_receipts(&self, account: &Account) -> Vec<([u8; 32], bool)> {
        let conn = rusqlite::Connection::open(&self.path).unwrap();
        let mut statement = conn
            .prepare(
                "SELECT n.nf, EXISTS(SELECT 1 FROM ironwood_received_note_spends s
                     JOIN transactions t ON t.id_tx = s.transaction_id
                     WHERE s.ironwood_received_note_id = n.id AND t.mined_height IS NOT NULL)
                 FROM ironwood_received_notes n
                 JOIN ironwood_one_time_keys k ON k.id = n.one_time_key_id
                 JOIN accounts a ON a.id = n.account_id
                 WHERE a.uuid = ?1 AND k.purpose = 0 ORDER BY n.id",
            )
            .unwrap();
        let rows = statement
            .query_map([account.id.expose_uuid().as_bytes()], |r| {
                Ok((r.get::<_, [u8; 32]>(0)?, r.get::<_, bool>(1)?))
            })
            .unwrap();
        rows.collect::<Result<_, _>>().unwrap()
    }

    /// The app's spendable plus pending total for `account`, as the home screen reads it.
    pub(super) fn balance(&self, account: &Account) -> u64 {
        crate::api::sync::get_balance(self.path.clone(), "main".into(), account.uuid.clone())
            .unwrap()
            .total
    }

    /// The app's transaction history for `account`.
    pub(super) fn history(&self, account: &Account) -> Vec<crate::api::sync::TransactionInfo> {
        crate::api::sync::get_transaction_history(
            self.path.clone(),
            "main".into(),
            None,
            account.uuid.clone(),
        )
        .unwrap()
    }

    /// The newest transaction the app built and stored, with its raw bytes.
    pub(super) fn last_built(&self) -> (Transaction, Vec<u8>) {
        let conn = rusqlite::Connection::open(&self.path).unwrap();
        let raw: Vec<u8> = conn
            .query_row(
                "SELECT raw FROM transactions WHERE raw IS NOT NULL ORDER BY id_tx DESC LIMIT 1",
                [],
                |r| r.get(0),
            )
            .unwrap();
        let branch = zcash_protocol::consensus::BranchId::for_height(
            &NETWORK,
            BlockHeight::from(self.scanned + 1),
        );
        (Transaction::read(&raw[..], branch).unwrap(), raw)
    }
}

/// Runs `recover_with_transport` with the generation the production entry point captures.
fn run_worker(
    path: &str,
    service: &Service,
    manual: Option<Option<u64>>,
    budget: Duration,
) -> Result<(), String> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(async {
            let generation = CANCEL.load(Ordering::SeqCst);
            recover_with_transport(
                path,
                NETWORK,
                manual,
                ORIGIN,
                service,
                generation,
                tokio::time::Instant::now() + budget,
            )
            .await
        })
}
