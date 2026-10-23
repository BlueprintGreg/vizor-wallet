//! Directed scenarios for promises the random harness reaches rarely or not at all.
use super::*;

/// Runs the world's default round on `dev` and fails on any violation.
fn settle(world: &mut World, dev: usize) {
    for _ in 0..4 {
        let publication = world.current();
        world.round(dev, 0, false, publication, 0, None).unwrap();
    }
}

/// Four incoming quotes shown to the user and never paid fill the four-slot window.
/// Two days after their deadlines, a new private quote must still find a slot once the
/// app refreshes their statuses, so a full window cannot stay blocked.
#[test]
fn expired_unpaid_quotes_release_their_slots_days_later() {
    if isolated("directed::expired_unpaid_quotes_release_their_slots_days_later") {
        return;
    }
    let mut world = World::new();
    world.sync(0, false);
    settle(&mut world, 0);
    for _ in 0..4 {
        let line = world.quote_in(0, 0, Reply::Accept, 3_600).unwrap();
        assert!(line.contains("accepted and shown"), "{line}");
    }
    let full = world.reserve_in(0, 0, false).unwrap();
    assert!(
        full.as_ref()
            .is_err_and(|e| e.contains("No swap address is free")),
        "{full:?}"
    );
    world.act(&Action::Warp(2 * 86_400)).unwrap();
    world.mine(1);
    world.sync(0, false);
    // Without fresh statuses the wallet cannot tell an expired quote from a late deposit.
    let stale = world.reserve_in(0, 0, false);
    println!("before a status refresh: {stale:?}");
    world.poll(0, 0).unwrap();
    let freed = world.reserve_in(0, 0, false).unwrap();
    assert_eq!(freed, Ok(0), "the lowest expired slot is reused");
}

/// The value of `dev`'s mined one-time notes on its first account, per key.
fn credited(world: &World, dev: usize) -> Vec<Note> {
    let device = &world.devices[dev];
    let mut notes: Vec<Note> = notes(&device.wallet, &device.accts[0].account.id)
        .into_iter()
        .filter(|n| n.mined)
        .collect();
    notes.sort();
    notes
}

/// A payout credited before a reorg that drops its block, and paid again on the new
/// branch, ends up credited exactly once from the new branch, and the balance follows.
#[test]
fn a_reorged_payout_is_credited_once_from_the_new_branch() {
    if isolated("directed::a_reorged_payout_is_credited_once_from_the_new_branch") {
        return;
    }
    let mut world = World::new();
    world.sync(0, false);
    settle(&mut world, 0);
    let line = world
        .act(&Action::Swap {
            dev: 0,
            acct: 0,
            value: 700_000,
        })
        .unwrap();
    assert!(line.contains("paid 700000 to I0"), "{line}");
    world.mine(1);
    world.sync(0, false);
    settle(&mut world, 0);
    let before = credited(&world, 0);
    assert_eq!(before.len(), 1);
    let ordinary = world.devices[0]
        .wallet
        .balance(&world.devices[0].accts[0].account)
        - 700_000;
    let reorg = world.reorg(3);
    assert!(reorg.contains("re-sent 1 payouts"), "{reorg}");
    world.sync(0, true);
    world.check_step().unwrap();
    settle(&mut world, 0);
    world.check_step().unwrap();
    let after = credited(&world, 0);
    assert_eq!(after.len(), 1, "{after:?}");
    assert_ne!(
        after[0].txid, before[0].txid,
        "the new branch's payout is credited"
    );
    assert_eq!(after[0].value, 700_000);
    // The orphaned note stays stored unmined. Like an orphaned ordinary payment (see
    // `an_orphaned_ordinary_payment_stays_pending`), it counts as pending but never as
    // spendable.
    world.mine(12);
    world.sync(0, true);
    settle(&mut world, 0);
    let account = &world.devices[0].accts[0].account;
    let wallet = &world.devices[0].wallet;
    let b = crate::api::sync::get_balance(wallet.path.clone(), "main".into(), account.uuid.clone())
        .unwrap();
    assert_eq!(
        b.spendable,
        ordinary + 700_000,
        "only the new branch's payout is spendable"
    );
    assert_eq!(
        b.total,
        ordinary + 1_400_000,
        "the orphaned note still shows as pending"
    );
}

/// Deleting an account and adding the same seed back recovers its one-time payments
/// like a restore at its birthday.
#[test]
fn a_deleted_and_readded_account_recovers_like_a_restore() {
    if isolated("directed::a_deleted_and_readded_account_recovers_like_a_restore") {
        return;
    }
    let mut world = World::new();
    world.act(&Action::AddAccount(0)).unwrap();
    world.sync(0, false);
    settle(&mut world, 0);
    let line = world
        .act(&Action::Swap {
            dev: 0,
            acct: 1,
            value: 400_000,
        })
        .unwrap();
    assert!(line.contains("paid 400000"), "{line}");
    world.mine(1);
    world.sync(0, false);
    settle(&mut world, 0);
    let second = |world: &World| {
        let device = &world.devices[0];
        let acct = device.accts.iter().find(|a| a.seed == SECOND).unwrap();
        notes(&device.wallet, &acct.account.id)
            .into_iter()
            .filter(|n| n.mined)
            .count()
    };
    assert_eq!(second(&world), 1);
    world
        .act(&Action::DeleteAccount { dev: 0, acct: 1 })
        .unwrap();
    world.act(&Action::AddAccount(0)).unwrap();
    world.sync(0, false);
    settle(&mut world, 0);
    assert_eq!(
        second(&world),
        1,
        "the re-added account found its payment again"
    );
    world.check_step().unwrap();
}

/// The funding device retires a refund key once its swap ended with no refund or its
/// refund arrived. A second device that learned the same keys from funding memos keeps
/// monitoring them, which is today's behavior and an open question (SPEC Q-2).
#[test]
fn local_refund_keys_retire_and_memo_learned_keys_stay_monitored() {
    if isolated("directed::local_refund_keys_retire_and_memo_learned_keys_stay_monitored") {
        return;
    }
    let mut world = World::new();
    world.add_device(activation(), true);
    world.sync(0, false);
    settle(&mut world, 0);
    for outcome in [0, 2] {
        let line = world
            .act(&Action::SwapOut {
                dev: 0,
                acct: 0,
                outcome,
            })
            .unwrap();
        assert!(line.contains("funded"), "{line}");
        // Change from the first funding needs confirmations before the second.
        world.mine(12);
        world.sync(0, false);
    }
    for dev in [0, 1] {
        world.sync(dev, true);
        world.poll(dev, 0).unwrap();
        settle(&mut world, dev);
    }
    let monitored = |world: &World, dev: usize| -> BTreeSet<u64> {
        let device = &world.devices[dev];
        device
            .wallet
            .db()
            .one_time_receivers(device.accts[0].account.id)
            .unwrap()
            .1
            .iter()
            .filter(|w| w.key.purpose() == Purpose::Refund)
            .map(|w| w.key.index())
            .collect()
    };
    assert!(
        monitored(&world, 0).is_empty(),
        "{:?}",
        monitored(&world, 0)
    );
    assert_eq!(monitored(&world, 1), BTreeSet::from([0, 1]));
    for dev in [0, 1] {
        assert_eq!(
            credited(&world, dev).iter().filter(|n| !n.receive).count(),
            1
        );
    }
}

/// Private addresses need both Private queries and NEAR swap privacy.
#[test]
fn private_addresses_need_both_switches() {
    if isolated("directed::private_addresses_need_both_switches") {
        return;
    }
    let mut world = World::new();
    world.sync(0, false);
    settle(&mut world, 0);
    world.devices[0].queries = false;
    world.toggled(0);
    let refused = world.reserve_in(0, 0, false).unwrap();
    assert!(refused.is_err_and(|e| e.contains("Enable Private queries")));
    world.devices[0].queries = true;
    world.toggled(0);
    assert_eq!(world.reserve_in(0, 0, false).unwrap(), Ok(0));
}

/// A started quote that never gets another provider status keeps its slot, even a month
/// after its deadline. This pins today's behavior for SPEC Q-7.
#[test]
fn a_started_quote_without_any_status_keeps_its_slot() {
    if isolated("directed::a_started_quote_without_any_status_keeps_its_slot") {
        return;
    }
    let mut world = World::new();
    world.sync(0, false);
    settle(&mut world, 0);
    for _ in 0..4 {
        world.quote_in(0, 0, Reply::Accept, 3_600).unwrap();
    }
    world.act(&Action::Warp(30 * 86_400)).unwrap();
    world.mine(1);
    world.sync(0, false);
    settle(&mut world, 0);
    let held = world.reserve_in(0, 0, false);
    assert!(
        matches!(&held, Err(v) if v.kind == "stalled-window"),
        "without a fresh status the slot stays held: {held:?}"
    );
}

/// With the feature off, a receipt a reorg displaced still gets repair lookups, so the
/// round makes receiver requests. This pins today's behavior for SPEC Q-5.
#[test]
fn a_feature_off_round_repairs_a_displaced_receipt() {
    if isolated("directed::a_feature_off_round_repairs_a_displaced_receipt") {
        return;
    }
    let mut world = World::new();
    world.sync(0, false);
    settle(&mut world, 0);
    world
        .act(&Action::Swap {
            dev: 0,
            acct: 0,
            value: 500_000,
        })
        .unwrap();
    world.mine(1);
    world.sync(0, false);
    settle(&mut world, 0);
    world.devices[0].feature = false;
    world.toggled(0);
    world.reorg(3);
    world.mine(12);
    world.sync(0, true);
    // Every later feature-off round repeats the repair: the orphaned note never leaves.
    let mut lines = vec![];
    for _ in 0..3 {
        let publication = world.current();
        lines.push(world.round(0, 0, false, publication, 0, None).unwrap());
    }
    println!("feature-off rounds after a reorg: {lines:?}");
    world.check_step().unwrap();
}

/// Control for the reorg test: an ordinary payment whose block a reorg drops, and which
/// is not mined again, also stays in the pending total and never becomes spendable. So a
/// lingering orphaned value is not specific to one-time receipts.
#[test]
fn an_orphaned_ordinary_payment_stays_pending() {
    if isolated("directed::an_orphaned_ordinary_payment_stays_pending") {
        return;
    }
    let mut world = World::new();
    world.sync(0, false);
    let account = world.devices[0].accts[0].account.clone();
    let before = world.devices[0].wallet.balance(&account);
    world.chain.pay(&account.parent(), 700_000, false);
    world.changed();
    world.mine(1);
    world.sync(0, false);
    assert_eq!(world.devices[0].wallet.balance(&account), before + 700_000);
    world.reorg(3);
    world.mine(12);
    world.sync(0, true);
    let wallet = &world.devices[0].wallet;
    let b = crate::api::sync::get_balance(wallet.path.clone(), "main".into(), account.uuid.clone())
        .unwrap();
    assert_eq!(b.spendable, before);
    assert_eq!(b.total, before + 700_000);
}

/// Finding F1. A device restored with a birthday after the note that funded a swap, but
/// before the funding transaction itself, sees the funding memo but has no record of
/// spending its own note, so it never learns the refund key and loses the refund.
#[test]
#[ignore = "product bug F1: memo recovery needs a pre-birthday spend record"]
fn a_restore_between_funding_input_and_funding_recovers_the_refund() {
    if isolated("directed::a_restore_between_funding_input_and_funding_recovers_the_refund") {
        return;
    }
    let mut world = World::new();
    world.sync(0, false);
    settle(&mut world, 0);
    let birthday = world.chain.tip() - 2;
    let restored = world.add_device(birthday, true);
    let line = world
        .act(&Action::SwapOut {
            dev: 0,
            acct: 0,
            outcome: 2,
        })
        .unwrap();
    assert!(line.contains("refunded 4900000"), "{line}");
    world.mine(1);
    world.sync(restored, true);
    settle(&mut world, restored);
    let device = &world.devices[restored];
    let account = &device.accts[0].account.id;
    assert_eq!(
        funded_refunds(&device.wallet, account),
        BTreeSet::from([0]),
        "the memo names R0"
    );
    assert_eq!(
        credited(&world, restored)
            .iter()
            .filter(|n| !n.receive)
            .count(),
        1
    );
}

/// Finding F2. After a reorg the provider pays a refund again in a new transaction. The
/// first refund note stays stored unmined, which keeps the key in repair, so the refund
/// key never retires even though its swap ended and its refund arrived.
#[test]
#[ignore = "product bug F2: an orphaned receipt keeps its key in repair forever"]
fn a_refund_replaced_by_a_reorg_still_retires() {
    if isolated("directed::a_refund_replaced_by_a_reorg_still_retires") {
        return;
    }
    let mut world = World::new();
    world.sync(0, false);
    settle(&mut world, 0);
    world
        .act(&Action::SwapOut {
            dev: 0,
            acct: 0,
            outcome: 1,
        })
        .unwrap();
    world.mine(1);
    world.sync(0, true);
    world.poll(0, 0).unwrap();
    settle(&mut world, 0);
    let reorg = world.reorg(3);
    assert!(reorg.contains("re-sent 1 payouts"), "{reorg}");
    world.mine(12);
    world.sync(0, true);
    world.poll(0, 0).unwrap();
    settle(&mut world, 0);
    let device = &world.devices[0];
    let monitored: Vec<_> = device
        .wallet
        .db()
        .one_time_receivers(device.accts[0].account.id)
        .unwrap()
        .1
        .iter()
        .filter(|w| w.key.purpose() == Purpose::Refund)
        .map(|w| w.key.index())
        .collect();
    assert!(monitored.is_empty(), "R0 still monitored: {monitored:?}");
}

/// Control: a wallet restored a few blocks below the tip follows a shallow reorg that
/// forks inside its scanned range, with no one-time state at all.
#[test]
fn a_recent_restore_follows_a_shallow_reorg() {
    if isolated("directed::a_recent_restore_follows_a_shallow_reorg") {
        return;
    }
    let mut world = World::new();
    world.mine(4);
    let birthday = world.chain.tip() - 3;
    let restored = world.add_device(birthday, false);
    world.mine(1);
    world.sync(restored, false);
    world.reorg(2);
    let line = world.sync(restored, false);
    assert!(!world.devices[restored].broken, "{line}");
}

/// Finding U1, outside the one-time feature. The same as
/// [`a_recent_restore_follows_a_shallow_reorg`], with an unrelated Ironwood output in the
/// block the reorg drops, so the commitment tree changes above the fork. The wallet
/// refuses every rewind, even to the safe height it reports.
#[test]
#[ignore = "upstream U1: a recent restore cannot rewind over an Ironwood output"]
fn a_recent_restore_follows_a_shallow_reorg_over_an_ironwood_output() {
    if isolated("directed::a_recent_restore_follows_a_shallow_reorg_over_an_ironwood_output") {
        return;
    }
    let mut world = World::new();
    world.mine(4);
    let birthday = world.chain.tip() - 3;
    let restored = world.add_device(birthday, false);
    let stranger = world.key(SECOND, true, 7);
    world.chain.pay(&stranger, 100_000, false);
    world.changed();
    world.sync(restored, false);
    world.reorg(2);
    let line = world.sync(restored, false);
    assert!(!world.devices[restored].broken, "{line}");
}

/// Finding F1, second effect. The restored device of
/// [`a_restore_between_funding_input_and_funding_recovers_the_refund`] does not know the
/// phone already funded refund key R0, so its own next ZEC deposit quote reserves R0
/// again, linking the two swaps and sharing one refund address between them.
#[test]
#[ignore = "product bug F1: an unauthenticated memo lets another device reuse its refund key"]
fn a_restored_device_never_reuses_a_funded_refund_key() {
    if isolated("directed::a_restored_device_never_reuses_a_funded_refund_key") {
        return;
    }
    let mut world = World::new();
    world.act(&Action::AddAccount(0)).unwrap();
    world.sync(0, false);
    settle(&mut world, 0);
    let birthday = world.chain.tip() - 2;
    let restored = world.add_device(birthday, true);
    let line = world
        .act(&Action::SwapOut {
            dev: 0,
            acct: 0,
            outcome: 0,
        })
        .unwrap();
    assert!(
        line.contains("R0 quote") && line.contains("funded"),
        "{line}"
    );
    world.mine(1);
    world.sync(restored, true);
    settle(&mut world, restored);
    let line = world.quote_out(restored, 0, 3_600).unwrap();
    assert!(
        !line.starts_with("R0 "),
        "the restored device reused R0: {line}"
    );
}
