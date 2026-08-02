#!/usr/bin/env python3
"""Remove the Nexus desktop launcher and menu entry.

This only removes the launcher files (wrapper script, .desktop entry, and icon).
It does NOT remove your local data in ~/.nexus or ~/.local/share/nexus.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


def uninstall() -> None:
    home = Path.home()
    wrapper = home / ".local" / "bin" / "nexus"
    desktop_file = home / ".local" / "share" / "applications" / "nexus.desktop"
    app_data_dir = home / ".local" / "share" / "nexus"

    removed = False

    if wrapper.exists():
        wrapper.unlink()
        print(f"Removed {wrapper}")
        removed = True
    else:
        print(f"Wrapper not found: {wrapper}")

    if desktop_file.exists():
        desktop_file.unlink()
        print(f"Removed {desktop_file}")
        removed = True
    else:
        print(f"Menu entry not found: {desktop_file}")

    # Refresh the desktop menu database if the tool is available.
    applications_dir = desktop_file.parent
    try:
        subprocess.run(
            ["update-desktop-database", str(applications_dir)],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        pass

    if app_data_dir.exists():
        icon = app_data_dir / "nexus-icon.png"
        if icon.exists():
            icon.unlink()
            print(f"Removed {icon}")
        # Only remove the directory if it is empty; leave user data behind otherwise.
        try:
            app_data_dir.rmdir()
            print(f"Removed empty {app_data_dir}")
        except OSError:
            print(f"Kept {app_data_dir} because it still contains files (e.g., user data or runtime state)")
        removed = True

    if removed:
        print("\nNexus launcher removed.")
        print("Your data is still in ~/.nexus and ~/.local/share/nexus")
    else:
        print("\nNothing to remove.")


if __name__ == "__main__":
    uninstall()
