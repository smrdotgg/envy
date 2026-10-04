#!/usr/bin/env python3
"""Drive age and envy terminal prompts; responses arrive on stdin, never in argv.

Usage: python3 tests/pty-helper.py [--timeout SECONDS] -- age ... < responses
Supply one response per line, including a confirmation for encryption.
Child terminal output is deliberately withheld to avoid logging secrets.
--transcript records output in a private fixture file for terminal assertions.
Only the test harness depends on Python; envy has no Python dependency.
"""

import argparse
import errno
import os
import pty
import re
import select
import signal
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--transcript")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command or args.timeout <= 0:
        parser.error("a command and a positive timeout are required")
    responses = iter(sys.stdin.buffer.read().splitlines())
    transcript = None
    if args.transcript:
        transcript = os.fdopen(
            os.open(args.transcript, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb"
        )
    pid, terminal = pty.fork()
    if pid == 0:
        try:
            os.execvp(command[0], command)
        except OSError:
            os._exit(127)

    # age 1.0, SSH and installer prompts; no platform-specific script flags.
    prompt = re.compile(
        rb"(?:Enter(?: same)?|Confirm) passphrase[^\r\n]*?: |Secret value: "
        rb"|Install age with (?:brew|apt-get)\? \[y/N\]: "
    )
    pending = b""
    deadline = time.monotonic() + args.timeout
    reaped = False
    try:
        while True:
            ended, status = os.waitpid(pid, os.WNOHANG)
            if ended:
                reaped = True
                # Drain the final output so transcript assertions cover the whole command.
                if transcript is not None:
                    while select.select([terminal], [], [], 0)[0]:
                        try:
                            output = os.read(terminal, 4096)
                        except OSError as error:
                            if error.errno != errno.EIO:
                                raise
                            break
                        if not output:
                            break
                        transcript.write(output)
                if os.WIFEXITED(status):
                    return os.WEXITSTATUS(status)
                return 128 + os.WTERMSIG(status)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                print("pty: command timed out", file=sys.stderr)
                return 1
            readable, _, _ = select.select([terminal], [], [], min(remaining, 0.1))
            if not readable:
                continue
            try:
                output = os.read(terminal, 4096)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                output = b""
            if not output:
                # A closed terminal can precede waitpid reporting process exit.
                time.sleep(min(remaining, 0.01))
                continue
            if transcript is not None:
                transcript.write(output)
            pending += output
            while True:
                match = prompt.search(pending)
                if match is None:
                    pending = pending[-4096:]
                    break
                pending = pending[match.end():]
                response = next(responses, None)
                if response is None:
                    print("pty: no response supplied for terminal prompt", file=sys.stderr)
                    return 1
                os.write(terminal, response + b"\n")
    finally:
        if not reaped:
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
        os.close(terminal)
        if transcript is not None:
            transcript.close()


if __name__ == "__main__":
    sys.exit(main())
