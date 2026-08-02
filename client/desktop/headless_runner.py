#!/usr/bin/env python3
"""Start the Nexus desktop node in headless mode and exit immediately."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


def main() -> None:
    project_root = Path(__file__).resolve().parents[1]
    env = os.environ.copy()
    env["PYTHONPATH"] = str(project_root)

    log_path = Path("/tmp/nexus_headless.log")
    log_path.write_text("", encoding="utf-8")

    log_file = open(log_path, "w", encoding="utf-8")
    process = subprocess.Popen(
        [sys.executable, "-u", "-m", "nexus.main", "--headless", "--debug"],
        cwd=str(project_root),
        env=env,
        stdout=log_file,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )
    # Detach from the log file handle; the service now owns it.
    log_file.close()

    pid_path = Path("/tmp/nexus_headless.pid")
    pid_path.write_text(str(process.pid), encoding="utf-8")
    print(process.pid)


if __name__ == "__main__":
    main()
