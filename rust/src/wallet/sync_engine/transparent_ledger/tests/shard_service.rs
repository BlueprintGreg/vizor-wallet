//! A real transparent shard service in process: a publisher that writes shards
//! for a synthetic mainnet chain, and wallet-pir's shard server answering the
//! requests a test transport hands it, so a test reaches real filters and
//! real PIR without a network.
//!
//! Adapted from wallet-libraries' `zakura/pir-transparent/tests/fixture`, which
//! adapted wallet-pir's shard-server test fixtures, through the crates' public
//! APIs only. Every shard has the smallest published geometry and no re-cut.
//! Block hashes follow the coordinator tests' main chain (`main_hash`), so a
//! wallet scanned with those tests' `scan` agrees with every shard boundary
//! the service publishes inside its scanned range.

use std::path::Path;
use std::sync::Arc;

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use sha2::{Digest, Sha256};
use tower::ServiceExt;
use transparent::address::TransparentAddress;
use transparent_events::{ReceiveEvent, SpendEvent, TransparentEvent, Txid};
use transparent_filter::{
    filter_hash, BlockHash, ScriptBytes, SealParameters, ShardMap, ShardMapEntry,
};
use transparent_shard::build::build_shard;
use transparent_shard::layout::{Geometry, RECENT_4K};
use transparent_shard::manifest::{
    ManifestLayout, ManifestOccupancy, ManifestSeal, ShardManifest, TableGeometry, SCHEMA,
};
use transparent_shard_server::service::{router, ServiceConfig, ServiceState};
use transparent_shard_server::shardset::{ShardSet, DEFAULT_RETAIN_REVISIONS};

use crate::wallet::sync_engine::enhancement::{ObservedRequest, RequestObserver};

/// Every shard's geometry: the smallest one a build publishes, which keeps the
/// tables a test sets up and queries small.
const GEOMETRY: &Geometry = &RECENT_4K;

/// The seal thresholds the publisher seals under.
const SEAL: SealParameters = SealParameters {
    max_scripts: 2_048,
    max_page_rows: 1_024,
    max_txids: 0,
};

/// One shard: its range, whether it is sealed, every event in it, keyed by
/// the script it concerns, and which revision of the shard it is.
pub(super) struct ShardSpec {
    pub(super) start: u64,
    pub(super) end: u64,
    pub(super) sealed: bool,
    pub(super) events: Vec<(ScriptBytes, TransparentEvent)>,
    /// Zero for a shard published once. A republished tail advances it and
    /// names the manifest digest it supersedes, as a publisher must.
    pub(super) revision: u32,
    pub(super) supersedes: String,
}

impl ShardSpec {
    /// The first revision of a shard.
    pub(super) fn first(
        start: u64,
        end: u64,
        sealed: bool,
        events: Vec<(ScriptBytes, TransparentEvent)>,
    ) -> Self {
        Self {
            start,
            end,
            sealed,
            events,
            revision: 0,
            supersedes: String::new(),
        }
    }
}

/// The pay-to-public-key-hash script of `address`.
pub(super) fn script(address: TransparentAddress) -> ScriptBytes {
    match address {
        TransparentAddress::PublicKeyHash(hash) => {
            ScriptBytes::new([&[0x76, 0xa9, 20][..], &hash, &[0x88, 0xac]].concat())
        }
        TransparentAddress::ScriptHash(_) => panic!("derived addresses pay to public key hashes"),
    }
}

/// The txid of the transaction tagged `tag`.
pub(super) fn tagged(tag: u64) -> Txid {
    let mut txid = [0u8; 32];
    txid[..8].copy_from_slice(&tag.to_le_bytes());
    txid[31] = 0x77;
    Txid(txid)
}

/// A receive of [`RECEIVED`] zatoshis at `height` in the transaction tagged
/// `tag`, its output 0.
pub(super) fn receive(height: u64, tag: u64) -> TransparentEvent {
    TransparentEvent::Receive(ReceiveEvent {
        metadata: None,
        height: height as u32,
        txid: tagged(tag),
        transaction_index: 1,
        output_index: 0,
        value: RECEIVED,
        coinbase: false,
    })
}

/// What every [`receive`] pays.
pub(super) const RECEIVED: u64 = 50_000;

/// A spend at `height`, in the transaction tagged `tag`, of output 0 of the
/// transaction tagged `spent`.
pub(super) fn spend(height: u64, tag: u64, spent: u64) -> TransparentEvent {
    TransparentEvent::Spend(SpendEvent {
        metadata: None,
        height: height as u32,
        spending_txid: tagged(tag),
        transaction_index: 1,
        input_index: 0,
        spent_txid: tagged(spent),
        spent_output_index: 0,
    })
}

/// Receives to scripts no account derives, spread over `[start, end]`, so that
/// a test's scripts are not alone in a shard.
pub(super) fn noise(start: u64, end: u64, salt: u32) -> Vec<(ScriptBytes, TransparentEvent)> {
    (0..40u32)
        .map(|n| {
            let tag = salt * 1_000 + n;
            let mut bytes = vec![0x76, 0xa9, 20];
            bytes.extend_from_slice(&tag.to_le_bytes());
            bytes.extend_from_slice(&[0xee; 16]);
            bytes.extend_from_slice(&[0x88, 0xac]);
            let height = start + u64::from(n * 7) % (end - start + 1);
            (
                ScriptBytes::new(bytes),
                receive(height, u64::from(tag) + 100_000),
            )
        })
        .collect()
}

/// The block hash at `height` on the coordinator tests' chain `fork`
/// (`chain_hash`; fork 0 is `main_hash`).
fn synthetic(height: u64, fork: u8) -> BlockHash {
    let mut bytes = [0u8; 32];
    bytes[..4].copy_from_slice(&(height as u32).to_le_bytes());
    bytes[4] = fork;
    bytes[31] = 1;
    BlockHash::from_internal_bytes(bytes)
}

/// A shard service serving one publication, answering in process.
pub(super) struct ShardService {
    runtime: Arc<tokio::runtime::Runtime>,
    router: axum::Router,
    /// The map published, for a later revision to supersede its entries.
    map: ShardMap,
    _dir: tempfile::TempDir,
}

impl ShardService {
    /// Publishes `shards`, numbered from zero, and serves them.
    pub(super) fn publish(shards: &[ShardSpec]) -> Self {
        Self::publish_forked(shards, u64::MAX)
    }

    /// Like [`Self::publish`], but on chain fork 1 from `fork_from` up: every
    /// block hash the publication names at or above it differs from the main
    /// chain's.
    pub(super) fn publish_forked(shards: &[ShardSpec], fork_from: u64) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let map = publish(dir.path(), shards, |height| {
            synthetic(height, u8::from(height >= fork_from))
        });
        let set = ShardSet::open(dir.path(), DEFAULT_RETAIN_REVISIONS).expect("a verified set");
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap();
        let state = runtime
            .block_on(async { ServiceState::build(set, ServiceConfig::default()) })
            .expect("a service");
        Self {
            runtime: Arc::new(runtime),
            router: router(state),
            map,
            _dir: dir,
        }
    }

    /// The manifest digest this service publishes for shard `shard_id`.
    pub(super) fn digest(&self, shard_id: usize) -> String {
        self.map.shards[shard_id].manifest_digest.clone()
    }

    /// An observer answering every request with the service's own reply.
    ///
    /// The transport consults it inside its own runtime, so each request is
    /// served on this service's runtime from a thread of its own.
    pub(super) fn observer(&self) -> RequestObserver {
        self.observer_with(|_, _, _| {})
    }

    /// Like [`Self::observer`], but `tamper` may rewrite each reply's status,
    /// headers and body before the wallet reads it: a misbehaving service
    /// in front of real data.
    pub(super) fn observer_with(
        &self,
        tamper: impl Fn(&ObservedRequest, &mut http::response::Parts, &mut Vec<u8>)
            + Send
            + Sync
            + 'static,
    ) -> RequestObserver {
        let (runtime, router) = (self.runtime.clone(), self.router.clone());
        RequestObserver::answering(move |observed| {
            let request = http::Request::builder()
                .method(observed.method.clone())
                .uri(observed.path.clone())
                .body(axum::body::Body::from(observed.body.clone()))
                .unwrap();
            let (runtime, router) = (runtime.clone(), router.clone());
            let (mut parts, mut body) = std::thread::spawn(move || {
                runtime.block_on(async move {
                    let response = router.oneshot(request).await.unwrap();
                    let (parts, body) = response.into_parts();
                    (parts, body.collect().await.unwrap().to_bytes().to_vec())
                })
            })
            .join()
            .unwrap();
            tamper(observed, &mut parts, &mut body);
            http::Response::from_parts(parts, Full::new(Bytes::from(body)))
        })
    }
}

/// Writes a publishable shard set for `shards` to `dir`, as the publisher
/// would: one directory per manifest digest and the map in `shards.json`.
fn publish(dir: &Path, shards: &[ShardSpec], hash: impl Fn(u64) -> BlockHash) -> ShardMap {
    let genesis = BlockHash::from_display_hex(transparent_filter::MAINNET_GENESIS_DISPLAY)
        .expect("mainnet's genesis hash");
    let mut entries = Vec::new();
    let mut parent_digest = String::new();
    for (shard_id, spec) in shards.iter().enumerate() {
        let shard_id = shard_id as u64;
        let built = build_shard(
            shard_id,
            spec.start,
            spec.end,
            genesis,
            hash(spec.end),
            transparent_filter::RANGE_PROFILE,
            GEOMETRY,
            &spec.events,
        )
        .expect("a buildable shard");
        let segments = |tables: &[Vec<u8>], rows: u64, row_bytes: usize| -> Vec<TableGeometry> {
            tables
                .iter()
                .map(|segment| TableGeometry {
                    rows,
                    row_bytes: row_bytes as u32,
                    sha256: hex::encode(Sha256::digest(segment)),
                })
                .collect()
        };
        let manifest = ShardManifest {
            schema: SCHEMA.to_string(),
            profile: transparent_filter::RANGE_PROFILE.to_string(),
            geometry: GEOMETRY.name.to_string(),
            network: transparent_filter::NETWORK.to_string(),
            genesis_hash: transparent_filter::MAINNET_GENESIS_DISPLAY.to_string(),
            shard_id,
            start_height: spec.start,
            end_height: spec.end,
            parent_block_hash: hash(spec.start - 1).to_display_hex(),
            terminal_block_hash: hash(spec.end).to_display_hex(),
            tag_salt_counter: built.tag_salt_counter,
            parent_manifest_digest: parent_digest.clone(),
            sealed: spec.sealed,
            revision: spec.revision,
            supersedes: spec.supersedes.clone(),
            seal: ManifestSeal {
                scripts_target: SEAL.max_scripts,
                scripts_capacity: SEAL.max_scripts * 2,
                page_rows_target: SEAL.max_page_rows,
                page_rows_capacity: SEAL.max_page_rows * 2,
            },
            layout: ManifestLayout {
                max_script_bytes: transparent_shard::MAX_SCRIPT_BYTES as u32,
                inline_events: transparent_shard::INLINE_EVENTS,
                events_per_page: transparent_shard::EVENTS_PER_PAGE,
                page_row_header_bytes: transparent_shard::PAGE_ROW_HEADER_BYTES as u32,
                page_entry_header_bytes: transparent_shard::PAGE_ENTRY_HEADER_BYTES as u32,
                directory_choices: transparent_shard::build::DIRECTORY_CHOICES as u32,
            },
            filter_hash: filter_hash(built.filter.as_slice()).to_display_hex(),
            directory_segments: segments(
                &built.directory,
                GEOMETRY.directory_rows,
                GEOMETRY.directory_row_bytes,
            ),
            page_segments: segments(&built.pages, GEOMETRY.page_rows, GEOMETRY.page_row_bytes),
            occupancy: ManifestOccupancy {
                scripts: built.scripts,
                page_rows: built.page_rows,
                fragments: built.fragments,
                events: built.events,
                blocks: spec.end - spec.start + 1,
                txids: 0,
                excluded_scripts: built.excluded_scripts,
            },
            directory_choice: None,
        };
        let digest = manifest.digest();
        let shard_dir = dir.join(&digest);
        std::fs::create_dir_all(&shard_dir).unwrap();
        std::fs::write(shard_dir.join("manifest.json"), manifest.canonical_bytes()).unwrap();
        std::fs::write(shard_dir.join("filter.bin"), built.filter.as_slice()).unwrap();
        for (index, segment) in built.directory.iter().enumerate() {
            std::fs::write(shard_dir.join(format!("directory.{index}.bin")), segment).unwrap();
        }
        for (index, segment) in built.pages.iter().enumerate() {
            std::fs::write(shard_dir.join(format!("pages.{index}.bin")), segment).unwrap();
        }
        entries.push(ShardMapEntry {
            shard_id,
            geometry: GEOMETRY.name.to_string(),
            start_height: spec.start,
            end_height: spec.end,
            parent_block_hash: manifest.parent_block_hash.clone(),
            terminal_block_hash: manifest.terminal_block_hash.clone(),
            filter_hash: manifest.filter_hash.clone(),
            scripts: built.scripts,
            page_rows: built.page_rows,
            txids: 0,
            directory_segments: built.directory_segments(),
            page_segments: built.page_segments(),
            manifest_digest: digest.clone(),
            revision: spec.revision,
            sealed: spec.sealed,
        });
        parent_digest = digest;
    }
    let map = ShardMap {
        genesis_hash: transparent_filter::MAINNET_GENESIS_DISPLAY.to_string(),
        network: transparent_filter::NETWORK.to_string(),
        profile: transparent_filter::RANGE_PROFILE.to_string(),
        range_envelope_version: transparent_filter::RANGE_ENVELOPE_VERSION,
        start_height: shards[0].start,
        seal: [(GEOMETRY.name.to_string(), SEAL)].into_iter().collect(),
        shards: entries,
        recuts: vec![],
    };
    map.check_shape().expect("a well-formed map");
    std::fs::write(dir.join("shards.json"), serde_json::to_vec(&map).unwrap()).unwrap();
    map
}
