//! The process-wide selected server and the product routes derived from it.

use std::sync::{
    atomic::{AtomicU64, Ordering},
    RwLock,
};

use zakura_pir_config::ServerBase;
pub(crate) use zakura_pir_protocol::endpoint::PirProduct;

/// The origin handed to `product`'s client: the selected server base. The
/// clients compose `<base>/<product>/v1/...` from it themselves
/// ([`PirProduct::route_prefix`]), so the base is passed bare.
///
/// Debug builds may name a test server through the product's environment
/// variable, but only while the user has selected nothing, so a test
/// override never redirects a user's choice.
pub(crate) fn client_origin(product: PirProduct) -> Option<String> {
    if let Some(base) = selected_server_base() {
        return Some(base);
    }
    #[cfg(debug_assertions)]
    if let Ok(origin) = std::env::var(debug_override_env(product)) {
        return Some(origin);
    }
    let _ = product;
    None
}

#[cfg(debug_assertions)]
fn debug_override_env(product: PirProduct) -> &'static str {
    match product {
        PirProduct::Enhance => "VIZOR_ENHANCE_PIR_URL",
        PirProduct::Status => "VIZOR_STATUS_PIR_URL",
        PirProduct::Transparent => "VIZOR_TRANSPARENT_PIR_URL",
        PirProduct::Receiver => "VIZOR_RECEIVER_PIR_URL",
    }
}

/// A selected server base and the generation that counts its changes.
///
/// The generation lets work that captured it before an await tell that its
/// server is no longer the selected one.
pub(crate) struct ServerSelection {
    base: RwLock<Option<String>>,
    generation: AtomicU64,
}

impl ServerSelection {
    pub(crate) const fn new() -> Self {
        Self {
            base: RwLock::new(None),
            generation: AtomicU64::new(0),
        }
    }

    pub(crate) fn base(&self) -> Option<String> {
        self.base
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    pub(crate) fn generation(&self) -> u64 {
        self.generation.load(Ordering::SeqCst)
    }

    /// Selects `base` and returns the new generation. Selecting the base
    /// already selected keeps the generation, so a repeated apply at startup
    /// or resume does not tear down sessions.
    pub(crate) fn select(&self, base: &str) -> Result<u64, String> {
        let normalized = ServerBase::parse(base)
            .map_err(|error| error.to_string())?
            .as_str()
            .to_owned();
        let mut selected = self
            .base
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if selected.as_deref() == Some(normalized.as_str()) {
            return Ok(self.generation());
        }
        *selected = Some(normalized);
        Ok(self.generation.fetch_add(1, Ordering::SeqCst) + 1)
    }

    /// Clears the selection; private PIR work then has no server.
    pub(crate) fn clear(&self) -> u64 {
        let mut selected = self
            .base
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if selected.take().is_none() {
            return self.generation();
        }
        self.generation.fetch_add(1, Ordering::SeqCst) + 1
    }
}

/// The process's selection, applied by Dart from the user's saved choice.
static SELECTION: ServerSelection = ServerSelection::new();

pub(crate) fn selected_server_base() -> Option<String> {
    SELECTION.base()
}

pub(crate) fn set_selected_server(base: &str) -> Result<u64, String> {
    SELECTION.select(base)
}

pub(crate) fn clear_selected_server() -> u64 {
    SELECTION.clear()
}
