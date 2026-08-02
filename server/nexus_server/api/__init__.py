# API Server - REST + WebSocket interface
#
# Provides the external interface for Nexus clients (desktop, CLI, web).

from __future__ import annotations

import json
import logging
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from typing import Optional
from urllib.parse import urlparse, parse_qs

logger = logging.getLogger("nexus.api")


class _ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    """Threading HTTP server — handles concurrent streaming connections."""
    daemon_threads = True


class _APIHandler(BaseHTTPRequestHandler):
    orchestrator = None

    def do_GET(self):
        if self.path == "/health":
            self._json_response({"status": "ok", "version": "0.3.0"})
        elif self.path == "/api/nodes":
            nodes = self.orchestrator.discovered_nodes if self.orchestrator else []
            self._json_response([{
                "id": n.id, "name": n.name, "address": n.address,
                "is_paired": n.is_paired,
            } for n in nodes])
        elif self.path == "/api/status":
            self._json_response({
                "node_id": self.orchestrator.node_id if self.orchestrator else "?",
                "chat_status": self.orchestrator.chat_status() if self.orchestrator else "offline",
            })
        elif self.path == "/api/routines":
            routines = self.orchestrator.get_todays_routine() if self.orchestrator else []
            self._json_response(routines)
        elif self.path == "/api/suggestions":
            suggestions = self.orchestrator.get_proactive_suggestions() if self.orchestrator else []
            self._json_response(suggestions)
        # Phase 2: Task execution
        elif self.path == "/api/tasks":
            tasks = self.orchestrator.list_tasks() if self.orchestrator else []
            self._json_response(tasks)
        elif self.path == "/api/network":
            summary = self.orchestrator.get_network_summary() if self.orchestrator else {}
            self._json_response(summary)
        elif self.path == "/api/devices/capabilities":
            caps = self.orchestrator.get_device_capabilities() if self.orchestrator else {}
            self._json_response(caps)
        # Phase 3: Vision
        elif self.path == "/api/vision/cameras":
            cameras = self.orchestrator.list_cameras() if self.orchestrator else []
            self._json_response(cameras)
        elif self.path == "/api/vision/status":
            status = self.orchestrator.vision_status() if self.orchestrator else {}
            self._json_response(status)
        elif self.path.startswith("/api/vision/snapshot/image"):
            # Raw JPEG endpoint: GET /api/vision/snapshot/image?camera=local-0
            parsed = urlparse(self.path)
            params = parse_qs(parsed.query)
            camera_id = params.get("camera", ["local-0"])[0]
            jpeg_bytes = self.orchestrator.snapshot_image(camera_id) if self.orchestrator else None
            if jpeg_bytes:
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Content-Length", str(len(jpeg_bytes)))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Cache-Control", "no-cache")
                self.end_headers()
                self.wfile.write(jpeg_bytes)
            else:
                self._json_response({"error": "Failed to capture image"})
        elif self.path == "/api/vision/warmup":
            result = self.orchestrator.warmup_vision() if self.orchestrator else {}
            self._json_response(result)
        # Phase 4: Proactive reminders and insights
        elif self.path == "/api/reminders":
            reminders = self.orchestrator.get_reminders() if self.orchestrator else []
            self._json_response(reminders)
        elif self.path == "/api/insights":
            insights = self.orchestrator.get_insights() if self.orchestrator else []
            self._json_response(insights)
        elif self.path == "/api/streaks":
            streaks = self.orchestrator.get_streaks() if self.orchestrator else []
            self._json_response(streaks)
        elif self.path == "/api/routines/predict":
            prediction = self.orchestrator.predict_next() if self.orchestrator else None
            self._json_response(prediction or {})
        # Real-time streaming (SSE + MJPEG)
        elif self.path.startswith("/api/vision/stream/mjpeg"):
            self._handle_stream("mjpeg")
        elif self.path.startswith("/api/vision/streams"):
            # List active streams
            if self.orchestrator and self.orchestrator.stream_manager:
                streams = self.orchestrator.stream_manager.list_streams()
                self._json_response(streams)
            else:
                self._json_response([])
        elif self.path.startswith("/api/vision/stream"):
            self._handle_stream("sse")
        elif self.path == "/api/mqtt/enable":
            status = self.orchestrator.mqtt_status() if self.orchestrator else {}
            self._json_response(status)
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path == "/api/command":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)
            command = data.get("command", "")
            result = self.orchestrator.execute_command(command)
            self._json_response({
                "success": result.success,
                "message": result.message,
                "action": result.action.name,
            })
        elif self.path == "/api/chat":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)
            message = data.get("message", "")
            result = self.orchestrator.chat(message)
            self._json_response({
                "text": result.text,
                "requires_confirmation": result.requires_confirmation,
                "action": result.action.name if result.action else None,
            })
        elif self.path == "/api/teach":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)
            success = self.orchestrator.teach_rule(
                data.get("input", ""),
                data.get("action", ""),
                data.get("payload", ""),
            )
            self._json_response({"success": success})
        elif self.path == "/api/vision/locate":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)
            result = self.orchestrator.locate_item(data.get("item", ""))
            self._json_response(result)
        # Phase 2: Distributed execution
        elif self.path == "/api/tasks/submit":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)
            result = self.orchestrator.submit_task(
                data.get("description", ""),
                data.get("workload_type", "command"),
                data.get("priority", 5),
            )
            self._json_response(result)
        elif self.path.startswith("/api/tasks/"):
            task_id = self.path.split("/api/tasks/")[-1]
            task = self.orchestrator.get_task(task_id)
            if task:
                self._json_response(task)
            else:
                self._json_response({"error": "Task not found"})
        elif self.path == "/api/mqtt/enable":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)
            success = self.orchestrator.enable_mqtt(
                data.get("broker", "localhost"),
                data.get("port", 1883),
            )
            self._json_response({"success": success})
        # Phase 3: Vision
        elif self.path == "/api/vision/snapshot":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)
            result = self.orchestrator.snapshot_camera(data.get("camera_id", ""))
            self._json_response(result)
        elif self.path == "/api/vision/search":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)
            result = self.orchestrator.search_cameras(data.get("query", ""))
            self._json_response(result)
        elif self.path == "/api/vision/register":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)
            self.orchestrator.vision.register_camera(
                camera_id=data.get("camera_id", ""),
                source=data.get("source", ""),
                name=data.get("name", ""),
                location=data.get("location", ""),
                camera_type=data.get("camera_type", "webcam"),
            )
            self._json_response({"success": True})
        # Phase 4: Dismiss reminder
        elif self.path == "/api/reminders/dismiss":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)
            ok = self.orchestrator.dismiss_reminder(data.get("index", -1))
            self._json_response({"success": ok})
        elif self.path == "/api/reminders/test":
            ok = self.orchestrator.send_test_reminder()
            self._json_response({"sent": ok})
        else:
            self.send_error(404)

    def do_OPTIONS(self):
        """Handle CORS preflight requests."""
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def _handle_stream(self, stream_type: str) -> None:
        """Handle a streaming request (SSE or MJPEG). Delegates to streaming module."""
        try:
            from nexus_server.api.streaming import handle_stream_request
            handle_stream_request(self, self.orchestrator, stream_type)
        except ImportError as e:
            self.send_error(500, f"Streaming module not available: {e}")
        except Exception as e:
            logger.exception(f"Stream error ({stream_type})")
            try:
                self.send_error(500, str(e))
            except Exception:
                pass  # Connection already closed

    def _json_response(self, data):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def log_message(self, format, *args):
        pass  # Suppress default logging; use our logger


def start_api_server(orchestrator, port: int = 9090) -> _ThreadingHTTPServer:
    _APIHandler.orchestrator = orchestrator
    server = _ThreadingHTTPServer(("0.0.0.0", port), _APIHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    logger.info(f"Nexus API server started on http://localhost:{port} (threading)")
    return server
