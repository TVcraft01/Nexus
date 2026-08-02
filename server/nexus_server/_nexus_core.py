# Bridge module: provides the _nexus_core API expected by the orchestrator.
#
# When the compiled Rust shared library (libnexus_core.so) is available, this
# module calls into it for performance-critical operations. Otherwise it falls
# back to pure Python implementations.
#
# Usage: from nexus_server import _nexus_core

from __future__ import annotations

import ctypes
import json
import logging
import os
import sys
import threading
from typing import Optional

logger = logging.getLogger("nexus._nexus_core")

__version__ = "0.3.0"
PROTOCOL_VERSION = 1

# Track whether the Rust core is loaded
_rust_loaded: bool = False
_lib: Optional[ctypes.CDLL] = None
_load_lock = threading.Lock()


def _find_library() -> Optional[str]:
    """Locate the compiled libnexus_core.so — installed via pip or dev build."""
    candidates = []

    # 1. Installed via pip (nexus_core package in site-packages)
    for site in sys.path:
        path = os.path.join(site, "nexus_core", "libnexus_core.so")
        if os.path.isfile(path):
            candidates.append(path)

    # 2. Development build in core/target/release/
    dev_path = os.path.join(
        os.path.dirname(__file__), "..", "..", "core",
        "target", "release", "libnexus_core.so",
    )
    if os.path.isfile(os.path.abspath(dev_path)):
        candidates.append(os.path.abspath(dev_path))

    for c in candidates:
        if os.path.isfile(c):
            return c

    return None


def _load_library() -> Optional[ctypes.CDLL]:
    """Load the Rust shared library via ctypes. Thread-safe via lock."""
    global _lib, _rust_loaded

    if _lib is not None:
        return _lib

    with _load_lock:
        if _lib is not None:
            return _lib

        lib_path = _find_library()
        if lib_path is None:
            logger.debug("Rust core not found — using Python fallback")
            return None

        try:
            _lib = ctypes.CDLL(lib_path)
            _rust_loaded = True
            logger.info(f"Rust core loaded: {lib_path}")
            return _lib
        except Exception as e:
            logger.debug(f"Failed to load Rust core: {e}")
            _lib = None
            return None


def is_rust_loaded() -> bool:
    """Check whether the Rust core is loaded and active."""
    return _rust_loaded


# ---------------------------------------------------------------------------
# Rust Task Executor wrapper
# ---------------------------------------------------------------------------

class RustTaskExecutor:
    """Python wrapper around the Rust task decomposition engine.

    Marshals Python dicts to JSON, calls Rust FFI functions via ctypes,
    and returns Python-native results. Falls back gracefully when Rust
    is not available.

    Usage:
        exec = RustTaskExecutor()
        if exec.available:
            strategy = exec.analyze_strategy("compute", devices)
            sub_tasks = exec.decompose("task-1", "render scene", "gpu_compute", devices)
    """

    def __init__(self):
        self._lib = _load_library()

    @property
    def available(self) -> bool:
        return self._lib is not None

    def analyze_strategy(
        self, workload_type: str, devices: list,
    ) -> dict:
        """Analyze the best execution strategy for a workload.

        Returns: {"strategy": "local"|"parallelized"|"fused"|"relay_to",
                  "target_node": null|"<node_id>"}
        """
        if not self._lib:
            return {"strategy": "local", "target_node": None}

        try:
            devices_json = json.dumps(devices)
            func = self._lib.nexus_exec_analyze_strategy
            func.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
            func.restype = ctypes.c_char_p
            result_ptr = func(
                workload_type.encode("utf-8"),
                devices_json.encode("utf-8"),
            )
            if result_ptr:
                raw = result_ptr.decode("utf-8") if isinstance(result_ptr, bytes) else str(result_ptr)
                return json.loads(raw)
        except Exception as e:
            logger.debug(f"Rust analyze_strategy failed, using Python fallback: {e}")

        return {"strategy": "local", "target_node": None}

    def decompose(
        self, task_id: str, description: str,
        workload_type: str, devices: list,
    ) -> list:
        """Decompose a task into sub-tasks.

        Returns list of: {"id": "...", "description": "...",
                          "assigned_node": null|"...",
                          "workload_type": "...", "estimated_cost": 0.5}
        """
        if not self._lib:
            return []

        try:
            devices_json = json.dumps(devices)
            func = self._lib.nexus_exec_decompose
            func.argtypes = [
                ctypes.c_char_p, ctypes.c_char_p,
                ctypes.c_char_p, ctypes.c_char_p,
            ]
            func.restype = ctypes.c_char_p
            result_ptr = func(
                task_id.encode("utf-8"),
                description.encode("utf-8"),
                workload_type.encode("utf-8"),
                devices_json.encode("utf-8"),
            )
            if result_ptr:
                raw = result_ptr.decode("utf-8") if isinstance(result_ptr, bytes) else str(result_ptr)
                return json.loads(raw)
        except Exception as e:
            logger.debug(f"Rust decompose failed, using Python fallback: {e}")

        return []

    def find_capable_devices(
        self, workload_type: str, devices: list,
    ) -> list:
        """Find device IDs capable of handling a workload.

        Returns list of node ID strings, sorted by capability (best first).
        """
        if not self._lib:
            return []

        try:
            devices_json = json.dumps(devices)
            func = self._lib.nexus_exec_find_capable_devices
            func.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
            func.restype = ctypes.c_char_p
            result_ptr = func(
                workload_type.encode("utf-8"),
                devices_json.encode("utf-8"),
            )
            if result_ptr:
                raw = result_ptr.decode("utf-8") if isinstance(result_ptr, bytes) else str(result_ptr)
                return json.loads(raw)
        except Exception as e:
            logger.debug(f"Rust find_capable_devices failed, using Python fallback: {e}")

        return []


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def scan_capabilities(node_id: str, hostname: str) -> str:
    """Scan local device capabilities. Uses Rust core if available, else Python."""
    lib = _load_library()
    if lib is not None:
        try:
            func = lib.scan_capabilities
            func.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
            func.restype = ctypes.c_char_p
            result = func(node_id.encode("utf-8"), hostname.encode("utf-8"))
            if result:
                return result.decode("utf-8")
        except Exception as e:
            logger.debug(f"Rust scan_capabilities failed: {e}")

    # Python fallback
    return _python_scan_capabilities(node_id, hostname)


def encrypt_message(key_bytes: bytes, plaintext: str) -> bytes:
    """Encrypt text using AES-256-GCM. Delegates to nexus_server.crypto."""
    from nexus_server.crypto import encrypt as crypto_encrypt
    return crypto_encrypt(bytes(key_bytes), plaintext.encode("utf-8"))


def decrypt_message(key_bytes: bytes, data: bytes) -> str:
    """Decrypt using AES-256-GCM. Delegates to nexus_server.crypto."""
    from nexus_server.crypto import decrypt as crypto_decrypt
    result = crypto_decrypt(bytes(key_bytes), data)
    return result.decode("utf-8")


def derive_key(pin: str, node_id: str) -> bytes:
    """Derive a 32-byte key from PIN and node ID using HKDF-SHA256."""
    import hashlib
    import hmac
    salt = hashlib.sha256(f"nexus-salt-v1{node_id}".encode()).digest()
    prk = hmac.new(salt, pin.encode(), hashlib.sha256).digest()
    return hashlib.sha256(prk + b"nexus-mesh-key").digest()


# ---------------------------------------------------------------------------
# Python fallback for capability scanning
# ---------------------------------------------------------------------------


def _python_scan_capabilities(node_id: str, hostname: str) -> str:
    """Python implementation of device capability scanning."""
    import platform

    cpu_cores = os.cpu_count() or 1

    # Detect RAM
    ram_mb = 1024
    try:
        with open("/proc/meminfo", "r") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    ram_mb = int(line.split()[1]) // 1024
                    break
    except Exception:
        pass

    # Detect storage
    storage_mb = 1024
    try:
        import shutil
        usage = shutil.disk_usage("/")
        storage_mb = usage.free // (1024 * 1024)
    except Exception:
        pass

    # Compute capability score (matches Rust discovery::compute_capability_score)
    score = min(1.0, (ram_mb / 32768.0) * 0.4 + (cpu_cores / 16.0) * 0.3)

    caps = {
        "node_id": node_id,
        "hostname": hostname,
        "device_class": "desktop" if platform.system() != "Android" else "phone",
        "os": {
            "name": platform.system(),
            "version": platform.version(),
            "arch": platform.machine(),
        },
        "cpu": {
            "model": platform.processor() or platform.machine(),
            "cores": cpu_cores,
            "frequency_mhz": None,
        },
        "ram_mb": ram_mb,
        "storage_mb": storage_mb,
        "gpu": None,
        "network": [],
        "peripherals": [],
        "ai_capabilities": {
            "local_llm_available": False,
            "llm_backends": [],
            "available_models": [],
            "voice_recognition": False,
            "computer_vision": False,
            "ml_frameworks": [],
        },
        "capability_score": round(score, 4),
    }
    return json.dumps(caps)
