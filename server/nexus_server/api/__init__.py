# API Server - REST + WebSocket interface
#
# Provides the external interface for Nexus clients (desktop, CLI, web).

from __future__ import annotations

import json
import logging
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Optional

logger = logging.getLogger("nexus.api")


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
        else:
            self.send_error(404)

    def _json_response(self, data):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def log_message(self, format, *args):
        pass  # Suppress default logging; use our logger


def start_api_server(orchestrator, port: int = 9090) -> HTTPServer:
    _APIHandler.orchestrator = orchestrator
    server = HTTPServer(("0.0.0.0", port), _APIHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    logger.info(f"Nexus API server started on http://localhost:{port}")
    return server
