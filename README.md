# envy

A personal secrets manager, under development. This first slice provides the
command-line scaffold; secret management is not implemented yet.

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
