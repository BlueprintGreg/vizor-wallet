//! The process-wide selected server and the product routes derived from it.

use std::sync::{
    atomic::{AtomicU64, Ordering},
    RwLock,
};

use zakura_pir_config::ServerBase;

/// The private PIR products a selected server serves.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PirProduct {
    Enhance,
    Status,
    Transparent,
    Receiver,
}

// `ALL`, `path` and `endpoint` are the canonical layout; until the pinned
// clients take it, only tests and the route contract use them.
#[cfg_attr(not(test), allow(dead_code))]
impl PirProduct {
    pub(crate) const ALL: [Self; 4] = [
        Self::Enhance,
        Self::Status,
        Self::Transparent,
        Self::Receiver,
    ];

    /// The canonical path prefix of this product below a server base.
    pub(crate) fn path(self) -> &'static str {
        match self {
            Self::Enhance => "/enhance/v1",
            Self::Status => "/status/v1",
            Self::Transparent => "/transparent/v1",
            Self::Receiver => "/receiver/v1",
        }
    }

    /// This product's endpoint on `base`, a canonical [`ServerBase`] string
    /// without a trailing `/`, so the product prefix is appended exactly once.
    pub(crate) fn endpoint(self, base: &str) -> String {
        format!("{base}{}", self.path())
    }

    /// The origin handed to this product's client: the selected server base.
    ///
    /// The pinned clients still append their own legacy `/v1/<product>`
    /// paths, so they receive the bare base rather than [`Self::endpoint`];
    /// passing both would double the product prefix. When the canonical
    /// route clients land this returns [`Self::endpoint`] of the base.
    ///
    /// Debug builds may name a test server through the product's environment
    /// variable, but only while the user has selected nothing, so a test
    /// override never redirects a user's choice.
    pub(crate) fn client_origin(self) -> Option<String> {
        if let Some(base) = selected_server_base() {
            return Some(base);
        }
        #[cfg(debug_assertions)]
        if let Ok(origin) = std::env::var(self.debug_override_env()) {
            return Some(origin);
        }
        None
    }

    #[cfg(debug_assertions)]
    fn debug_override_env(self) -> &'static str {
        match self {
            Self::Enhance => "VIZOR_ENHANCE_PIR_URL",
            Self::Status => "VIZOR_STATUS_PIR_URL",
            Self::Transparent => "VIZOR_TRANSPARENT_PIR_URL",
            Self::Receiver => "VIZOR_RECEIVER_PIR_URL",
        }
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
