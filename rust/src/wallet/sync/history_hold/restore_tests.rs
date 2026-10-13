//! A full-history restore on the wallet library's test chain, scanned in
//! Zakura's order: the chain tip range first, then history from the birthday.
//!
//! Block A pays the account a note that completes Orchard shard 0, block B
//! spends it, and block C completes shard 1. With both subtree roots known
//! when the chain tip is updated, the tip range starts at C, the last
//! completed shard's end, so B lies in history that is scanned last. Once A's
//! history is scanned, Zakura marks the note `witness_stabilized` and counts
//! it spendable while B is still unscanned; the sweep holds it until B is
//! scanned.

use std::num::NonZeroU8;

use incrementalmerkletree::{frontier::Frontier, Level};
use orchard::tree::MerkleHashOrchard;
use zcash_client_backend::data_api::{
    chain::{ChainState, CommitmentTreeRoot},
    testing::{
        orchard::OrchardPoolTester, pool::ShieldedPoolTester,
        random_frontier_with_prior_subtree_roots, AddressType, FakeCompactOutput,
        InitialChainState, TestBuilder, TestState,
    },
    wallet::TargetHeight,
    Account as _, TargetValue, WalletCommitmentTrees as _, WalletWrite as _,
};
use zcash_client_sqlite::{
    testing::{
        db::{TestDb, TestDbFactory},
        BlockCache,
    },
    AccountUuid,
};
use zcash_primitives::block::BlockHash;
use zcash_protocol::{
    consensus::{NetworkUpgrade, Parameters as _},
    local_consensus::LocalNetwork,
    value::Zatoshis,
};

use super::*;
use crate::wallet::db::with_wallet_db_write_lock;

type State = TestState<BlockCache, TestDb, LocalNetwork>;

const NETWORK: WalletNetwork = WalletNetwork::Regtest;
const SHARD: u32 = 1 << 16;
const NOTE: u64 = 1_000_000;
const PAYMENT: u64 = 600_000;
const CHANGE: u64 = NOTE - PAYMENT;
/// Empty blocks between the birthday and A, A and B, and B and C.
const GAP_BLOCKS: u32 = 10;
/// Empty blocks above C, so A and C both sit more than `PRUNING_DEPTH` (100)
/// below the tip.
const TIP_BLOCKS: u32 = 110;
const HISTORIC: i64 = 20;
const CHAIN_TIP: i64 = 50;

/// Vizor's regtest chain in tests: every upgrade through NU6.2 at height 1,
/// NU6.3 inactive (`WalletNetwork::Regtest` keeps it at `u32::MAX` unless a
/// test configures it).
fn regtest() -> LocalNetwork {
    let one = Some(BlockHeight::from_u32(1));
    LocalNetwork {
        overwinter: one,
        sapling: one,
        blossom: one,
        heartwood: one,
        canopy: one,
        nu5: one,
        nu6: one,
        nu6_1: one,
        nu6_2: one,
        nu6_3: None,
        nu7: None,
    }
}

fn zat(value: u64) -> Zatoshis {
    Zatoshis::const_from_u64(value)
}

/// The root of the Orchard shard that the block ending in `state` completed.
fn completed_shard_root(state: &ChainState) -> MerkleHashOrchard {
    let frontier = state.final_orchard_tree().value().expect("non-empty tree");
    assert_eq!(
        (u64::from(frontier.position()) + 1) % u64::from(SHARD),
        0,
        "the block ends a shard"
    );
    frontier.root(Some(Level::from(16)))
}

fn db_path(st: &State) -> String {
    st.wallet().conn().path().expect("file-backed").to_owned()
}

/// `(start, end, priority)` of every scan queue row.
fn scan_queue(path: &str) -> Vec<(u32, u32, i64)> {
    let conn = Connection::open(path).unwrap();
    let mut stmt = conn
        .prepare(
            "SELECT block_range_start, block_range_end, priority
             FROM scan_queue ORDER BY block_range_start",
        )
        .unwrap();
    let rows = stmt
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    rows
}

#[derive(Debug)]
struct NoteRow {
    txid: [u8; 32],
    action_index: u32,
    stabilized: bool,
    lock_owner: Option<Vec<u8>>,
    spend_mined_height: Option<u32>,
}

/// The account's Orchard note received at `height`.
fn note_at(path: &str, height: u32) -> NoteRow {
    let conn = Connection::open(path).unwrap();
    conn.query_row(
        "SELECT t.txid, rn.action_index, rn.witness_stabilized, rn.lock_owner,
                (SELECT MAX(stx.mined_height)
                 FROM orchard_received_note_spends s
                 JOIN transactions stx ON stx.id_tx = s.transaction_id
                 WHERE s.orchard_received_note_id = rn.id)
         FROM orchard_received_notes rn
         JOIN transactions t ON t.id_tx = rn.transaction_id
         WHERE t.mined_height = ?1",
        params![height],
        |row| {
            Ok(NoteRow {
                txid: row.get::<_, Vec<u8>>(0)?.try_into().unwrap(),
                action_index: row.get(1)?,
                stabilized: row.get(2)?,
                lock_owner: row.get(3)?,
                spend_mined_height: row.get(4)?,
            })
        },
    )
    .unwrap()
}

/// Sweeps the way the sync engine does, under the wallet write lock, on a
/// handle opened and dropped around it.
fn sweep_as_sync_engine(path: &str) -> SweepOutcome {
    with_wallet_db_write_lock("history_hold.restore_test", || {
        let mut db = super::super::open_wallet_db(path, NETWORK).unwrap();
        sweep(path, &mut db).unwrap()
    })
}

/// Orchard notes an ordinary send's input selector returns for `PAYMENT`
/// (locked outputs excluded, Vizor's confirmation policy).
fn selectable_notes(st: &State, account: AccountUuid, tip: BlockHeight) -> usize {
    OrchardPoolTester::select_spendable_notes(
        st,
        account,
        TargetValue::AtLeast(zat(PAYMENT)),
        TargetHeight::from(tip + 1),
        crate::wallet::confirmations_policy(),
        &[],
    )
    .unwrap()
    .len()
}

/// A wallet whose account is born where the Orchard tree is one leaf short of
/// a full shard 0, so the first Orchard output completes it.
fn wallet_one_leaf_short_of_a_shard() -> State {
    TestBuilder::new()
        .with_network(regtest())
        .with_data_store_factory(TestDbFactory::file_backed())
        .with_block_cache(BlockCache::new())
        .with_initial_chain_state(|rng, network| {
            let birthday = network.activation_height(NetworkUpgrade::Nu5).unwrap() + 1000;
            let (prior_roots, orchard_tree) = random_frontier_with_prior_subtree_roots(
                rng,
                u64::from(SHARD - 1),
                NonZeroU8::new(16).unwrap(),
                |rng| MerkleHashOrchard::random(rng),
            );
            assert!(prior_roots.is_empty());
            InitialChainState {
                chain_state: ChainState::new(
                    birthday - 1,
                    BlockHash([5; 32]),
                    Frontier::empty(),
                    orchard_tree,
                    Frontier::empty(),
                ),
                prior_sapling_roots: vec![],
                prior_orchard_roots: vec![],
            }
        })
        .with_account_having_current_birthday()
        .build()
}

#[test]
fn a_restored_note_spent_in_unscanned_history_is_held_until_that_history_is_scanned() {
    let mut st = wallet_one_leaf_short_of_a_shard();
    let path = db_path(&st);
    let account = st.test_account().unwrap().id();
    let uuid = account.expose_uuid().to_string();
    let birthday = st.test_account().unwrap().birthday().height();
    let ours = OrchardPoolTester::test_account_fvk(&st);
    let other = OrchardPoolTester::sk_to_fvk(&OrchardPoolTester::sk(&[0xf5; 32]));
    let recipient = OrchardPoolTester::fvk_default_address(&other);
    let recipient_str = recipient.encode(&NETWORK);

    // --- The chain: A receives, B spends, C completes shard 1, then the tip.
    for _ in 0..GAP_BLOCKS {
        st.generate_empty_block();
    }
    let (a, _, nf) = st.generate_next_block(&ours, AddressType::DefaultExternal, zat(NOTE));
    let a_state = st.latest_cached_block().unwrap().clone();
    assert_eq!(a_state.orchard_end_size(), SHARD);
    for _ in 0..GAP_BLOCKS {
        st.generate_empty_block();
    }
    let (b, _) = st.generate_next_block_spending(&ours, (nf, zat(NOTE)), recipient, zat(PAYMENT));
    for _ in 0..GAP_BLOCKS {
        st.generate_empty_block();
    }
    let filled = st.latest_cached_block().unwrap().orchard_end_size();
    let output = FakeCompactOutput::new(other.clone(), AddressType::DefaultExternal, zat(10_000));
    let filler = vec![output; (2 * SHARD - filled) as usize];
    let (c, _, _) = st.generate_next_block_multi(&filler);
    let c_state = st.latest_cached_block().unwrap().clone();
    assert_eq!(c_state.orchard_end_size(), 2 * SHARD);
    for _ in 0..TIP_BLOCKS {
        st.generate_empty_block();
    }
    let tip = st.latest_cached_block().unwrap().height();
    let birthday32 = u32::from(birthday);
    let (a32, b32, c32, tip32) = (u32::from(a), u32::from(b), u32::from(c), u32::from(tip));
    assert!(birthday32 < a32);
    eprintln!("birthday={birthday32} A={a32} B={b32} C={c32} tip={tip32}");

    // --- Sync start: subtree roots, then the chain tip, as the engine does.
    st.wallet_mut()
        .put_orchard_subtree_roots(
            0,
            &[
                CommitmentTreeRoot::from_parts(a, completed_shard_root(a_state.chain_state())),
                CommitmentTreeRoot::from_parts(c, completed_shard_root(c_state.chain_state())),
            ],
        )
        .unwrap();
    st.wallet_mut().update_chain_tip(tip).unwrap();
    {
        let conn = Connection::open(&path).unwrap();
        ensure_tables(&conn).unwrap();
        conn.execute(
            "INSERT INTO ext_vizor_sync_meta (key, value) VALUES ('sync_in_progress', '1')",
            [],
        )
        .unwrap();
    }
    // Below the birthday the queue holds one Ignored range.
    assert_eq!(
        scan_queue(&path),
        vec![
            (1, birthday32, 0),
            (birthday32, c32, HISTORIC),
            (c32, tip32 + 1, CHAIN_TIP)
        ],
        "the tip range starts at C, the last completed shard's end"
    );
    assert_eq!(sweep_as_sync_engine(&path).held, 0);

    // --- The tip range first, then history from the birthday up to B; B..C
    // stays pending.
    st.scan_cached_blocks(c, (tip32 - c32 + 1) as usize);
    assert_eq!(sweep_as_sync_engine(&path).held, 0);
    let summary = st.scan_cached_blocks(birthday, (b32 - birthday32) as usize);
    assert_eq!(summary.received_orchard_note_count(), 1);
    let queue = scan_queue(&path);
    eprintln!("scan queue with B's range pending: {queue:?}");
    assert!(queue.contains(&(b32, c32, HISTORIC)), "{queue:?}");
    let shard_end: Option<u32> = Connection::open(&path)
        .unwrap()
        .query_row(
            "SELECT subtree_end_height FROM orchard_tree_shards WHERE shard_index = 0",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(shard_end, Some(a32));

    // --- PROBLEM (main has no sweep): the note is stabilized and spendable
    // although B, which spends it, is unscanned.
    let note = note_at(&path, a32);
    eprintln!("note before sweep: {note:?}");
    assert!(note.stabilized, "Zakura stabilizes the note");
    assert_eq!(note.spend_mined_height, None, "B's spend is not known yet");
    let balance = crate::wallet::sync::get_wallet_balance(&path, NETWORK, &uuid).unwrap();
    eprintln!(
        "PROBLEM balance: orchard spendable={} locked={} history_hold={} pending={}",
        balance.orchard,
        balance.orchard_locked,
        balance.orchard_history_hold,
        balance.orchard_pending
    );
    assert_eq!(balance.orchard, NOTE);
    assert_eq!(balance.orchard_history_hold, 0);
    assert_eq!(
        st.get_spendable_balance(account, crate::wallet::confirmations_policy()),
        zat(NOTE)
    );
    assert_eq!(selectable_notes(&st, account, tip), 1);
    let max = crate::wallet::sync::estimate_send_max(&path, NETWORK, &uuid, &recipient_str, None)
        .expect("a max-send proposal selects the note");
    eprintln!(
        "PROBLEM max-send proposal: amount={} fee={}",
        max.amount_zatoshi, max.fee_zatoshi
    );
    assert_eq!(max.amount_zatoshi + max.fee_zatoshi, NOTE);

    // --- FIX: the sweep the engine runs after each scan batch holds it.
    assert_eq!(
        sweep_as_sync_engine(&path),
        SweepOutcome {
            held: 1,
            changed: true
        }
    );
    let note = note_at(&path, a32);
    assert_eq!(note.lock_owner, Some(hold_owner().as_bytes().to_vec()));
    assert!(held_orchard_outputs(&path)
        .unwrap()
        .contains(&(note.txid, note.action_index)));
    let balance = crate::wallet::sync::get_wallet_balance(&path, NETWORK, &uuid).unwrap();
    eprintln!(
        "FIX balance: orchard spendable={} locked={} history_hold={} pending={}",
        balance.orchard,
        balance.orchard_locked,
        balance.orchard_history_hold,
        balance.orchard_pending
    );
    assert_eq!(balance.orchard, 0);
    assert_eq!(balance.orchard_locked, 0);
    assert_eq!(balance.orchard_history_hold, NOTE);
    assert_eq!(
        st.get_spendable_balance(account, crate::wallet::confirmations_policy()),
        zat(0)
    );
    assert_eq!(selectable_notes(&st, account, tip), 0);
    let max = crate::wallet::sync::estimate_send_max(&path, NETWORK, &uuid, &recipient_str, None);
    eprintln!(
        "FIX max-send proposal: {:?}",
        max.as_ref().map(|m| (m.amount_zatoshi, m.fee_zatoshi))
    );
    assert!(max.is_err(), "no input is left to select");
    let proposal = crate::wallet::sync::propose_send(
        &path,
        NETWORK,
        &uuid,
        "history-hold-restore-test",
        &recipient_str,
        PAYMENT,
        None,
    );
    let error = proposal.err().expect("the send proposal finds no input");
    eprintln!("FIX send proposal error: {error}");

    // --- RELEASE: B's history is scanned, the spend is found, the hold ends.
    let summary = st.scan_cached_blocks(b, (c32 - b32) as usize);
    assert_eq!(summary.spent_orchard_note_count(), 1);
    assert!(scan_queue(&path)
        .iter()
        .all(|&(_, _, priority)| priority <= SCANNED_PRIORITY));
    assert_eq!(
        sweep_as_sync_engine(&path),
        SweepOutcome {
            held: 0,
            changed: true
        }
    );
    let note = note_at(&path, a32);
    eprintln!("note after B is scanned: {note:?}");
    assert_eq!(note.spend_mined_height, Some(b32));
    assert_eq!(note.lock_owner, None);
    assert!(held_orchard_outputs(&path).unwrap().is_empty());
    let balance = crate::wallet::sync::get_wallet_balance(&path, NETWORK, &uuid).unwrap();
    eprintln!(
        "RELEASE balance: orchard spendable={} locked={} history_hold={} pending={}",
        balance.orchard,
        balance.orchard_locked,
        balance.orchard_history_hold,
        balance.orchard_pending
    );
    assert_eq!(balance.orchard_history_hold, 0);
    assert_eq!(balance.orchard_locked, 0);
    assert_eq!(balance.orchard + balance.orchard_pending, CHANGE);
}
