use crate::error::KanniError;
use crate::handle::RepoHandle;
use git2::DiffOptions;
use rustler::{NifResult, ResourceArc};
use serde::Serialize;

#[derive(Serialize)]
struct DiffResult {
    path: String,
    hunks: Vec<Hunk>,
}

#[derive(Serialize)]
struct Hunk {
    header: String,
    old_start: u32,
    old_lines: u32,
    new_start: u32,
    new_lines: u32,
    lines: Vec<DiffLine>,
}

#[derive(Serialize)]
struct DiffLine {
    origin: String,   // "+", "-", " "
    content: String,
    old_lineno: Option<u32>,
    new_lineno: Option<u32>,
}

/// Get the diff for a specific file. If `staged` is true, diffs index vs HEAD.
/// If `staged` is false, diffs working tree vs index.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn repo_diff_file(
    handle: ResourceArc<RepoHandle>,
    path: String,
    staged: bool,
) -> NifResult<String> {
    let repo = handle.repo.lock().map_err(|_| {
        rustler::Error::Term(Box::new(KanniError::LockPoisoned))
    })?;

    let mut opts = DiffOptions::new();
    opts.pathspec(&path);

    let diff = if staged {
        // Staged: diff between HEAD and index
        let head_tree = repo
            .head()
            .ok()
            .and_then(|h| h.peel_to_tree().ok());

        repo.diff_tree_to_index(head_tree.as_ref(), None, Some(&mut opts))
    } else {
        // Unstaged: diff between index and working directory
        repo.diff_index_to_workdir(None, Some(&mut opts))
    };

    let diff = diff.map_err(|e| {
        rustler::Error::Term(Box::new(KanniError::from(e)))
    })?;

    let mut result = DiffResult {
        path: path.clone(),
        hunks: Vec::new(),
    };

    diff.print(git2::DiffFormat::Patch, |_delta, hunk, line| {
        let origin = match line.origin() {
            '+' => "+",
            '-' => "-",
            ' ' => " ",
            _ => return true, // Skip file headers etc.
        };

        let content = String::from_utf8_lossy(line.content())
            .trim_end_matches('\n')
            .trim_end_matches('\r')
            .to_string();

        if let Some(hunk_header) = hunk {
            let header = format!(
                "@@ -{},{} +{},{} @@",
                hunk_header.old_start(),
                hunk_header.old_lines(),
                hunk_header.new_start(),
                hunk_header.new_lines()
            );

            // Find or create the hunk
            let needs_new = result.hunks.last().map_or(true, |h| h.header != header);
            if needs_new {
                result.hunks.push(Hunk {
                    header,
                    old_start: hunk_header.old_start(),
                    old_lines: hunk_header.old_lines(),
                    new_start: hunk_header.new_start(),
                    new_lines: hunk_header.new_lines(),
                    lines: Vec::new(),
                });
            }

            if let Some(current_hunk) = result.hunks.last_mut() {
                current_hunk.lines.push(DiffLine {
                    origin: origin.to_string(),
                    content,
                    old_lineno: line.old_lineno(),
                    new_lineno: line.new_lineno(),
                });
            }
        }

        true
    })
    .map_err(|e| {
        rustler::Error::Term(Box::new(KanniError::from(e)))
    })?;

    serde_json::to_string(&result).map_err(|e| {
        rustler::Error::Term(Box::new(format!("json: {}", e)))
    })
}

/// Get diff for an untracked file (show full content as additions).
#[rustler::nif(schedule = "DirtyCpu")]
pub fn repo_diff_untracked(
    handle: ResourceArc<RepoHandle>,
    path: String,
) -> NifResult<String> {
    let repo = handle.repo.lock().map_err(|_| {
        rustler::Error::Term(Box::new(KanniError::LockPoisoned))
    })?;

    let workdir = repo.workdir().ok_or_else(|| {
        rustler::Error::Term(Box::new("bare repository"))
    })?;

    let full_path = workdir.join(&path);
    let content = std::fs::read_to_string(&full_path).unwrap_or_default();

    let lines: Vec<DiffLine> = content
        .lines()
        .enumerate()
        .map(|(i, line)| DiffLine {
            origin: "+".to_string(),
            content: line.to_string(),
            old_lineno: None,
            new_lineno: Some(i as u32 + 1),
        })
        .collect();

    let total_lines = lines.len() as u32;

    let result = DiffResult {
        path,
        hunks: vec![Hunk {
            header: format!("@@ -0,0 +1,{} @@", total_lines),
            old_start: 0,
            old_lines: 0,
            new_start: 1,
            new_lines: total_lines,
            lines,
        }],
    };

    serde_json::to_string(&result).map_err(|e| {
        rustler::Error::Term(Box::new(format!("json: {}", e)))
    })
}
