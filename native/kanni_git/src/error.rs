use rustler::{Encoder, Env, Term};
use std::fmt;

/// Unified error type for all kanni_git NIF operations.
#[derive(Debug)]
pub enum KanniError {
    Git(git2::Error),
    InvalidHandle,
    LockPoisoned,
}

impl fmt::Display for KanniError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            KanniError::Git(e) => write!(f, "git: {}", e),
            KanniError::InvalidHandle => write!(f, "invalid repository handle"),
            KanniError::LockPoisoned => write!(f, "repository lock poisoned"),
        }
    }
}

impl From<git2::Error> for KanniError {
    fn from(e: git2::Error) -> Self {
        KanniError::Git(e)
    }
}

impl Encoder for KanniError {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        format!("{}", self).encode(env)
    }
}
