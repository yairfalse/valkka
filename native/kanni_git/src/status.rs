use crate::error::KanniError;
use crate::handle::RepoHandle;
use rustler::{NifResult, ResourceArc};
use serde::Serialize;

#[derive(Serialize)]
pub struct FileStatus {
    pub path: String,
    pub status: String,
}

/// Get the working directory status of a repository.
///
/// Returns a JSON-encoded list of file statuses. We use JSON as the
/// serialization boundary between Rust and Elixir for complex data —
/// simpler than building Erlang terms manually, and the overhead is
/// negligible compared to the git operations themselves.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn repo_status(handle: ResourceArc<RepoHandle>) -> NifResult<String> {
    let repo = handle.repo.lock().map_err(|_| {
        rustler::Error::Term(Box::new(KanniError::LockPoisoned))
    })?;

    let statuses = repo.statuses(None).map_err(|e| {
        rustler::Error::Term(Box::new(KanniError::from(e)))
    })?;

    let file_statuses: Vec<FileStatus> = statuses
        .iter()
        .map(|entry| {
            let path = entry.path().unwrap_or("").to_string();
            let status = format!("{:?}", entry.status());
            FileStatus { path, status }
        })
        .collect();

    serde_json::to_string(&file_statuses).map_err(|e| {
        rustler::Error::Term(Box::new(format!("json: {}", e)))
    })
}
