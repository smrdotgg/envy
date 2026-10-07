#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-snapshot-passphrase
throwaway-snapshot-passphrase
RESPONSES
printf 'throwaway snapshot credential\n' > "$HOME/value"
"$ENVY_BIN" set RACE_KEY < "$HOME/value"
cat > "$HOME/editor" <<'EDITOR'
#!/bin/sh
printf 'Global=RACE_KEY\n' > "$1"
EDITOR
chmod +x "$HOME/editor"
EDITOR=$HOME/editor "$ENVY_BIN" project edit --global
EDITOR=$HOME/editor "$ENVY_BIN" project edit race
"$ENVY_BIN" config quiet on

python3 - <<'PY'
import errno
import os
import pathlib
import shutil
import signal
import subprocess
import tempfile
import time

home = pathlib.Path(os.environ['HOME'])
tool = os.environ['ENVY_BIN']
app = home / 'checkout'
app.mkdir()
mapping = app / '.envy'
original = b'FromCheckout=RACE_KEY\n'
expected = (home / 'value').read_bytes()
barrier = home / 'barrier'
barrier.mkdir()
bin_dir = home / 'bin'
bin_dir.mkdir()
real_cat = shutil.which('cat')
real_git = shutil.which('git')
env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'],
           REAL_CAT=real_cat, REAL_GIT=real_git, RACE_MAPPING=str(mapping),
           RACE_BARRIER=str(barrier))
(bin_dir / 'envy').symlink_to(tool)
for command, condition, real in (
    ('cat', '[ "${1-}" = "$RACE_MAPPING" ]', 'REAL_CAT'),
    ('git', '[ "${1-}" = hash-object ] && [ "${2-}" = --stdin ] && '
            '[ "${RACE_HASH-}" = 1 ]', 'REAL_GIT'),
):
    wrapper = bin_dir / command
    wrapper.write_text('#!/bin/sh\n'
        'if [ -e "$RACE_BARRIER/armed" ] && ' + condition + '; then\n'
        '    rm -f "$RACE_BARRIER/armed"\n'
        '    printf "%s\\n" "$$" > "$RACE_BARRIER/ready"\n'
        '    IFS= read -r release < "$RACE_BARRIER/release" || exit 1\n'
        'fi\nexec "$' + real + '" "$@"\n')
    wrapper.chmod(0o700)


def reset():
    if mapping.is_dir():
        mapping.rmdir()
    elif mapping.exists() or mapping.is_symlink():
        mapping.unlink()
    mapping.write_bytes(original)
    for name in ('armed', 'ready', 'release'):
        (barrier / name).unlink(missing_ok=True)


def approve():
    subprocess.run([tool, 'allow'], cwd=app, env=env, check=True,
                   stdout=subprocess.DEVNULL, timeout=5)


def clean():
    for root, pattern in (
        (pathlib.Path(env['XDG_DATA_HOME']) / 'envy', '.env.*'),
        (pathlib.Path(env['XDG_DATA_HOME']) / 'envy', '.allow.*'),
        (pathlib.Path(env['TMPDIR']), 'envy-hook.*'),
    ):
        assert not list(root.glob(pattern)), 'snapshot left temporary files'
    assert not (pathlib.Path(env['XDG_STATE_HOME']) / 'envy/lock').exists()


def gone(group):
    # All owned children (including the watchdog's sleep) must have been reaped.
    try:
        os.killpg(group, 0)
    except ProcessLookupError:
        return
    raise AssertionError('snapshot left a background process')


def execute(args, mutate=None, hook=False, hash_barrier=False, interrupt=False):
    local_env = dict(env)
    if hash_barrier:
        local_env['RACE_HASH'] = '1'
        # Only Git pauses in this probe, after the copy has already completed.
        local_env['RACE_MAPPING'] = ''
    if mutate is not None or interrupt:
        os.mkfifo(barrier / 'release', 0o600)
        if not hook:
            (barrier / 'armed').touch()
    start = time.monotonic()
    process = subprocess.Popen(args, cwd=app, env=local_env,
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True)
    try:
        if mutate is not None or interrupt:
            deadline = start + 3
            while not (barrier / 'ready').exists():
                assert process.poll() is None, 'command missed the PATH barrier'
                assert time.monotonic() < deadline, 'PATH barrier was not reached'
                time.sleep(0.005)
            if mutate is not None:
                mutate()
            if interrupt:
                os.killpg(process.pid, signal.SIGTERM)
            else:
                while True:
                    try:
                        fd = os.open(barrier / 'release', os.O_WRONLY | os.O_NONBLOCK)
                        break
                    except OSError as error:
                        assert error.errno == errno.ENXIO
                        assert time.monotonic() < deadline, 'barrier could not release'
                        time.sleep(0.005)
                with os.fdopen(fd, 'wb') as stream:
                    stream.write(b'go\n')
        output, error = process.communicate(timeout=max(0.01, start + 3 - time.monotonic()))
        assert time.monotonic() - start < 2.5, 'mapping read did not return promptly'
        gone(process.pid)
        clean()
        assert expected.strip() not in error, 'mapping diagnostic disclosed a secret'
        return process.returncode, output, error
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=3)


def fifo():
    mapping.unlink()
    os.mkfifo(mapping, 0o600)


def refused(result):
    code, output, error = result
    assert code != 0 and not output, 'mapping refusal exported partial values'
    assert b'cannot read mapping' in error or b'mapping is not a regular file' in error
    assert len(error.splitlines()) == 1, 'mapping refusal emitted extra diagnostics'
    assert not (home / 'child-ran').exists(), 'refused run started its child'


reset()
subprocess.run([tool, 'link', '--local', 'race'], cwd=app, env=env, check=True, timeout=5)
approve()
commands = ([tool, 'env'], [tool, 'run', '--', 'sh', '-c', 'touch "$HOME/child-ran"'])

# QA's regular-to-FIFO race: pause cat after the product's regular-file check.
for command in commands:
    reset()
    refused(execute(command, fifo))

# Static faults, including permissions and symlink behaviour, remain unchanged.
for kind in ('fifo', 'directory', 'dangling', 'unreadable'):
    for command in commands:
        reset()
        if kind == 'fifo':
            fifo()
        elif kind == 'directory':
            mapping.unlink()
            mapping.mkdir()
        elif kind == 'dangling':
            mapping.unlink()
            mapping.symlink_to(home / 'absent')
        else:
            mapping.chmod(0)
        refused(execute(command))
reset()
target = home / 'regular-target'
target.write_bytes(original)
mapping.unlink()
mapping.symlink_to(target)
approve()
code, output, error = execute([tool, 'run', '--', 'sh', '-c', 'printf "%s" "$FromCheckout"'])
assert code == 0 and output == expected and not error, 'regular symlink changed behaviour'
reset()

# A different regular mapping swapped before the read cannot borrow approval.
refused_code, output, error = execute([tool, 'env'], lambda: mapping.write_bytes(b'Other=RACE_KEY\n'))
assert refused_code != 0 and not output and b'run envy allow' in error
reset()

# Swap after snapshotting, at Git's hash barrier: parse exactly the hashed bytes.
code, output, error = execute([tool, 'run', '--', 'sh', '-c',
    '[ "${Other+x}" != x ] && printf "%s" "$FromCheckout"'],
    lambda: mapping.write_bytes(b'Other=RACE_KEY\n'), hash_barrier=True)
assert code == 0 and output == expected and not error, 'hash and parser used different contents'
reset()

# A handled interruption also terminates the reader, watchdog and timer.
code, output, error = execute([tool, 'env'], interrupt=True)
assert code != 0 and not output
reset()

# Both real parent shells must unload and return the prompt on the same race.
session = '''
eval "$(envy hook)"
_envy_hook
sh -c '[ "${FromCheckout+x}${Global+x}" = xx ]' || exit 1
touch "$RACE_BARRIER/armed"
envy version > /dev/null
_envy_hook
sh -c '[ "${FromCheckout+x}${Global+x}" = "" ]' || exit 1
printf 'prompt returned\\n'
'''
for shell in ('bash', 'zsh'):
    reset()
    code, output, error = execute([shell, '-c', session], fifo, hook=True)
    assert code == 0 and output == b'prompt returned\n', 'hook retained variables or hung'
    assert b'cannot read mapping' in error and len(error.splitlines()) == 1

# Exercise real filesystem boundaries on Linux without mount privileges. The
# reader uses no hard links; Mac CI exercises the same path with its native tools.
if pathlib.Path('/dev/shm').is_dir() and os.access('/dev/shm', os.W_OK):
    with tempfile.TemporaryDirectory(prefix='envy-snapshot-', dir='/dev/shm') as other:
        data = pathlib.Path(other) / 'data'
        shutil.copytree(pathlib.Path(env['XDG_DATA_HOME']) / 'envy', data / 'envy')
        assert data.stat().st_dev != app.stat().st_dev, 'cross-filesystem fixture is ineffective'
        env['XDG_DATA_HOME'] = str(data)
        env['TMPDIR'] = other
        reset()
        approve()
        code, output, error = execute([tool, 'run', '--', 'sh', '-c', 'printf "%s" "$FromCheckout"'])
        assert code == 0 and output == expected and not error
        for command in commands:
            reset()
            refused(execute(command, fifo))
        for shell in ('bash', 'zsh'):
            reset()
            code, output, error = execute([shell, '-c', session], fifo, hook=True)
            assert code == 0 and output == b'prompt returned\n'
            assert b'cannot read mapping' in error and len(error.splitlines()) == 1
PY
