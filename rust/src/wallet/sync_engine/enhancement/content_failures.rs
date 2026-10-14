//! Private lookups already answered at the current chain tip.
//!
//! A reply that does not decode, or a record the wallet rejects, leaves its
//! work durable, while an honest reply would have completed it. If that
//! leftover counted towards a recovery-only sync restart, a service could
//! tell a forged reply from an honest one by the wallet asking again 30
//! seconds later at the same block. So Enhance work that failed on content is
//! left out of the restart count, and out of every further query, until the
//! chain tip moves: it waits for the next block, which every wallet syncs for
//! anyway.
//!
//! Private status is stricter, because an honest reply can leave work too:
//! "not found" for an unmined transaction keeps it, "mined" completes it. So
//! every private status txid that got any reply at this tip, honest or not,
//! is left out of the restart count and is not asked again until the next
//! block. No status txid is asked twice at one tip, whatever the reply.
//!
//! Request failures (a refusal, an overload, a transport error) are not
//! recorded and may still bring a restart; the service already knows it
//! refused.
//!
//! The record lives in memory, per wallet. An app restart forgets it, and the
//! first sync after a restart runs at whatever tip it finds, which is public.

use std::collections::{BTreeSet, HashMap};
use std::sync::{LazyLock, Mutex, MutexGuard, PoisonError};

use zcash_client_backend::data_api::enhance_pir::EnhancePirRequest;
use zcash_primitives::transaction::TxId;

#[derive(Default)]
struct Failed {
    tip: u64,
    requests: BTreeSet<EnhancePirRequest>,
    statuses: BTreeSet<TxId>,
}

static FAILED: LazyLock<Mutex<HashMap<String, Failed>>> = LazyLock::new(Default::default);

fn failed() -> MutexGuard<'static, HashMap<String, Failed>> {
    FAILED.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Starts a sync of the wallet at `db_path` at chain tip `tip`: content
/// failures recorded below it are forgotten, so their work counts again.
pub(crate) fn at_tip(db_path: &str, tip: u64) {
    let mut failed = failed();
    let entry = failed.entry(db_path.to_owned()).or_default();
    if tip > entry.tip {
        *entry = Failed {
            tip,
            ..Failed::default()
        };
    }
}

/// Records Enhance requests whose reply failed on content.
pub(crate) fn enhance(db_path: &str, requests: impl IntoIterator<Item = EnhancePirRequest>) {
    failed()
        .entry(db_path.to_owned())
        .or_default()
        .requests
        .extend(requests);
}

/// Records a transaction whose private status lookup got a reply, of any
/// content, at the current tip.
pub(crate) fn status_answered(db_path: &str, txid: TxId) {
    failed()
        .entry(db_path.to_owned())
        .or_default()
        .statuses
        .insert(txid);
}

/// Whether the Enhance request failed on content at the current tip.
pub(crate) fn enhance_failed(db_path: &str, request: &EnhancePirRequest) -> bool {
    failed()
        .get(db_path)
        .is_some_and(|failed| failed.requests.contains(request))
}

/// Whether the transaction's private status lookup got a reply at the
/// current tip.
pub(crate) fn status_was_answered(db_path: &str, txid: &TxId) -> bool {
    failed()
        .get(db_path)
        .is_some_and(|failed| failed.statuses.contains(txid))
}
