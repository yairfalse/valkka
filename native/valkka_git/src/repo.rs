use crate::error::ValkkaError;
use crate::handle::RepoHandle;
use git2::Repository;
use rustler::{Atom, NifResult, ResourceArc};

mod atoms {
    rustler::atoms! {
        ok,
    }
}

/// Open a git repository at the given path, returning a resource handle.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn repo_open(path: String) -> NifResult<ResourceArc<RepoHandle>> {
    let repo = Repository::open(&path).map_err(|e| {
        rustler::Error::Term(Box::new(ValkkaError::from(e)))
    })?;
    Ok(RepoHandle::new(repo))
}

/// Close a repository handle. The handle becomes invalid after this call.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn repo_close(_handle: ResourceArc<RepoHandle>) -> Atom {
    atoms::ok()
}
