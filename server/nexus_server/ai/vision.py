# Computer Vision Module — Phase 3
#
# Real camera integration with OpenCV and YOLOv8-nano object detection.
# Implements the "Forgotten USB" use case:
#   User asks "Where's my USB?" → Nexus scans camera feeds → detects USB stick → reports location
#
# Camera sources:
#   - Local webcams (auto-detected via /dev/video* on Linux)
#   - IP cameras (rtsp://, http://mjpg streams)
#   - Remote Nexus node cameras (via mesh/MQTT)
#
# Features:
#   - Auto-detect local cameras
#   - Capture snapshots and frames
#   - YOLOv8 object detection with auto-download model
#   - Item search across all cameras (finds objects by name)
#   - Location caching (remembers where items were last seen)

from __future__ import annotations

import base64
import glob
import json
import logging
import os
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

try:
    import numpy as np
except ImportError:
    np = None  # type: ignore

logger = logging.getLogger("nexus.ai.vision")

# ---- Optional heavy dependencies ----

try:
    import cv2
    CV2_AVAILABLE = True
except ImportError:
    CV2_AVAILABLE = False
    logger.info("OpenCV (cv2) not installed — camera capture unavailable. Install: pip install opencv-python")

try:
    from ultralytics import YOLO
    YOLO_AVAILABLE = True
except ImportError:
    YOLO_AVAILABLE = False
    logger.info("ultralytics not installed — YOLO detection unavailable. Install: pip install ultralytics")

YOLO_MODEL_NAME = "yolov8n.pt"  # Nano model — fast, lightweight, ~6MB
YOLO_MODEL_URL = "https://github.com/ultralytics/assets/releases/download/v0.0.0/yolov8n.pt"

# Common COCO class names YOLO knows about (key ones used for matching)
COCO_CLASSES = {
    0: "person", 41: "cup", 56: "chair", 62: "tv",
    63: "laptop", 64: "mouse", 65: "remote", 66: "keyboard",
    67: "cell phone", 73: "book", 75: "vase", 76: "scissors",
    77: "teddy bear", 78: "hair drier", 79: "toothbrush",
    39: "bottle",
}


# ---------------------------------------------------------------------------
# Vision Module
# ---------------------------------------------------------------------------

class VisionModule:
    """Computer vision engine for locating physical items via connected cameras."""

    # Directories
    SNAPSHOTS_DIR = "snapshots"

    def __init__(self, storage_dir: str = ".nexus") -> None:
        self.storage_dir = storage_dir
        self.vision_dir = os.path.join(storage_dir, "vision")
        self.snapshots_dir = os.path.join(self.vision_dir, self.SNAPSHOTS_DIR)
        os.makedirs(self.snapshots_dir, exist_ok=True)

        # Camera registry
        self.cameras: Dict[str, CameraSource] = {}
        self._cam_lock = threading.Lock()
        self._camera_locks: Dict[str, threading.Lock] = {}  # Per-camera mutex
        self._camera_active: Dict[str, threading.Event] = {}

        # Item location cache
        self.item_cache: Dict[str, Dict[str, Any]] = {}
        self._load_cache()

        # YOLO model + warmup
        self._model: Any = None
        self._model_lock = threading.Lock()
        self._inference_lock = threading.Lock()  # Serialize YOLO inference calls
        self._model_load_attempted: bool = False
        self._warmed_up: bool = False

    # ------------------------------------------------------------------
    # Camera management
    # ------------------------------------------------------------------

    def warmup(self) -> Dict[str, bool]:
        """Pre-load YOLO model and run a dummy inference to prime CUDA/CPU kernels.

        Call during startup so the first user snapshot is fast.
        Returns dict with warmup status."""
        result = {"model_loaded": False, "inference_ok": False}

        # Load model
        model = self._load_model()
        if model is not None:
            result["model_loaded"] = True

            # Run a dummy inference on a tiny tensor to prime the graph
            if np is not None:
                try:
                    dummy = np.zeros((64, 64, 3), dtype=np.uint8)
                    _ = model(dummy, verbose=False)
                    result["inference_ok"] = True
                except Exception as e:
                    logger.debug(f"YOLO warmup inference failed (non-fatal): {e}")

        self._warmed_up = True
        if result["model_loaded"]:
            logger.info(f"YOLO warmup complete (inference: {result['inference_ok']})")
        return result

    def auto_detect_cameras(self) -> int:
        """Scan for local cameras and register them. Returns count found."""
        found = 0

        # Linux: scan /dev/video*
        if os.path.exists("/dev"):
            for video_dev in sorted(glob.glob("/dev/video*")):
                idx = video_dev.replace("/dev/video", "")
                if idx.isdigit():
                    self.register_camera(
                        camera_id=f"local-{idx}",
                        source=str(int(idx)),
                        name=f"Local Camera {idx}",
                        location="Local",
                        camera_type="webcam",
                    )
                    found += 1

        # Windows: try camera indices 0-3
        if CV2_AVAILABLE and found == 0:
            for idx in range(3):
                cap = cv2.VideoCapture(idx)
                if cap.isOpened():
                    self.register_camera(
                        camera_id=f"local-{idx}",
                        source=str(idx),
                        name=f"Webcam {idx}",
                        location="Local",
                        camera_type="webcam",
                    )
                    cap.release()
                    found += 1

        # Create per-camera locks for registered cameras
        with self._cam_lock:
            for cid in self.cameras:
                if cid not in self._camera_locks:
                    self._camera_locks[cid] = threading.Lock()

        if found > 0:
            logger.info(f"Auto-detected {found} local camera(s)")
        else:
            logger.debug("No local cameras detected")

        return found

    def register_camera(
        self,
        camera_id: str,
        source: str,            # Camera index ("0") or URL ("rtsp://...")
        name: str = "",
        location: str = "",
        camera_type: str = "webcam",
    ) -> None:
        """Register a camera for vision queries."""
        camera = CameraSource(
            id=camera_id,
            source=source,
            name=name or camera_id,
            location=location,
            camera_type=camera_type,
        )
        with self._cam_lock:
            self.cameras[camera_id] = camera
            self._camera_active[camera_id] = threading.Event()
            self._camera_locks[camera_id] = threading.Lock()
        logger.info(f"Camera registered: {camera_id} ({camera_type}) at {location}")

    def remove_camera(self, camera_id: str) -> bool:
        with self._cam_lock:
            if camera_id in self.cameras:
                del self.cameras[camera_id]
                self._camera_active.pop(camera_id, None)
                self._camera_locks.pop(camera_id, None)
                return True
        return False

    def list_cameras(self) -> List[Dict[str, Any]]:
        with self._cam_lock:
            camera_snapshots = list(self.cameras.values())
        # Check availability outside the lock (can be slow)
        return [
            {
                "id": c.id,
                "name": c.name,
                "location": c.location,
                "type": c.camera_type,
                "source": _mask_source(c.source),
                "available": self._is_camera_available(c),
            }
            for c in camera_snapshots
        ]

    def get_camera_source(self, camera_id: str) -> Optional[str]:
        """Public accessor: get the raw source string for a camera.

        Returns None if camera not registered.
        Used by streaming module to open cameras directly.
        """
        with self._cam_lock:
            camera = self.cameras.get(camera_id)
            return camera.source if camera else None

    def acquire_camera_lock(self, camera_id: str) -> Optional[threading.Lock]:
        """Get the per-camera lock for external use (e.g., streaming).

        Returns the lock if the camera is registered, None otherwise.
        Caller MUST release any acquired resources and honor the lock.
        """
        with self._cam_lock:
            if camera_id in self._camera_locks:
                return self._camera_locks[camera_id]
        return None

    def is_camera_registered(self, camera_id: str) -> bool:
        """Fast check if a camera is registered (does not open the device)."""
        with self._cam_lock:
            return camera_id in self.cameras

    def _is_camera_available(self, camera: CameraSource) -> bool:
        """Check if a camera is currently accessible."""
        if not CV2_AVAILABLE:
            return False
        cap = _open_camera(camera.source)
        if cap is not None:
            cap.release()
            return True
        return False

    # ------------------------------------------------------------------
    # Snapshot
    # ------------------------------------------------------------------

    def capture_snapshot(
        self, camera_id: str, save: bool = True,
    ) -> Optional[Dict[str, Any]]:
        """Capture a still frame from a camera. Returns full base64 JPEG + metadata."""
        with self._cam_lock:
            camera = self.cameras.get(camera_id)
            cam_lock = self._camera_locks.get(camera_id)
        if not camera:
            return {"error": f"Camera '{camera_id}' not found"}

        if not CV2_AVAILABLE:
            return {"error": "OpenCV not installed (pip install opencv-python)"}

        # Use per-camera lock to prevent concurrent access
        if cam_lock is None:
            cam_lock = threading.Lock()
            # Store it back so future callers share the same lock
            with self._cam_lock:
                if camera_id not in self._camera_locks:
                    self._camera_locks[camera_id] = cam_lock

        with cam_lock:
            return self._capture_snapshot_impl(camera, save)

    def _capture_snapshot_impl(
        self, camera: CameraSource, save: bool,
    ) -> Dict[str, Any]:
        """Internal snapshot — caller must hold per-camera lock."""
        cap = _open_camera(camera.source)
        if cap is None:
            return {"error": f"Cannot open camera: {camera.source}"}

        try:
            # Discard warmup frames (USB cameras need 2-3 frames to adjust exposure)
            for _ in range(2):
                cap.read()

            ret, frame = cap.read()
            if not ret or frame is None:
                return {"error": "Failed to capture frame after warmup"}

            # Encode as JPEG
            _, jpeg = cv2.imencode(".jpg", frame)
            jpeg_b64 = base64.b64encode(jpeg).decode("ascii")

            # Save to disk if requested
            filepath = ""
            if save:
                timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
                filename = f"{camera.id}-{timestamp}.jpg"
                filepath = os.path.join(self.snapshots_dir, filename)
                cv2.imwrite(filepath, frame)

            return {
                "camera_id": camera.id,
                "camera_name": camera.name,
                "location": camera.location,
                "timestamp": time.time(),
                "image_base64": jpeg_b64,  # Full base64 — the real image!
                "image_size": f"{frame.shape[1]}x{frame.shape[0]}",
                "filepath": filepath,
                "detections": self._detect_objects(frame),
            }
        finally:
            cap.release()

    def capture_snapshot_raw(
        self, camera_id: str,
    ) -> Optional[bytes]:
        """Capture a snapshot and return raw JPEG bytes (for dedicated image endpoint)."""
        with self._cam_lock:
            camera = self.cameras.get(camera_id)
            cam_lock = self._camera_locks.get(camera_id)
        if not camera:
            return None

        if cam_lock is None:
            cam_lock = threading.Lock()
            # Store it back so future callers share the same lock
            with self._cam_lock:
                if camera_id not in self._camera_locks:
                    self._camera_locks[camera_id] = cam_lock

        with cam_lock:
            cap = _open_camera(camera.source)
            if cap is None:
                return None
            try:
                for _ in range(2):
                    cap.read()
                ret, frame = cap.read()
                if not ret or frame is None:
                    return None
                _, jpeg = cv2.imencode(".jpg", frame)
                return jpeg.tobytes()
            finally:
                cap.release()

    # ------------------------------------------------------------------
    # Object detection
    # ------------------------------------------------------------------

    def _detect_objects(self, frame: "np.ndarray") -> List[Dict[str, Any]]:
        """Run YOLO object detection on a frame. Thread-safe via inference lock."""
        if not YOLO_AVAILABLE:
            return []

        model = self._load_model()
        if model is None:
            return []

        with self._inference_lock:
            try:
                results = model(frame, verbose=False)
                detections = []

                for result in results:
                    boxes = result.boxes
                    if boxes is None:
                        continue

                    for box in boxes:
                        cls_id = int(box.cls[0]) if len(box.cls) > 0 else -1
                        conf = float(box.conf[0]) if len(box.conf) > 0 else 0.0
                        label = COCO_CLASSES.get(cls_id, f"class_{cls_id}")

                        if conf >= 0.3:  # Confidence threshold
                            x1, y1, x2, y2 = box.xyxy[0].tolist()
                            detections.append({
                                "label": label,
                                "confidence": round(conf, 2),
                                "bbox": {
                                    "x": round(x1), "y": round(y1),
                                    "w": round(x2 - x1), "h": round(y2 - y1),
                                },
                            })

                return sorted(detections, key=lambda d: -d["confidence"])
            except Exception as e:
                logger.warning(f"YOLO detection failed: {e}")
                return []

    def _load_model(self):
        """Lazy-load YOLO model with auto-download. Only attempts once."""
        if self._model is not None:
            return self._model

        with self._model_lock:
            if self._model is not None:
                return self._model

            # Avoid infinite retries if load failed
            if self._model_load_attempted:
                return None
            self._model_load_attempted = True

            if not YOLO_AVAILABLE:
                return None

            model_path = os.path.join(self.vision_dir, YOLO_MODEL_NAME)
            try:
                if not os.path.exists(model_path):
                    logger.info(f"Downloading YOLOv8-nano model to {model_path}...")
                self._model = YOLO(YOLO_MODEL_NAME)
                logger.info("YOLOv8-nano model loaded")
            except Exception as e:
                logger.warning(f"Failed to load YOLO model: {e}")
                self._model = None
                self._model_load_attempted = False  # Allow retry on next attempt

            return self._model

    # ------------------------------------------------------------------
    # Item location (The "Forgotten USB" use case)
    # ------------------------------------------------------------------

    def locate_item(self, item_description: str) -> Dict[str, Any]:
        """
        Search all cameras for a physical item.

        Pipeline:
        1. Check cache first
        2. Capture frame from each camera
        3. Run YOLO detection
        4. Match detected objects against description
        5. Return location if found
        """
        cache_key = item_description.lower().strip()

        # Check cache
        if cache_key in self.item_cache:
            cached = self.item_cache[cache_key]
            age = time.time() - cached.get("timestamp", 0)
            if age < 86400:  # Cache valid for 24 hours
                logger.info(f"Item '{item_description}' found in cache (age: {age:.0f}s)")
                return {
                    **cached,
                    "source": "cache",
                    "cameras_searched": 0,  # Explicit: no cameras were re-searched
                }

        with self._cam_lock:
            camera_snapshots = list(self.cameras.items())

        active_cameras = [
            (cid, c) for cid, c in camera_snapshots
            if self._is_camera_available(c)
        ]

        if not active_cameras:
            return {
                "found": False,
                "item": item_description,
                "reason": "No connected cameras available.",
                "suggestion": "Add a webcam or IP camera. Use /api/vision/register to add one.",
            }

        # Build search terms from description
        search_terms = _extract_search_terms(item_description)

        for camera_id, camera in active_cameras:
            result = self._search_camera_feed(camera, search_terms, cache_key)
            if result and result.get("found"):
                # Cache the result
                self.item_cache[cache_key] = {
                    **result,
                    "timestamp": time.time(),
                    "item": item_description,
                }
                self._save_cache()
                return result

        return {
            "found": False,
            "item": item_description,
            "reason": f"'{item_description}' not visible on any camera.",
            "cameras_searched": len(active_cameras),
            "suggestion": "Check if the item is within camera view or try a different description.",
        }

    def query_cameras(self, query: str) -> List[Dict[str, Any]]:
        """Run a natural-language query across all cameras."""
        results = []

        with self._cam_lock:
            cameras = list(self.cameras.items())

        for camera_id, camera in cameras:
            cap = _open_camera(camera.source)
            if cap is None:
                results.append({
                    "camera_id": camera_id,
                    "name": camera.name,
                    "location": camera.location,
                    "error": "Camera unavailable",
                })
                continue

            try:
                ret, frame = cap.read()
                if not ret:
                    results.append({
                        "camera_id": camera_id,
                        "error": "Failed to read frame",
                    })
                    continue

                detections = self._detect_objects(frame)
                object_counts = {}
                for d in detections:
                    label = d["label"]
                    object_counts[label] = object_counts.get(label, 0) + 1

                results.append({
                    "camera_id": camera_id,
                    "name": camera.name,
                    "location": camera.location,
                    "query": query,
                    "objects_detected": object_counts,
                    "total_objects": len(detections),
                    "top_detections": detections[:5],
                })
            except Exception as e:
                results.append({
                    "camera_id": camera_id,
                    "error": str(e),
                })
            finally:
                cap.release()

        return results

    def _search_camera_feed(
        self, camera: CameraSource, search_terms: List[str], cache_key: str,
    ) -> Optional[Dict[str, Any]]:
        """Search a single camera feed for matching objects."""
        if not CV2_AVAILABLE:
            return None

        cap = _open_camera(camera.source)
        if cap is None:
            return None

        try:
            # Capture a few frames for better detection
            detections_all: List[Dict] = []
            for _ in range(3):
                ret, frame = cap.read()
                if not ret:
                    continue
                dets = self._detect_objects(frame)
                detections_all.extend(dets)

            if not detections_all:
                return {
                    "found": False,
                    "camera_id": camera.id,
                    "location": camera.location,
                    "objects_detected": 0,
                }

            # Match search terms against detected labels
            for detection in detections_all:
                label = detection["label"].lower()
                for term in search_terms:
                    if term in label or label in term:
                        return {
                            "found": True,
                            "camera_id": camera.id,
                            "camera_name": camera.name,
                            "location": camera.location,
                            "matched_label": detection["label"],
                            "confidence": detection["confidence"],
                            "all_detections": detections_all[:10],
                        }

            return {
                "found": False,
                "camera_id": camera.id,
                "location": camera.location,
                "objects_detected": len(detections_all),
                "labels_seen": list(set(d["label"] for d in detections_all)),
            }
        finally:
            cap.release()

    # ------------------------------------------------------------------
    # Cache persistence
    # ------------------------------------------------------------------

    def _save_cache(self) -> None:
        # Convert datetime objects to strings for JSON
        cache_file = os.path.join(self.vision_dir, "item_cache.json")
        try:
            with open(cache_file, "w", encoding="utf-8") as f:
                json.dump(self.item_cache, f, indent=2, default=str)
        except Exception as e:
            logger.warning(f"Failed to save vision cache: {e}")

    def _load_cache(self) -> None:
        cache_file = os.path.join(self.vision_dir, "item_cache.json")
        if os.path.exists(cache_file):
            try:
                with open(cache_file, "r", encoding="utf-8") as f:
                    self.item_cache = json.load(f)
            except Exception:
                self.item_cache = {}

    # ------------------------------------------------------------------
    # Health
    # ------------------------------------------------------------------

    def detect_objects(self, frame: "np.ndarray") -> List[Dict[str, Any]]:
        """Public API: run YOLO object detection on a frame.

        Used by streaming module and other external consumers.
        """
        return self._detect_objects(frame)

    def status(self) -> Dict[str, Any]:
        with self._cam_lock:
            camera_snapshots = list(self.cameras.values())
        return {
            "opencv_available": CV2_AVAILABLE,
            "yolo_available": YOLO_AVAILABLE,
            "yolo_loaded": self._model is not None,
            "yolo_warmed_up": self._warmed_up,
            "cameras_registered": len(self.cameras),
            "cameras_available": sum(
                1 for c in camera_snapshots
                if self._is_camera_available(c)
            ),
            "cached_items": len(self.item_cache),
        }


# ---------------------------------------------------------------------------
# Camera source
# ---------------------------------------------------------------------------

class CameraSource:
    __slots__ = ("id", "source", "name", "location", "camera_type")

    def __init__(self, id: str, source: str, name: str,
                 location: str, camera_type: str):
        self.id = id
        self.source = source          # "0", "/dev/video0", "rtsp://..."
        self.name = name
        self.location = location
        self.camera_type = camera_type


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def open_camera(source: str):
    """Open a camera by source string. Supports: index ("0"), device path, URL."""
    if not CV2_AVAILABLE:
        return None

    # Try as integer index first
    try:
        idx = int(source)
        return cv2.VideoCapture(idx)
    except ValueError:
        pass

    # Try as device path
    if source.startswith("/dev/"):
        return cv2.VideoCapture(source)

    # Try as URL (rtsp, http, etc.)
    if source.startswith(("rtsp://", "http://", "https://")):
        cap = cv2.VideoCapture(source)
        cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        # Set read timeout for IP cameras (5 seconds)
        if hasattr(cv2, 'CAP_PROP_OPEN_TIMEOUT_MSEC'):
            cap.set(cv2.CAP_PROP_OPEN_TIMEOUT_MSEC, 5000)
        return cap

    # Fallback: try as name
    return cv2.VideoCapture(source)


# Backward-compatible alias
_open_camera = open_camera


def _extract_search_terms(description: str) -> List[str]:
    """Extract useful search terms from a natural-language description."""
    desc = description.lower().strip()

    # Known item mappings
    MAPPINGS = {
        "usb": ["usb", "flash drive", "thumb drive", "stick"],
        "phone": ["phone", "cell phone", "smartphone", "mobile"],
        "laptop": ["laptop", "computer", "notebook"],
        "keyboard": ["keyboard"],
        "mouse": ["mouse"],
        "wallet": ["wallet", "purse"],
        "keys": ["keys", "keychain"],
        "book": ["book"],
        "bottle": ["bottle", "water bottle"],
        "remote": ["remote", "tv remote"],
        "person": ["person", "people", "someone"],
        "cup": ["cup", "mug"],
        "chair": ["chair"],
        "tv": ["tv", "television"],
        "bag": ["backpack", "bag", "handbag", "suitcase"],
        "car": ["car", "vehicle"],
    }

    # Check descriptions containing known items - collect ALL matches
    terms = []
    for key, mappings in MAPPINGS.items():
        if key in desc or any(m in desc for m in mappings):
            terms.extend(mappings)

    if not terms:
        # Just use the raw description as a term
        terms = [desc]

    return terms


def _mask_source(source: str) -> str:
    """Mask sensitive source URLs for API responses."""
    if source.startswith(("rtsp://", "http://")):
        return f"{source[:20]}***"
    return source
