# envy

A personal secrets manager, under development. Create or join a store in a git
repository with one command:

```sh
curl -fsSL https://raw.githubusercontent.com/smrdotgg/envy/main/install.sh | sh -s -- <store-url>
```

## Threat model

The local age identity is unencrypted at rest. Its owner-only permissions do
not stop another process running as your user from reading it and decrypting
every secret. This is the same exposure as a cached cloud login.

A leaked store repository is as strong as its passphrase: someone with a copy
can try to crack the passphrase protecting the stored identity. Use a strong
passphrase and keep it safe. Write access to the store repository alone cannot
read encrypted secret values, but it can change mappings, including which
secrets a project receives. Treat store writers as trusted.

Secret names, project names, remotes and mapping files, including literal
values, are plaintext in the store. Only secret values and the identity
protected by the passphrase are encrypted; do not put secrets in mapping literals.

Ambient mode hands a project's secrets to every process started in that shell,
including coding agents. To control when they are supplied, use
`envy config ambient off` for the machine or export `ENVY_AMBIENT=0` for one
shell, then use `envy run -- your-command arg` to supply them to a chosen
command and its child processes. Ambient changes unload managed variables at
the next prompt; they cannot remove copies already inherited by running
processes. These controls do not prevent same-user access to the local identity.

Narrowly scoped per-project tokens are the real mitigation: limit each token
to the resources and actions its project needs so a leaked token has limited
reach. `envy uninstall` does not remove variables from shells that are already
running; close those shells to discard their environments.

## Installation and use

The installer puts `envy` in `~/.local/bin`, adds a marked block to `~/.bashrc`
and `~/.zshrc` for each available shell, and runs `envy init` with the store URL.
Open a new interactive bash or zsh shell to use ambient loading. Each block
adds the install directory to `PATH` if needed and evaluates `envy hook`, while
preserving existing startup content. Bash login shells must already source
`.bashrc` from their login startup file; zsh is the expected shell on macOS.

Git must already be installed. If age or age-keygen is missing, the installer
asks once and installs age with Homebrew, or apt-get (using sudo when needed).
Declining stops with manual installation instructions. Confirmations read from
the terminal, so piping the installer works. Pass `--yes` to skip confirmations;
age still requires the store passphrase when creating or joining a store.
Re-running with the same URL preserves a configured machine without prompting
again. A different URL is refused, and a missing or mismatched identity directs
you to `envy unlock`. With no URL, installation stops before store initialization.

For an offline installation from a checkout, use a local source:

```sh
ENVY_INSTALL_SOURCE="$PWD/envy" sh ./install.sh --yes /path/to/store.git
```

`ENVY_INSTALL_SOURCE` also accepts a download URL; it defaults to this repository's
`main/envy`. Downloads are checked with `sh -n` before atomic replacement.

Run `envy doctor` to diagnose the machine. It prints a `PASS` or `FAIL` line
for dependency versions (age and age-keygen require 1.0 or newer), store format,
identity match, store cleanliness, remote reachability, installed startup blocks,
the executable on `PATH`, and ownership and permissions. Any failure returns a
non-zero status, while the remaining checks still run. The remote check uses
`git ls-remote` with authentication prompts disabled; it never fetches, pushes
or decrypts secrets. Local data, store, state and settings directories should
be owner-only (`0700`), with identity and settings files at `0600`. The executable
and startup files must belong to the current user and cannot be writable by
group or other users. Startup symlinks are checked through their targets.

`envy self-update` downloads the `envy` asset from the latest tagged GitHub
release, validates its shell syntax, shebang, version metadata, core functions
and command dispatcher, and atomically replaces the invoked executable. It
reports the old and new versions. An empty,
failed or corrupt download leaves the current version intact. Curl is needed
for downloads; `ENVY_UPDATE_SOURCE` accepts a URL or local release script for
offline use. For example:

```sh
ENVY_UPDATE_SOURCE=/path/to/released-envy envy self-update
```

The installer and updater trust this public repository and apply the same
static sanity check before replacement. Validation guards against wrong or
corrupt downloads; it does not authenticate the source, and the candidate is
never executed during validation. Releases must include an `envy` asset with
the script's `ENVY_VERSION` metadata and program structure. Invoke the actual
executable path when updating or uninstalling; a final executable symlink is
refused so it cannot be replaced accidentally.

`envy uninstall` removes the marked envy blocks from `.bashrc` and `.zshrc`
and removes the invoked executable. It preserves other startup content and
startup symlinks. It asks through the terminal before deleting the local identity
and store clone; declining or running without a terminal retains both. Piped
stdin never supplies deletion consent. Settings, trust approvals and local links
are retained. The remote store is always untouched. Damaged startup markers
must be repaired before uninstalling so unrelated content cannot be removed.

Then set, read and list encrypted secrets, or use the script from a checkout:

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

Use `./envy edit NAME` to edit a secret's current value or create a missing
secret. It opens `$EDITOR`, falling back to `vi`; editor options are supported.
Multi-line values and trailing newlines are preserved exactly. Changed values
are encrypted, committed and pushed; leaving an existing value unchanged makes
no commit. Plaintext and editor backups stay in an owner-only temporary
directory that is removed on exit, including interrupts and editor failures.
An editor failure leaves the stored secret unchanged. Saving a changed value
also clears that secret's pending rotation mark.

Run `./envy rekey` after losing a machine to replace the shared identity and
protect it with a new passphrase (leave age's prompt blank to generate one).
Rekey requires a successful pull, re-encrypts every current secret, and pushes
one commit. Keep the new passphrase safe. Other machines must pull, then run
`envy unlock` and enter it once; until then commands refuse the mismatched key
and the hook prints a one-line notice without prompting.

Rekey prints every secret name and records them in `rotation-pending`.
Rotate each credential at its provider, then save the replacement with `set`
or `edit` to clear its mark. `status` reports how many remain. Removal clears
the mark; rename carries it to the new name. Rekey does not revoke credentials
or protect old values in Git history: the old identity can still decrypt them.
Failures before the rekey commit restore the pulled store and local identity.
A failed push retains the new local key and commit. Sync refuses divergent
histories that use different keys; reconcile those histories before syncing
so old-key writes cannot silently become unreadable.

Remove or rename a secret with:

```sh
./envy rm UNUSED_TOKEN
./envy rm --force REFERENCED_TOKEN
./envy mv OLD_TOKEN NEW_TOKEN
```

`rm` refuses references in the global mapping or any central project mapping,
listing each file, line and alias, including overridden assignments. `--force`
removes the secret anyway and leaves those mappings for you to repair. In-project
`.envy` files are outside this reference check.

`mv` keeps the encrypted value and rewrites every central reference in the same
commit, preserving exported aliases: a bare `OLD_TOKEN` becomes
`OLD_TOKEN=NEW_TOKEN`. Comments, literals and references to other secrets stay
unchanged. The destination must be a valid, unused secret name. Rename warns
that in-project `.envy` files are not updated; update them and approve them again
on each machine. Rename and ordinary removal validate central mappings before
changing the store; repair invalid mappings first or use force removal.

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
Reads use the local store without waiting for that lock or contacting the remote
in the foreground.

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
Exports preserve quotes and all newlines, including trailing newlines, and
non-UTF-8 bytes. Binary values containing NUL bytes are available through `get`
only: `set` and `get` preserve them exactly, but `env`, `run` and the ambient hook
reject their mappings with a diagnostic naming the secret and load nothing.
Environment variables cannot contain NUL bytes. `run`
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
restores pre-existing values and their export state and unsets other managed
variables. Integer, array and readonly attributes are not restored; a readonly
alias can prevent loading. Moving to another project swaps the environment.
Global mappings apply outside projects
too. Loads, unloads and errors each print one line to stderr. A mapping, approval
or decryption error unloads the previous environment and loads nothing.

The hook checks again after changing directory or invoking `envy`, while
transitions between subdirectories of the same project skip decryption when
the mapping and store revision are unchanged. It preserves the previous
command's exit status and registering it twice is harmless. The installer adds
the hook to the startup files of available bash and zsh shells.

`envy config` shows machine-local settings. Ambient loading defaults to on;
`envy config ambient off` unloads managed variables at the next prompt and
keeps ambient loading off. `envy config ambient on` enables it again. Explicit
`envy run` and `envy env` work with either setting. Export `ENVY_AMBIENT=0` or
`ENVY_AMBIENT=1` to override the setting for one shell; changing the override
takes effect at the next prompt, and unsetting it returns to the machine setting.

`envy config quiet on` silences load and unload notices while keeping errors
visible; `envy config quiet off` restores notices. Settings are stored in
`${XDG_CONFIG_HOME:-$HOME/.config}/envy/config` and never synced with the store.

The hook and `envy run` refresh a stale store in the background without waiting
for the remote or the store lock. The refresh is silent, disables authentication
prompts, uses the same lock as writes, and makes fetched changes available on
the next directory change or environment command. A command already running
keeps its original environment.
Other reads, including `env`, `get` and `ls`, use only the local store.

`envy config sync_interval <seconds>` changes the interval (default: 14400,
four hours); zero requests a refresh on every hook evaluation or `run`.
Successful clones and fetches record their time in
`${XDG_STATE_HOME:-$HOME/.local/state}/envy/last-fetch`. An unreachable remote
leaves that timestamp and the cached environment available for the next retry.

Run `envy status` to inspect the current directory using the initialized local
store. It shows the physical project root and whether it matched by remote,
local link, an in-project file alone, or no project. Each mapping layer is
reported as present, absent, unapproved or invalid. For usable layers, each
alias points to its winning mapping file and line, marked as secret or literal;
neither kind prints its value. Blocked layers produce no alias table.

Status also shows the effective ambient setting and machine setting, quiet mode,
local identity match, pending-rotation count, cached ahead/behind counts and the
last successful fetch time in epoch seconds, with cache freshness and the configured interval.
Ahead/behind compare against the cached upstream, so unseen remote changes
require a later sync to appear. Missing upstream information is shown as unknown.
Status never fetches, decrypts values or waits for the store lock, even when
the cache is stale. It works outside projects and reports mapping, approval and
identity problems without hiding the other state; those problems return a
non-zero exit status. Invalid mappings include file, line and key diagnostics.

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

## Release checklist

1. Bump `ENVY_VERSION` in `envy` to the release version (for example, `0.1.0`).
2. Merge the reviewed changes to `main`.
3. Tag that commit with the matching `v` prefix (for example, `v0.1.0`) and
   push the tag. The release workflow runs the full gate on Ubuntu and macOS,
   refuses a version mismatch or failed gate, and publishes the unchanged
   `envy` and `install.sh` files as release assets.
4. Confirm the README installer one-liner works against a disposable store,
   then run `envy self-update` and confirm `envy version` reports the release.

Before tagging, push a branch named `release-dry-run/<anything>` to exercise
the whole workflow except publication, even before it reaches `main`.
Dry runs use `v` plus the script's current version as the prospective tag.
Both operating systems upload `release-assets-<os>` workflow artifacts
containing `envy` and `install.sh`; the final job checks their bytes against
the commit. The first merge, tag and public-download verification belong to
release acceptance (#19).
