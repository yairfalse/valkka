use crate::error::ValkkaError;
use crate::handle::RepoHandle;
use git2::Status;
use rustler::{NifResult, ResourceArc};
use serde::Serialize;

#[derive(Serialize)]
struct StatusResult {
    staged: Vec<FileEntry>,
    unstaged: Vec<FileEntry>,
    untracked: Vec<FileEntry>,
}

#[derive(Serialize)]
struct FileEntry {
    path: String,
    status: String,
}

/// Get the working directory status, separated into staged/unstaged/untracked.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn repo_status(handle: ResourceArc<RepoHandle>) -> NifResult<String> {
    let repo = handle.repo.lock().map_err(|_| {
        rustler::Error::Term(Box::new(ValkkaError::LockPoisoned))
    })?;

    let statuses = repo.statuses(None).map_err(|e| {
        rustler::Error::Term(Box::new(ValkkaError::from(e)))
    })?;

    let mut result = StatusResult {
        staged: Vec::new(),
        unstaged: Vec::new(),
        untracked: Vec::new(),
    };

    for entry in statuses.iter() {
        let path = entry.path().unwrap_or("").to_string();
        let s = entry.status();

        // Untracked files
        if s.contains(Status::WT_NEW) {
            result.untracked.push(FileEntry {
                path: path.clone(),
                status: "new".to_string(),
            });
            continue;
        }

        // Staged changes (index)
        if s.intersects(Status::INDEX_NEW | Status::INDEX_MODIFIED | Status::INDEX_DELETED | Status::INDEX_RENAMED | Status::INDEX_TYPECHANGE) {
            let status = if s.contains(Status::INDEX_NEW) {
                "added"
            } else if s.contains(Status::INDEX_MODIFIED) {
                "modified"
            } else if s.contains(Status::INDEX_DELETED) {
                "deleted"
            } else if s.contains(Status::INDEX_RENAMED) {
                "renamed"
            } else {
                "modified"
            };
            result.staged.push(FileEntry {
                path: path.clone(),
                status: status.to_string(),
            });
        }

        // Unstaged changes (working tree)
        if s.intersects(Status::WT_MODIFIED | Status::WT_DELETED | Status::WT_RENAMED | Status::WT_TYPECHANGE) {
            let status = if s.contains(Status::WT_MODIFIED) {
                "modified"
            } else if s.contains(Status::WT_DELETED) {
                "deleted"
            } else if s.contains(Status::WT_RENAMED) {
                "renamed"
            } else {
                "modified"
            };
            result.unstaged.push(FileEntry {
                path: path.clone(),
                status: status.to_string(),
            });
        }
    }

    serde_json::to_string(&result).map_err(|e| {
        rustler::Error::Term(Box::new(format!("json: {}", e)))
    })
}
