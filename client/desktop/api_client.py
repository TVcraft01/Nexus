# Nexus Server API Client
#
# Communicates with the Nexus server's REST API for vision streaming,
# MQTT status, network info, task execution, and more.
#
# All calls are non-blocking (run in background threads) and results are
# delivered to the main UI thread via a callback queue.

from __future__ import annotations

import base64
import io
import json
import logging
import threading
import time
import urllib.error
import urllib.request
from typing import Any, Callable, Dict, List, Optional

logger = logging.getLogger(__name__)


class NexusApiClient:
    """HTTP client for the Nexus orchestrator server API."""

    def __init__(self, base_url: str = "http://localhost:9090", timeout: float = 10.0):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self._connected = False

    # ------------------------------------------------------------------
    # Low-level HTTP
    # ------------------------------------------------------------------

    def _url(self, path: str) -> str:
        return f"{self.base_url}{path}"

    def _request(self, method: str, path: str, data: Optional[dict] = None) -> dict:
        """Synchronous request returning parsed JSON dict."""
        url = self._url(path)
        req = urllib.request.Request(url, method=method)
        req.add_header("Accept", "application/json")
        req.add_header("User-Agent", "Nexus-Desktop/0.3.0")

        body = None
        if data is not None:
            body = json.dumps(data).encode("utf-8")
            req.add_header("Content-Type", "application/json")

        try:
            with urllib.request.urlopen(req, data=body, timeout=self.timeout) as resp:
                self._connected = True
                raw = resp.read().decode("utf-8")
                return json.loads(raw)
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8", errors="replace")
            try:
                return json.loads(err_body)
            except json.JSONDecodeError:
                return {"error": f"HTTP {e.code}", "detail": err_body[:200]}
        except urllib.error.URLError as e:
            self._connected = False
            return {"error": f"Connection failed: {e.reason}"}
        except Exception as e:
            return {"error": str(e)}

    def _get(self, path: str) -> dict:
        return self._request("GET", path)

    def _post(self, path: str, data: Optional[dict] = None) -> dict:
        return self._request("POST", path, data)

    def _get_raw(self, path: str, timeout: Optional[float] = None) -> Optional[bytes]:
        """Fetch raw bytes (for JPEG images, streaming, etc.)."""
        url = self._url(path)
        t = timeout if timeout is not None else self.timeout
        try:
            req = urllib.request.Request(url, method="GET")
            req.add_header("User-Agent", "Nexus-Desktop/0.3.0")
            with urllib.request.urlopen(req, timeout=t) as resp:
                self._connected = True
                return resp.read()
        except Exception as e:
            logger.debug(f"Raw GET {path} failed: {e}")
            self._connected = False
            return None

    # ------------------------------------------------------------------
    # Async helpers
    # ------------------------------------------------------------------

    def _async(self, fn, callback: Optional[Callable[[dict], None]] = None) -> None:
        """Run fn() in a background thread; call callback(result) on UI thread."""
        def _runner():
            try:
                result = fn()
            except Exception as exc:
                result = {"error": str(exc)}
            if callback:
                callback(result)
        threading.Thread(target=_runner, daemon=True).start()

    # ------------------------------------------------------------------
    # Health
    # ------------------------------------------------------------------

    def health(self) -> dict:
        return self._get("/health")

    def is_connected(self) -> bool:
        return self._connected

    # ------------------------------------------------------------------
    # Vision — status & cameras
    # ------------------------------------------------------------------

    def vision_status(self) -> dict:
        return self._get("/api/vision/status")

    def list_cameras(self) -> list:
        return self._get("/api/vision/cameras")

    def search_cameras(self, query: str) -> list:
        return self._post("/api/vision/search", {"query": query})

    def locate_item(self, item: str) -> dict:
        return self._post("/api/vision/locate", {"item": item})

    def warmup_vision(self) -> dict:
        return self._get("/api/vision/warmup")

    # ------------------------------------------------------------------
    # Vision — snapshots & streaming
    # ------------------------------------------------------------------

    def snapshot_jpeg(self, camera_id: str = "local-0",
                       timeout: Optional[float] = None) -> Optional[bytes]:
        """Fetch a raw JPEG snapshot from a camera.

        Args:
            camera_id: Camera identifier
            timeout: Override default timeout (preview should use ~2s)
        """
        return self._get_raw(
            f"/api/vision/snapshot/image?camera={camera_id}",
            timeout=timeout,
        )

    def snapshot(self, camera_id: str = "local-0") -> dict:
        """Fetch a base64-encoded snapshot with detection metadata."""
        return self._post("/api/vision/snapshot", {"camera_id": camera_id})

    # ------------------------------------------------------------------
    # MQTT
    # ------------------------------------------------------------------

    def mqtt_status(self) -> dict:
        return self._get("/api/mqtt/enable")

    def enable_mqtt(self, broker: str = "localhost", port: int = 1883) -> dict:
        return self._post("/api/mqtt/enable", {"broker": broker, "port": port})

    # ------------------------------------------------------------------
    # Network / Tasks
    # ------------------------------------------------------------------

    def network_summary(self) -> dict:
        return self._get("/api/network")

    def device_capabilities(self) -> dict:
        return self._get("/api/devices/capabilities")

    def submit_task(self, description: str,
                    workload_type: str = "command",
                    priority: int = 5) -> dict:
        return self._post("/api/tasks/submit", {
            "description": description,
            "workload_type": workload_type,
            "priority": priority,
        })

    def list_tasks(self) -> list:
        return self._get("/api/tasks")

    def server_status(self) -> dict:
        return self._get("/api/status")

    # ------------------------------------------------------------------
    # Routine learning
    # ------------------------------------------------------------------

    def routines(self) -> list:
        return self._get("/api/routines")

    def suggestions(self) -> list:
        return self._get("/api/suggestions")

    def insights(self) -> list:
        return self._get("/api/insights")

    def streaks(self) -> list:
        return self._get("/api/streaks")

    def predict_next(self) -> dict:
        return self._get("/api/routines/predict")

    # ------------------------------------------------------------------
    # Streaming — MJPEG frame extractor (for desktop preview)
    # ------------------------------------------------------------------

    def stream_mjpeg_frames(
        self, camera_id: str = "local-0", fps: int = 5,
        on_frame: Optional[Callable[[bytes, List[dict]], None]] = None,
    ) -> None:
        """Connect to the MJPEG stream and call on_frame(jpeg_bytes, detections)
        for each frame. Runs in a background thread. Blocks until the stream
        ends or the thread is stopped via the returned stop event.

        Returns a threading.Event that can be set to stop streaming.
        """
        stop_event = threading.Event()

        def _stream():
            url = self._url(
                f"/api/vision/stream/mjpeg?camera={camera_id}&fps={fps}"
            )
            boundary = b"--nexusframe"
            try:
                req = urllib.request.Request(url, method="GET")
                req.add_header("User-Agent", "Nexus-Desktop/0.3.0")
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    self._connected = True
                    content_type = resp.headers.get("Content-Type", "")
                    # Extract boundary from content type if needed
                    if "boundary=" in content_type:
                        boundary = (
                            "--" +
                            content_type.split("boundary=")[-1]
                            .split(";")[0].strip().encode()
                        )

                    buffer = b""
                    while not stop_event.is_set():
                        chunk = resp.read(8192)
                        if not chunk:
                            break
                        buffer += chunk

                        # Parse multipart parts
                        while boundary in buffer:
                            idx = buffer.find(boundary)
                            if idx == -1:
                                break
                            # Find the part between boundaries
                            next_idx = buffer.find(boundary, idx + len(boundary))
                            if next_idx == -1:
                                break
                            part = buffer[idx + len(boundary):next_idx]

                            # Extract headers and body
                            header_end = part.find(b"\r\n\r\n")
                            if header_end == -1:
                                buffer = buffer[next_idx:]
                                continue

                            headers_raw = part[:header_end].decode(
                                "utf-8", errors="replace"
                            )
                            jpeg_bytes = part[header_end + 4:].rstrip(b"\r\n")

                            # Parse X-Detections header
                            detections = []
                            for line in headers_raw.split("\r\n"):
                                if line.lower().startswith("x-detections:"):
                                    try:
                                        detections = json.loads(
                                            line.split(":", 1)[1].strip()
                                        )
                                    except json.JSONDecodeError:
                                        pass

                            if jpeg_bytes and on_frame:
                                try:
                                    on_frame(jpeg_bytes, detections)
                                except Exception:
                                    pass  # Don't crash the stream for a bad callback

                            buffer = buffer[next_idx + len(boundary):]

            except Exception as e:
                logger.debug(f"MJPEG stream ended: {e}")
            finally:
                self._connected = False

        threading.Thread(target=_stream, daemon=True).start()
        return stop_event
