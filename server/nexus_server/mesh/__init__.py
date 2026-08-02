# Mesh Networking - Python Management Layer
#
# Wraps the Rust mesh core (when available) or provides a pure Python
# fallback using mDNS + encrypted TCP for peer-to-peer communication.

from __future__ import annotations

import json
import logging
import os
import socket
import threading
import time
from typing import Callable, Dict, List, Optional

try:
    from zeroconf import ServiceBrowser, ServiceInfo, ServiceListener, Zeroconf
    ZEROCONF_AVAILABLE = True
except ImportError:
    ZEROCONF_AVAILABLE = False
    logger = logging.getLogger("nexus.mesh")
    logger.warning("zeroconf not installed - mDNS discovery unavailable")

from nexus_server.models import (
    CommandAction, CommandResult, MeshMessage, MeshMessageType,
    MeshNode, MeshPayload, TransportType,
)

logger = logging.getLogger("nexus.mesh")

SERVICE_TYPE = "_nexus._tcp.local."


# ---------------------------------------------------------------------------
# Peer Trust Store
# ---------------------------------------------------------------------------

class PeerTrustStore:
    """Stores trusted peer identities and shared AES keys."""

    def __init__(self, storage_path: str = "peer_keys.json"):
        self.storage_path = storage_path
        self._keys: Dict[str, str] = {}
        self._paired: Dict[str, bool] = {}
        self._load()

    def _load(self) -> None:
        if os.path.exists(self.storage_path):
            try:
                with open(self.storage_path, "r") as f:
                    data = json.load(f)
                self._keys = data.get("keys", {})
                self._paired = data.get("paired", {})
            except Exception:
                pass

    def _save(self) -> None:
        with open(self.storage_path, "w") as f:
            json.dump({"keys": self._keys, "paired": self._paired}, f)

    def store_peer_key(self, peer_id: str, key_base64: str) -> None:
        self._keys[peer_id] = key_base64
        self._paired[peer_id] = True
        self._save()

    def get_peer_key(self, peer_id: str) -> Optional[str]:
        return self._keys.get(peer_id)

    def is_paired(self, peer_id: str) -> bool:
        return self._paired.get(peer_id, False)

    def remove_peer(self, peer_id: str) -> None:
        self._keys.pop(peer_id, None)
        self._paired.pop(peer_id, None)
        self._save()

    def list_paired_peer_ids(self) -> List[str]:
        return [pid for pid, paired in self._paired.items() if paired]


# ---------------------------------------------------------------------------
# Mesh Manager
# ---------------------------------------------------------------------------

class MeshManager:
    """Coordinates mDNS discovery, TCP server, MQTT bridge, and peer management."""

    def __init__(
        self,
        node_id: str,
        node_name: str,
        peer_store: PeerTrustStore,
        command_engine,
        on_command: Optional[Callable] = None,
        on_node_changed: Optional[Callable] = None,
        mqtt_broker: str = "localhost",
        mqtt_port: int = 1883,
    ):
        self.node_id = node_id
        self.node_name = node_name
        self.peer_store = peer_store
        self.command_engine = command_engine
        self.on_command = on_command
        self.on_node_changed = on_node_changed
        self.nodes: Dict[str, MeshNode] = {}
        self._server: Optional[_CommandServer] = None
        self._running = False

        # Phase 2: MQTT bridge and discovery
        from nexus_server.mesh.mqtt_bridge import MqttBridge
        from nexus_server.mesh.discovery import DeviceDiscoveryService

        self.discovery = DeviceDiscoveryService(
            node_id=node_id,
            node_name=node_name,
            on_device_found=self._on_device_found_mqtt,
            on_device_lost=self._on_device_lost_mqtt,
        )
        self.mqtt = MqttBridge(
            node_id=node_id,
            broker_host=mqtt_broker,
            broker_port=mqtt_port,
            on_command=self._on_mqtt_command,
            on_node_discovered=self.discovery.on_device_announce,
            on_subtask=self._on_mqtt_subtask,
        )
        self._on_subtask_callback: Optional[Callable] = None

    def start(self, enable_mqtt: bool = False) -> None:
        self._running = True
        self._server = _CommandServer(
            self.node_id, 0, self.peer_store,
            self.command_engine, self.on_command,
        )
        self._server.start()
        logger.info(f"Mesh TCP server started on port {self._server.actual_port}")

        # Start MQTT bridge (optional)
        if enable_mqtt:
            from nexus_server.mesh.discovery import build_local_capabilities
            caps = build_local_capabilities(self.node_id, self.node_name)
            self.mqtt.start(local_capabilities=caps)
            logger.info(f"MQTT bridge started (broker: {self.mqtt.broker_host}:{self.mqtt.broker_port})")

    def stop(self) -> None:
        self._running = False
        self.mqtt.stop()
        if self._server:
            self._server.stop()
            self._server = None

    # --- MQTT callbacks ---

    def _on_device_found_mqtt(self, device_info: dict) -> None:
        """New device discovered via MQTT."""
        logger.info(f"Device discovered via MQTT: {device_info.get('node_id', '?')}")
        if self.on_node_changed:
            self.on_node_changed()

    def _on_device_lost_mqtt(self, node_id: str) -> None:
        """Device went offline via MQTT."""
        logger.info(f"Device offline: {node_id}")
        if self.on_node_changed:
            self.on_node_changed()

    def _on_mqtt_command(self, sender_id: str, command: str, payload: dict) -> None:
        """Command received via MQTT."""
        result = self.command_engine.execute_command(command)
        if self.on_command:
            self.on_command(sender_id, result)
        # Send result back
        self.mqtt.send_result(sender_id, "direct-cmd", result.success, result.message)

    def _on_mqtt_subtask(self, sender_id: str, payload: dict) -> None:
        """Sub-task received for distributed execution."""
        if self._on_subtask_callback:
            self._on_subtask_callback(sender_id, payload)

    def set_subtask_handler(self, callback: Callable) -> None:
        self._on_subtask_callback = callback

    def pair_with_pin(self, peer_id: str, pin: str) -> None:
        """Derive shared key from PIN and store it."""
        from nexus_server.crypto import derive_key_from_pin, encode_key_base64, salt_for_node_id
        symmetric_id = "|".join(sorted([self.node_id, peer_id]))
        salt = salt_for_node_id(symmetric_id)
        key = derive_key_from_pin(pin, salt)
        self.peer_store.store_peer_key(peer_id, encode_key_base64(key))
        logger.info(f"Paired with {peer_id}")

    def send_command(self, node: MeshNode, command: str) -> Optional[CommandResult]:
        if not node.port:
            return None
        try:
            data = (json.dumps({"cmd": command, "senderId": self.node_id}) + "\n").encode()
            with socket.create_connection((node.address, node.port), timeout=5) as sock:
                sock.sendall(data)
                resp = sock.recv(4096)
                result = json.loads(resp.decode())
                return CommandResult(
                    result.get("ok", False),
                    result.get("result", ""),
                    CommandAction.Unknown(command),
                )
        except Exception as e:
            return CommandResult(False, f"Send failed: {e}", CommandAction.Unknown(command))


# ---------------------------------------------------------------------------
# Internal TCP server
# ---------------------------------------------------------------------------

class _CommandServer(threading.Thread):
    """TCP server for receiving Nexus commands."""

    def __init__(self, node_id: str, port: int, peer_store: PeerTrustStore,
                 command_engine, on_command: Optional[Callable] = None):
        super().__init__(daemon=True)
        self.node_id = node_id
        self.peer_store = peer_store
        self.command_engine = command_engine
        self.on_command = on_command
        self._stop = threading.Event()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("0.0.0.0", port))

    @property
    def actual_port(self) -> int:
        return self.sock.getsockname()[1]

    def run(self) -> None:
        self.sock.listen(5)
        self.sock.settimeout(1.0)
        logger.info(f"TCP server listening on :{self.actual_port}")
        while not self._stop.is_set():
            try:
                client, addr = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self._handle, args=(client, addr), daemon=True).start()

    def _handle(self, client: socket.socket, addr) -> None:
        try:
            client.settimeout(5.0)
            with client:
                data = client.recv(4096)
                if not data:
                    return
                text = data.decode("utf-8", errors="replace").strip()
                try:
                    parsed = json.loads(text)
                    command = parsed.get("cmd", "")
                    sender = parsed.get("senderId", "unknown")
                    result = self.command_engine.execute_command(command)
                    if self.on_command:
                        self.on_command(sender, result)
                    resp = json.dumps({"ok": result.success, "result": result.message}) + "\n"
                    client.sendall(resp.encode())
                except json.JSONDecodeError:
                    client.sendall(b'{"ok": false, "result": "Invalid JSON"}\n')
        except Exception as e:
            logger.warning(f"Client handler failed: {e}")

    def stop(self) -> None:
        self._stop.set()
        try:
            self.sock.close()
        except OSError:
            pass
