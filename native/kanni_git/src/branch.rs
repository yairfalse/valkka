use crate::error::KanniError;
use crate::handle::RepoHandle;
use rustler::{NifResult, ResourceArc};
use serde::Serialize;

#[derive(Serialize)]
struct HeadInfo {
    branch: Option<String>,
    is_detached: bool,
    ahead: usize,
    behind: usize,
}

/// Get head info for an open repository: current branch, ahead/behind counts.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn repo_head_info(handle: ResourceArc<RepoHandle>) -> NifResult<String> {
    let repo = handle.repo.lock().map_err(|_| {
        rustler::Error::Term(Box::new(KanniError::LockPoisoned))
    })?;

    let head = match repo.head() {
        Ok(h) => h,
        Err(_) => {
            // No HEAD yet (empty repo)
            let info = HeadInfo {
                branch: None,
                is_detached: false,
                ahead: 0,
                behind: 0,
            };
            return serde_json::to_string(&info).map_err(|e| {
                rustler::Error::Term(Box::new(format!("json: {}", e)))
            });
        }
    };

    let is_detached = repo.head_detached().unwrap_or(false);
    let branch = if is_detached {
        None
    } else {
        head.shorthand().map(|s| s.to_string())
    };

    let (ahead, behind) = compute_ahead_behind(&repo, &head);

    let info = HeadInfo {
        branch,
        is_detached,
        ahead,
        behind,
    };

    serde_json::to_string(&info).map_err(|e| {
        rustler::Error::Term(Box::new(format!("json: {}", e)))
    })
}

fn compute_ahead_behind(
    repo: &git2::Repository,
    head: &git2::Reference,
) -> (usize, usize) {
    let local_oid = match head.target() {
        Some(oid) => oid,
        None => return (0, 0),
    };

    // Try to find the upstream branch
    let branch_name = match head.shorthand() {
        Some(name) => name.to_string(),
        None => return (0, 0),
    };

    let branch = match repo.find_branch(&branch_name, git2::BranchType::Local) {
        Ok(b) => b,
        Err(_) => return (0, 0),
    };

    let upstream = match branch.upstream() {
        Ok(u) => u,
        Err(_) => return (0, 0), // No upstream configured
    };

    let upstream_oid = match upstream.get().target() {
        Some(oid) => oid,
        None => return (0, 0),
    };

    repo.graph_ahead_behind(local_oid, upstream_oid)
        .unwrap_or((0, 0))
}
