"""Utility helpers for the Linux desktop node."""

from __future__ import annotations

import socket


def get_local_ip() -> str:
    """Return the local IP used for the default route, falling back to loopback."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(1)
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
