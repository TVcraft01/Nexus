"""Mesh networking for the Linux desktop node.

Includes mDNS service advertisement/discovery, a TCP command server, and
encrypted MeshMessage handling matching the Android protocol.
"""

from __future__ import annotations

import json
import logging
import os
import socket
import threading
import time
from typing import Callable, Dict, List, Optional

from zeroconf import ServiceBrowser, ServiceInfo, ServiceListener, Zeroconf

from .command_engine import ZeroLLMCommandEngine
from .crypto import derive_key_from_pin, encrypt as crypto_encrypt, decrypt as crypto_decrypt, encode_key_base64, decode_key_base64, salt_for_node_id
from .models import CommandAction, CommandResult, MeshMessage, MeshMessageType, MeshNode, MeshPayload, TransportType
from .utils import get_local_ip


logger = logging.getLogger(__name__)

SERVICE_TYPE = "_nexus._tcp.local."


class PeerTrustStore:
    """Stores trusted peer identities and shared AES keys."""

    def __init__(self, storage_path: str = "nexus_peer_keys.json"):
        self.storage_path = storage_path
        self._keys: Dict[str, str] = {}
        self._paired: Dict[str, bool] = {}
        self._load()

    def _load(self) -> None:
        if os.path.exists(self.storage_path):
            try:
                with open(self.storage_path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                self._keys = data.get("keys", {})
                self._paired = data.get("paired", {})
            except Exception:
                pass

    def _save(self) -> None:
        with open(self.storage_path, "w", encoding="utf-8") as f:
            json.dump({"keys": self._keys, "paired": self._paired}, f)

    def store_peer_key(self, peer_id: str, key: bytes) -> None:
        self._keys[peer_id] = encode_key_base64(key)
        self._paired[peer_id] = True
        self._save()

    def get_peer_key(self, peer_id: str) -> Optional[bytes]:
        encoded = self._keys.get(peer_id)
        if encoded:
            return decode_key_base64(encoded)
        return None

    def is_paired(self, peer_id: str) -> bool:
        return self._paired.get(peer_id, False)

    def remove_peer(self, peer_id: str) -> None:
        self._keys.pop(peer_id, None)
        self._paired.pop(peer_id, None)
        self._save()

    def list_paired_peer_ids(self) -> List[str]:
        return [peer_id for peer_id, paired in self._paired.items() if paired]


class CommandServer(threading.Thread):
    """TCP server that accepts incoming Nexus command relays."""

    def __init__(
        self,
        node_id: str,
        port: int,
        peer_store: PeerTrustStore,
        command_engine: ZeroLLMCommandEngine,
        on_command: Optional[Callable[[str, CommandResult], None]] = None,
    ):
        super().__init__(daemon=True)
        self.node_id = node_id
        self.port = port
        self.peer_store = peer_store
        self.command_engine = command_engine
        self.on_command = on_command
        self._stop_event = threading.Event()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("0.0.0.0", port))
        self.sock.listen(5)

    @property
    def actual_port(self) -> int:
        return self.sock.getsockname()[1]

    def run(self) -> None:
        logger.info("TCP command server listening on port %d", self.actual_port)
        self.sock.settimeout(1.0)
        while not self._stop_event.is_set():
            try:
                client, addr = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self._handle_client, args=(client, addr), daemon=True).start()

    def _handle_client(self, client: socket.socket, addr) -> None:
        try:
            client.settimeout(5.0)
            with client:
                data = b""
                while True:
                    chunk = client.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                    if b"\n" in chunk:
                        break
                if not data:
                    return
                text = data.decode("utf-8", errors="replace").strip()
                result = self._handle_payload(text)
                response = json.dumps({
                    "ok": result.success,
                    "result": result.message,
                    "senderId": self.node_id,
                }) + "\n"
                client.sendall(response.encode("utf-8"))
        except Exception as exc:
            logger.warning("Client handling failed: %s", exc)

    def _handle_payload(self, text: str) -> CommandResult:
        # Try encrypted MeshMessage first
        try:
            message = MeshMessage.from_json(text)
            peer_id = message.sender_id
            key = self.peer_store.get_peer_key(peer_id)
            if key is None:
                return CommandResult(False, f"No shared key for {peer_id}; pair first.", CommandAction.Unknown(""))
            iv_and_cipher = message.iv + message.payload
            plain = crypto_decrypt(key, iv_and_cipher).decode("utf-8")
            payload = MeshPayload.from_json(plain)
            if message.type == MeshMessageType.COMMAND:
                result = self.command_engine.execute_command(payload.command or "")
                if self.on_command:
                    self.on_command(peer_id, result)
                return result
            return CommandResult(True, f"Received {message.type.name}", CommandAction.Unknown(""))
        except Exception:
            pass

        # Legacy raw JSON
        try:
            data = json.loads(text)
            command = data.get("cmd", "")
            sender = data.get("senderId", "unknown")
            logger.debug("Legacy relayed command from %s: %s", sender, command)
            result = self.command_engine.execute_command(command)
            if self.on_command:
                self.on_command(sender, result)
            return result
        except Exception as exc:
            return CommandResult(False, f"Failed to parse relay payload: {exc}", CommandAction.Unknown(""))

    def stop(self) -> None:
        self._stop_event.set()
        try:
            self.sock.close()
        except OSError:
            pass


class NexusListener(ServiceListener):
    def __init__(self, on_add: Callable, on_update: Callable, on_remove: Callable):
        self.on_add = on_add
        self.on_update = on_update
        self.on_remove = on_remove

    def add_service(self, zc: Zeroconf, type_: str, name: str) -> None:
        info = zc.get_service_info(type_, name)
        if info:
            self.on_add(info)

    def update_service(self, zc: Zeroconf, type_: str, name: str) -> None:
        info = zc.get_service_info(type_, name)
        if info:
            self.on_update(info)

    def remove_service(self, zc: Zeroconf, type_: str, name: str) -> None:
        self.on_remove(name)


class MeshManager:
    """Coordinates mDNS, TCP server, and peer store."""

    def __init__(
        self,
        node_id: str,
        node_name: str,
        peer_store: PeerTrustStore,
        command_engine: ZeroLLMCommandEngine,
        on_node_changed: Optional[Callable[[], None]] = None,
        on_command: Optional[Callable[[str, CommandResult], None]] = None,
    ):
        self.node_id = node_id
        self.node_name = node_name
        self.peer_store = peer_store
        self.command_engine = command_engine
        self.on_node_changed = on_node_changed
        self.on_command = on_command
        self.nodes: Dict[str, MeshNode] = {}
        self.zeroconf = Zeroconf()
        self.server: Optional[CommandServer] = None
        self.browser: Optional[ServiceBrowser] = None
        self.service_info: Optional[ServiceInfo] = None

    @property
    def port(self) -> int:
        return self.server.actual_port if self.server else 0

    def start(self) -> None:
        self.server = CommandServer(self.node_id, 0, self.peer_store, self.command_engine, self.on_command)
        self.server.start()
        self._register_service()
        self._start_discovery()

    def stop(self) -> None:
        if self.browser:
            try:
                self.browser.cancel()
            except Exception:
                pass
            self.browser = None
        if self.service_info:
            try:
                self.zeroconf.unregister_service(self.service_info)
            except Exception:
                pass
            self.service_info = None
        if self.server:
            self.server.stop()
            self.server = None
        try:
            self.zeroconf.close()
        except Exception:
            pass

    def pair_with_pin(self, peer_id: str, pin: str) -> None:
        # Derive a symmetric salt from both node IDs so the initiator and the
        # target compute the exact same shared key without caring who is which.
        symmetric_id = "|".join(sorted([self.node_id, peer_id]))
        salt = salt_for_node_id(symmetric_id)
        key = derive_key_from_pin(pin, salt)
        self.peer_store.store_peer_key(peer_id, key)

    def _register_service(self) -> None:
        from zeroconf import NonUniqueNameException
        service_name = f"{self.node_name}-{self.node_id}.{SERVICE_TYPE}"
        self.service_info = ServiceInfo(
            type_=SERVICE_TYPE,
            name=service_name,
            addresses=[socket.inet_aton(get_local_ip())],
            port=self.port,
            properties={b"nodeId": self.node_id.encode("utf-8")},
        )
        try:
            self.zeroconf.register_service(self.service_info)
        except NonUniqueNameException:
            # A previous instance may have left the name registered; try to replace it.
            try:
                self.zeroconf.unregister_service(self.service_info)
                self.zeroconf.register_service(self.service_info)
            except NonUniqueNameException as exc:
                raise RuntimeError("Failed to register mDNS service: name still in use") from exc

    def _start_discovery(self) -> None:
        def _add(info: ServiceInfo) -> None:
            raw_node_id = info.properties.get(b"nodeId", b"")
            node_id = (raw_node_id or b"").decode("utf-8") or info.name
            node = MeshNode(
                id=node_id,
                name=info.name,
                address=info.parsed_addresses()[0] if info.parsed_addresses() else "",
                port=info.port,
                transport=TransportType.WIFI_NSD,
                last_seen=int(time.time() * 1000),
                is_paired=self.peer_store.is_paired(node_id),
            )
            self.nodes[node_id] = node
            if self.on_node_changed:
                self.on_node_changed()

        def _update(info: ServiceInfo) -> None:
            _add(info)

        def _remove(name: str) -> None:
            for key in list(self.nodes.keys()):
                if self.nodes[key].name == name:
                    del self.nodes[key]
            if self.on_node_changed:
                self.on_node_changed()

        self.browser = ServiceBrowser(self.zeroconf, SERVICE_TYPE, NexusListener(_add, _update, _remove))

    def send_command(self, node: MeshNode, command: str) -> Optional[CommandResult]:
        if not node.port:
            return None
        key = self.peer_store.get_peer_key(node.id)
        payload_obj = MeshPayload(command=command)
        if key:
            encrypted = crypto_encrypt(key, payload_obj.to_json().encode("utf-8"))
            message = MeshMessage(
                sender_id=self.node_id,
                type=MeshMessageType.COMMAND,
                iv=encrypted[:12],
                payload=encrypted[12:],
            )
            data = (message.to_json() + "\n").encode("utf-8")
        else:
            data = (json.dumps({"cmd": command, "senderId": self.node_id}) + "\n").encode("utf-8")

        try:
            with socket.create_connection((node.address, node.port), timeout=5) as sock:
                sock.sendall(data)
                response = b""
                while True:
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    response += chunk
                    if b"\n" in chunk:
                        break
                text = response.decode("utf-8", errors="replace").strip()
                data = json.loads(text)
                return CommandResult(data.get("ok", False), data.get("result", ""), self.command_engine.parse_command(command) or CommandAction.Unknown(command))
        except Exception as exc:
            return CommandResult(False, f"Send failed: {exc}", self.command_engine.parse_command(command) or CommandAction.Unknown(command))



