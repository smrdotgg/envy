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
./envy link my-project  # run inside the project's checkout
./envy run -- your-command arg
./envy env
./envy unlink
EDITOR=vi ./envy project edit --global
./envy project show --global
./envy run -- your-command arg
./envy check
```

The mapping accepts `ALIAS=SECRET_NAME`, bare `SECRET_NAME`, and
`ALIAS=__literal__("text")` lines. Literal text has no escapes or interpolation
and cannot contain a double quote. Literals and mappings are plaintext in the
store. Aliases use
letters, digits and underscores, starting with a letter or underscore; prefixes
`ENVY_` and `_ENVY_` are reserved. Secret names use uppercase letters, digits and
underscores, starting with a letter or underscore. Project names follow
`[a-z0-9][a-z0-9._-]*`. Blank lines and comments starting with `#` are ignored.
Whitespace around assignments and inline comments are errors. Global mappings
apply to every `run` and `env`, including when no project is selected. Layers
are read in order: global, the selected central project, then the approved
in-project `.envy`. The last assignment to an alias wins, including repeated
aliases within a file.

`link [name]` associates the checkout's `origin` with a central project, creating
an empty mapping if needed. The name defaults to the checkout directory name.
Remote links are committed and pushed. SSH, SCP-style and HTTPS URLs match after
removing the scheme, user, port, trailing slash and `.git`, and ignoring case.
Matching uses the configured `origin` URL, independent of Git's `insteadOf`
transport rewrites on a machine.
A remote can belong to only one project. Other clones and git worktrees match
automatically, including from subdirectories; reads use only the cached store.
Without `--project`, `run` and `env` select this matched project. An unlinked
directory receives the global layer and its approved `.envy`, if present.

If a push retry brings in a competing link from another machine, envy refuses
to push duplicate remote ownership and keeps the local commits for recovery.
Remove the conflicting project with `project rm <name>` before syncing again.

With no `origin`, or with `link --local [name]`, the association is recorded in
`${XDG_STATE_HOME:-$HOME/.local/state}/envy/links` and never synced. A newly
created central project is still committed and pushed. Local links use physical
absolute paths, take priority over remote matches, and apply to subdirectories
of non-git directories too. Local link paths cannot contain newlines. `unlink`
removes the local association first, if present; otherwise it removes the
current `origin` from the central project's remotes and commits and pushes.
Removing a remote association affects every matching clone and worktree, and
preserves the project's mapping. If a local override covered a remote match,
removing that override reveals the remote project again.

A project can carry a `.envy` mapping at its root, using the same grammar. Run
`envy allow` from that project or a subdirectory to review its aliases and secret
names and approve it on this machine. The review includes overwritten requests
and identifies literals without printing values. Approval records the physical
absolute path and Git object hash in
`${XDG_STATE_HOME:-$HOME/.local/state}/envy/allowed`; it never changes the store.
Any change to the file requires approval again. An unapproved or changed `.envy`
blocks all layers: `env` emits no exports and `run` starts no command, with a
message directing you to `envy allow`. Clones, worktrees and other machines need
their own approval.

The root is the Git checkout's top level; nested `.envy` files do not create
subdirectory projects. Outside Git, the nearest ancestor with a `.envy` or a
local link is the root. A `.envy` works without a central project or link.
`--project` selects the central layer explicitly; the current root's `.envy`
still applies and requires approval. Approval paths cannot contain newlines.

Project edits validate the entire mapping before saving, committing and pushing.
Invalid edits leave the previous mapping intact. Syntax errors and missing secrets
report the file, line and key; `run` launches nothing and `env` emits nothing.
Exports preserve quotes and all newlines, including trailing newlines. `run`
returns the command's exit status. Project removal leaves its secrets in the store.
`check` validates the global mapping, every central project mapping and the
current root's `.envy`, even before approval. It reports all errors with their
file and line and exits non-zero on errors. It also reports
remotes listed under more than one project and lists unreferenced secrets as
information, without decrypting them.

Evaluate the ambient hook by hand in bash or zsh:

```sh
eval "$(envy hook)"
```

At the next prompt, entering a project loads its layered environment. Leaving
restores pre-existing values and unsets other managed variables; moving to
another project swaps the environment. Global mappings apply outside projects
too. Loads, unloads and errors each print one line to stderr. A mapping, approval
or decryption error unloads the previous environment and loads nothing.

The hook checks again after changing directory or invoking `envy`, while
transitions between subdirectories of the same project skip decryption when
the mapping and store revision are unchanged. It preserves the previous
command's exit status and registering it twice is harmless. Startup-file
installation, ambient settings and background refresh are planned slices.

For command help and version information:

```sh
./envy version
./envy help
```

Run the development checks with `shellcheck -s sh envy` (also include
`install.sh` when present), then `dash tests/run.sh`.
Tests need git, age and age-keygen, dash, bash, zsh, and Python 3. Python is used
only by the test harness to answer real age passphrase prompts through a controlling
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
