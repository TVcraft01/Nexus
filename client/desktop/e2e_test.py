#!/usr/bin/env python3
"""End-to-end phone-to-desktop pairing and command relay smoke test.

Assumptions:
- A release APK is installed on the phone.
- The phone is connected via adb and on the same LAN as the desktop.
- The Android app auto-starts its mesh service (MainActivity calls startMeshService).
- The Android app has a TestPairingReceiver that responds to TEST_PAIR broadcasts.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

# Allow running from the repo root or the desktop directory.
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from nexus.service import NexusService
from nexus.models import MeshNode

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("e2e_test")


class E2ETest:
    def __init__(self) -> None:
        self.service = NexusService(storage_dir=".nexus_e2e")
        self.desktop_node_id: str = self.service.node_id
        self.phone_node: Optional[MeshNode] = None

    def start_desktop(self) -> None:
        logger.info("Starting desktop service; node_id=%s", self.desktop_node_id)
        self.service.start()

    def stop_desktop(self) -> None:
        logger.info("Stopping desktop service")
        self.service.stop()

    def launch_android_app(self) -> None:
        logger.info("Launching Android app")
        subprocess.run(
            ["adb", "shell", "am", "start", "-n", "com.nexus.app/.ui.MainActivity"],
            check=True,
            capture_output=True,
            text=True,
        )

    def _is_likely_phone(self, node: MeshNode) -> bool:
        if node.id == self.desktop_node_id:
            return False
        name = node.name.lower()
        return "android" in name or "samsung" in name or node.transport.value == "WIFI_NSD"

    def wait_for_phone(self, timeout_s: float = 60.0) -> MeshNode:
        logger.info("Waiting for Android phone to be discovered via mDNS/NSD...")
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            nodes = [n for n in self.service.discovered_nodes if self._is_likely_phone(n)]
            if nodes:
                self.phone_node = nodes[0]
                logger.info("Discovered phone: %s (%s:%s)", self.phone_node.name, self.phone_node.address, self.phone_node.port)
                return self.phone_node
            time.sleep(2.0)
        raise TimeoutError("Phone was not discovered within the timeout")

    def pair(self, pin: str) -> None:
        if not self.phone_node:
            raise RuntimeError("Phone node not discovered yet")
        logger.info("Pairing desktop -> phone with PIN %s", pin)
        if not self.service.pair_with_node(self.phone_node.id, pin):
            raise RuntimeError("Desktop pairing call failed")

    def send_pairing_broadcast_to_phone(self, pin: str) -> None:
        logger.info("Sending TEST_PAIR broadcast to phone")
        result = subprocess.run(
            [
                "adb", "shell", "am", "broadcast",
                "-a", "com.nexus.app.action.TEST_PAIR",
                "--es", "peer_id", self.desktop_node_id,
                "--es", "pin", pin,
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        logger.info("Broadcast result: %s", result.stdout.strip())

    def relay_command(self, command: str) -> bool:
        if not self.phone_node:
            raise RuntimeError("Phone node not discovered yet")
        logger.info("Relaying command to phone: %s", command)
        result = self.service.relay_command(self.phone_node, command)
        if result is None:
            logger.error("Relay returned no result")
            return False
        logger.info("Relay result: success=%s, message=%s", result.success, result.message)
        return result.success

    def verify_pairing(self, timeout_s: float = 10.0) -> bool:
        logger.info("Verifying pairing state on desktop...")
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            if self.phone_node and self.service.is_paired(self.phone_node.id):
                logger.info("Desktop reports phone as paired")
                return True
            time.sleep(0.5)
        logger.error("Desktop does not report phone as paired")
        return False

    def run(self) -> bool:
        try:
            self.start_desktop()
            self.launch_android_app()
            phone = self.wait_for_phone()
            pin = "123456"  # fixed PIN for the test
            self.pair(pin)
            time.sleep(1.0)
            self.send_pairing_broadcast_to_phone(pin)
            if not self.verify_pairing(timeout_s=15.0):
                return False
            success = self.relay_command("hello")
            return success
        finally:
            self.stop_desktop()


def main() -> int:
    test = E2ETest()
    try:
        ok = test.run()
        if ok:
            logger.info("E2E test PASSED")
            return 0
        logger.error("E2E test FAILED")
        return 1
    except Exception as exc:
        logger.exception("E2E test failed with exception: %s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
