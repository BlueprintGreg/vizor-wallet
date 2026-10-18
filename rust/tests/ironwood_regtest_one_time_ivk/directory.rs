//! The receiver directory: an indexer that reads the regtest chain the way the live one
//! reads a Zakura node, publishing over the receiver routes and real PIR, served to
//! Vizor over loopback HTTP. The routes answer as the receiver service does; the
//! service's own router is tested against the same clients in wallet-pir.

use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{Arc, Mutex},
};

use receiver_directory::{
    snapshot::{Manifest, ProviderSet, Snapshot, PROFILE},
    RawRecord,
};
use receiver_pir::{server::Server, MIN_ROWS};
use rust_lib_zcash_wallet::wallet::network::WalletNetwork;
use zakura_receiver_crypto::{
    recovery::Action,
    witness::{Publication as WitnessPublication, WitnessSnapshot},
    Payment, Receiver, Record,
};
use zcash_primitives::block::Block;

use super::chain::Stack;

/// One block as the live indexer extracts it (see `receiver-indexer`'s `extract_block`).
struct IndexedBlock {
    hash: [u8; 32],
    /// Every Ironwood note commitment, in tree order.
    commitments: Vec<[u8; 32]>,
    /// Zero-OVK payments outside coinbase, with the receivers the zero OVK recovers.
    payments: Vec<(Receiver, Payment)>,
}

/// The chain's blocks from Ironwood activation, indexed as the live directory indexes
/// them.
pub struct Indexer {
    activation: u32,
    blocks: BTreeMap<u32, IndexedBlock>,
}

impl Indexer {
    /// An empty index for a chain whose Ironwood activates at `activation`.
    pub fn new(activation: u32) -> Self {
        Self {
            activation,
            blocks: BTreeMap::new(),
        }
    }

    /// A publication of every zero-OVK payment through `end`, with NEAR's `sets`, for a
    /// chain whose genesis is `genesis` (internal byte order).
    pub fn publication(
        &mut self,
        stack: &Stack,
        end: u32,
        sets: &[ProviderSet],
        genesis: [u8; 32],
    ) -> Publication {
        self.index_through(stack, end);
        let payments: Vec<&(Receiver, Payment)> =
            self.blocks.values().flat_map(|b| &b.payments).collect();
        let mut totals: BTreeMap<[u8; 43], u32> = BTreeMap::new();
        for (receiver, _) in &payments {
            *totals.entry(*receiver.as_bytes()).or_default() += 1;
        }
        let mut pages: BTreeMap<[u8; 43], u32> = BTreeMap::new();
        let records: Vec<Record> = payments
            .into_iter()
            .map(|(receiver, payment)| {
                let key = *receiver.as_bytes();
                let page = pages.entry(key).or_default();
                let record = Record {
                    receiver: receiver.clone(),
                    page: *page,
                    total: totals[&key],
                    payment: payment.clone(),
                };
                *page += 1;
                record
            })
            .collect();
        let commitments: Vec<[u8; 32]> = self
            .blocks
            .values()
            .flat_map(|b| b.commitments.iter().copied())
            .collect();
        let manifest = Manifest {
            profile: PROFILE.into(),
            genesis,
            start_height: self.activation,
            start_parent: stack.block_hash(self.activation - 1),
            start_position: 0,
            end_height: end,
            end_hash: self.blocks[&end].hash,
            end_position: commitments.len() as u64,
            rows: MIN_ROWS,
            salt: [7; 32],
            records: 0,
            data_sha256: [0; 32],
            filters: Vec::new(),
            filters_sha256: [0; 32],
        };
        // The publisher validated every record before writing its row slot.
        let raw: Vec<RawRecord> = records
            .iter()
            .map(|r| {
                let slot = r.encode().expect("a valid record");
                RawRecord::decode(&slot)
                    .expect("a row slot")
                    .expect("a record")
            })
            .collect();
        let snapshot = Snapshot::build(manifest, &raw, sets).expect("a valid publication");
        let positions: BTreeSet<u32> = records
            .iter()
            .map(|r| u32::try_from(r.payment.position).expect("a regtest position"))
            .collect();
        let witnesses = (!commitments.is_empty()).then(|| {
            WitnessSnapshot::build(
                &witness_publication(&snapshot.manifest),
                &commitments,
                &positions,
            )
            .expect("witnesses build")
            .encode()
        });
        let server = Server::new(snapshot).expect("the PIR server prepares");
        Publication::new(server, witnesses)
    }

    /// Indexes the chain through `end`, reindexing from the lowest block a reorg replaced.
    fn index_through(&mut self, stack: &Stack, end: u32) {
        self.blocks.split_off(&(end + 1));
        // Reorgs replace the top of the chain, so check down from the top.
        let mut stale = None;
        for (height, block) in self.blocks.iter().rev() {
            if stack.block_hash(*height) == block.hash {
                break;
            }
            stale = Some(*height);
        }
        if let Some(height) = stale {
            self.blocks.split_off(&height);
        }
        let mut position: u64 = self
            .blocks
            .values()
            .map(|b| b.commitments.len() as u64)
            .sum();
        let next = self
            .blocks
            .keys()
            .next_back()
            .map_or(self.activation, |h| h + 1);
        for height in next..=end {
            let raw = stack.raw_block(height);
            let (header, transactions) = Block::read(&raw[..], &WalletNetwork::Regtest)
                .expect("a block parses")
                .into_parts();
            let mut indexed = IndexedBlock {
                hash: header.hash().0,
                commitments: Vec::new(),
                payments: Vec::new(),
            };
            for (tx_index, tx) in transactions.iter().enumerate() {
                let coinbase = tx.transparent_bundle().is_some_and(|b| b.is_coinbase());
                let Some(bundle) = tx.ironwood_bundle() else {
                    continue;
                };
                for (action_index, a) in bundle.actions().iter().enumerate() {
                    let cmx = a.cmx().to_bytes();
                    indexed.commitments.push(cmx);
                    if !coinbase {
                        let note = a.encrypted_note();
                        let action = Action {
                            cv: a.cv_net().to_bytes(),
                            nullifier: a.nullifier().to_bytes(),
                            cmx,
                            ephemeral_key: note.epk_bytes,
                            enc_ciphertext: note.enc_ciphertext,
                            out_ciphertext: note.out_ciphertext,
                        };
                        if let Some(receiver) =
                            action.recover_receiver().expect("a well-formed action")
                        {
                            let payment = Payment {
                                height,
                                block_hash: indexed.hash,
                                txid: *tx.txid().as_ref(),
                                tx_index: u32::try_from(tx_index).expect("fits"),
                                action_index: u32::try_from(action_index).expect("fits"),
                                position,
                                action_nullifier: action.nullifier,
                                cmx,
                                ephemeral_key: action.ephemeral_key,
                                ciphertext_prefix: note.enc_ciphertext[..52]
                                    .try_into()
                                    .expect("a fixed prefix"),
                            };
                            indexed.payments.push((receiver, payment));
                        }
                    }
                    position += 1;
                }
            }
            self.blocks.insert(height, indexed);
        }
    }

    /// The note commitment tree position of every zero-OVK payment to `receiver`, in chain
    /// order.
    pub fn positions(&self, receiver: &[u8; 43]) -> Vec<u64> {
        self.blocks
            .values()
            .flat_map(|b| &b.payments)
            .filter(|(r, _)| r.as_bytes() == receiver)
            .map(|(_, p)| p.position)
            .collect()
    }

    /// The Ironwood note commitment tree's size after `height`, once indexed.
    pub fn tree_size(&mut self, stack: &Stack, height: u32) -> u64 {
        self.index_through(stack, height);
        self.blocks
            .values()
            .map(|b| b.commitments.len() as u64)
            .sum()
    }
}

/// The receiver the zero OVK recovers from each of `tx`'s Ironwood actions, in order.
pub fn zero_ovk_receivers(
    tx: &zcash_primitives::transaction::Transaction,
) -> Vec<Option<[u8; 43]>> {
    tx.ironwood_bundle()
        .map(|bundle| {
            bundle
                .actions()
                .iter()
                .map(|a| {
                    let note = a.encrypted_note();
                    Action {
                        cv: a.cv_net().to_bytes(),
                        nullifier: a.nullifier().to_bytes(),
                        cmx: a.cmx().to_bytes(),
                        ephemeral_key: note.epk_bytes,
                        enc_ciphertext: note.enc_ciphertext,
                        out_ciphertext: note.out_ciphertext,
                    }
                    .recover_receiver()
                    .expect("a well-formed action")
                    .map(|r| *r.as_bytes())
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The fields of `manifest` its witness file binds to.
fn witness_publication(manifest: &Manifest) -> WitnessPublication {
    WitnessPublication {
        genesis: manifest.genesis,
        directory_revision: manifest.revision().expect("a valid manifest"),
        end_height: manifest.end_height,
        end_hash: manifest.end_hash,
        start_position: manifest.start_position,
        end_position: manifest.end_position,
        records: manifest.records,
    }
}

/// One publication's receiver routes, answered as the receiver service answers them:
/// its manifest, PIR setup, filters and witnesses, and real PIR evaluation of each
/// encrypted query. A session it does not serve is gone (410).
pub struct Publication {
    server: Server,
    id: String,
    witnesses: Option<Vec<u8>>,
}

impl Publication {
    /// Serves `server`'s publication with its common witness file, if it has one.
    fn new(server: Server, witnesses: Option<Vec<u8>>) -> Self {
        Self {
            id: hex::encode(server.id()),
            server,
            witnesses,
        }
    }

    /// The status and body for `method` on `path`.
    fn answer(&self, method: &http::Method, path: &str, body: &[u8]) -> (u16, Vec<u8>) {
        let route = path.strip_prefix("/v1/receiver/").unwrap_or(path);
        if (method, route) == (&http::Method::POST, "query") {
            return match self.server.respond(body) {
                Ok(response) => (200, response),
                Err(receiver_pir::Error::Revision) => (410, Vec::new()),
                Err(receiver_pir::Error::Malformed) => (400, Vec::new()),
                Err(_) => (500, Vec::new()),
            };
        }
        if method != http::Method::GET {
            return (404, Vec::new());
        }
        if route == "init" {
            let manifest = serde_json::to_vec(self.server.manifest()).expect("a manifest");
            return (200, manifest);
        }
        let Some((material, id)) = route.split_once('/') else {
            return (404, Vec::new());
        };
        if hex::decode(id).ok().filter(|id| id.len() == 32).is_none() {
            return (400, Vec::new());
        }
        if id != self.id {
            return (410, Vec::new());
        }
        match material {
            "public" => (200, self.server.public().to_vec()),
            "filters" => (200, self.server.filters().to_vec()),
            "witness" => match &self.witnesses {
                Some(bytes) => (200, bytes.clone()),
                None => (503, Vec::new()),
            },
            _ => (404, Vec::new()),
        }
    }
}

/// The directory's HTTP service on the loopback interface, which Vizor reaches through
/// its debug-only loopback transport (see `swap_private`).
pub struct DirectoryServer {
    current: Arc<Mutex<Option<Arc<Publication>>>>,
    requests: Arc<Mutex<Vec<String>>>,
    origin: String,
    _runtime: tokio::runtime::Runtime,
}

impl DirectoryServer {
    /// Serves no publication yet.
    pub fn start() -> Self {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("the directory runtime");
        let current: Arc<Mutex<Option<Arc<Publication>>>> = Arc::default();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let (served, log) = (current.clone(), requests.clone());
        let router = axum::Router::new().fallback(move |request: axum::extract::Request| {
            let (served, log) = (served.clone(), log.clone());
            async move {
                let method = request.method().clone();
                let path = request.uri().path().to_owned();
                log.lock().unwrap().push(format!("{method} {path}"));
                let body = axum::body::to_bytes(request.into_body(), usize::MAX)
                    .await
                    .expect("a request body");
                let publication = served.lock().unwrap().clone();
                let (status, body) = match publication {
                    Some(publication) => tokio::task::spawn_blocking(move || {
                        publication.answer(&method, &path, &body)
                    })
                    .await
                    .expect("the route answers"),
                    // Nothing published yet.
                    None => (503, Vec::new()),
                };
                (http::StatusCode::from_u16(status).expect("a status"), body)
            }
        });
        let listener = runtime
            .block_on(tokio::net::TcpListener::bind("127.0.0.1:0"))
            .expect("a loopback port");
        let origin = format!("http://{}", listener.local_addr().expect("an address"));
        runtime.spawn(async move {
            axum::serve(listener, router)
                .await
                .expect("the directory serves")
        });
        Self {
            current,
            requests,
            origin,
            _runtime: runtime,
        }
    }

    /// The plaintext loopback origin Vizor is pointed at.
    pub fn origin(&self) -> &str {
        &self.origin
    }

    /// Replaces the served publication. A session on the previous one is gone at once,
    /// as after the live indexer revokes it. These tests sync one wallet at a time, so
    /// no session spans a publish.
    pub fn publish(&self, publication: Publication) {
        *self.current.lock().unwrap() = Some(Arc::new(publication));
    }

    /// Encrypted lookups served so far.
    pub fn lookups(&self) -> usize {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .filter(|r| *r == "POST /v1/receiver/query")
            .count()
    }
}
