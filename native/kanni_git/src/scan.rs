use rustler::NifResult;
use serde::Serialize;
use std::path::Path;

#[derive(Serialize)]
struct RepoEntry {
    path: String,
    name: String,
}

/// Walk a directory tree up to `max_depth` looking for directories that contain `.git`.
/// Returns a JSON array of `{path, name}` objects.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn workspace_scan(root: String, max_depth: usize) -> NifResult<String> {
    let root_path = Path::new(&root);
    let mut repos = Vec::new();

    if !root_path.is_dir() {
        return serde_json::to_string(&repos).map_err(|e| {
            rustler::Error::Term(Box::new(format!("json: {}", e)))
        });
    }

    let walker = walkdir::WalkDir::new(&root)
        .max_depth(max_depth)
        .follow_links(false)
        .into_iter()
        .filter_entry(|e| {
            let name = e.file_name().to_string_lossy();
            // Skip all hidden dirs and common large directories
            if e.depth() > 0 && name.starts_with('.') {
                return false;
            }
            if name == "node_modules" || name == "target" || name == "_build" || name == "deps" {
                return false;
            }
            true
        });

    for entry in walker {
        let entry = match entry {
            Ok(e) => e,
            Err(_) => continue,
        };

        if !entry.file_type().is_dir() {
            continue;
        }

        // Check if this directory contains a .git subdirectory
        let git_dir = entry.path().join(".git");
        if git_dir.is_dir() {
            let repo_path = entry.path().to_string_lossy().to_string();
            let name = entry
                .path()
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| repo_path.clone());

            repos.push(RepoEntry {
                path: repo_path,
                name,
            });
        }
    }

    repos.sort_by(|a, b| a.name.cmp(&b.name));

    serde_json::to_string(&repos).map_err(|e| {
        rustler::Error::Term(Box::new(format!("json: {}", e)))
    })
}
