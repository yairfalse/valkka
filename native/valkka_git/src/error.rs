use rustler::{Encoder, Env, Term};
use std::fmt;

/// Unified error type for all valkka_git NIF operations.
#[derive(Debug)]
#[allow(dead_code)]
pub enum ValkkaError {
    Git(git2::Error),
    InvalidHandle,
    LockPoisoned,
}

impl fmt::Display for ValkkaError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ValkkaError::Git(e) => write!(f, "git: {}", e),
            ValkkaError::InvalidHandle => write!(f, "invalid repository handle"),
            ValkkaError::LockPoisoned => write!(f, "repository lock poisoned"),
        }
    }
}

impl From<git2::Error> for ValkkaError {
    fn from(e: git2::Error) -> Self {
        ValkkaError::Git(e)
    }
}

impl Encoder for ValkkaError {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        format!("{}", self).encode(env)
    }
}
