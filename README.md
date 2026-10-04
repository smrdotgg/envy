# envy

A personal secrets manager, under development. Create or join a store in a git
repository, then set, read and list encrypted secrets:

```sh
./envy init /path/to/store.git
./envy set API_TOKEN
./envy get API_TOKEN
./envy ls
```

On an empty repository, `init` asks age to encrypt the store identity with a
passphrase; leave the prompt blank to generate one, and keep it safe. On another
machine, run `init` with the same repository URL and enter that passphrase once.
Subsequent reads need no prompt. Run `./envy unlock` to recover a missing local
identity or replace it after the store's key changes.

The local decrypted identity is stored with mode `0600` under
`${XDG_DATA_HOME:-$HOME/.local/share}/envy`, alongside the store clone. `set` reads
one line from a hidden terminal prompt, or preserves the exact bytes of piped
stdin. Values cannot be supplied as arguments. Each write creates one commit and
pushes it immediately. If another machine has pushed first, envy pulls with
rebase and retries the push once. Offline writes succeed locally with a warning;
run `sync` when the remote is available to send those commits.

```sh
./envy pull   # fetch and rebase local commits onto the remote
./envy push   # push local commits, with one pull/rebase retry
./envy sync   # pull, then push
```

These commands report whether they updated the store and fail if the remote is
unavailable. If both machines changed the same secret, envy aborts the rebase,
preserves the local commit and value, and exits with an explanation. Reconcile
the conflicting changes before retrying. Writes and sync refuse a dirty store.
Missing Git author settings are supplied in the store clone only.

Store mutations share a lock under
`${XDG_STATE_HOME:-$HOME/.local/state}/envy`; dead owners are cleared automatically.
Reads use the local store without waiting for that lock or contacting the remote.

Define a named project's central mapping with your editor, then use it from any
directory:

```sh
EDITOR=vi ./envy project edit my-project
./envy project ls
./envy project show my-project
./envy run --project my-project -- your-command arg
eval "$(./envy env --project my-project)"
./envy project rm my-project
```

The mapping accepts `ALIAS=SECRET_NAME` and bare `SECRET_NAME` lines. Aliases use
letters, digits and underscores, starting with a letter or underscore; prefixes
`ENVY_` and `_ENVY_` are reserved. Secret names use uppercase letters, digits and
underscores, starting with a letter or underscore. Project names follow
`[a-z0-9][a-z0-9._-]*`. Blank lines and comments starting with `#` are ignored.
Whitespace around assignments and inline comments are errors. The last assignment
to an alias wins.

Project edits validate the entire mapping before saving, committing and pushing.
Invalid edits leave the previous mapping intact. Syntax errors and missing secrets
report the file, line and key; `run` launches nothing and `env` emits nothing.
Exports preserve quotes and embedded newlines, stripping trailing newlines when
converting secret values into environment variables. `run` returns the command's
exit status. Project removal leaves its secrets in the store. Literal values,
global mappings and automatic project selection are planned for later slices.

For command help and version information:

```sh
./envy version
./envy help
```

Run the development checks with `shellcheck -s sh envy` (also include
`install.sh` when present), then `dash tests/run.sh`.
Tests need git, age and age-keygen, dash, and Python 3. Python is used only by
the test harness to answer real age passphrase prompts through a controlling
pseudo-terminal. Responses are supplied on stdin and terminal output is hidden;
the helper times out instead of waiting indefinitely.

To run selected tests:

```sh
dash tests/run.sh tests/age-pty.test.sh
```

Each test gets a temporary home, XDG directories, working directory, and local
bare git remote exposed as `TEST_REMOTE`. The runner clears inherited git
identities and `GH_TOKEN`. Tests can use `tests/fixtures.sh` for assertions and
additional local remotes; they exercise envy only through its command line.
CI runs the gate on Ubuntu and macOS. The tool is licensed under MIT.
