//! Desktop wallet-link import of two software accounts into a synced mobile wallet.
//!
//! The mobile link flow adds every selected account in turn, with no scan between them
//! (`AccountNotifier._importLinkedWalletAccounts`), so each account's rewind starts from the
//! state the previous one left. This case drives that sequence through the same Rust entry
//! point, `import_software_account_at_index`, after NU6.3 activation and a run of blocks that
//! each spend Orchard notes into Ironwood outputs. The mobile wallet keeps up with the chain
//! while it grows, as an app in use does, so the trees receiving commitments (Ironwood, and
//! Orchard, whose spend actions append commitments too) end with fewer old checkpoints than the
//! Sapling tree, and below them only ZIP 318 anchors remain. Both imports must succeed, the
//! rescan must recover the linked account's funds, and the account must be able to spend them.
//!
//! Run against a fresh chain, since the stack refuses to start past activation:
//!
//! ```text
//! scripts/ironwood-regtest/reset.sh && scripts/ironwood-regtest/up.sh
//! cd rust && cargo test --test ironwood_regtest_linked_import -- --ignored --nocapture
//! ```

use std::path::{Path, PathBuf};
use std::process::Command;

use rust_lib_zcash_wallet::api::{simple as simple_api, sync as sync_api, wallet as wallet_api};

const NETWORK: &str = "regtest";
/// Interval of the ZIP 318 anchors every pool's tree retains from NU6.3 activation.
const ANCHOR_INTERVAL: u64 = 144;
/// Number of the newest checkpoints each note commitment tree keeps besides anchors.
const PRUNING_DEPTH: u64 = 100;
/// Consecutive blocks, ending at the scanned tip, that each carry Ironwood outputs.
const ACTIVITY_BLOCKS: u64 = 120;
/// Most blocks the mobile wallet falls behind before it syncs again. A wallet that keeps up
/// scans blocks in order, so each tree checkpoints, and retains, every anchor height as the
/// scan passes it. A first sync instead scans the tip range first, and a tree that has already
/// pruned skips the older heights it is asked to checkpoint later.
const SYNC_STEP: u64 = 60;
/// Orchard notes funded to the wallet that produces the activity. Each block's send spends at
/// least one, and note selection may consolidate a second into the same action envelope.
const ACTIVITY_NOTES: usize = 260;
/// Notes per funding transaction, within the regtest node's per-transaction action limit.
const FUNDING_BATCH_NOTES: usize = 50;
const ACTIVITY_ZATOSHI: u64 = 10_000;
const MOBILE_FUNDING: &str = "1.0";
const MOBILE_FUNDING_ZATOSHI: u64 = 100_000_000;
const LINKED_FUNDING: &str = "0.5";
const LINKED_FUNDING_ZATOSHI: u64 = 50_000_000;
const LINKED_SEND_ZATOSHI: u64 = 10_000_000;
/// Birthday both linked accounts carry, far below the pruning window, as a desktop account's
/// first-transaction height is.
const LINKED_BIRTHDAY: u64 = 10;
const TRUSTED_CONFIRMATIONS: u32 = 10;

#[test]
#[ignore = "requires the Dockerized Ironwood zcashd/lightwalletd regtest stack"]
fn linked_accounts_import_back_to_back_after_dense_ironwood_activity() {
    let activation = u64::from(activation_height());
    simple_api::configure_regtest_ironwood_activation_height(activation_height())
        .expect("configure wallet NU6.3 activation");
    ensure_stack_up();
    let start_tip = latest_height();
    assert!(
        start_tip < activation,
        "test must begin before NU6.3: tip={start_tip}, activation={activation}"
    );

    // The mobile wallet, funded the way a wallet in use is.
    let mobile_dir = tempfile::tempdir().expect("mobile wallet tempdir");
    let db = path_string(&mobile_dir.path().join("zcash_wallet.db"));
    let mobile = wallet_api::create_wallet(
        NETWORK.to_string(),
        db.clone(),
        Some(start_tip),
        Some("Mobile primary".to_string()),
    )
    .expect("create mobile wallet");
    run_harness("fund-orchard.sh", &[&mobile.unified_address, MOBILE_FUNDING, "10"]);
    sync_to_tip(&db);

    // Two desktop accounts; the first has received funds the link must bring across.
    let linked_a_mnemonic = wallet_api::generate_mnemonic();
    let linked_b_mnemonic = wallet_api::generate_mnemonic();
    let linked_a_address = orchard_addresses(&linked_a_mnemonic, 1).remove(0);
    run_harness("fund-orchard.sh", &[&linked_a_address, LINKED_FUNDING, "1"]);

    // A wallet that will spend one Orchard note per block after activation.
    let activity_mnemonic = wallet_api::generate_mnemonic();
    for batch in orchard_addresses(&activity_mnemonic, ACTIVITY_NOTES).chunks(FUNDING_BATCH_NOTES)
    {
        let destinations = serde_json::to_string(batch).expect("funding destinations");
        let amount = format!("{:.8}", batch.len() as f64 * 0.01);
        let note_count = batch.len().to_string();
        run_harness(
            "fund-orchard.sh",
            &[&destinations, &amount, "1", "1", &note_count],
        );
    }
    sync_to_tip(&db);

    run_harness("activate-ironwood.sh", &[]);
    assert_eq!(latest_height(), activation);
    sync_to_tip(&db);

    let activity_dir = tempfile::tempdir().expect("activity wallet tempdir");
    let activity_db = path_string(&activity_dir.path().join("zcash_wallet.db"));
    let activity = wallet_api::import_wallet(
        activity_mnemonic.clone(),
        String::new(),
        Some(start_tip),
        NETWORK.to_string(),
        activity_db.clone(),
        Some("Activity".to_string()),
    )
    .expect("import activity wallet");
    sync_to_tip(&activity_db);
    let sink_dir = tempfile::tempdir().expect("sink wallet tempdir");
    let sink = wallet_api::create_wallet(
        NETWORK.to_string(),
        path_string(&sink_dir.path().join("zcash_wallet.db")),
        Some(activation),
        Some("Sink".to_string()),
    )
    .expect("create sink wallet");

    // Quiet blocks, then blocks that each carry Ironwood outputs, with the mobile wallet
    // keeping up throughout.
    let tip = planned_tip(latest_height() + ACTIVITY_BLOCKS + 1, activation);
    let activity_start = tip - (ACTIVITY_BLOCKS - 1);
    while latest_height() + 1 < activity_start {
        let quiet = (activity_start - 1 - latest_height()).min(SYNC_STEP);
        run_harness("mine.sh", &[&quiet.to_string()]);
        sync_to_tip(&db);
    }
    for expected_height in activity_start..=tip {
        sync_to_tip(&activity_db);
        send(
            &activity_db,
            &activity.account_uuid,
            &activity_mnemonic,
            &sink.unified_address,
            ACTIVITY_ZATOSHI,
        );
        run_harness("mine.sh", &["1"]);
        assert_eq!(latest_height(), expected_height);
        if (expected_height - activity_start + 1) % SYNC_STEP == 0 {
            sync_to_tip(&db);
        }
    }
    sync_to_tip(&db);

    let sapling = pool_checkpoints(&db, "sapling");
    let orchard = pool_checkpoints(&db, "orchard");
    let ironwood = pool_checkpoints(&db, "ironwood");
    eprintln!("chain: activation {activation}, activity {activity_start}..={tip}");
    for line in [
        describe("sapling", &sapling),
        describe("orchard", &orchard),
        describe("ironwood", &ironwood),
    ] {
        eprintln!("before import: {line}");
    }
    // The layout the app's sync leaves: the trees receiving commitments keep the newest
    // checkpoints, the Sapling tree keeps older ones, and anchors remain below.
    assert_eq!(ironwood.ordinary.len() as u64, PRUNING_DEPTH);
    assert!(matches!(
        (sapling.ordinary.first(), ironwood.ordinary.first()),
        (Some(sapling_oldest), Some(ironwood_oldest)) if sapling_oldest < ironwood_oldest
    ));
    assert!(ironwood
        .retained
        .iter()
        .any(|&height| height < activity_start));

    // The link import, account by account with no scan in between, as the app runs it.
    let first = wallet_api::import_software_account_at_index(
        linked_a_mnemonic.clone(),
        String::new(),
        Some(LINKED_BIRTHDAY),
        NETWORK.to_string(),
        db.clone(),
        "Linked A".to_string(),
        0,
        false,
    );
    let second = wallet_api::import_software_account_at_index(
        linked_b_mnemonic,
        String::new(),
        Some(LINKED_BIRTHDAY),
        NETWORK.to_string(),
        db.clone(),
        "Linked B".to_string(),
        0,
        false,
    );
    let listed = wallet_api::list_accounts(db.clone(), NETWORK.to_string()).expect("list accounts");
    eprintln!("first import: {:?}", first.as_ref().err());
    eprintln!("second import: {:?}", second.as_ref().err());
    eprintln!("accounts after imports: {}", listed.len());
    let linked_a = first.expect("first linked import");
    second.expect("second linked import");
    assert_eq!(listed.len(), 3);

    // The rescan brings the linked account's history across and leaves the others intact.
    sync_to_tip(&db);
    assert_eq!(balance(&db, &mobile.account_uuid).orchard, MOBILE_FUNDING_ZATOSHI);
    assert_eq!(balance(&db, &linked_a.account_uuid).orchard, LINKED_FUNDING_ZATOSHI);

    // The recovered note is spendable: its witness exists after the rewind and rescan.
    send(
        &db,
        &linked_a.account_uuid,
        &linked_a_mnemonic,
        &mobile.unified_address,
        LINKED_SEND_ZATOSHI,
    );
    run_harness("mine.sh", &[&TRUSTED_CONFIRMATIONS.to_string()]);
    sync_to_tip(&db);
    assert_eq!(balance(&db, &mobile.account_uuid).ironwood, LINKED_SEND_ZATOSHI);
}

#[test]
fn planned_tip_keeps_anchors_out_of_the_second_floor_gap() {
    for activation in [1, 500] {
        for minimum in [130, 250, 621, 1_000] {
            let tip = planned_tip(minimum, activation);
            let second_floor = tip - 2 * (PRUNING_DEPTH - 1);
            let activity_start = tip - (ACTIVITY_BLOCKS - 1);
            assert!(tip >= minimum);
            assert!((activation..second_floor).any(|height| height % ANCHOR_INTERVAL == 0));
            assert!((second_floor..activity_start).all(|height| height % ANCHOR_INTERVAL != 0));
        }
    }
}

/// The lowest tip at or above `minimum` for which the second import's pruning floor, under a
/// floor taken from `MAX(blocks.height)`, lies below the first activity block with no anchor
/// between them, and with an anchor at or above `activation` below it. A tip that puts an
/// anchor in that gap would let every pool agree on the anchor and hide the failure this case
/// exists to observe.
fn planned_tip(minimum: u64, activation: u64) -> u64 {
    let lowest = 2 * (PRUNING_DEPTH - 1) + ACTIVITY_BLOCKS;
    (minimum.max(lowest)..)
        .find(|&tip| {
            let second_floor = tip - 2 * (PRUNING_DEPTH - 1);
            let activity_start = tip - (ACTIVITY_BLOCKS - 1);
            (activation..second_floor).any(|height| height % ANCHOR_INTERVAL == 0)
                && !(second_floor..activity_start).any(|height| height % ANCHOR_INTERVAL == 0)
        })
        .expect("a tip satisfying the anchor layout")
}

struct PoolCheckpoints {
    ordinary: Vec<u64>,
    retained: Vec<u64>,
}

fn pool_checkpoints(db: &str, pool: &str) -> PoolCheckpoints {
    let conn =
        rusqlite::Connection::open_with_flags(db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .expect("open wallet db read-only");
    let heights = |sql: &str| -> Vec<u64> {
        let mut statement = conn.prepare(sql).expect("prepare checkpoint query");
        statement
            .query_map([], |row| row.get::<_, i64>(0))
            .expect("query checkpoints")
            .map(|height| u64::try_from(height.expect("checkpoint row")).expect("height"))
            .collect()
    };
    let retained = heights(&format!(
        "SELECT checkpoint_id FROM {pool}_tree_retained_checkpoints ORDER BY checkpoint_id"
    ));
    let ordinary = heights(&format!(
        "SELECT checkpoint_id FROM {pool}_tree_checkpoints ORDER BY checkpoint_id"
    ))
    .into_iter()
    .filter(|height| !retained.contains(height))
    .collect();
    PoolCheckpoints { ordinary, retained }
}

fn describe(name: &str, checkpoints: &PoolCheckpoints) -> String {
    format!(
        "{name}: ordinary {} in [{:?}..{:?}], retained {:?}",
        checkpoints.ordinary.len(),
        checkpoints.ordinary.first(),
        checkpoints.ordinary.last(),
        checkpoints.retained,
    )
}

/// Diversified receive addresses of the first account of `mnemonic`, derived in a throwaway
/// wallet so that the funded wallet's own address state stays untouched.
fn orchard_addresses(mnemonic: &str, count: usize) -> Vec<String> {
    let tempdir = tempfile::tempdir().expect("address tempdir");
    let db = path_string(&tempdir.path().join("zcash_wallet.db"));
    let wallet = wallet_api::import_wallet(
        mnemonic.to_string(),
        String::new(),
        Some(1),
        NETWORK.to_string(),
        db.clone(),
        Some("Addresses".to_string()),
    )
    .expect("import address wallet");
    sync_api::update_chain_tip(db.clone(), NETWORK.to_string(), 1)
        .expect("initialize address wallet chain tip");
    let mut addresses = vec![wallet.unified_address];
    while addresses.len() < count {
        addresses.push(
            sync_api::get_next_available_address(
                db.clone(),
                NETWORK.to_string(),
                wallet.account_uuid.clone(),
                "orchard".to_string(),
            )
            .expect("diversified Orchard address"),
        );
    }
    addresses
}

fn send(db: &str, account_uuid: &str, mnemonic: &str, to_address: &str, amount_zatoshi: u64) {
    let send_flow_id = "linked-import-e2e";
    let proposal = sync_api::propose_send(
        db.to_string(),
        NETWORK.to_string(),
        account_uuid.to_string(),
        send_flow_id.to_string(),
        to_address.to_string(),
        amount_zatoshi,
        None,
    )
    .expect("propose send");
    assert!(!proposal.needs_sapling_params);
    sync_api::execute_proposal(
        db.to_string(),
        lightwalletd_url(),
        proposal.proposal_id,
        send_flow_id.to_string(),
        mnemonic.as_bytes().to_vec(),
        None,
        None,
    )
    .expect("execute send");
}

fn sync_to_tip(db: &str) {
    let tip = latest_height();
    sync_api::run_full_sync_blocking(db.to_string(), lightwalletd_url(), NETWORK.to_string(), 1)
        .expect("sync wallet");
    let status = sync_api::get_sync_status(db.to_string(), NETWORK.to_string())
        .expect("read sync status");
    assert!(status.is_complete, "sync did not complete");
    assert_eq!(status.chain_tip_height, tip);
    assert_eq!(status.scanned_height, tip);
}

fn balance(db: &str, account_uuid: &str) -> sync_api::WalletBalance {
    sync_api::get_balance(db.to_string(), NETWORK.to_string(), account_uuid.to_string())
        .expect("wallet balance")
}

fn activation_height() -> u32 {
    std::env::var("IRONWOOD_ACTIVATION_HEIGHT")
        .unwrap_or_else(|_| "500".to_string())
        .parse()
        .expect("IRONWOOD_ACTIVATION_HEIGHT must be a u32")
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust crate must be inside the repository")
        .to_path_buf()
}

fn path_string(path: &Path) -> String {
    path.to_str().expect("UTF-8 path").to_string()
}

fn run_harness(script: &str, args: &[&str]) -> String {
    let path = repo_root()
        .join("scripts")
        .join("ironwood-regtest")
        .join(script);
    let output = Command::new(path)
        .args(args)
        .current_dir(repo_root())
        .env(
            "IRONWOOD_ACTIVATION_HEIGHT",
            activation_height().to_string(),
        )
        .output()
        .unwrap_or_else(|error| panic!("run {script}: {error}"));
    assert!(
        output.status.success(),
        "{script} failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn ensure_stack_up() {
    run_harness("up.sh", &[]);
}

fn latest_height() -> u64 {
    wallet_api::get_latest_block_height(lightwalletd_url(), NETWORK.to_string())
        .expect("read Ironwood regtest tip")
}

fn lightwalletd_url() -> String {
    let port = std::env::var("IRONWOOD_LIGHTWALLETD_PORT").unwrap_or_else(|_| "19067".to_string());
    format!("http://127.0.0.1:{port}")
}
