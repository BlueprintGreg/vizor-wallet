//! Exercises the app worker against production filter encoding and encrypted PIR.
use super::*;
use std::sync::Mutex;
use zakura_pir_receiver::{
    receiver_directory::{
        blocks::{BlockFilter, BlockId},
        snapshot::{Manifest, Snapshot, PROFILE},
    },
    receiver_pir::{server::Server, MIN_ROWS},
};
use zcash_client_backend::data_api::{chain::BlockSource, testing::TestBuilder, WalletRead};
use zcash_client_sqlite::testing::{db::TestDbFactory, BlockCache};

/// Serves real immutable directory material and counts wire bodies by route.
struct Service {
    server: Server,
    head: Head,
    filters: Vec<BlockFilter>,
    requests: Mutex<Vec<(String, usize, usize)>>,
}
impl Service {
    /// Routes a request through the production encoder or encrypted PIR server.
    fn reply(&self, url: &str, body: &[u8], limit: usize) -> Result<Vec<u8>, DirectoryError> {
        let route = url.split("/v1/receiver/").nth(1).unwrap();
        let response = if route == "init" {
            serde_json::to_vec(self.server.manifest()).unwrap()
        } else if route == "block-filters/head" {
            serde_json::to_vec(&self.head).unwrap()
        } else if let Some(range) = route.strip_prefix("block-filters/0/") {
            let (from, count) = range.split_once('/').unwrap();
            let from: u32 = from.parse().unwrap();
            let count: usize = count.parse().unwrap();
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
        } else if route.starts_with("public/") {
            self.server.public().to_vec()
        } else if route == "query" {
            self.server.respond(body).unwrap()
        } else {
            panic!("unexpected receiver route {route}")
        };
        assert!(response.len() <= limit);
        self.requests
            .lock()
            .unwrap()
            .push((route.into(), body.len(), response.len()));
        Ok(response)
    }

    /// Counts actual encrypted address queries, excluding setup and public hints.
    fn queries(&self) -> usize {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .filter(|(route, _, _)| route == "query")
            .count()
    }

    /// Reports actual request and response body bytes, including public setup.
    fn bytes(&self) -> usize {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .map(|(_, request, response)| request + response)
            .sum()
    }
}
impl Transport for Service {
    /// Returns a bounded encoded public resource.
    async fn get(&self, url: &str, limit: usize) -> Result<Vec<u8>, DirectoryError> {
        self.reply(url, &[], limit)
    }
    /// Evaluates a real encrypted query without exposing its receiver to the fixture.
    async fn post(
        &self,
        url: &str,
        body: Vec<u8>,
        limit: usize,
    ) -> Result<Vec<u8>, DirectoryError> {
        self.reply(url, &body, limit)
    }
}

/// Runs near-head negative/positive hints and unavailable-history catch-up through the app worker.
#[test]
fn worker_filters_and_direct_catchup_use_real_pir() {
    if crate::wallet::db::isolated_test(
        module_path!(),
        "worker_filters_and_direct_catchup_use_real_pir",
    ) {
        return;
    }
    crate::api::sync::set_enhance_pir_enabled(true);
    crate::api::sync::set_near_swap_privacy_enabled(true);
    let network = WalletNetwork::Main;
    let activation = network.activation_height(NetworkUpgrade::Nu6_3).unwrap();
    let height = |upgrade| network.activation_height(upgrade);
    let mut st = TestBuilder::new()
        .with_network(zcash_protocol::local_consensus::LocalNetwork {
            overwinter: height(NetworkUpgrade::Overwinter),
            sapling: height(NetworkUpgrade::Sapling),
            blossom: height(NetworkUpgrade::Blossom),
            heartwood: height(NetworkUpgrade::Heartwood),
            canopy: height(NetworkUpgrade::Canopy),
            nu5: height(NetworkUpgrade::Nu5),
            nu6: height(NetworkUpgrade::Nu6),
            nu6_1: height(NetworkUpgrade::Nu6_1),
            nu6_2: height(NetworkUpgrade::Nu6_2),
            nu6_3: Some(activation),
            nu7: None,
        })
        .with_data_store_factory(TestDbFactory::default())
        .with_block_cache(BlockCache::new())
        .with_initial_chain_state(|_, _| {
            zcash_client_backend::data_api::testing::InitialChainState {
                chain_state: zcash_client_backend::data_api::chain::ChainState::empty(
                    activation - 1,
                    BlockHash([0; 32]),
                ),
                prior_sapling_roots: vec![],
                prior_orchard_roots: vec![],
            }
        })
        .with_account_having_current_birthday()
        .build();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("wallet.db");
    let path = path.to_str().unwrap();
    let (account, _) = crate::wallet::keys::init_db_and_create_account(
        path,
        network,
        &secrecy::SecretVec::new(vec![4; 32]),
        Some(u64::from(u32::from(activation))),
        "Recovery",
    )
    .unwrap();
    let account = crate::wallet::keys::parse_account_uuid(&account).unwrap();
    let mut previous = zcash_client_backend::data_api::chain::ChainState::empty(
        activation - 1,
        BlockHash([0; 32]),
    );
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let generation = CANCEL.load(Ordering::SeqCst);
    let mut total_bytes = Vec::new();
    for mode in 0..4 {
        let count = if mode == 0 { 3 } else { 2 };
        st.generate_and_scan_empty_blocks(count);
        let end = st.wallet().block_fully_scanned().unwrap().unwrap();
        let end_height = u32::from(end.block_height());
        let mut db =
            open_existing_wallet_db_with_timeout(path, network, WALLET_DB_BUSY_TIMEOUT).unwrap();
        zcash_client_backend::data_api::WalletWrite::update_chain_tip(&mut db, end.block_height())
            .unwrap();
        zcash_client_backend::data_api::chain::scan_cached_blocks(
            &network,
            st.cache(),
            &mut db,
            previous.block_height() + 1,
            &previous,
            count,
        )
        .unwrap();
        previous = zcash_client_backend::data_api::chain::ChainState::empty(
            end.block_height(),
            end.block_hash(),
        );
        let receivers = if mode == 2 {
            db.one_time_receivers(account).unwrap().1
        } else {
            vec![]
        };
        let mut filters = Vec::new();
        st.cache()
            .with_blocks::<_, ()>(Some(activation), None, |block| {
                let hits: Vec<_> = if mode == 2 && block.height == u64::from(end_height) {
                    vec![receivers[0].receiver]
                } else {
                    vec![]
                };
                filters.push(
                    BlockFilter::build(
                        &MAINNET_GENESIS,
                        BlockId {
                            height: block.height.try_into().unwrap(),
                            hash: block.hash().0,
                        },
                        block.prev_hash().0,
                        &hits,
                    )
                    .unwrap(),
                );
                Ok(())
            })
            .unwrap();
        let manifest = Manifest {
            profile: PROFILE.into(),
            history_revision: 0,
            genesis: MAINNET_GENESIS,
            start_height: activation.into(),
            start_parent: filters[0].parent(),
            start_position: 0,
            end_height,
            end_hash: end.block_hash().0,
            end_position: 0,
            rows: MIN_ROWS,
            salt: [5; 32],
            records: 0,
            data_sha256: [0; 32],
        };
        let service = Service {
            server: Server::new(Snapshot::build(manifest, &[]).unwrap()).unwrap(),
            head: Head {
                genesis: MAINNET_GENESIS,
                revision: 0,
                first: if mode == 3 {
                    end_height
                } else {
                    activation.into()
                },
                tip: BlockId {
                    height: end_height,
                    hash: end.block_hash().0,
                },
            },
            filters,
            requests: Mutex::new(Vec::new()),
        };
        runtime.block_on(async {
            recover_with_transport(
                &path,
                network,
                None,
                "https://receiver.test",
                &service,
                generation,
                tokio::time::Instant::now() + Duration::from_secs(45),
            )
            .await
            .unwrap();
        });
        let state = db
            .one_time_recovery(account, one_time_ivk::now().unwrap())
            .unwrap();
        assert!(state.restore_complete);
        assert!(state.lookups.is_empty());
        assert_eq!(service.queries(), [4, 0, 1, 4][mode], "mode {mode}");
        total_bytes.push(service.bytes());
        if mode == 3 {
            assert!(!service
                .requests
                .lock()
                .unwrap()
                .iter()
                .any(|(route, _, _)| route.starts_with("block-filters/0/")));
        }
    }
    assert!(total_bytes[1] < total_bytes[3]);
    println!(
        "receiver body bytes: initial={}, negative={}, positive={}, expired-history={}",
        total_bytes[0], total_bytes[1], total_bytes[2], total_bytes[3]
    );
}
