#!/usr/bin/env python3
"""Run one proof-runner phase in a bounded process group."""

from __future__ import annotations

import json
import math
import os
import resource
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import NoReturn

OUTPUT_LIMIT = 1_048_576
TERM_GRACE_SECONDS = 5

def monotonic_now() -> float:
    clock = getattr(time, "CLOCK_MONOTONIC_RAW", time.CLOCK_MONOTONIC)
    return time.clock_gettime(clock)


def fail(message: str) -> NoReturn:
    print(f"run-proof-command: {message}", file=sys.stderr)
    raise SystemExit(2)


def write_status(path: Path, *, exit_code: int, timed_out: bool) -> None:
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(
                {"exit_code": exit_code, "timed_out": timed_out},
                handle,
                separators=(",", ":"),
            )
            handle.write("\n")
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def limit_output() -> None:
    resource.setrlimit(resource.RLIMIT_FSIZE, (OUTPUT_LIMIT, OUTPUT_LIMIT))


def signal_group(group: int, sig: signal.Signals) -> bool:
    try:
        os.killpg(group, sig)
    except ProcessLookupError:
        return False
    return True

def group_has_live_members(group: int) -> bool:
    result = subprocess.run(
        ["ps", "-axo", "pgid=,stat="],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=1,
    )
    if result.returncode != 0:
        fail("cannot inspect runner process group")
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[0].isdigit():
            if int(fields[0]) == group and not fields[1].startswith("Z"):
                return True
    return False


def kill_remaining_group(group: int) -> None:
    if not signal_group(group, signal.SIGKILL):
        return
    deadline = monotonic_now() + TERM_GRACE_SECONDS
    while group_has_live_members(group):
        if monotonic_now() >= deadline:
            fail(f"runner process group {group} did not terminate")
        time.sleep(0.01)


def stop_group(process: subprocess.Popen[bytes]) -> None:
    signal_group(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=TERM_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        pass
    kill_remaining_group(process.pid)
    if process.poll() is None:
        process.wait()

def main() -> int:
    if len(sys.argv) < 7 or sys.argv[5] != "--":
        fail(
            "usage: run-proof-command.py <status.json> <deadline-monotonic> "
            "<stdout> <stderr> -- <command> [args...]"
        )

    status_path = Path(sys.argv[1])
    stdout_path = Path(sys.argv[3])
    stderr_path = Path(sys.argv[4])
    try:
        deadline = float(sys.argv[2])
    except ValueError:
        fail("deadline must be numeric")
    if not math.isfinite(deadline) or deadline <= 0:
        fail("deadline must be positive and finite")

    command = sys.argv[6:]
    status_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    stdout_fd = os.open(stdout_path, flags, 0o600)
    try:
        stderr_fd = os.open(stderr_path, flags, 0o600)
    except BaseException:
        os.close(stdout_fd)
        raise

    timeout = deadline - monotonic_now()
    if timeout <= 0:
        os.close(stdout_fd)
        os.close(stderr_fd)
        write_status(status_path, exit_code=124, timed_out=True)
        return 0

    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=stdout_fd,
            stderr=stderr_fd,
            start_new_session=True,
            preexec_fn=limit_output,
        )
    finally:
        os.close(stdout_fd)
        os.close(stderr_fd)

    timed_out = False
    try:
        return_code = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        stop_group(process)
        return_code = process.returncode
    else:
        kill_remaining_group(process.pid)

    exit_code = return_code if return_code >= 0 else 128 - return_code
    write_status(status_path, exit_code=exit_code, timed_out=timed_out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
