//! Thin application policy over the wallet library's one-time IVKs (see
//! `zcash_client_sqlite::wallet::one_time_ivk`), which Vizor uses for private NEAR swap
//! addresses.

use zakura_near_intents::NearStatus;
use zcash_client_backend::data_api::{
    one_time_ivk::{restore::OneTimeIvkRestoreRead as _, OneTimeIvkRead as _},
    Account as _, WalletRead,
};
use zcash_client_sqlite::{wallet::one_time_ivk::OneTimeKey, AccountUuid};
use zcash_keys::address::{Address, UnifiedAddress};
use zcash_protocol::{consensus::BlockHeight, value::Zatoshis};

use super::{
    db::{
        open_wallet_db_with_timeout, with_wallet_db_write_lock, WalletDatabase,
        WALLET_DB_BUSY_TIMEOUT,
    },
    keys::parse_account_uuid,
    network::WalletNetwork,
    sync_engine::enhancement::EnhancementPolicy,
};

/// Whether `network` runs one-time IVKs at all: wherever Private queries could (see
/// [`EnhancementPolicy`]), whatever the switches say. Discovery, key closing and
/// provider statuses need nothing more; new addresses do (see [`require_new_address`]).
pub(crate) fn supported(network: WalletNetwork) -> bool {
    EnhancementPolicy::for_preference(network, true).is_private()
}

/// Fails unless new private swap addresses are allowed: where [`supported`], with both
/// Private queries and NEAR swap privacy on.
pub(crate) fn require_new_address(network: WalletNetwork) -> Result<(), String> {
    if !EnhancementPolicy::current(network).is_private()
        || !crate::api::sync::near_swap_privacy_enabled()
    {
        return Err(
            "Enable Private queries and NEAR swap privacy before reserving an address".into(),
        );
    }
    Ok(())
}

/// The network tip a quote flow fetched, which address issuance checks scanning against.
pub(crate) fn network_tip(live_tip: u64) -> Result<BlockHeight, String> {
    u32::try_from(live_tip)
        .map(BlockHeight::from_u32)
        .map_err(|_| "Invalid chain tip".into())
}

/// Borrows a bridged provider status for the library. Unparseable amounts are
/// treated as unreported.
pub(crate) fn near_status(status: &crate::api::one_time_ivk::SwapProviderStatus) -> NearStatus<'_> {
    let amount = |value: &Option<String>| {
        value
            .as_deref()
            .and_then(|v| v.parse::<u64>().ok())
            .and_then(|v| Zatoshis::from_u64(v).ok())
    };
    NearStatus {
        status: &status.status,
        swap_type: status.swap_type.as_deref(),
        refunded_amount: amount(&status.refunded_amount),
        amount_out: amount(&status.amount_out),
    }
}

/// Whether `account` is a software account: one with ZIP 32 derivation metadata, from
/// which Vizor derives its spending key (see `execute_stored_proposal`), and without a
/// hardware signer. That includes the first account, created as `Derived`, and accounts
/// added later as spending UFVK imports; view-only imports have no derivation.
fn is_software(db: &WalletDatabase, account: AccountUuid) -> Result<bool, String> {
    let account = db
        .get_account(account)
        .map_err(|e| e.to_string())?
        .ok_or("Account not found")?;
    let source = account.source();
    Ok(source.key_derivation().is_some() && super::keys::hardware_signer_kind(source).is_none())
}

/// Fails unless `account` is a software account (see [`is_software`]).
pub(crate) fn require_software_account(
    db: &WalletDatabase,
    account: AccountUuid,
) -> Result<(), String> {
    if !is_software(db, account)? {
        return Err("Swap receiving requires a software wallet".into());
    }
    Ok(())
}

/// The software accounts that can spend with one-time keys.
pub(crate) fn software_accounts(db: &WalletDatabase) -> Result<Vec<AccountUuid>, String> {
    let mut accounts = Vec::new();
    for account in db.get_account_ids().map_err(|e| e.to_string())? {
        if is_software(db, account)? {
            accounts.push(account);
        }
    }
    Ok(accounts)
}

/// Encodes `key`'s receiver as a unified address with no other receiver.
pub(crate) fn encode_address(key: &OneTimeKey, network: WalletNetwork) -> Result<String, String> {
    let address = UnifiedAddress::from_receivers(Some(key.receiver()), None, None)
        .ok_or("Invalid swap receiver")?;
    Ok(Address::Unified(address)
        .to_zcash_address(&network)
        .to_string())
}

/// Whether the wallet still scans `account`'s one-time key behind swap address
/// `address`, as [`encode_address`] encodes it. False once the key closed, as when an
/// unpaid reservation is reclaimed, and for an address that is not such a key's.
pub(crate) fn is_address_scanning(
    db: &WalletDatabase,
    network: WalletNetwork,
    account: AccountUuid,
    address: &str,
) -> Result<bool, String> {
    let Some(Address::Unified(address)) = Address::decode(&network, address) else {
        return Ok(false);
    };
    let Some(receiver) = address.orchard() else {
        return Ok(false);
    };
    let Some(key) = db
        .get_one_time_key_for_receiver(account, receiver)
        .map_err(|e| e.to_string())?
    else {
        return Ok(false);
    };
    Ok(db
        .get_one_time_scanning_keys()
        .map_err(|e| e.to_string())?
        .iter()
        .any(|scanning| scanning.key_id() == key.key_id()))
}

/// The current Unix time in seconds, as the library's lifecycle takes it.
pub(crate) fn now() -> Result<i64, String> {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_secs()
        .try_into()
        .map_err(|_| "Clock overflow".into())
}

/// Runs `action` on `uuid`'s account in the wallet at `path`, under the wallet write lock.
pub(crate) fn with_db<T, E: From<String>>(
    path: &str,
    network: WalletNetwork,
    uuid: &str,
    action: impl FnOnce(&mut WalletDatabase, AccountUuid) -> Result<T, E>,
) -> Result<T, E> {
    with_wallet_db_write_lock("one_time_ivk", || {
        let mut db = open_wallet_db_with_timeout(path, network, WALLET_DB_BUSY_TIMEOUT)?;
        let account = parse_account_uuid(uuid)?;
        action(&mut db, account)
    })
}

/// Declares `uuid`'s account newly created from a seed generated for it, so it has no
/// one-time payments to restore (see `WalletDb::mark_one_time_account_fresh`). Account
/// creation calls it before returning, so before any sync sees the account. A failure
/// leaves the account treated as restored, which costs only lookups.
pub(crate) fn mark_fresh(path: &str, network: WalletNetwork, uuid: &str) {
    let marked = with_db(path, network, uuid, |db, account| {
        db.mark_one_time_account_fresh(account)
            .map_err(|e| e.to_string())
    });
    if let Err(e) = marked {
        log::warn!("one-time IVKs: could not mark a new account fresh: {e}");
    }
}

/// Whether any software account's swap history check is unfinished: its discovery is
/// incomplete, or has lookups or late payments left. Sync runs discovery until it is not.
pub(crate) fn history_pending(db: &WalletDatabase) -> Result<bool, String> {
    let now = now()?;
    for account in software_accounts(db)? {
        let status = db
            .one_time_discovery(account, now)
            .map_err(|e| e.to_string())?;
        if status.is_some_and(|s| !s.complete || !s.lookups.is_empty() || !s.witnesses.is_empty())
        {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Stops scanning finished one-time keys, under the wallet write lock, once sync has
/// scanned to `tip`, the chain tip it revalidated this session. Sync calls it only where
/// [`supported`].
pub(crate) fn close_finished_keys(db: &mut WalletDatabase, tip: BlockHeight) -> Result<(), String> {
    let now = now()?;
    for account in software_accounts(db)? {
        db.close_finished_one_time_keys(account, now, tip)
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use secrecy::SecretVec;
    use zakura_one_time_ivk::{KeyId, Purpose};
    use zcash_client_backend::data_api::WalletWrite;
    use zcash_client_sqlite::wallet::one_time_ivk::swap::{ProviderSeen, ReservationPolicy};

    /// A seen set fresh at `now` that holds no receiver.
    fn unseen(now: i64) -> ProviderSeen<'static> {
        fn none(receivers: &[[u8; 43]]) -> Vec<bool> {
            vec![false; receivers.len()]
        }
        ProviderSeen {
            since: 0,
            until: now,
            contains: &none,
        }
    }

    /// Creates a regtest wallet at `path` whose first account, from the zero seed, is
    /// scanned through block 110, and returns that account.
    fn scanned_wallet(path: &str) -> (WalletDatabase, AccountUuid) {
        let network = WalletNetwork::Regtest;
        super::super::network::configure_regtest_nu6_3_activation_height(100).unwrap();
        let (uuid, _) = super::super::keys::init_db_and_create_account(
            path,
            network,
            &SecretVec::new(vec![0; 32]),
            Some(100),
            "POC",
        )
        .unwrap();
        let mut db = open_wallet_db_with_timeout(path, network, WALLET_DB_BUSY_TIMEOUT).unwrap();
        db.update_chain_tip(BlockHeight::from_u32(110)).unwrap();
        // Model completed ordinary scanning.
        rusqlite::Connection::open(path)
            .unwrap()
            .execute_batch(
                "INSERT INTO blocks(height,hash,time,sapling_tree) VALUES(110,zeroblob(32),0,X'000000');
                 DELETE FROM scan_queue;
                 INSERT INTO scan_queue(block_range_start,block_range_end,priority) VALUES(100,111,10);",
            )
            .unwrap();
        (db, parse_account_uuid(&uuid).unwrap())
    }

    /// A restored account's swap history is unchecked until discovery runs, which needs
    /// neither privacy switch, and new addresses wait for it.
    #[test]
    fn restored_accounts_wait_for_discovery_with_both_settings_off() {
        assert!(!crate::api::sync::enhance_pir_enabled());
        assert!(!crate::api::sync::near_swap_privacy_enabled());
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("wallet.db");
        let (mut db, account) = scanned_wallet(path.to_str().unwrap());
        assert!(history_pending(&db).unwrap());
        let now = now().unwrap();
        let tip = BlockHeight::from_u32(110);
        assert_eq!(
            db.prepare_receive_reservation(account, now, tip, Some(&unseen(now)))
                .unwrap()
                .err(),
            Some(ReservationPolicy::Gap)
        );
        assert!(db.get_one_time_scanning_keys().unwrap().is_empty());
        let error = require_new_address(WalletNetwork::Main).unwrap_err();
        assert!(error.contains("Enable Private queries"), "{error}");
    }

    /// A fresh account has no history to check, so it issues at once, but only with a
    /// seen set fresh at the caller's clock.
    #[test]
    fn fresh_accounts_issue_with_a_fresh_seen_set() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("wallet.db");
        let (mut db, account) = scanned_wallet(path.to_str().unwrap());
        db.mark_one_time_account_fresh(account).unwrap();
        assert!(!history_pending(&db).unwrap());
        let now = now().unwrap();
        let tip = BlockHeight::from_u32(110);
        assert_eq!(
            db.prepare_receive_reservation(account, now, tip, None)
                .unwrap()
                .err(),
            Some(ReservationPolicy::SeenUnavailable)
        );
        let stale = unseen(now - 3600);
        assert_eq!(
            db.reserve_refund_key(account, now, tip, Some(&stale))
                .unwrap()
                .err(),
            Some(ReservationPolicy::SeenUnavailable)
        );
        let key = db
            .prepare_receive_reservation(account, now, tip, Some(&unseen(now)))
            .unwrap()
            .unwrap();
        assert_eq!(key.key_id(), KeyId::new(Purpose::Receive, 0));
        // The unquoted draft is resumed rather than another address reserved.
        let again = db
            .prepare_receive_reservation(account, now, tip, Some(&unseen(now)))
            .unwrap()
            .unwrap();
        assert_eq!(again.key_id(), key.key_id());
    }

    /// A swap address counts as scanning while its key is open, and not once the key
    /// closes, as reclaiming an unpaid reservation closes it.
    #[test]
    fn a_swap_address_scans_until_its_key_closes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("wallet.db");
        let path = path.to_str().unwrap();
        let network = WalletNetwork::Regtest;
        let (mut db, account) = scanned_wallet(path);
        // Issue the first incoming address, as a fresh account can at once.
        db.mark_one_time_account_fresh(account).unwrap();
        let now = now().unwrap();
        let tip = BlockHeight::from_u32(110);
        let key = db
            .prepare_receive_reservation(account, now, tip, Some(&unseen(now)))
            .unwrap()
            .unwrap();
        let address = encode_address(&key, network).unwrap();
        let ordinary = super::super::keys::get_address_from_db(
            path,
            network,
            Some(&account.expose_uuid().to_string()),
        )
        .unwrap();
        let scanning = |db: &WalletDatabase, address: &str| {
            is_address_scanning(db, network, account, address).unwrap()
        };

        assert!(scanning(&db, &address));
        assert!(!scanning(&db, &ordinary), "not a swap address");
        assert!(!scanning(&db, "not an address"));
        rusqlite::Connection::open(path)
            .unwrap()
            .execute(
                "UPDATE ironwood_one_time_keys SET closed_at = 1
                 WHERE purpose = 1 AND key_index = X'0000000000000000'",
                [],
            )
            .unwrap();
        assert!(!scanning(&db, &address));
    }

    /// Accounts the app creates from a seed it generated start fresh, so no discovery
    /// runs for them. A payment-link claim imports the link's seed, which
    /// is not fresh.
    #[test]
    fn created_accounts_are_fresh_but_a_claimed_seed_is_not() {
        use super::super::keys::generate_mnemonic;
        use crate::api::wallet as api;

        let dir = tempfile::tempdir().unwrap();
        super::super::network::configure_regtest_nu6_3_activation_height(100).unwrap();
        let fresh = |path: &str, uuid: &str| -> bool {
            rusqlite::Connection::open(path)
                .unwrap()
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM ironwood_one_time_fresh_accounts f
                     JOIN accounts a ON a.id = f.account_id WHERE a.uuid = ?1)",
                    [parse_account_uuid(uuid).unwrap().expose_uuid()],
                    |r| r.get(0),
                )
                .unwrap()
        };
        let path = dir.path().join("wallet.db").to_str().unwrap().to_owned();
        let created = api::create_wallet("regtest".into(), path.clone(), Some(100), None).unwrap();
        let added = api::add_account(
            path.clone(),
            "regtest".into(),
            "Added".into(),
            generate_mnemonic(),
            String::new(),
            Some(100),
        )
        .unwrap();
        assert!(fresh(&path, &created.account_uuid));
        assert!(fresh(&path, &added.account_uuid));

        let claim = dir.path().join("claim.db").to_str().unwrap().to_owned();
        let claimed = api::import_wallet(
            generate_mnemonic(),
            String::new(),
            Some(100),
            "regtest".into(),
            claim.clone(),
            None,
            false,
        )
        .unwrap();
        assert!(!fresh(&claim, &claimed.account_uuid));
    }

    /// One-time IVKs cover the first account and accounts added from another seed,
    /// whose swap notes Vizor can spend, but not hardware or view-only accounts.
    #[test]
    fn added_seed_accounts_are_software_but_hardware_and_view_only_accounts_are_not() {
        use super::super::keys;
        use secrecy::ExposeSecret;
        use std::collections::HashSet;
        use zcash_keys::keys::UnifiedSpendingKey;

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("wallet.db");
        let path = path.to_str().unwrap();
        let network = WalletNetwork::Regtest;
        super::super::network::configure_regtest_nu6_3_activation_height(100).unwrap();
        let uuid = |uuid: String| parse_account_uuid(&uuid).unwrap();
        let derived = SecretVec::new(vec![0; 32]);
        let derived = uuid(
            keys::init_db_and_create_account(path, network, &derived, Some(100), "Derived")
                .unwrap()
                .0,
        );
        // Accounts added to a wallet are spending UFVK imports with ZIP 32 metadata.
        let added_seed = SecretVec::new(vec![1; 32]);
        let added = uuid(
            keys::add_account(path, network, "Added", &added_seed, Some(100))
                .unwrap()
                .0,
        );
        let hardware_ufvk =
            UnifiedSpendingKey::from_seed(&network, &[2; 32], zip32::AccountId::ZERO)
                .unwrap()
                .to_unified_full_viewing_key();
        let hardware = uuid(
            keys::import_hardware_account(
                path,
                network,
                "Keystone",
                &hardware_ufvk.encode(&network),
                &[2; 32],
                0,
                Some(100),
                keys::HardwareSignerKind::Keystone,
            )
            .unwrap()
            .0,
        );
        let observer_phrase = keys::generate_mnemonic();
        let observer_seed = keys::mnemonic_to_seed(&observer_phrase).unwrap();
        let observer = uuid(
            keys::register_gift_card_observer(
                path,
                network,
                observer_phrase.as_bytes(),
                &keys::derive_gift_address(network, &observer_seed, 0).unwrap(),
                100,
            )
            .unwrap(),
        );

        let mut db = open_wallet_db_with_timeout(path, network, WALLET_DB_BUSY_TIMEOUT).unwrap();
        assert_eq!(
            software_accounts(&db)
                .unwrap()
                .into_iter()
                .collect::<HashSet<_>>(),
            HashSet::from([derived, added])
        );
        for account in [hardware, observer] {
            assert!(require_software_account(&db, account).is_err());
        }

        // A fresh added account issues its first address, as in the test above.
        db.update_chain_tip(BlockHeight::from_u32(110)).unwrap();
        rusqlite::Connection::open(path)
            .unwrap()
            .execute_batch(
                "INSERT INTO blocks(height,hash,time,sapling_tree) VALUES(110,zeroblob(32),0,X'000000');
                 DELETE FROM scan_queue;
                 INSERT INTO scan_queue(block_range_start,block_range_end,priority) VALUES(100,111,10);",
            )
            .unwrap();
        db.mark_one_time_account_fresh(added).unwrap();
        let now = now().unwrap();
        db.prepare_receive_reservation(
            added,
            now,
            BlockHeight::from_u32(110),
            Some(&unseen(now)),
        )
        .unwrap()
        .unwrap();
        let registered: u64 = rusqlite::Connection::open(path)
            .unwrap()
            .query_row("SELECT COUNT(*) FROM ironwood_one_time_keys", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(registered, 1);
        let first_receiver = |fvk: &orchard::keys::FullViewingKey| {
            KeyId::new(Purpose::Receive, 0)
                .derive(fvk)
                .unwrap()
                .address_at(0u32, orchard::keys::Scope::External)
        };
        let observer_ufvk = UnifiedSpendingKey::from_seed(
            &network,
            observer_seed.expose_secret(),
            zip32::AccountId::ZERO,
        )
        .unwrap()
        .to_unified_full_viewing_key();
        for (account, ufvk) in [(hardware, hardware_ufvk), (observer, observer_ufvk)] {
            let receiver = first_receiver(ufvk.orchard().unwrap());
            assert!(db
                .get_one_time_key_for_receiver(account, &receiver)
                .unwrap()
                .is_none());
        }

        // Spending derives the added account's key from its seed and ZIP 32 index, as
        // `execute_stored_proposal` does. The builder finds the account by that key's
        // UFVK, and the swap FVK it derives shares the account's spending authority
        // and matches the registered key.
        let index = db
            .get_account(added)
            .unwrap()
            .unwrap()
            .source()
            .key_derivation()
            .unwrap()
            .account_index();
        let usk =
            UnifiedSpendingKey::from_seed(&network, added_seed.expose_secret(), index).unwrap();
        assert_eq!(
            db.get_account_for_ufvk(&usk.to_unified_full_viewing_key())
                .unwrap()
                .map(|account| account.id()),
            Some(added)
        );
        let fvk = orchard::keys::FullViewingKey::from(usk.orchard());
        let swap_fvk = KeyId::new(Purpose::Receive, 0).derive(&fvk).unwrap();
        // A one-time FVK keeps the account's ak and nk, its first 64 bytes.
        assert_eq!(fvk.to_bytes()[..64], swap_fvk.to_bytes()[..64]);
        let key = db
            .get_one_time_key_for_receiver(added, &first_receiver(&fvk))
            .unwrap()
            .unwrap();
        assert_eq!(key.key_id(), KeyId::new(Purpose::Receive, 0));
    }
}
