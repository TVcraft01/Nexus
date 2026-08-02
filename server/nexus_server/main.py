# Nexus Server - Main Entry Point
#
# This is the central entry point for the Nexus server.
# It initializes all services and provides the API for clients.

from __future__ import annotations

import argparse
import logging
import signal
import sys
import time

from nexus_server.orchestrator import NexusOrchestrator
from nexus_server.storage import configure_storage

logger = logging.getLogger("nexus.server")


def main() -> None:
    parser = argparse.ArgumentParser(description="Nexus Server - Universal AI Orchestrator")
    parser.add_argument("--storage", default=".nexus", help="Storage directory")
    parser.add_argument("--debug", action="store_true", help="Debug logging")
    parser.add_argument("--headless", action="store_true", help="Run without GUI")
    parser.add_argument("--port", type=int, default=9090, help="API port")
    parser.add_argument("--no-mesh", action="store_true", help="Disable mesh networking")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    logger.info("Nexus Server v0.3.0 starting...")

    # Configure local storage
    configure_storage(args.storage)

    # Initialize master orchestrator
    orchestrator = NexusOrchestrator(storage_dir=args.storage)

    # Start core services
    orchestrator.start(
        enable_mesh=not args.no_mesh,
        api_port=args.port,
    )

    if args.headless:
        logger.info("Nexus server running in headless mode. Press Ctrl+C to stop.")
        signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass
        finally:
            orchestrator.stop()
        return

    # Start GUI (if available)
    try:
        from nexus_server.gui import launch_gui
        launch_gui(orchestrator, start_hidden=False)
    except ImportError:
        logger.info("GUI not available, running headless. Press Ctrl+C to stop.")
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass
        finally:
            orchestrator.stop()


if __name__ == "__main__":
    main()
