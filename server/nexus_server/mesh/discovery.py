# Enhanced Device Discovery with MQTT Capability Exchange
#
# Handles:
# - mDNS service discovery on local network (zeroconf)
# - MQTT-based discovery for cross-network devices
# - Capability exchange and scoring
# - Device presence/heartbeat tracking

from __future__ import annotations

import json
import logging
import os
import socket
import time
from typing import Any, Callable, Dict, List, Optional

logger = logging.getLogger("nexus.mesh.discovery")


class DeviceDiscoveryService:
    """Unified device discovery across mDNS and MQTT."""

    def __init__(
        self,
        node_id: str,
        node_name: str,
        on_device_found: Optional[Callable[[dict], None]] = None,
        on_device_lost: Optional[Callable[[str], None]] = None,
    ):
        self.node_id = node_id
        self.node_name = node_name
        self.on_device_found = on_device_found
        self.on_device_lost = on_device_lost

        # All discovered devices: node_id → info dict
        self._devices: Dict[str, dict] = {}
        self._last_seen: Dict[str, float] = {}

        # Heartbeat tracking
        self._heartbeat_timeout = 120  # seconds before device considered offline

    # ------------------------------------------------------------------
    # Device registration
    # ------------------------------------------------------------------

    def on_device_announce(self, device_info: dict) -> None:
        """Handle a device announcement from mDNS or MQTT."""
        node_id = device_info.get("node_id", "")
        if not node_id or node_id == self.node_id:
            return

        is_new = node_id not in self._devices

        self._devices[node_id] = {
            **device_info,
            "discovery_method": device_info.get("discovery_method", "mqtt"),
        }
        self._last_seen[node_id] = time.time()

        if is_new and self.on_device_found:
            self.on_device_found(self._devices[node_id])
        elif not is_new:
            logger.debug(f"Device heartbeat: {node_id}")

    def on_device_offline(self, node_id: str) -> None:
        """Handle a device going offline."""
        if node_id in self._devices:
            self._devices[node_id]["status"] = "offline"
            if self.on_device_lost:
                self.on_device_lost(node_id)

    # ------------------------------------------------------------------
    # Query methods
    # ------------------------------------------------------------------

    def get_all_devices(self) -> List[dict]:
        return list(self._devices.values())

    def get_online_devices(self) -> List[dict]:
        now = time.time()
        return [
            d for nid, d in self._devices.items()
            if d.get("status") == "online" and
            (now - self._last_seen.get(nid, 0)) < self._heartbeat_timeout
        ]

    def get_device(self, node_id: str) -> Optional[dict]:
        return self._devices.get(node_id)

    def get_devices_by_capability(self, min_ram_mb: int = 0,
                                  min_cores: int = 0,
                                  needs_gpu: bool = False) -> List[dict]:
        """Filter devices by capability requirements."""
        results = []
        for device in self.get_online_devices():
            caps = device.get("capabilities", {})
            ram = caps.get("ram_mb", 0)
            cores = caps.get("cpu", {}).get("cores", 0)
            gpu = caps.get("gpu", {}).get("ml_capable", False)

            if ram >= min_ram_mb and cores >= min_cores:
                if not needs_gpu or gpu:
                    results.append(device)
        return results

    def get_network_summary(self) -> dict:
        """Return a summary of the device network."""
        online = self.get_online_devices()
        total_compute = sum(
            d.get("capabilities", {}).get("cpu", {}).get("cores", 0)
            for d in online
        )
        total_ram = sum(
            d.get("capabilities", {}).get("ram_mb", 0)
            for d in online
        )
        gpu_devices = [d for d in online
                      if d.get("capabilities", {}).get("gpu", {}).get("ml_capable", False)]
        camera_devices = [d for d in online
                         if any(
                             p.get("peripheral_type") == "camera" and p.get("available")
                             for p in d.get("capabilities", {}).get("peripherals", [])
                         )]

        return {
            "total_devices": len(online),
            "total_compute_cores": total_compute,
            "total_ram_mb": total_ram,
            "total_compute_power": total_compute * total_ram,  # rough metric
            "gpu_devices": len(gpu_devices),
            "camera_devices": len(camera_devices),
            "can_fuse": len(online) >= 3,  # Fusion needs 3+ devices
        }


# ---------------------------------------------------------------------------
# Local network scanner
# ---------------------------------------------------------------------------

def scan_local_network() -> List[dict]:
    """Quick scan for devices on the local network via TCP port scan.

    Used as a fallback when mDNS isn't available.
    """
    found = []
    local_ip = _get_local_ip()
    if not local_ip:
        return found

    # Extract subnet (e.g., 192.168.1)
    parts = local_ip.rsplit(".", 1)
    if len(parts) != 2:
        return found
    subnet = parts[0]

    # Scan common Nexus ports on .1 - .20
    for i in range(1, 21):
        ip = f"{subnet}.{i}"
        for port in [9090, 35545]:
            try:
                with socket.create_connection((ip, port), timeout=0.3):
                    found.append({"address": ip, "port": port, "discovery_method": "scan"})
            except (socket.timeout, ConnectionRefusedError, OSError):
                continue

    return found


def _get_local_ip() -> str:
    """Get the local IP address."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(1)
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"


# ---------------------------------------------------------------------------
# Capability broadcaster
# ---------------------------------------------------------------------------

def build_local_capabilities(node_id: str, node_name: str) -> dict:
    """Build a capability profile for the local device."""
    import platform

    caps = {
        "node_id": node_id,
        "hostname": node_name,
        "device_class": _detect_device_class(),
        "os": {
            "name": platform.system(),
            "version": platform.version(),
            "arch": platform.machine(),
        },
        "cpu": {
            "model": platform.processor() or "Unknown",
            "cores": os.cpu_count() or 1,
        },
        "ram_mb": _detect_ram_mb(),
        "peripherals": _detect_peripherals(),
        "ai_capabilities": _detect_ai_capabilities(),
    }

    # Compute capability score (same formula as Rust)
    cpu_cores = caps["cpu"]["cores"]
    ram = caps["ram_mb"]
    ai = caps["ai_capabilities"]

    score = 0.0
    score += (ram / 32768.0) * 0.4
    score += (cpu_cores / 16.0) * 0.3
    if ai.get("local_llm_available", False):
        score += 0.15
    if ai.get("computer_vision", False):
        score += 0.1
    if ai.get("available_models"):
        score += 0.05
    caps["capability_score"] = round(min(score, 1.0), 3)

    return caps


def _detect_device_class() -> str:
    import platform
    system = platform.system()
    if system == "Android":
        return "phone"
    elif system == "Linux":
        return "desktop"
    elif system == "Darwin":
        return "laptop"
    elif system == "Windows":
        return "desktop"
    return "unknown"


def _detect_ram_mb() -> int:
    try:
        with open("/proc/meminfo", "r") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) // 1024
    except Exception:
        pass

    try:
        import psutil
        return psutil.virtual_memory().total // (1024 * 1024)
    except ImportError:
        return 1024


def _detect_peripherals() -> List[dict]:
    peripherals = []

    # Check for webcam (Linux)
    try:
        if os.path.exists("/dev/video0"):
            peripherals.append({
                "peripheral_type": "camera",
                "name": "Webcam (/dev/video0)",
                "available": True,
            })
    except Exception:
        pass

    # Check for microphone
    try:
        import subprocess
        result = subprocess.run(
            ["arecord", "-l"], capture_output=True, text=True, timeout=3,
        )
        if "card" in result.stdout.lower():
            peripherals.append({
                "peripheral_type": "microphone",
                "name": "Audio input",
                "available": True,
            })
    except Exception:
        pass

    return peripherals


def _detect_ai_capabilities() -> dict:
    """Detect local AI/ML capabilities."""
    caps = {
        "local_llm_available": False,
        "llm_backends": [],
        "available_models": [],
        "voice_recognition": False,
        "computer_vision": False,
        "ml_frameworks": [],
    }

    # Check for Ollama
    try:
        import urllib.request, json
        req = urllib.request.Request("http://127.0.0.1:11434/api/tags")
        req.add_header("Accept", "application/json")
        with urllib.request.urlopen(req, timeout=1.0) as resp:
            data = json.loads(resp.read().decode())
            models = [m.get("name", "") for m in data.get("models", [])]
            if models:
                caps["local_llm_available"] = True
                caps["llm_backends"].append("ollama")
                caps["available_models"].extend(models)
    except Exception:
        pass

    # Check for llama.cpp
    try:
        import urllib.request, json
        with urllib.request.urlopen("http://127.0.0.1:8080/v1/models", timeout=1.0) as resp:
            data = json.loads(resp.read().decode())
            if data.get("data"):
                caps["local_llm_available"] = True
                caps["llm_backends"].append("llama.cpp")
    except Exception:
        pass

    # Check for OpenCV
    try:
        import cv2
        caps["computer_vision"] = True
    except ImportError:
        pass

    # Check for Vosk
    try:
        import vosk
        caps["voice_recognition"] = True
    except ImportError:
        pass

    return caps
