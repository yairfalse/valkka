use git2::Repository;
use rustler::ResourceArc;
use std::sync::Mutex;

/// Thread-safe wrapper around git2::Repository for use as a NIF resource.
///
/// The Mutex ensures safe concurrent access from BEAM schedulers.
/// Each open repository gets one RepoHandle, stored server-side in the
/// Repo.Worker GenServer.
pub struct RepoHandle {
    pub repo: Mutex<Repository>,
}

impl RepoHandle {
    pub fn new(repo: Repository) -> ResourceArc<Self> {
        ResourceArc::new(Self {
            repo: Mutex::new(repo),
        })
    }
}
