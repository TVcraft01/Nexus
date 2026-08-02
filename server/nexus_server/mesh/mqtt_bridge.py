# MQTT Bridge - Universal Device Communication Protocol
#
# Enables Nexus devices to communicate across networks using MQTT.
# Works with any local MQTT broker (mosquitto, vernemq, etc.)
# providing lightweight pub/sub for everything from IoT to desktops.
#
# Topic Structure:
#   nexus/{node_id}/announce    - Device presence & capabilities
#   nexus/{node_id}/command     - Inbound commands
#   nexus/{node_id}/result      - Command results
#   nexus/{node_id}/subtask     - Distributed task execution
#   nexus/{node_id}/capabilities - Capability broadcasts
#   nexus/broadcast             - All-nodes broadcast

from __future__ import annotations

import json
import logging
import threading
import time
import uuid
from typing import Any, Callable, Dict, List, Optional

logger = logging.getLogger("nexus.mesh.mqtt")

# Try importing paho-mqtt (optional dependency)
try:
    import paho.mqtt.client as mqtt
    MQTT_AVAILABLE = True
except ImportError:
    MQTT_AVAILABLE = False
    logger.info("paho-mqtt not installed — MQTT bridge disabled. Install: pip install paho-mqtt")


# ---------------------------------------------------------------------------
# MQTT Bridge
# ---------------------------------------------------------------------------

class MqttBridge:
    """Bridges Nexus mesh nodes via MQTT for cross-network communication."""

    def __init__(
        self,
        node_id: str,
        broker_host: str = "localhost",
        broker_port: int = 1883,
        on_command: Optional[Callable[[str, str, dict], None]] = None,
        on_node_discovered: Optional[Callable[[dict], None]] = None,
        on_subtask: Optional[Callable[[str, dict], None]] = None,
    ):
        self.node_id = node_id
        self.broker_host = broker_host
        self.broker_port = broker_port
        self.on_command = on_command
        self.on_node_discovered = on_node_discovered
        self.on_subtask = on_subtask

        self._client: Optional[mqtt.Client] = None
        self._connected = False
        self._running = False
        self._lock = threading.Lock()

        # Track discovered nodes
        self.discovered_nodes: Dict[str, dict] = {}

    @property
    def is_available(self) -> bool:
        return MQTT_AVAILABLE

    @property
    def status(self) -> dict:
        """Return MQTT bridge status for API queries."""
        return {
            "available": MQTT_AVAILABLE,
            "connected": self._connected,
            "running": self._running,
            "broker_host": self.broker_host,
            "broker_port": self.broker_port,
            "discovered_nodes": len(self.discovered_nodes),
        }

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def start(self, local_capabilities: Optional[dict] = None) -> bool:
        """Connect to MQTT broker and subscribe to Nexus topics."""
        if not MQTT_AVAILABLE:
            logger.debug("MQTT not available — bridge not started")
            return False

        self._running = True
        self._client = mqtt.Client(
            client_id=f"nexus-{self.node_id}-{uuid.uuid4().hex[:4]}",
            clean_session=True,
        )
        self._client.on_connect = self._on_connect
        self._client.on_message = self._on_message
        self._client.on_disconnect = self._on_disconnect

        # Store will message so other nodes know when we disconnect
        self._client.will_set(
            f"nexus/{self.node_id}/announce",
            payload=json.dumps({"status": "offline", "node_id": self.node_id}),
            qos=1,
            retain=False,
        )

        # Connect in background thread
        threading.Thread(target=self._connect_loop, daemon=True).start()

        # Announce ourselves
        if local_capabilities:
            self.announce(local_capabilities)

        logger.info(f"MQTT bridge connecting to {self.broker_host}:{self.broker_port}")
        return True

    def stop(self) -> None:
        """Disconnect from MQTT broker."""
        self._running = False
        # Send offline announcement
        self._publish(f"nexus/{self.node_id}/announce",
                      json.dumps({"status": "offline", "node_id": self.node_id}))
        if self._client:
            try:
                self._client.disconnect()
            except Exception:
                pass
            self._client = None
        logger.info("MQTT bridge stopped")

    def _connect_loop(self) -> None:
        """Connect with retry logic."""
        retry_delay = 2
        max_delay = 60

        while self._running:
            try:
                self._client.connect(self.broker_host, self.broker_port, keepalive=30)
                self._client.loop_forever()
            except Exception as e:
                logger.warning(f"MQTT connection failed: {e} — retrying in {retry_delay}s")
                time.sleep(retry_delay)
                retry_delay = min(retry_delay * 2, max_delay)

    # ------------------------------------------------------------------
    # MQTT callbacks
    # ------------------------------------------------------------------

    def _on_connect(self, client, userdata, flags, rc):
        if rc == 0:
            self._connected = True
            logger.info("MQTT bridge connected")

            # Subscribe to relevant topics
            client.subscribe("nexus/+/announce", qos=1)       # Device announcements
            client.subscribe("nexus/broadcast", qos=1)         # Broadcast messages
            client.subscribe(f"nexus/{self.node_id}/command", qos=1)   # Commands to us
            client.subscribe(f"nexus/{self.node_id}/subtask", qos=1)   # Sub-tasks to us
            client.subscribe(f"nexus/{self.node_id}/result", qos=1)    # Sub-task results
        else:
            logger.warning(f"MQTT connection failed with code {rc}")

    def _on_message(self, client, userdata, msg):
        try:
            payload = json.loads(msg.payload.decode("utf-8"))
            topic = msg.topic

            # Device announcements
            if topic.endswith("/announce") and "status" in payload:
                node_id = payload.get("node_id", "")
                if node_id and node_id != self.node_id:
                    self.discovered_nodes[node_id] = {
                        **payload,
                        "last_seen": time.time(),
                    }
                    if self.on_node_discovered:
                        self.on_node_discovered(payload)

            # Broadcast messages
            elif topic == "nexus/broadcast":
                if self.on_command:
                    self.on_command(
                        payload.get("sender_id", ""),
                        payload.get("message", ""),
                        payload,
                    )

            # Direct commands
            elif topic.endswith("/command"):
                if self.on_command:
                    self.on_command(
                        payload.get("sender_id", ""),
                        payload.get("command", ""),
                        payload,
                    )

            # Sub-tasks for distributed execution
            elif topic.endswith("/subtask"):
                if self.on_subtask:
                    self.on_subtask(
                        payload.get("sender_id", ""),
                        payload,
                    )

            # Sub-task results
            elif topic.endswith("/result"):
                if self.on_subtask:  # Reuse subtask callback for results too
                    self.on_subtask(
                        payload.get("sender_id", ""),
                        payload,
                    )

        except json.JSONDecodeError:
            logger.debug(f"Invalid MQTT payload on {msg.topic}")
        except Exception as e:
            logger.warning(f"MQTT message handler failed: {e}")

    def _on_disconnect(self, client, userdata, rc):
        self._connected = False
        logger.info("MQTT bridge disconnected")

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def announce(self, capabilities: dict) -> None:
        """Announce this device's presence and capabilities."""
        payload = {
            "node_id": self.node_id,
            "status": "online",
            "timestamp": time.time(),
            "capabilities": capabilities,
        }
        self._publish(f"nexus/{self.node_id}/announce", json.dumps(payload))
        logger.debug(f"Announced via MQTT: {self.node_id}")

    def send_command(self, target_node_id: str, command: str,
                    sender_id: str, extra: Optional[dict] = None) -> bool:
        """Send a command to a specific node via MQTT."""
        payload = {
            "sender_id": sender_id,
            "command": command,
            "timestamp": time.time(),
        }
        if extra:
            payload.update(extra)

        self._publish(f"nexus/{target_node_id}/command", json.dumps(payload))
        return True

    def send_result(self, target_node_id: str, task_id: str,
                   success: bool, output: str, subtask_id: str = "") -> bool:
        """Send a task result back to the requesting node."""
        payload = {
            "sender_id": self.node_id,
            "task_id": task_id,
            "subtask_id": subtask_id,
            "success": success,
            "output": output,
            "timestamp": time.time(),
        }
        self._publish(f"nexus/{target_node_id}/result", json.dumps(payload))
        return True

    def dispatch_subtask(self, target_node_id: str, subtask: dict,
                        sender_id: str) -> bool:
        """Dispatch a sub-task to a specific node for distributed execution."""
        payload = {
            "sender_id": sender_id,
            "task_id": subtask.get("task_id", ""),
            "subtask_id": subtask.get("id", ""),
            "workload_type": subtask.get("workload_type", "command"),
            "command": subtask.get("command", ""),
            "estimated_cost": subtask.get("estimated_cost", 1.0),
            "timestamp": time.time(),
        }
        self._publish(f"nexus/{target_node_id}/subtask", json.dumps(payload))
        return True

    def broadcast(self, message: str) -> bool:
        """Send a message to all nodes on the network."""
        payload = {
            "sender_id": self.node_id,
            "message": message,
            "timestamp": time.time(),
        }
        self._publish("nexus/broadcast", json.dumps(payload))
        return True

    def get_online_nodes(self) -> List[dict]:
        """Get list of nodes discovered via MQTT that are still online."""
        now = time.time()
        online = []
        for node_id, info in self.discovered_nodes.items():
            if info.get("status") == "online" and (now - info.get("last_seen", 0)) < 120:
                online.append(info)
        return online

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    def _publish(self, topic: str, payload: str) -> None:
        """Publish a message to MQTT (non-blocking)."""
        if not self._client or not self._connected:
            return
        try:
            self._client.publish(topic, payload, qos=1)
        except Exception as e:
            logger.debug(f"MQTT publish failed: {e}")


# ---------------------------------------------------------------------------
# MQTT Simulator (for testing without a broker)
# ---------------------------------------------------------------------------

class MqttSimulator:
    """In-process MQTT simulator for testing without an external broker.

    Implements the same interface as MqttBridge but routes messages
    in-memory between registered clients.
    """

    _clients: Dict[str, "MqttSimulator"] = {}
    _lock = threading.Lock()

    def __init__(self, node_id: str):
        self.node_id = node_id
        self._message_handler: Optional[Callable] = None
        self._connected = False

    def start(self, local_capabilities: Optional[dict] = None) -> bool:
        with self._lock:
            self._clients[self.node_id] = self
        self._connected = True
        if local_capabilities:
            self.announce(local_capabilities)
        logger.debug(f"MQTT simulator started for {self.node_id}")
        return True

    def stop(self) -> None:
        with self._lock:
            self._clients.pop(self.node_id, None)
        self._connected = False

    def set_handler(self, handler: Callable[[str, str, dict], None]) -> None:
        self._message_handler = handler

    def announce(self, capabilities: dict) -> None:
        self._route_to_all({
            "node_id": self.node_id,
            "status": "online",
            "capabilities": capabilities,
        })

    def send_command(self, target: str, command: str,
                    sender: str, extra: dict = None) -> bool:
        payload = {"sender_id": sender, "command": command, "timestamp": time.time()}
        if extra:
            payload.update(extra)
        self._route_to(target, payload)
        return True

    def dispatch_subtask(self, target: str, subtask: dict, sender: str) -> bool:
        payload = {
            "sender_id": sender,
            "task_id": subtask.get("task_id", ""),
            "subtask_id": subtask.get("id", ""),
            "command": subtask.get("command", ""),
        }
        self._route_to(target, payload)
        return True

    def broadcast(self, message: str) -> bool:
        self._route_to_all({"sender_id": self.node_id, "message": message})
        return True

    def get_online_nodes(self) -> List[dict]:
        return [
            {"node_id": nid, "status": "online"}
            for nid in self._clients if nid != self.node_id
        ]

    def _route_to(self, target: str, payload: dict) -> None:
        with self._lock:
            client = self._clients.get(target)
        if client and client._message_handler:
            cmd = payload.get("command", payload.get("message", ""))
            client._message_handler(self.node_id, cmd, payload)

    def _route_to_all(self, payload: dict) -> None:
        with self._lock:
            for nid, client in self._clients.items():
                if nid != self.node_id and client._message_handler:
                    client._message_handler(self.node_id, "broadcast", payload)
