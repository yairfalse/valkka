use crate::error::ValkkaError;
use crate::handle::RepoHandle;
use git2::Signature;
use rustler::{Atom, NifResult, ResourceArc};

mod atoms {
    rustler::atoms! {
        ok,
    }
}

/// Stage a file (add to index).
#[rustler::nif(schedule = "DirtyCpu")]
pub fn repo_stage(handle: ResourceArc<RepoHandle>, path: String) -> NifResult<Atom> {
    let repo = handle.repo.lock().map_err(|_| {
        rustler::Error::Term(Box::new(ValkkaError::LockPoisoned))
    })?;

    let mut index = repo.index().map_err(|e| {
        rustler::Error::Term(Box::new(ValkkaError::from(e)))
    })?;

    // Check if file exists on disk — if not, this is a deletion
    let workdir = repo.workdir().ok_or_else(|| {
        rustler::Error::Term(Box::new("bare repository"))
    })?;

    if workdir.join(&path).exists() {
        index.add_path(std::path::Path::new(&path)).map_err(|e| {
            rustler::Error::Term(Box::new(ValkkaError::from(e)))
        })?;
    } else {
        index.remove_path(std::path::Path::new(&path)).map_err(|e| {
            rustler::Error::Term(Box::new(ValkkaError::from(e)))
        })?;
    }

    index.write().map_err(|e| {
        rustler::Error::Term(Box::new(ValkkaError::from(e)))
    })?;

    Ok(atoms::ok())
}

/// Unstage a file (reset index entry to HEAD).
#[rustler::nif(schedule = "DirtyCpu")]
pub fn repo_unstage(handle: ResourceArc<RepoHandle>, path: String) -> NifResult<Atom> {
    let repo = handle.repo.lock().map_err(|_| {
        rustler::Error::Term(Box::new(ValkkaError::LockPoisoned))
    })?;

    let head = repo.head().ok().and_then(|h| h.peel_to_tree().ok());

    repo.reset_default(head.as_ref().map(|t| t.as_object()), &[&path])
        .map_err(|e| {
            rustler::Error::Term(Box::new(ValkkaError::from(e)))
        })?;

    Ok(atoms::ok())
}

/// Create a commit from the current index.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn repo_commit(
    handle: ResourceArc<RepoHandle>,
    message: String,
    author_name: String,
    author_email: String,
) -> NifResult<String> {
    let repo = handle.repo.lock().map_err(|_| {
        rustler::Error::Term(Box::new(ValkkaError::LockPoisoned))
    })?;

    let sig = Signature::now(&author_name, &author_email).map_err(|e| {
        rustler::Error::Term(Box::new(ValkkaError::from(e)))
    })?;

    let mut index = repo.index().map_err(|e| {
        rustler::Error::Term(Box::new(ValkkaError::from(e)))
    })?;

    let tree_oid = index.write_tree().map_err(|e| {
        rustler::Error::Term(Box::new(ValkkaError::from(e)))
    })?;

    let tree = repo.find_tree(tree_oid).map_err(|e| {
        rustler::Error::Term(Box::new(ValkkaError::from(e)))
    })?;

    let parents = match repo.head() {
        Ok(head) => {
            let commit = head.peel_to_commit().map_err(|e| {
                rustler::Error::Term(Box::new(ValkkaError::from(e)))
            })?;
            vec![commit]
        }
        Err(_) => vec![], // Initial commit
    };

    let parent_refs: Vec<&git2::Commit> = parents.iter().collect();

    let oid = repo
        .commit(Some("HEAD"), &sig, &sig, &message, &tree, &parent_refs)
        .map_err(|e| {
            rustler::Error::Term(Box::new(ValkkaError::from(e)))
        })?;

    Ok(oid.to_string())
}
