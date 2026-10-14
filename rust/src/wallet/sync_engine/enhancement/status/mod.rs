//! Transaction-status source policy.
//!
//! A reader selects exactly one source for its lifetime. When private Status
//! PIR is selected, initialization or observation failure is inconclusive and
//! must not fall back to a public transaction-ID request. It also never fails
//! the sync, except for a local wallet database failure
//! (`StatusError::LocalStorage`).
//!
//! Private polls follow the wallet's fixed schedule, never the replies.
//! Every private reply, whatever it said, is recorded as that tip's poll and
//! as answered at this block (`content_failures`), and the next transaction
//! is asked. Only a request outcome, which the service chooses without
//! knowing which row was asked (a refusal, an overload, a stale publication,
//! a transport error or a reply that does not match the session), records
//! nothing: the work stays due at this tip and private status is skipped for
//! the rest of the session, so a lagging or unreachable service cannot stall
//! scanning.

mod private;
mod public;
mod store;

use std::collections::HashSet;

use crate::wallet::{
    network::WalletNetwork,
    sync_engine::{SyncError, TransparentLookupGate, WalletDatabase},
};
use zakura_transaction_status::{
    DisabledSource, StatusError, StatusMode, StatusObservation, StatusReader, StatusRequest,
    StatusSource,
};
use zcash_client_backend::data_api::{status::TransactionStatusWork, WalletRead};
use zcash_primitives::transaction::TxId;

pub(crate) use private::PrivateStatusSource;
#[cfg(test)]
pub(crate) use public::gated;
pub(crate) use public::lightwalletd_source;
#[cfg(test)]
pub(super) use store::persist_status_observation;

/// Both sources are lazy. The work variant is the only dispatch authority; there is no
/// fallback and no second policy decision when servicing a snapshot.
pub(crate) struct RoutedStatusReader<P: StatusSource, R: StatusSource> {
    public: StatusReader<P, DisabledSource>,
    private: StatusReader<DisabledSource, R>,
}
impl<P: StatusSource, R: StatusSource> RoutedStatusReader<P, R> {
    pub(crate) fn new(public: P, private: R) -> Self {
        Self {
            public: StatusReader::new(StatusMode::PublicLightwalletd, public, DisabledSource),
            private: StatusReader::new(StatusMode::PrivatePir, DisabledSource, private),
        }
    }
    pub(crate) async fn observe(
        &mut self,
        work: TransactionStatusWork,
        required_through: Option<u32>,
    ) -> Result<StatusObservation, StatusError> {
        match work {
            TransactionStatusWork::Public(request) => {
                self.public
                    .observe(StatusRequest {
                        txid: request.txid(),
                        coverage: Default::default(),
                    })
                    .await
            }
            TransactionStatusWork::Private(request) => {
                self.private
                    .observe(StatusRequest {
                        txid: request.txid(),
                        coverage: zakura_pir_status::LocalCoverageContext {
                            earliest_possible_inclusion: request
                                .earliest_possible_inclusion()
                                .map(u32::from),
                            required_through,
                        },
                    })
                    .await
            }
        }
    }
}

pub(crate) fn reader<'a, F, P>(
    db_path: &'a str,
    network: WalletNetwork,
    should_exit: &'a F,
    public_source: P,
) -> RoutedStatusReader<P, PrivateStatusSource<'a, F>>
where
    F: Fn() -> bool + Sync,
    P: StatusSource,
{
    RoutedStatusReader::new(
        public_source,
        PrivateStatusSource::new(db_path, network, should_exit),
    )
}

fn is_private(work: &TransactionStatusWork) -> bool {
    matches!(work, TransactionStatusWork::Private(_))
}

pub(super) async fn run_requests<P, R>(
    reader: &mut RoutedStatusReader<P, R>,
    db: &mut WalletDatabase,
    work: &[TransactionStatusWork],
    gate: &TransparentLookupGate,
    attempted: &mut HashSet<TxId>,
    private_failed: &mut bool,
    db_path: &str,
    ready: &mut HashSet<Vec<u8>>,
    should_exit: &impl Fn() -> bool,
) -> Result<bool, SyncError>
where
    P: StatusSource,
    R: StatusSource,
{
    // Public status discloses the txid; private work is unaffected. The public
    // source is gated per observation, and persistence re-reads the generation
    // in its own transaction. Withheld public work stays durable.
    let mut public_allowed = work.iter().any(|work| !is_private(work)) && gate.permits()?;
    let pending: Vec<_> = work
        .iter()
        .copied()
        .filter(|work| !attempted.contains(&work.txid()))
        .filter(|work| !(*private_failed && is_private(work)))
        // The wallet's poll window decides what is due at this tip. A private
        // txid answered at this tip, or created by a reply here, still waits
        // for the next block, whatever the reply said.
        .filter(|work| {
            !is_private(work) || super::content_failures::may_ask_status(db_path, &work.txid())
        })
        .filter(|work| public_allowed || is_private(work))
        .collect();
    let actionable = !pending.is_empty();
    // set_transaction_status evaluates absence against this database's advertised chain tip.
    let required_through = db
        .chain_height()
        .map_err(|e| SyncError::db(e.to_string()))?
        .map(u32::from);
    let decision_hash = match required_through {
        Some(height) => db
            .get_block_hash(zcash_protocol::consensus::BlockHeight::from_u32(height))
            .map_err(|e| SyncError::db(e.to_string()))?,
        None => None,
    };
    for work in pending {
        if *private_failed && is_private(&work) {
            continue;
        }
        if should_exit() {
            return Ok(actionable);
        }
        if !is_private(&work) && !public_allowed {
            continue;
        }
        let txid = work.txid();
        attempted.insert(txid);
        let observation = match reader.observe(work, required_through).await {
            Ok(observation) => {
                if let TransactionStatusWork::Private(request) = work {
                    super::content_failures::status_answered(db_path, txid);
                    store::record_private_poll(db, txid, required_through)?;
                    // The poll was due, so it was sent; the wallet already
                    // holds a conclusive status, so the answer is dropped.
                    if request.settled() {
                        continue;
                    }
                }
                observation.into()
            }
            // Content outcomes: the reply came back, but its row did not
            // decode, or the service's record could not prove the
            // transaction absent. A service could aim either at chosen rows,
            // so neither changes what is asked next. The poll is recorded and
            // the work stays durable for its next scheduled tip.
            Err(error @ (StatusError::Unreadable | StatusError::CoverageIncomplete))
                if is_private(&work) =>
            {
                super::content_failures::status_answered(db_path, txid);
                store::record_private_poll(db, txid, required_through)?;
                log::warn!("private status reply was inconclusive ({error}); the transaction waits for its next poll");
                continue;
            }
            // The gated public source reports a withheld observation as
            // `Cancelled`; the rest of the public work is withheld too.
            Err(StatusError::Cancelled) if !is_private(&work) && !gate.permits()? => {
                attempted.remove(&txid);
                public_allowed = false;
                continue;
            }
            Err(StatusError::Cancelled) => return Ok(actionable),
            // The wallet's own database could not be read. That is not a
            // service outage, so it fails the sync rather than being deferred.
            Err(StatusError::LocalStorage) => {
                return Err(SyncError::db(
                    "transaction status: local wallet database read failed",
                ));
            }
            Err(error) if is_private(&work) => {
                // A request outcome: keep the work due and stop querying the
                // private service for this session. Never a public fallback.
                log::warn!(
                    "private status observation failed; deferring for this session: {error}"
                );
                *private_failed = true;
                continue;
            }
            Err(error) => return Err(SyncError::net(error.to_string())),
        };
        if should_exit() {
            return Ok(actionable);
        }
        if store::persist_work_observation(
            db,
            db_path,
            work,
            observation,
            required_through,
            decision_hash,
            gate,
        )? {
            ready.insert(txid.as_ref().to_vec());
        }
    }
    Ok(actionable)
}
