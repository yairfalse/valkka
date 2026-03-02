mod error;
mod handle;
mod repo;
mod status;

use handle::RepoHandle;

rustler::init!("Elixir.Kanni.Git.Native", load = load);

fn load(env: rustler::Env, _info: rustler::Term) -> bool {
    rustler::resource!(RepoHandle, env);
    true
}
