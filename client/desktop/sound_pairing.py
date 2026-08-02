"""Professional sound pairing helpers.

Transmits a numeric PIN as a clean major-7 arpeggio from the desktop's speaker
and listens for the same sequence from a phone's speaker. This is much more
professional than DTMF "phone dial" tones and avoids being mistaken for
someone typing a number.
"""

from __future__ import annotations

import logging
import math
import re
import secrets
from typing import List, Optional, Tuple

import numpy as np

logger = logging.getLogger(__name__)

# C Major 7 chord: clean, pleasant, and distinct from DTMF.
TONE_FREQS = [523, 659, 784, 988]

# Map PIN digits 0-9 to two *distinct* tone indices (1..4 each).
# Using distinct pairs avoids merging consecutive identical tones in the
# decoder, which would otherwise drop digits.
_DIGIT_TO_TONES = [
    (1, 2),  # 0
    (1, 3),  # 1
    (1, 4),  # 2
    (2, 1),  # 3
    (2, 3),  # 4
    (2, 4),  # 5
    (3, 1),  # 6
    (3, 2),  # 7
    (3, 4),  # 8
    (4, 1),  # 9
]


def generate_tone(
    frequency: float,
    duration_s: float,
    sample_rate: int = 44100,
    amplitude: float = 0.5,
) -> np.ndarray:
    t = np.linspace(0, duration_s, int(sample_rate * duration_s), endpoint=False)
    return amplitude * np.sin(2 * math.pi * frequency * t)


def generate_tone_with_envelope(
    frequency: float,
    duration_s: float,
    sample_rate: int = 44100,
    amplitude: float = 0.5,
) -> np.ndarray:
    """Generate a sine tone with a soft attack/decay envelope."""
    samples = generate_tone(frequency, duration_s, sample_rate, amplitude)
    length = len(samples)
    if length == 0:
        return samples
    # Apply a Hann-like window for smooth attack and decay.
    envelope = np.sin(np.linspace(0, math.pi, length)) * 0.85 + 0.15
    return samples * envelope


def generate_pairing_sequence(
    pin: str,
    *,
    tone_duration: float = 0.18,
    gap_duration: float = 0.08,
    sample_rate: int = 44100,
    amplitude: float = 0.5,
) -> Tuple[np.ndarray, int]:
    """Generate a professional pairing waveform for the given digit string.

    Each digit is encoded as two short tones from the C Major 7 chord. Tones use
    a soft attack/decay envelope so the result is a smooth pairing chime, not
    the harsh clicks of typed numbers.
    """
    if not pin:
        return np.array([], dtype=np.float32), sample_rate

    gap_samples = int(sample_rate * gap_duration)
    gap = np.zeros(gap_samples, dtype=np.float32)

    chunks: List[np.ndarray] = []

    # Pleasant lead-in chirp so the listener knows pairing started.
    lead_freqs = np.linspace(523, 988, int(sample_rate * 0.12), endpoint=False)
    chunks.append(generate_sweep(lead_freqs, 0.12, sample_rate, amplitude))
    chunks.append(gap)

    for digit in pin:
        if not digit.isdigit():
            continue
        idx = int(digit)
        for tone_idx in _DIGIT_TO_TONES[idx]:
            freq = TONE_FREQS[tone_idx - 1]
            chunks.append(generate_tone_with_envelope(freq, tone_duration, sample_rate, amplitude).astype(np.float32))
        chunks.append(gap)

    return np.concatenate(chunks), sample_rate


def generate_sweep(
    frequencies: np.ndarray,
    duration_s: float,
    sample_rate: int = 44100,
    amplitude: float = 0.5,
) -> np.ndarray:
    t = np.linspace(0, duration_s, int(sample_rate * duration_s), endpoint=False)
    phase = 2 * math.pi * np.cumsum(frequencies) / sample_rate
    return amplitude * np.sin(phase)


def _goertzel(samples: np.ndarray, frequency: float, sample_rate: int) -> float:
    """Return magnitude of a single frequency component using Goertzel."""
    n = len(samples)
    k = int(0.5 + (n * frequency) / sample_rate)
    w = 2 * math.pi * k / n
    cosine = math.cos(w)
    sine = math.sin(w)
    coeff = 2 * cosine

    s0 = 0.0
    s1 = 0.0
    s2 = 0.0
    for sample in samples:
        s0 = sample + coeff * s1 - s2
        s2 = s1
        s1 = s0

    real = s1 - s2 * cosine
    imag = s2 * sine
    return math.sqrt(real * real + imag * imag)


def detect_tone(samples: np.ndarray, sample_rate: int) -> Optional[int]:
    """Detect which of the four pairing tones is present, or None."""
    if len(samples) == 0:
        return None

    total_energy = np.sum(samples.astype(np.float64) ** 2)
    if total_energy < 1e-4:
        return None

    mags = sorted(
        [(_goertzel(samples, f, sample_rate), idx + 1) for idx, f in enumerate(TONE_FREQS)],
        reverse=True,
    )
    if len(mags) < 2:
        return None
    if mags[0][0] < mags[1][0] * 2.5:
        return None
    return mags[0][1]


def detect_pairing_sequence(
    audio: np.ndarray,
    sample_rate: int = 44100,
    *,
    window_s: float = 0.1,
    step_s: float = 0.02,
    min_tone_s: float = 0.12,
) -> str:
    """Decode a pairing PIN from an audio buffer."""
    window_samples = int(sample_rate * window_s)
    step_samples = int(sample_rate * step_s)

    tones: List[int] = []
    last_tone: Optional[int] = None
    last_tone_start = 0
    current_index = 0

    i = 0
    while i + window_samples <= len(audio):
        window = audio[i : i + window_samples]
        tone = detect_tone(window, sample_rate)

        if tone != last_tone:
            if last_tone is not None:
                tone_duration = (current_index - last_tone_start) * step_s
                if tone_duration >= min_tone_s:
                    tones.append(last_tone)
            last_tone = tone
            last_tone_start = current_index

        i += step_samples
        current_index += 1

    if last_tone is not None:
        tone_duration = (current_index - last_tone_start) * step_s
        if tone_duration >= min_tone_s:
            tones.append(last_tone)

    return tones_to_pin(tones) or ""


def tones_to_pin(tones: List[int]) -> Optional[str]:
    """Convert a list of detected tone indices back into a PIN."""
    if len(tones) < 4:
        return None
    builder: List[str] = []
    i = 0
    while i + 1 < len(tones):
        pair = (tones[i], tones[i + 1])
        try:
            digit = _DIGIT_TO_TONES.index(pair)
            builder.append(str(digit))
            i += 2
        except ValueError:
            i += 1
    return "".join(builder) if builder else None


def play_pairing_sequence(pin: str, sample_rate: int = 44100) -> None:
    """Play a pairing sequence over the default audio output."""
    import sounddevice as sd

    audio, _ = generate_pairing_sequence(pin, sample_rate=sample_rate)
    if len(audio) == 0:
        return
    sd.play(audio, samplerate=sample_rate)
    sd.wait()


def listen_for_pairing_sequence(
    duration_s: float = 10.0,
    sample_rate: int = 44100,
    *,
    min_length: int = 4,
) -> Optional[str]:
    """Record audio and try to decode a pairing PIN."""
    import sounddevice as sd

    logger.info("Listening for pairing PIN...")
    recorded = sd.rec(int(duration_s * sample_rate), samplerate=sample_rate, channels=1, dtype=np.float32)
    sd.wait()

    audio = recorded.flatten()
    sequence = detect_pairing_sequence(audio, sample_rate)
    logger.info("Heard pairing sequence: %s", sequence)

    if len(sequence) < min_length:
        return None
    return sequence[:min_length]


def generate_pin(length: int = 6) -> str:
    """Generate a numeric PIN suitable for sound transmission."""
    return "".join(str(secrets.randbelow(10)) for _ in range(length))


# Backwards-compatible aliases (kept so callers using the old DTMF names keep working).
def generate_dtmf_sequence(pin: str, sample_rate: int = 44100) -> Tuple[np.ndarray, int]:
    return generate_pairing_sequence(pin, sample_rate=sample_rate)


def play_dtmf_sequence(pin: str, sample_rate: int = 44100) -> None:
    play_pairing_sequence(pin, sample_rate)


def listen_for_dtmf_sequence(
    duration_s: float = 10.0,
    sample_rate: int = 44100,
    *,
    min_length: int = 4,
) -> Optional[str]:
    return listen_for_pairing_sequence(duration_s, sample_rate, min_length=min_length)


def find_loopback_devices() -> Optional[Tuple[int, int]]:
    """Return (input_device_id, output_device_id) for an ALSA loopback, or None."""
    import sounddevice as sd

    try:
        devices = sd.query_devices()
    except Exception:
        return None

    # ALSA loopback pairs two subdevices: output on subdev 0 is routed to
    # input on subdev 1 (and vice-versa). We prefer that pairing.
    loopbacks: dict[int, dict[str, int]] = {}
    for idx, device in enumerate(devices):
        name = str(device.get("name", ""))
        if "loopback" not in name.lower():
            continue
        match = re.search(r"hw:(\d+),(\d+)", name)
        if not match:
            continue
        card = int(match.group(1))
        sub = int(match.group(2))
        info = loopbacks.setdefault(card, {})
        if device.get("max_input_channels", 0) > 0:
            info[f"input_{sub}"] = idx
        if device.get("max_output_channels", 0) > 0:
            info[f"output_{sub}"] = idx

    for card, info in loopbacks.items():
        # Prefer subdev 1 input with subdev 0 output.
        if "input_1" in info and "output_0" in info:
            return info["input_1"], info["output_0"]
        # Fallback to any available input/output pair on the same card.
        if info:
            inputs = [v for k, v in info.items() if k.startswith("input_")]
            outputs = [v for k, v in info.items() if k.startswith("output_")]
            if inputs and outputs:
                return inputs[0], outputs[0]

    return None
