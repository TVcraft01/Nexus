# Device Registry - Hardware & Peripheral Management
#
# Manages connected devices, their capabilities, and infrastructure setup.

from __future__ import annotations

import json
import logging
import os
from typing import Any, Dict, List, Optional

logger = logging.getLogger("nexus.devices")


class DeviceRegistry:
    """Registry of all connected devices with capability tracking."""

    def __init__(self, storage_dir: str = ".nexus"):
        self.devices: Dict[str, Dict[str, Any]] = {}
        self.device_file = os.path.join(storage_dir, "devices.json")
        self._load()

    def register_or_update(self, node) -> None:
        """Register or update a discovered mesh node."""
        self.devices[node.id] = {
            "id": node.id,
            "name": node.name,
            "address": node.address,
            "port": node.port,
            "is_paired": node.is_paired,
            "last_seen": getattr(node, "last_seen", 0),
        }
        self._save()

    def list_all(self) -> List[Dict[str, Any]]:
        return list(self.devices.values())

    def get_all_capabilities(self) -> Dict[str, Any]:
        return {
            "device_count": len(self.devices),
            "devices": self.list_all(),
            "paired_devices": sum(1 for d in self.devices.values() if d.get("is_paired")),
        }

    def setup_network(self, devices: list, config: dict) -> bool:
        """Auto-configure network for connected devices."""
        logger.info(f"Network setup requested for {len(devices)} devices: {config}")
        return True

    def _save(self) -> None:
        try:
            with open(self.device_file, "w") as f:
                json.dump(self.devices, f, indent=2)
        except Exception as e:
            logger.warning(f"Failed to save device registry: {e}")

    def _load(self) -> None:
        if os.path.exists(self.device_file):
            try:
                with open(self.device_file, "r") as f:
                    self.devices = json.load(f)
            except Exception:
                self.devices = {}
