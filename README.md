# envy

A personal secrets manager, under development. Create a store in an empty git
repository, then set, read and list encrypted secrets:

```sh
./envy init /path/to/empty-store.git
./envy set API_TOKEN
./envy get API_TOKEN
./envy ls
```

`init` asks age to encrypt the store identity with a passphrase; leave the prompt
blank to generate one, and keep it safe. The local decrypted identity is stored
with mode `0600` under `${XDG_DATA_HOME:-$HOME/.local/share}/envy`, alongside the
store clone. `set` reads one line from a hidden terminal prompt, or preserves the
exact bytes of piped stdin. Values cannot be supplied as arguments. Each write
creates one commit and pushes it immediately. Joining existing stores and more
advanced sync are planned for later slices.

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
