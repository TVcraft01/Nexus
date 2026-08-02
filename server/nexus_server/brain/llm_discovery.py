# LLM Backend Discovery & Model Recommendation
#
# Ported from the existing llm_discovery.py.
# Auto-discovers local LLM servers (Ollama, LM Studio, llama.cpp).

from __future__ import annotations

import json
import logging
import os
import re
import socket
from dataclasses import dataclass
from typing import Any, Dict, List, Optional
from urllib import error as urllib_error
from urllib import request as urllib_request

logger = logging.getLogger("nexus.brain.discovery")


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
]


def recommend_model(total_ram_bytes: Optional[int] = None) -> ModelRecommendation:
    """Recommend a sensible local model given available RAM."""
    try:
        import psutil
        ram = total_ram_bytes or psutil.virtual_memory().total
    except ImportError:
        ram = total_ram_bytes or (8 * 1024**3)  # default 8GB

    ram_gb = ram / (1024**3)
    if ram_gb < 4:
        return ModelRecommendation(2, f"Only {ram_gb:.1f} GB RAM. A 1-2B model is safe.",
                                   ["Llama-3.2-1B-Instruct", "Qwen2.5-1.5B-Instruct"])
    if ram_gb < 8:
        return ModelRecommendation(4, f"{ram_gb:.1f} GB RAM. A 3-4B model fits.",
                                   ["Llama-3.2-3B-Instruct", "Phi-3.5-mini"])
    if ram_gb < 16:
        return ModelRecommendation(8, f"{ram_gb:.1f} GB RAM. A 7-8B model is comfortable.",
                                   ["Llama-3.1-8B-Instruct", "Qwen2.5-7B-Instruct"])
    return ModelRecommendation(14, f"{ram_gb:.1f} GB RAM. Run 13-14B+ models.",
                               ["Llama-3.1-8B-Instruct", "Qwen2.5-14B-Instruct"])


def discover_backends() -> List[DiscoveredBackend]:
    discovered: List[DiscoveredBackend] = []
    for backend in _KNOWN_BACKENDS:
        try:
            port = int(backend.base_url.rsplit(":", 1)[-1])
        except ValueError:
            continue
        if not _is_port_open("127.0.0.1", port):
            continue
        data = _fetch_json(backend.models_endpoint)
        if data is None:
            continue
        models = _extract_models(backend, data)
        recommendation = recommend_model()
        selected = _pick_model(models, recommendation)
        discovered.append(DiscoveredBackend(backend=backend, models=models, selected_model=selected))
        logger.info(f"Found backend {backend.name}: {models}")
    return discovered


def best_backend(discovered: Optional[List[DiscoveredBackend]] = None) -> Optional[DiscoveredBackend]:
    backends = discovered or discover_backends()
    if not backends:
        return None
    for b in backends:
        if b.models:
            return b
    return backends[0] if backends else None


def backend_status_message(backend: Optional[DiscoveredBackend] = None) -> str:
    if not backend:
        return "No local LLM server. Install Ollama (ollama.com) or start llama.cpp."
    model = backend.selected_model or (backend.models[0] if backend.models else "unknown")
    return f"Using {backend.backend.name} with {model}."


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
            return json.loads(resp.read().decode("utf-8"))
    except Exception:
        return None


def _extract_models(backend: LLMBackend, data: Dict[str, Any]) -> List[str]:
    if backend.name == "Ollama":
        return [m.get("name", "") for m in data.get("models", []) if m.get("name")]
    return [m.get("id", "") for m in data.get("data", []) if isinstance(m, dict) and m.get("id")]


def _pick_model(models: List[str], rec: ModelRecommendation) -> Optional[str]:
    for model in models:
        match = re.search(r"(\d+)(?:\.[0-9])?[bB]", model)
        if match and int(match.group(1)) <= rec.max_billions:
            return model
    return models[0] if models else None
