# Streaming API — Real-time Camera Feeds with YOLO Detections
#
# Provides two streaming endpoints for the desktop GUI:
#   1. SSE  (Server-Sent Events)  — JSON events with base64 frame + detections
#   2. MJPEG (multipart/x-mixed-replace) — raw JPEG stream for <img> tags
#
# Architecture: publish-subscribe per camera
#   - Each camera has one capture thread (CameraStream)
#   - Multiple clients subscribe via thread-safe queues
#   - Capture thread stops when last subscriber disconnects
#   - YOLO detection runs on each frame in the capture thread
#   - Camera access is synchronized with vision module's per-camera locks

from __future__ import annotations

import base64
import json
import logging
import queue
import threading
import time
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger("nexus.api.streaming")

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_FPS = 5
MAX_FPS = 30
MIN_FPS = 1
FRAME_TIMEOUT = 5.0          # seconds before dropping a slow subscriber
CLEANUP_INTERVAL = 30.0      # seconds between cleanup sweeps
MJPEG_BOUNDARY = "--nexusframe"
MAX_QUEUE_SIZE = 30
MAX_SUBSCRIBERS_PER_CAMERA = 10

# ---------------------------------------------------------------------------
# Camera Stream Manager
# ---------------------------------------------------------------------------


class CameraStreamManager:
    """Manages camera streaming with publish-subscribe for multiple clients.

    Thread-safe. One capture thread per camera, N subscribers per camera.
    """

    def __init__(self, vision_module) -> None:
        self._vision = vision_module
        self._streams: Dict[str, CameraStream] = {}
        self._lock = threading.Lock()
        self._cleanup_running = False

    # ---- Public API ----

    def subscribe(
        self, camera_id: str, fps: int = DEFAULT_FPS,
    ) -> Tuple[Optional["queue.Queue[Dict[str, Any]]"], Optional[str]]:
        """Subscribe to a camera stream.

        Returns (queue, error).  Queue receives dicts:
            {"frame": <np.ndarray>, "jpeg": <bytes>,
             "detections": [...], "timestamp": float}
        """
        fps = max(MIN_FPS, min(fps, MAX_FPS))

        with self._lock:
            if camera_id not in self._streams:
                # Verify camera exists (lightweight check, no open)
                if not self._vision.is_camera_registered(camera_id):
                    return None, f"Camera '{camera_id}' not registered"
                stream = CameraStream(self._vision, camera_id, fps)
                self._streams[camera_id] = stream
            else:
                stream = self._streams[camera_id]

            # Check subscriber limit
            if stream.subscriber_count() >= MAX_SUBSCRIBERS_PER_CAMERA:
                return None, (
                    f"Camera '{camera_id}' has reached max subscribers "
                    f"({MAX_SUBSCRIBERS_PER_CAMERA})"
                )

            sub_queue: "queue.Queue[Dict[str, Any]]" = queue.Queue(
                maxsize=MAX_QUEUE_SIZE,
            )
            stream.add_subscriber(sub_queue)

            if not stream.is_running():
                stream.start()

        self._ensure_cleanup()
        return sub_queue, None

    def unsubscribe(self, camera_id: str, sub_queue: "queue.Queue") -> None:
        """Unsubscribe from a camera stream."""
        with self._lock:
            stream = self._streams.get(camera_id)
        if stream:
            stream.remove_subscriber(sub_queue)

    def camera_count(self) -> int:
        with self._lock:
            return len(self._streams)

    def active_count(self) -> int:
        with self._lock:
            return sum(1 for s in self._streams.values() if s.is_running())

    def subscriber_count(self, camera_id: str) -> int:
        with self._lock:
            stream = self._streams.get(camera_id)
            return stream.subscriber_count() if stream else 0

    def list_streams(self) -> List[Dict[str, Any]]:
        """List active streams for API introspection."""
        with self._lock:
            return [
                {
                    "camera_id": cid,
                    "fps": s.fps,
                    "running": s.is_running(),
                    "subscribers": s.subscriber_count(),
                    "frame_shape": s.frame_shape,
                    "frames_captured": s.frame_count,
                }
                for cid, s in self._streams.items()
            ]

    def shutdown(self) -> None:
        """Stop all streams. Call on server shutdown."""
        with self._lock:
            for stream in list(self._streams.values()):
                stream.stop()
            self._streams.clear()

    # ---- Internals ----

    def _ensure_cleanup(self) -> None:
        """Start cleanup thread if not already running."""
        if self._cleanup_running:
            return
        self._cleanup_running = True
        threading.Thread(target=self._cleanup_loop, daemon=True).start()

    def _cleanup_loop(self) -> None:
        """Periodically stop idle streams (no subscribers)."""
        while True:
            time.sleep(CLEANUP_INTERVAL)
            with self._lock:
                for cid, stream in list(self._streams.items()):
                    if stream.subscriber_count() == 0 and stream.is_running():
                        stream.stop()
                    if (stream.subscriber_count() == 0
                            and not stream.is_running()
                            and time.time() - stream.last_active > 120):
                        del self._streams[cid]
                if not self._streams:
                    self._cleanup_running = False
                    break


# ---------------------------------------------------------------------------
# Single Camera Stream
# ---------------------------------------------------------------------------


class CameraStream:
    """Captures frames from one camera, runs YOLO, fans out to subscribers.

    Uses the vision module's per-camera lock for synchronization with
    snapshot/locate requests.
    """

    def __init__(self, vision_module, camera_id: str, fps: int) -> None:
        self._vision = vision_module
        self.camera_id = camera_id
        self.fps = fps
        self.last_active = time.time()
        self.frame_count = 0
        self.has_sse_subscribers = False

        self._subscribers: List["queue.Queue[Dict[str, Any]]"] = []
        self._sub_lock = threading.Lock()
        self._running = False
        self._thread: Optional[threading.Thread] = None
        self.frame_shape: Optional[Tuple[int, int]] = None

    # ---- Lifecycle ----

    def start(self) -> None:
        if self._running:
            return
        self._running = True
        self._thread = threading.Thread(
            target=self._capture_loop, daemon=True,
            name=f"cam-{self.camera_id}",
        )
        self._thread.start()
        logger.info(f"Camera stream started: {self.camera_id} @ {self.fps}fps")

    def stop(self) -> None:
        self._running = False
        if self._thread:
            self._thread.join(timeout=3)
            self._thread = None
        # Drain subscriber queues
        with self._sub_lock:
            for q in self._subscribers:
                while not q.empty():
                    try:
                        q.get_nowait()
                    except queue.Empty:
                        break
        logger.info(f"Camera stream stopped: {self.camera_id}")

    def is_running(self) -> bool:
        return self._running

    # ---- Subscribers ----

    def add_subscriber(self, q: "queue.Queue") -> None:
        with self._sub_lock:
            self._subscribers.append(q)
        self.last_active = time.time()

    def remove_subscriber(self, q: "queue.Queue") -> None:
        with self._sub_lock:
            if q in self._subscribers:
                self._subscribers.remove(q)
        self.last_active = time.time()

    def subscriber_count(self) -> int:
        with self._sub_lock:
            return len(self._subscribers)

    # ---- Capture loop ----

    def _capture_loop(self) -> None:
        """Main loop: acquire camera lock → capture → YOLO → encode → fan out."""
        import cv2

        # Get camera source via public API
        source = self._vision.get_camera_source(self.camera_id)
        if source is None:
            logger.error(f"Camera '{self.camera_id}' source not found")
            self._running = False
            return

        # Acquire per-camera lock from vision module (coordinates with snapshots)
        cam_lock = self._vision.acquire_camera_lock(self.camera_id)
        if cam_lock is None:
            logger.error(f"Camera '{self.camera_id}' lock not available")
            self._running = False
            return

        # Open camera UNDER the per-camera lock
        from nexus_server.ai.vision import open_camera
        with cam_lock:
            cap = open_camera(source)

        if cap is None:
            logger.error(f"Cannot open camera: {source}")
            self._running = False
            return

        frame_interval = 1.0 / self.fps

        try:
            # Warmup frames (under lock)
            with cam_lock:
                for _ in range(2):
                    cap.read()

            while self._running:
                loop_start = time.time()

                # Check subscribers (snapshot count outside lock to avoid
                # holding _sub_lock during the entire frame cycle)
                with self._sub_lock:
                    sub_count = len(self._subscribers)

                if sub_count == 0:
                    time.sleep(0.5)
                    continue

                # Capture frame (under camera lock — coordinates with snapshot)
                with cam_lock:
                    ret, frame = cap.read()

                if not ret or frame is None:
                    logger.warning(f"Camera {self.camera_id}: empty frame")
                    time.sleep(0.1)
                    continue

                self.frame_count += 1
                self.frame_shape = (frame.shape[1], frame.shape[0])

                # JPEG encode (always needed for both SSE and MJPEG)
                _, jpeg = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 75])
                jpeg_bytes = jpeg.tobytes()

                # YOLO detection (thread-safe via vision module's detect_objects)
                detections = self._vision.detect_objects(frame)

                # Build payload — base64 computed lazily only if SSE subscribers exist
                payload = {
                    "frame": frame,
                    "jpeg": jpeg_bytes,
                    "_jpeg_b64": None,  # Lazy: computed on first access
                    "detections": detections,
                    "timestamp": time.time(),
                    "frame_number": self.frame_count,
                }

                # Fan out to subscribers (copy list under lock, put outside lock)
                with self._sub_lock:
                    subscribers = list(self._subscribers)

                dead: List["queue.Queue"] = []
                for q in subscribers:
                    try:
                        q.put_nowait(payload)
                    except queue.Full:
                        # Drain and replace with latest frame
                        try:
                            q.get_nowait()
                            q.put_nowait(payload)
                        except queue.Full:
                            dead.append(q)

                if dead:
                    with self._sub_lock:
                        for q in dead:
                            if q in self._subscribers:
                                self._subscribers.remove(q)

                # Sleep to maintain target FPS
                elapsed = time.time() - loop_start
                sleep_time = frame_interval - elapsed
                if sleep_time > 0:
                    time.sleep(sleep_time)

        except Exception as e:
            logger.error(f"Capture loop error for {self.camera_id}: {e}")
        finally:
            with cam_lock:
                cap.release()
            self._running = False


# ---------------------------------------------------------------------------
# SSE Response Writer
# ---------------------------------------------------------------------------

def write_sse_stream(
    wfile, sub_queue: "queue.Queue", camera_id: str,
    stop_event: threading.Event,
) -> None:
    """Write Server-Sent Events to an HTTP response.

    Format:
        event: frame
        data: {"frame": "<base64>", "detections": [...],
               "timestamp": ..., "camera_id": "...", "width": ..., "height": ...}

    """
    while not stop_event.is_set():
        try:
            payload = sub_queue.get(timeout=1.0)
        except queue.Empty:
            # Send a heartbeat comment to keep connection alive
            try:
                wfile.write(b": heartbeat\n\n")
                wfile.flush()
            except Exception:
                break
            continue

        # Lazy base64 encode (only computed when SSE subscriber exists)
        if payload["_jpeg_b64"] is None:
            payload["_jpeg_b64"] = base64.b64encode(payload["jpeg"]).decode("ascii")

        frame = payload["frame"]

        # Build JSON event
        event_data = {
            "frame": payload["_jpeg_b64"],
            "detections": payload["detections"],
            "timestamp": payload["timestamp"],
            "camera_id": camera_id,
            "width": frame.shape[1],
            "height": frame.shape[0],
            "frame_number": payload["frame_number"],
        }

        try:
            msg = (
                f"event: frame\n"
                f"data: {json.dumps(event_data)}\n"
                f"\n"
            ).encode("utf-8")
            wfile.write(msg)
            wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            break


# ---------------------------------------------------------------------------
# MJPEG Response Writer
# ---------------------------------------------------------------------------

def write_mjpeg_stream(
    wfile, sub_queue: "queue.Queue",
    stop_event: threading.Event,
) -> None:
    """Write MJPEG multipart/x-mixed-replace stream.

    Detection metadata is embedded as X-Detections header in each part.
    Compatible with <img src="..."> in browsers and most IP camera viewers.
    """
    while not stop_event.is_set():
        try:
            payload = sub_queue.get(timeout=1.0)
        except queue.Empty:
            continue

        jpeg_bytes = payload["jpeg"]
        detections_json = json.dumps(payload["detections"])

        try:
            header = (
                f"{MJPEG_BOUNDARY}\r\n"
                f"Content-Type: image/jpeg\r\n"
                f"Content-Length: {len(jpeg_bytes)}\r\n"
                f"X-Detections: {detections_json}\r\n"
                f"X-Timestamp: {payload['timestamp']}\r\n"
                f"X-Frame-Number: {payload['frame_number']}\r\n"
                f"\r\n"
            ).encode("utf-8")
            wfile.write(header)
            wfile.write(jpeg_bytes)
            wfile.write(b"\r\n")
            wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            break


# ---------------------------------------------------------------------------
# HTTP Handler Helpers
# ---------------------------------------------------------------------------

def handle_stream_request(
    handler, orchestrator, stream_type: str,
) -> None:
    """Handle an incoming streaming HTTP request (SSE or MJPEG).

    Called from the API handler's do_GET method.
    """
    from urllib.parse import urlparse, parse_qs

    parsed = urlparse(handler.path)
    params = parse_qs(parsed.query)
    camera_id = params.get("camera", ["local-0"])[0]
    fps = int(params.get("fps", [str(DEFAULT_FPS)])[0])

    # Get stream manager
    if (not hasattr(orchestrator, "stream_manager")
            or orchestrator.stream_manager is None):
        handler.send_response(503)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Access-Control-Allow-Origin", "*")
        handler.end_headers()
        handler.wfile.write(
            json.dumps({"error": "Streaming not available"}).encode(),
        )
        return

    stream_mgr = orchestrator.stream_manager
    sub_queue, error = stream_mgr.subscribe(camera_id, fps)

    if error:
        handler.send_response(400)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Access-Control-Allow-Origin", "*")
        handler.end_headers()
        handler.wfile.write(json.dumps({"error": error}).encode())
        return

    stop_event = threading.Event()

    if stream_type == "sse":
        handler.send_response(200)
        handler.send_header("Content-Type", "text/event-stream")
        handler.send_header("Cache-Control", "no-cache")
        handler.send_header("Connection", "keep-alive")
        handler.send_header("Access-Control-Allow-Origin", "*")
        handler.send_header("X-Accel-Buffering", "no")  # Disable nginx buffering
        handler.end_headers()

        try:
            write_sse_stream(handler.wfile, sub_queue, camera_id, stop_event)
        finally:
            stop_event.set()
            stream_mgr.unsubscribe(camera_id, sub_queue)

    elif stream_type == "mjpeg":
        handler.send_response(200)
        handler.send_header(
            "Content-Type",
            f"multipart/x-mixed-replace; boundary={MJPEG_BOUNDARY}",
        )
        handler.send_header("Cache-Control", "no-cache")
        handler.send_header("Connection", "keep-alive")
        handler.send_header("Access-Control-Allow-Origin", "*")
        handler.send_header("Pragma", "no-cache")
        handler.send_header("Expires", "Thu, 01 Jan 1970 00:00:00 GMT")
        handler.end_headers()

        try:
            write_mjpeg_stream(handler.wfile, sub_queue, stop_event)
        finally:
            stop_event.set()
            stream_mgr.unsubscribe(camera_id, sub_queue)

    else:
        handler.send_response(400)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Access-Control-Allow-Origin", "*")
        handler.end_headers()
        handler.wfile.write(
            json.dumps({"error": f"Unknown stream type: {stream_type}"}).encode(),
        )



