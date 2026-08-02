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
        node_id = getattr(node, "id", node.get("id", "unknown")) if hasattr(node, "id") else node.get("id", "unknown")
        name = getattr(node, "name", node.get("name", "unknown")) if hasattr(node, "name") else node.get("name", "unknown")

        self.devices[node_id] = {
            "id": node_id,
            "name": name,
            "address": getattr(node, "address", node.get("address", "")) if hasattr(node, "address") else node.get("address", ""),
            "port": getattr(node, "port", node.get("port")) if hasattr(node, "port") else node.get("port"),
            "is_paired": getattr(node, "is_paired", node.get("is_paired", False)) if hasattr(node, "is_paired") else node.get("is_paired", False),
            "last_seen": getattr(node, "last_seen", node.get("last_seen", 0)) if hasattr(node, "last_seen") else node.get("last_seen", 0),
            "capabilities": node.get("capabilities", {}) if isinstance(node, dict) else {},
        }
        self._save()

    def register_with_capabilities(self, node_id: str, capabilities: dict) -> None:
        """Register/update a device with explicit capabilities."""
        self.devices[node_id] = {
            "id": node_id,
            "name": capabilities.get("hostname", node_id),
            "address": capabilities.get("address", "unknown"),
            "port": capabilities.get("port"),
            "is_paired": True,
            "last_seen": capabilities.get("last_seen", 0),
            "capabilities": capabilities,
        }
        self._save()

    def list_all(self) -> List[Dict[str, Any]]:
        return list(self.devices.values())

    def get_all_capabilities(self) -> Dict[str, Any]:
        return {
            "device_count": len(self.devices),
            "devices": [
                {
                    "id": d["id"],
                    "name": d["name"],
                    "capability_score": d.get("capabilities", {}).get("capability_score", 0),
                    "device_class": d.get("capabilities", {}).get("device_class", "unknown"),
                    "cpu_cores": d.get("capabilities", {}).get("cpu", {}).get("cores", 0),
                    "ram_mb": d.get("capabilities", {}).get("ram_mb", 0),
                    "has_gpu": bool(d.get("capabilities", {}).get("gpu", {}).get("ml_capable", False)),
                }
                for d in self.list_all()
            ],
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
