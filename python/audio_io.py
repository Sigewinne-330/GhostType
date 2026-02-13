from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import wave

import numpy as np


class WavFormatError(ValueError):
    """Raised when a WAV file does not match 16kHz/mono/PCM16 requirements."""


@dataclass(frozen=True)
class WavMetadata:
    channels: int
    sample_width: int
    sample_rate: int
    frame_count: int


def load_wav_pcm16_mono(path: str | Path) -> np.ndarray:
    """Load a strict 16kHz mono PCM16 WAV file as float32 waveform in [-1, 1]."""

    metadata, raw = _read_wav_bytes(path)

    if metadata.channels != 1:
        raise WavFormatError(
            f"Unsupported WAV channel count: {metadata.channels}. Expected mono (1)."
        )
    if metadata.sample_width != 2:
        raise WavFormatError(
            f"Unsupported WAV sample width: {metadata.sample_width}. Expected 16-bit PCM (2 bytes)."
        )
    if metadata.sample_rate != 16_000:
        raise WavFormatError(
            f"Unsupported WAV sample rate: {metadata.sample_rate}. Expected 16000 Hz."
        )

    waveform = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    return np.clip(waveform, -1.0, 1.0)


def read_wav_metadata(path: str | Path) -> WavMetadata:
    """Read WAV metadata without decoding audio payload."""

    metadata, _ = _read_wav_bytes(path, read_frames=False)
    return metadata


def _read_wav_bytes(path: str | Path, read_frames: bool = True) -> tuple[WavMetadata, bytes]:
    wav_path = Path(path).expanduser().resolve()
    if not wav_path.exists():
        raise FileNotFoundError(f"Audio file not found: {wav_path}")

    with wave.open(str(wav_path), "rb") as wf:
        channels = int(wf.getnchannels())
        sample_width = int(wf.getsampwidth())
        sample_rate = int(wf.getframerate())
        frame_count = int(wf.getnframes())
        raw = wf.readframes(frame_count) if read_frames else b""

    return (
        WavMetadata(
            channels=channels,
            sample_width=sample_width,
            sample_rate=sample_rate,
            frame_count=frame_count,
        ),
        raw,
    )
