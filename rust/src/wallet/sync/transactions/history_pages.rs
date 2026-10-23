//! Reusable local Activity snapshots. Connections stay open, read transactions do
//! not. data_version on the same connection detects outside commits. A page
//! may continue across unrelated writes after comparing account summaries and
//! re-reading its details; the next explicit index refresh advances its token.
use std::{
    collections::{BTreeSet, VecDeque},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex, OnceLock,
    },
};

use super::*;

const DETAIL_BATCH: usize = 20;
const MAX_ACCOUNTS: usize = 4;

pub(crate) struct HistoryIndex {
    pub snapshot_id: String,
    pub summaries: Vec<HistorySummary>,
}

pub(crate) struct HistorySummary {
    pub txid_hex: String,
    pub mined_height: u64,
    pub expired_unmined: bool,
    pub block_time: u64,
    pub created_time: u64,
    pub source_order: u32,
}

pub(crate) struct HistoryRows {
    pub stale: bool,
    pub transactions: Vec<TransactionInfo>,
}

#[derive(Clone, PartialEq, Eq)]
struct Key {
    path: String,
    network: WalletNetwork,
    account: AccountUuid,
}

struct Entry {
    conn: rusqlite::Connection,
    file: same_file::Handle,
    snapshot: Option<Snapshot>,
}

struct Snapshot {
    id: String,
    version: i64,
    refresh_on_next_index: bool,
    bases: Vec<TxBase>,
    order: Vec<usize>,
    by_txid: HashMap<Vec<u8>, usize>,
    peers: HashMap<(String, i64), Vec<usize>>,
    details: HashMap<Vec<u8>, HistoryCompleteness>,
    outputs: HashMap<Vec<u8>, Vec<TxOutput>>,
}

struct HistorySlot {
    retired: AtomicBool,
    entry: Mutex<Option<Entry>>,
}
type Slot = Arc<HistorySlot>;

fn next_snapshot_id() -> String {
    static NEXT_ID: AtomicU64 = AtomicU64::new(1);
    NEXT_ID.fetch_add(1, Ordering::Relaxed).to_string()
}

fn entries() -> &'static Mutex<VecDeque<(Key, Slot)>> {
    static ENTRIES: OnceLock<Mutex<VecDeque<(Key, Slot)>>> = OnceLock::new();
    ENTRIES.get_or_init(|| Mutex::new(VecDeque::new()))
}

fn slot(key: Key) -> Slot {
    let mut entries = entries().lock().unwrap_or_else(|e| e.into_inner());
    let entry = entries
        .iter()
        .position(|(k, _)| k == &key)
        .and_then(|i| entries.remove(i))
        .unwrap_or_else(|| {
            (
                key,
                Arc::new(HistorySlot {
                    retired: AtomicBool::new(false),
                    entry: Mutex::new(None),
                }),
            )
        });
    let result = entry.1.clone();
    entries.push_back(entry);
    while entries.len() > MAX_ACCOUNTS {
        entries.pop_front();
    }
    result
}

pub(crate) fn clear() {
    let retired = {
        let mut active = entries().lock().unwrap_or_else(|e| e.into_inner());
        std::mem::take(&mut *active)
    };
    let mut snapshots = Vec::new();
    // This function is also called from synchronous FFI. Close idle file
    // handles now, but destroy potentially large receipt maps off that thread.
    // Busy entries finish and are dropped on their existing native worker.
    for (_, slot) in &retired {
        slot.retired.store(true, Ordering::Release);
        if let Ok(mut entry) = slot.entry.try_lock() {
            if let Some(Entry {
                conn,
                file,
                snapshot,
            }) = entry.take()
            {
                drop(conn);
                drop(file);
                snapshots.push(snapshot);
            }
        }
    }
    if !retired.is_empty() {
        let _ = std::thread::Builder::new()
            .name("activity-cache-release".into())
            .spawn(move || drop((retired, snapshots)));
    }
}

pub(crate) fn evict_db(path: &str) {
    let retired = {
        let mut active = entries().lock().unwrap_or_else(|e| e.into_inner());
        let mut retired = Vec::new();
        let mut kept = VecDeque::new();
        for (key, slot) in active.drain(..) {
            if key.path == path {
                slot.retired.store(true, Ordering::Release);
                retired.push(slot);
            } else {
                kept.push_back((key, slot));
            }
        }
        *active = kept;
        retired
    };
    // Reset's asynchronous FFI boundary drains in-flight reads before closing
    // the cached connections; the caller may delete the file afterwards.
    for slot in retired {
        slot.entry.lock().unwrap_or_else(|e| e.into_inner()).take();
    }
}

fn with_snapshot<T>(
    path: &str,
    network: WalletNetwork,
    account: AccountUuid,
    expected: Option<&str>,
    rebase_unchanged_summary: bool,
    read: impl FnOnce(&rusqlite::Connection, &mut Snapshot) -> Result<T, String>,
) -> Result<Option<T>, String> {
    let slot = slot(Key {
        path: path.into(),
        network,
        account,
    });
    let mut entry = slot.entry.lock().unwrap_or_else(|e| e.into_inner());
    if slot.retired.load(Ordering::Acquire) {
        return Err("Activity snapshot is no longer available".into());
    }
    let file = same_file::Handle::from_path(path).map_err(|e| e.to_string())?;
    if entry.as_ref().is_none_or(|e| e.file != file) {
        *entry = Some(Entry {
            conn: open_readonly_conn(path)?,
            file,
            snapshot: None,
        });
    }
    let Entry { conn, snapshot, .. } = entry.as_mut().unwrap();
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    // Establish the SQLite snapshot before observing its connection-local
    // data_version. A concurrent writer cannot change either within this read.
    let present: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM accounts WHERE uuid = ?1)",
            [account.expose_uuid().as_bytes().as_slice()],
            |r| r.get(0),
        )
        .map_err(|e| e.to_string())?;
    if !present {
        return Err("Activity account no longer exists".into());
    }
    let version: i64 = tx
        .pragma_query_value(None, "data_version", |r| r.get(0))
        .map_err(|e| e.to_string())?;
    if let Some(expected) = expected {
        let Some(saved) = snapshot.as_mut().filter(|s| s.id == expected) else {
            return Ok(None);
        };
        if !rebase_unchanged_summary && saved.refresh_on_next_index {
            return Ok(None);
        }
        if saved.version != version {
            if !rebase_unchanged_summary {
                return Ok(None);
            }
            let bases = read_history_bases_with_claim_state(&tx, path, network, account)?;
            if bases != saved.bases {
                return Ok(None);
            }
            // Scanning often commits blocks unrelated to this account between
            // the index and row calls. The same ordering remains valid, but
            // detail facts must come from this transaction, never the old cache.
            saved.bases = bases;
            saved.version = version;
            saved.details.clear();
            saved.outputs.clear();
            // A screen refresh must still replace its older displayed facts,
            // even when a page continued under unchanged ordering metadata.
            saved.refresh_on_next_index = true;
        }
    } else if let Some(saved) = snapshot
        .as_mut()
        .filter(|s| s.version == version && s.refresh_on_next_index)
    {
        // The page already revalidated this version. Advance the UI identity
        // without repeating its summary/detail SQL on an unchanged database.
        saved.id = next_snapshot_id();
        saved.refresh_on_next_index = false;
    } else if snapshot.as_ref().is_none_or(|s| s.version != version) {
        let bases = read_history_bases_with_claim_state(&tx, path, network, account)?;
        let mut order: Vec<_> = (0..bases.len()).collect();
        order.sort_by_cached_key(|&i| std::cmp::Reverse(bases[i].history_sort_key()));
        let by_txid = bases
            .iter()
            .enumerate()
            .map(|(i, b)| (b.txid.clone(), i))
            .collect();
        let mut peers: HashMap<(String, i64), Vec<usize>> = HashMap::new();
        for (i, base) in bases.iter().enumerate() {
            if let Some(created) = &base.created {
                peers
                    .entry((created.clone(), base.expiry_key()))
                    .or_default()
                    .push(i);
            }
        }
        *snapshot = Some(Snapshot {
            id: next_snapshot_id(),
            version,
            refresh_on_next_index: false,
            bases,
            order,
            by_txid,
            peers,
            details: HashMap::new(),
            outputs: HashMap::new(),
        });
    }
    read(&tx, snapshot.as_mut().unwrap()).map(Some)
}

fn load_details(
    conn: &rusqlite::Connection,
    snapshot: &mut Snapshot,
    path: &str,
    network: WalletNetwork,
    account: AccountUuid,
    bases: &mut [TxBase],
) -> Result<(), String> {
    let mut missing: Vec<_> = bases
        .iter()
        .filter(|b| !snapshot.details.contains_key(&b.txid))
        .cloned()
        .collect();
    for batch in missing.chunks_mut(DETAIL_BATCH) {
        attach_history_details(conn, path, network, account, batch)?;
        let outputs = read_history_outputs(
            conn,
            account.expose_uuid().as_bytes(),
            batch.iter().map(|b| b.txid.as_slice()),
        )?;
        snapshot.outputs.extend(outputs);
        for base in batch.iter() {
            snapshot
                .details
                .insert(base.txid.clone(), base.history.clone());
        }
    }
    for base in bases {
        base.attach_history(snapshot.details[&base.txid].clone());
    }
    Ok(())
}

pub(crate) fn index(
    path: &str,
    network: WalletNetwork,
    account: AccountUuid,
) -> Result<HistoryIndex, String> {
    Ok(
        with_snapshot(path, network, account, None, false, |_, snapshot| {
            Ok(HistoryIndex {
                snapshot_id: snapshot.id.clone(),
                summaries: snapshot
                    .order
                    .iter()
                    .enumerate()
                    .map(|(source_order, &i)| {
                        let base = &snapshot.bases[i];
                        HistorySummary {
                            txid_hex: hex::encode(&base.txid),
                            mined_height: base.mined_height.unwrap_or(0).into(),
                            expired_unmined: base.expired_unmined,
                            block_time: base.block_time,
                            created_time: base.created_time,
                            source_order: source_order as u32,
                        }
                    })
                    .collect(),
            })
        })?
        .unwrap(),
    )
}

pub(crate) fn rows(
    path: &str,
    network: WalletNetwork,
    account: AccountUuid,
    snapshot_id: &str,
    txids: &[String],
) -> Result<HistoryRows, String> {
    if txids.len() > DETAIL_BATCH {
        return Err("Activity batch exceeds 20 transactions".into());
    }
    let requested = txids
        .iter()
        .map(|s| {
            let bytes = hex::decode(s).map_err(|e| e.to_string())?;
            if bytes.len() != 32 {
                return Err("Invalid Activity txid".to_owned());
            }
            Ok(bytes)
        })
        .collect::<Result<HashSet<_>, String>>()?;
    let transactions = with_snapshot(
        path,
        network,
        account,
        Some(snapshot_id),
        !requested.is_empty(),
        |conn, snapshot| {
            let mut selected = BTreeSet::new();
            for txid in &requested {
                if let Some(&i) = snapshot.by_txid.get(txid) {
                    selected.insert(i);
                    let base = &snapshot.bases[i];
                    if let Some(created) = &base.created {
                        if let Some(peers) =
                            snapshot.peers.get(&(created.clone(), base.expiry_key()))
                        {
                            selected.extend(peers);
                        }
                    }
                }
            }
            let mut bases: Vec<_> = selected
                .into_iter()
                .map(|i| snapshot.bases[i].clone())
                .collect();
            load_details(conn, snapshot, path, network, account, &mut bases)?;
            let mut rows = assemble_history(
                &bases,
                &snapshot.outputs,
                account.expose_uuid().as_bytes(),
                None,
            );
            let hexes: HashSet<_> = requested.iter().map(hex::encode).collect();
            rows.retain(|row| hexes.contains(&row.txid_hex));
            Ok(rows)
        },
    )?;
    Ok(HistoryRows {
        stale: transactions.is_none(),
        transactions: transactions.unwrap_or_default(),
    })
}

pub(crate) fn recent(
    path: &str,
    network: WalletNetwork,
    account: AccountUuid,
    limit: u32,
) -> Result<Vec<TransactionInfo>, String> {
    if limit == 0 {
        return Ok(Vec::new());
    }
    Ok(
        with_snapshot(path, network, account, None, false, |conn, snapshot| {
            recent_history::assemble_recent_history(
                snapshot.bases.clone(),
                account.expose_uuid().as_bytes(),
                limit,
                |batch| {
                    load_details(conn, snapshot, path, network, account, batch)?;
                    Ok(batch
                        .iter()
                        .filter_map(|b| {
                            snapshot
                                .outputs
                                .get(&b.txid)
                                .map(|outputs| (b.txid.clone(), outputs.clone()))
                        })
                        .collect())
                },
            )
        })?
        .unwrap(),
    )
}
