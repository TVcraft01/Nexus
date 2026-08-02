"""Local LLM backend discovery and model recommendation.

Nexus can talk to any OpenAI-compatible local server.  This module discovers
which one is available, picks a sensible model size for the host hardware,
and returns a configuration the rest of the app can use.
"""

from __future__ import annotations

import json
import logging
import os
import platform
import re
import socket
import subprocess
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple
from urllib import error as urllib_error
from urllib import request as urllib_request

logger = logging.getLogger(__name__)


@dataclass
class LLMBackend:
    name: str
    base_url: str
    chat_endpoint: str
    models_endpoint: str
    health_endpoint: Optional[str] = None


@dataclass
class DiscoveredBackend:
    backend: LLMBackend
    models: List[str]
    selected_model: Optional[str] = None


@dataclass
class ModelRecommendation:
    max_billions: int
    reasoning: str
    examples: List[str]


# Common local backends.  Order matters: first reachable wins unless a later
# one advertises a loaded model.
_KNOWN_BACKENDS: List[LLMBackend] = [
    LLMBackend(
        name="Ollama",
        base_url="http://127.0.0.1:11434",
        chat_endpoint="http://127.0.0.1:11434/v1/chat/completions",
        models_endpoint="http://127.0.0.1:11434/api/tags",
        health_endpoint="http://127.0.0.1:11434/api/tags",
    ),
    LLMBackend(
        name="LM Studio",
        base_url="http://127.0.0.1:1234",
        chat_endpoint="http://127.0.0.1:1234/v1/chat/completions",
        models_endpoint="http://127.0.0.1:1234/v1/models",
    ),
    LLMBackend(
        name="llama.cpp",
        base_url="http://127.0.0.1:8080",
        chat_endpoint="http://127.0.0.1:8080/v1/chat/completions",
        models_endpoint="http://127.0.0.1:8080/v1/models",
    ),
    LLMBackend(
        name="generic",
        base_url="http://127.0.0.1:8080",
        chat_endpoint="http://127.0.0.1:8080/v1/chat/completions",
        models_endpoint="http://127.0.0.1:8080/v1/models",
    ),
]


def _total_ram_bytes() -> Optional[int]:
    """Best-effort total RAM in bytes."""
    try:
        if os.path.exists("/proc/meminfo"):
            with open("/proc/meminfo", "r", encoding="utf-8") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        kb = int(line.split()[1])
                        return kb * 1024
    except Exception:
        pass
    try:
        import psutil  # type: ignore

        return psutil.virtual_memory().total
    except Exception:
        pass
    return None


def _cpu_count() -> int:
    try:
        return os.cpu_count() or 1
    except Exception:
        return 1


def recommend_model(total_ram_bytes: Optional[int] = None) -> ModelRecommendation:
    """Recommend the largest sensible local model given available RAM."""
    ram = total_ram_bytes or _total_ram_bytes()
    if ram is None:
        return ModelRecommendation(
            max_billions=3,
            reasoning="Could not detect RAM; defaulting to a small, safe model.",
            examples=["Llama-3.2-3B-Instruct", "Qwen2.5-3B-Instruct"],
        )

    ram_gb = ram / (1024 ** 3)

    if ram_gb < 4:
        return ModelRecommendation(
            max_billions=2,
            reasoning=f"Only {ram_gb:.1f} GB RAM available. A 1-2B model is the safe choice.",
            examples=["Llama-3.2-1B-Instruct", "Qwen2.5-1.5B-Instruct"],
        )
    if ram_gb < 8:
        return ModelRecommendation(
            max_billions=4,
            reasoning=f"{ram_gb:.1f} GB RAM available. A 3-4B model fits well.",
            examples=["Llama-3.2-3B-Instruct", "Phi-3.5-mini"],
        )
    if ram_gb < 16:
        return ModelRecommendation(
            max_billions=8,
            reasoning=f"{ram_gb:.1f} GB RAM available. A 7-8B model is comfortable.",
            examples=["Llama-3.1-8B-Instruct", "Qwen2.5-7B-Instruct"],
        )
    return ModelRecommendation(
        max_billions=14,
        reasoning=f"{ram_gb:.1f} GB RAM available. You can run a 13-14B model or larger.",
        examples=["Llama-3.1-8B-Instruct", "Qwen2.5-14B-Instruct"],
    )


def _is_port_open(host: str, port: int, timeout: float = 0.5) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except Exception:
        return False


def _fetch_json(url: str, timeout: float = 1.0) -> Optional[Dict[str, Any]]:
    try:
        req = urllib_request.Request(url, method="GET")
        req.add_header("Accept", "application/json")
        with urllib_request.urlopen(req, timeout=timeout) as resp:
            data = resp.read()
            if not data:
                return None
            return json.loads(data.decode("utf-8"))
    except (urllib_error.URLError, json.JSONDecodeError, socket.timeout):
        return None


def _ollama_models(data: Dict[str, Any]) -> List[str]:
    models: List[str] = []
    for item in data.get("models", []) or []:
        name = item.get("name") or item.get("model")
        if name:
            models.append(str(name))
    return models


def _openai_models(data: Dict[str, Any]) -> List[str]:
    models: List[str] = []
    choices = data.get("data", []) or []
    for item in choices:
        if isinstance(item, dict):
            name = item.get("id")
            if name:
                models.append(str(name))
    return models


def _extract_model_names(backend: LLMBackend, data: Optional[Dict[str, Any]]) -> List[str]:
    if not data:
        return []
    if backend.name == "Ollama":
        return _ollama_models(data)
    return _openai_models(data)


def discover_backends() -> List[DiscoveredBackend]:
    """Probe known local endpoints and return any that respond."""
    discovered: List[DiscoveredBackend] = []
    for backend in _KNOWN_BACKENDS:
        # Quick port check before doing a full HTTP probe.
        try:
            port = int(backend.base_url.rsplit(":", 1)[-1])
        except ValueError:
            continue
        if not _is_port_open("127.0.0.1", port):
            continue

        data = _fetch_json(backend.models_endpoint)
        if data is None:
            continue

        models = _extract_model_names(backend, data)
        # Prefer a model that matches the recommended size.
        recommendation = recommend_model()
        selected: Optional[str] = None
        for model in models:
            # Extract a rough parameter count, e.g. "8b", "3B".
            match = re.search(r"(\d+)(?:\.[0-9])?(b|B)", model, re.IGNORECASE)
            if match:
                billions = int(match.group(1))
                if billions <= recommendation.max_billions:
                    selected = model
                    break
        if not selected and models:
            selected = models[0]

        discovered.append(DiscoveredBackend(backend=backend, models=models, selected_model=selected))
        logger.info("Discovered backend %s with models: %s", backend.name, models)

    return discovered


def best_backend(discovered: Optional[List[DiscoveredBackend]] = None) -> Optional[DiscoveredBackend]:
    """Return the best discovered backend, or None if nothing is available."""
    backends = discovered or discover_backends()
    if not backends:
        return None
    # Prefer backends that have a model loaded/available.
    for backend in backends:
        if backend.models:
            return backend
    return backends[0]


def backend_status_message(backend: Optional[DiscoveredBackend] = None) -> str:
    if not backend:
        return "No local LLM server detected. Install Ollama or start llama.cpp/LM Studio."
    model = backend.selected_model or (backend.models[0] if backend.models else "unknown")
    return f"Using {backend.backend.name} with model {model}."
