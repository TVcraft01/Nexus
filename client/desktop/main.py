#!/usr/bin/env python3
"""Entry point for the Nexus Linux desktop node."""

from __future__ import annotations

import argparse
import logging
import signal
import sys
import time

import customtkinter as ctk

from .app import NexusDesktopApp
from .service import NexusService


def main() -> None:
    parser = argparse.ArgumentParser(description="Nexus Linux Desktop Node")
    parser.add_argument("--storage", default=".nexus", help="Directory for persistent state")
    parser.add_argument("--debug", action="store_true", help="Enable debug logging")
    parser.add_argument("--hidden", action="store_true", help="Start with the window hidden in the system tray")
    parser.add_argument("--headless", action="store_true", help="Run the mesh service only (no GUI)")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    service = NexusService(storage_dir=args.storage)
    service.start()

    if args.headless:
        logger = logging.getLogger(__name__)
        logger.info("Nexus desktop running in headless mode")

        def _shutdown(_signum, _frame):
            logger.info("Shutting down Nexus headless service")
            sys.exit(0)

        signal.signal(signal.SIGINT, _shutdown)
        signal.signal(signal.SIGTERM, _shutdown)
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass
        finally:
            service.stop()
        return

    root = ctk.CTk()
    app = NexusDesktopApp(root, service, start_hidden=args.hidden)
    try:
        root.mainloop()
    finally:
        service.stop()


if __name__ == "__main__":
    main()
