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
    parser.add_argument("--server", default=None, metavar="URL",
                        help="Connect to a Nexus orchestrator server (e.g. http://localhost:9090)")
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

    # Connect to Nexus server if --server was provided
    api_client = None
    if args.server:
        from .api_client import NexusApiClient
        api_client = NexusApiClient(base_url=args.server)
        # Quick health check in background
        import threading
        def _check_connection():
            try:
                health = api_client.health()
                logger = logging.getLogger(__name__)
                if health.get("status") == "ok":
                    logger.info("Connected to Nexus server at %s", args.server)
                else:
                    logger.warning("Server %s returned: %s", args.server, health)
            except Exception as exc:
                logger = logging.getLogger(__name__)
                logger.warning("Could not connect to server %s: %s", args.server, exc)
        threading.Thread(target=_check_connection, daemon=True).start()

    root = ctk.CTk()
    app = NexusDesktopApp(root, service, start_hidden=args.hidden,
                          api_client=api_client)
    try:
        root.mainloop()
    finally:
        service.stop()


if __name__ == "__main__":
    main()
