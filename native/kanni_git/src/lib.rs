mod actions;
mod branch;
mod diff;
mod error;
mod handle;
mod repo;
mod scan;
mod status;

use handle::RepoHandle;

rustler::init!("Elixir.Kanni.Git.Native", load = load);

#[allow(non_local_definitions, unused_must_use)]
fn load(env: rustler::Env, _info: rustler::Term) -> bool {
    rustler::resource!(RepoHandle, env);
    true
}
