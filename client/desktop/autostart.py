"""Linux desktop autostart helper for the Nexus desktop node."""

from __future__ import annotations

import logging
import os
import sys
from contextlib import contextmanager

logger = logging.getLogger(__name__)

_AUTOSTART_DIR = os.path.expanduser("~/.config/autostart")
_DESKTOP_FILE = os.path.join(_AUTOSTART_DIR, "nexus.desktop")


def _desktop_file_path() -> str:
    return _DESKTOP_FILE


@contextmanager
def _temp_path(path: str):
    """Internal helper for tests to redirect the .desktop file path."""
    global _DESKTOP_FILE
    original = _DESKTOP_FILE
    _DESKTOP_FILE = path
    try:
        yield
    finally:
        _DESKTOP_FILE = original


def _nexus_main_path() -> str:
    """Return the absolute path to the main entry point."""
    # Prefer the installed module so the launcher works even if cwd changes.
    import nexus.main as _main_module

    return os.path.abspath(_main_module.__file__)


def is_enabled() -> bool:
    """Return True if the Nexus autostart .desktop file exists."""
    return os.path.exists(_desktop_file_path())


def enable() -> bool:
    """Create the autostart .desktop file. Returns True on success."""
    try:
        os.makedirs(_AUTOSTART_DIR, exist_ok=True)
        main_path = _nexus_main_path()
        # Write the .desktop file using the same Python interpreter.
        content = (
            "[Desktop Entry]\n"
            "Type=Application\n"
            "Name=Nexus Node\n"
            "Comment=Nexus Linux Desktop Node\n"
            f"Exec={sys.executable} {main_path} --hidden\n"
            "Terminal=false\n"
            "X-GNOME-Autostart-enabled=true\n"
        )
        with open(_desktop_file_path(), "w", encoding="utf-8") as f:
            f.write(content)
        logger.info("Autostart enabled at %s", _desktop_file_path())
        return True
    except Exception as exc:
        logger.exception("Failed to enable autostart: %s", exc)
        return False


def disable() -> bool:
    """Remove the autostart .desktop file. Returns True on success."""
    try:
        if os.path.exists(_desktop_file_path()):
            os.remove(_desktop_file_path())
            logger.info("Autostart disabled: removed %s", _desktop_file_path())
        return True
    except Exception as exc:
        logger.exception("Failed to disable autostart: %s", exc)
        return False
