"""Offline desktop voice input using Vosk.

Provides privacy-first speech-to-text for the Nexus desktop app.  The Vosk
model is downloaded on first use and cached under the storage directory.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import tempfile
import urllib.request
import zipfile
from typing import Callable, Optional

logger = logging.getLogger(__name__)

VOSK_MODEL_URL = "https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip"
VOSK_MODEL_NAME = "vosk-model-small-en-us-0.15"
DEFAULT_SAMPLE_RATE = 16000
DEFAULT_CHUNK_SIZE = 8000


def _ensure_model(storage_dir: str) -> Optional[str]:
    """Return the path to the cached Vosk model, downloading it if needed."""
    cache_dir = os.path.join(storage_dir, "vosk")
    model_dir = os.path.join(cache_dir, VOSK_MODEL_NAME)
    ready_marker = os.path.join(cache_dir, f"{VOSK_MODEL_NAME}.ready")
    if os.path.isdir(model_dir) and os.path.isfile(ready_marker):
        return model_dir

    os.makedirs(cache_dir, exist_ok=True)
    try:
        logger.info("Downloading Vosk model for offline speech recognition...")
        with tempfile.TemporaryDirectory(dir=cache_dir) as tmpdir:
                zip_path = os.path.join(tmpdir, "model.zip")
                urllib.request.urlretrieve(VOSK_MODEL_URL, zip_path)
                with zipfile.ZipFile(zip_path, "r") as zip_ref:
                    zip_ref.extractall(tmpdir)
                extracted = [p for p in os.listdir(tmpdir) if os.path.isdir(os.path.join(tmpdir, p)) and p != "__pycache__"]
                if not extracted:
                    raise RuntimeError("Model zip did not contain a model directory")
                source_dir = os.path.join(tmpdir, extracted[0])
                if os.path.isdir(model_dir):
                    shutil.rmtree(model_dir)
                shutil.move(source_dir, model_dir)

        with open(ready_marker, "w", encoding="utf-8") as f:
            f.write("ready")
        return model_dir
    except Exception as exc:
        logger.error("Failed to download Vosk model: %s", exc)
        return None


def is_available() -> bool:
    """Return True if Vosk and sounddevice can be imported."""
    try:
        import sounddevice as sd  # noqa: F401
        from vosk import KaldiRecognizer, Model  # noqa: F401
        return True
    except Exception:
        return False


def listen_for_speech(
    storage_dir: str,
    duration_s: int = 5,
    sample_rate: int = DEFAULT_SAMPLE_RATE,
    chunk_size: int = DEFAULT_CHUNK_SIZE,
    should_stop: Optional[Callable[[], bool]] = None,
) -> Optional[str]:
    """Record audio from the default microphone and return the transcript.

    Returns None if voice recognition is unavailable, the model cannot be
    downloaded, or no speech is detected.

    If ``should_stop`` is provided, it is called between chunks and stops
    recording early when it returns True.
    """
    try:
        import sounddevice as sd
        from vosk import KaldiRecognizer, Model
    except ImportError as exc:
        logger.warning("Voice dependencies missing: %s", exc)
        return None

    model_path = _ensure_model(storage_dir)
    if not model_path:
        return None

    try:
        model = Model(model_path)
        recognizer = KaldiRecognizer(model, sample_rate)
        recognizer.SetWords(True)

        text: Optional[str] = None
        with sd.RawInputStream(
            samplerate=sample_rate,
            blocksize=chunk_size,
            dtype="int16",
            channels=1,
        ) as stream:
            total_chunks = max(1, int(duration_s * sample_rate / chunk_size))
            for _ in range(total_chunks):
                if should_stop and should_stop():
                    break
                data, _ = stream.read(chunk_size)
                if recognizer.AcceptWaveform(data.tobytes()):
                    result = json.loads(recognizer.Result())
                    text = result.get("text") or text
            final = json.loads(recognizer.FinalResult())
            text = final.get("text") or text
        return text
    except Exception as exc:
        logger.error("Voice recognition failed: %s", exc)
        return None
