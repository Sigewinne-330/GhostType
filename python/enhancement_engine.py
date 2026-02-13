#!/usr/bin/env python3
"""GhostType audio enhancement engine v2.

This module focuses on robust low-volume speech enhancement with graceful
fallbacks. It is intentionally dependency-light: all third-party enhancement
plugins are optional.
"""

from __future__ import annotations

import math
import shutil
from dataclasses import dataclass, field
from typing import Any

import numpy as np

try:
    import pyloudnorm as pyln
except Exception:  # pragma: no cover - optional runtime import
    pyln = None

try:
    from webrtc_audio_processing import AudioProcessingModule as WebRTCAudioProcessingModule
except Exception:  # pragma: no cover - optional runtime import
    WebRTCAudioProcessingModule = None

try:
    import rnnoise  # type: ignore
except Exception:  # pragma: no cover - optional runtime import
    rnnoise = None

try:
    import deepfilternet  # type: ignore
except Exception:  # pragma: no cover - optional runtime import
    deepfilternet = None

try:
    import speexdsp  # type: ignore
except Exception:  # pragma: no cover - optional runtime import
    speexdsp = None


def _clamp(value: float, lower: float, upper: float) -> float:
    return max(lower, min(upper, value))


@dataclass
class LimiterConfig:
    enabled: bool = True
    threshold: float = 0.98
    attack_ms: float = 5.0
    release_ms: float = 50.0


@dataclass
class TargetsConfig:
    lufs_target: float = -18.0
    max_gain_db: float = 18.0


@dataclass
class VADConfig:
    engine: str = "webrtcvad"
    aggressiveness: int = 1
    preroll_ms: int = 100
    hangover_ms: int = 350


@dataclass
class EnhancementV2Config:
    mode: str = "fast_dsp"
    ns_engine: str = "webrtc"
    noise_suppression_level: str = "moderate"
    loudness_strategy: str = "dynaudnorm"
    dynamics: str = "upward_comp"
    limiter: LimiterConfig = field(default_factory=LimiterConfig)
    targets: TargetsConfig = field(default_factory=TargetsConfig)
    vad: VADConfig = field(default_factory=VADConfig)
    hpf_cutoff_hz: float = 80.0


@dataclass
class EnhancementV2Result:
    signal: np.ndarray
    stats: dict[str, Any]


def probe_enhancement_plugins() -> dict[str, Any]:
    return {
        "pyloudnorm": pyln is not None,
        "webrtc_apm": WebRTCAudioProcessingModule is not None,
        "rnnoise": rnnoise is not None,
        "deepfilternet": deepfilternet is not None,
        "speexdsp": speexdsp is not None,
        "ffmpeg": shutil.which("ffmpeg") is not None,
    }


class EnhancementEngine:
    def __init__(self, config: EnhancementV2Config):
        self.config = config

    def process(
        self,
        signal: np.ndarray,
        sample_rate: int,
        speech_mask: np.ndarray | None = None,
    ) -> EnhancementV2Result:
        stats: dict[str, Any] = {
            "v2_mode": self.config.mode,
            "ns_engine_requested": self.config.ns_engine,
            "loudness_strategy_requested": self.config.loudness_strategy,
            "dynamics_requested": self.config.dynamics,
        }

        if signal.size == 0:
            stats["v2_empty_input"] = True
            return EnhancementV2Result(signal=signal.astype(np.float32, copy=False), stats=stats)

        work = np.clip(signal.astype(np.float32, copy=False), -1.0, 1.0)

        work, dc_stats = self._apply_dc_removal(work)
        stats.update(dc_stats)

        work, hpf_stats = self._apply_high_pass_filter(work, self.config.hpf_cutoff_hz, sample_rate)
        stats.update(hpf_stats)

        work, ns_stats = self._apply_noise_suppression(work, sample_rate)
        stats.update(ns_stats)

        # Estimate noise floor from non-speech region if we have a mask.
        if speech_mask is not None and speech_mask.size == work.size and np.any(~speech_mask):
            noise_region = work[~speech_mask]
            stats["noise_estimate_db"] = round(self._estimate_rms_dbfs(noise_region), 2)
        else:
            stats["noise_estimate_db"] = round(self._estimate_noise_floor_db(work), 2)

        work, loudness_stats = self._apply_loudness_stage(work, sample_rate, speech_mask)
        stats.update(loudness_stats)

        work, dynamics_stats = self._apply_dynamics_stage(work)
        stats.update(dynamics_stats)

        work, limiter_stats = self._apply_limiter(work)
        stats.update(limiter_stats)

        stats["output_rms_dbfs"] = round(self._estimate_rms_dbfs(work), 2)
        stats["output_peak_dbfs"] = round(self._estimate_peak_dbfs(work), 2)
        stats["clipping_sample_ratio"] = round(float(np.mean(np.abs(work) >= 0.999)), 6)
        return EnhancementV2Result(signal=work.astype(np.float32, copy=False), stats=stats)

    def _apply_dc_removal(self, signal: np.ndarray) -> tuple[np.ndarray, dict[str, Any]]:
        dc = float(np.mean(signal))
        centered = signal - dc
        return centered.astype(np.float32, copy=False), {"dc_offset_removed": round(dc, 6)}

    def _apply_high_pass_filter(
        self,
        signal: np.ndarray,
        cutoff_hz: float,
        sample_rate: int,
    ) -> tuple[np.ndarray, dict[str, Any]]:
        if signal.size < 2 or cutoff_hz <= 0:
            return signal, {"hpf_enabled": False}

        dt = 1.0 / float(sample_rate)
        rc = 1.0 / (2.0 * math.pi * cutoff_hz)
        alpha = rc / (rc + dt)

        output = np.empty_like(signal, dtype=np.float32)
        output[0] = signal[0]
        for i in range(1, signal.size):
            output[i] = alpha * (output[i - 1] + signal[i] - signal[i - 1])

        stats = {
            "hpf_enabled": True,
            "hpf_cutoff_hz": round(cutoff_hz, 2),
            "hpf_alpha": round(alpha, 6),
        }
        return output, stats

    def _apply_noise_suppression(
        self,
        signal: np.ndarray,
        sample_rate: int,
    ) -> tuple[np.ndarray, dict[str, Any]]:
        requested = self.config.ns_engine
        if requested == "off":
            return signal, {"ns_backend": "off"}

        # External plugins are optional. If unavailable, we degrade gracefully.
        if requested == "rnnoise":
            if rnnoise is None:
                requested = "webrtc"
            else:
                # Keep as pass-through until stable Python binding is standardized.
                return signal, {"ns_backend": "rnnoise_passthrough"}

        if requested == "deepfilternet":
            if deepfilternet is None:
                requested = "webrtc"
            else:
                return signal, {"ns_backend": "deepfilternet_passthrough"}

        if requested == "speex":
            if speexdsp is None:
                requested = "webrtc"
            else:
                return signal, {"ns_backend": "speex_passthrough"}

        if requested != "webrtc":
            return signal, {"ns_backend": "off"}

        if WebRTCAudioProcessingModule is None:
            return signal, {"ns_backend": "unavailable"}

        frame_size = max(1, int(round(sample_rate * 0.01)))  # 10ms
        if signal.size < frame_size:
            return signal, {"ns_backend": "webrtc_apm", "ns_frames_processed": 0}

        ns_level = self._map_ns_level()
        agc_target, agc_level = self._map_agc_params()

        try:
            apm = WebRTCAudioProcessingModule(
                aec_type=0,
                enable_ns=True,
                agc_type=1,
                enable_vad=False,
            )
            apm.set_stream_format(sample_rate, 1, sample_rate, 1)
            apm.set_ns_level(ns_level)
            apm.set_agc_target(agc_target)
            apm.set_agc_level(agc_level)
        except Exception as exc:  # pragma: no cover - runtime dependency path
            return signal, {"ns_backend": "error", "ns_error": f"init_failed: {exc}"}

        processed = np.empty_like(signal, dtype=np.float32)
        frames_processed = 0
        for start in range(0, signal.size, frame_size):
            end = min(start + frame_size, signal.size)
            frame = signal[start:end]
            if frame.size < frame_size:
                frame = np.pad(frame, (0, frame_size - frame.size))
            try:
                payload = self._float_to_pcm16(frame).tobytes()
                out_payload = apm.process_stream(payload)
                if isinstance(out_payload, str):
                    out_payload = out_payload.encode("latin1")
                out_frame = np.frombuffer(out_payload, dtype=np.int16).astype(np.float32) / 32768.0
                if out_frame.size < frame_size:
                    out_frame = np.pad(out_frame, (0, frame_size - out_frame.size))
            except Exception as exc:  # pragma: no cover - runtime dependency path
                return signal, {"ns_backend": "error", "ns_error": f"process_failed: {exc}"}

            processed[start:end] = out_frame[: end - start]
            frames_processed += 1

        return processed.astype(np.float32, copy=False), {
            "ns_backend": "webrtc_apm",
            "ns_frames_processed": frames_processed,
            "ns_level": ns_level,
            "agc_target": agc_target,
            "agc_level": agc_level,
        }

    def _apply_loudness_stage(
        self,
        signal: np.ndarray,
        sample_rate: int,
        speech_mask: np.ndarray | None,
    ) -> tuple[np.ndarray, dict[str, Any]]:
        strategy = self.config.loudness_strategy
        if strategy == "lufs":
            out, stats = self._apply_lufs_normalization(signal, sample_rate, speech_mask)
            if stats.get("lufs_backend") == "fallback_rms":
                return out, stats
            return out, stats
        if strategy == "dynaudnorm":
            return self._apply_dynaudnorm_like(signal, sample_rate, speech_mask)
        return self._apply_rms_target(signal)

    def _apply_lufs_normalization(
        self,
        signal: np.ndarray,
        sample_rate: int,
        speech_mask: np.ndarray | None,
    ) -> tuple[np.ndarray, dict[str, Any]]:
        if pyln is None:
            fallback, fallback_stats = self._apply_rms_target(signal)
            fallback_stats["lufs_backend"] = "fallback_rms"
            return fallback, fallback_stats

        meter = pyln.Meter(sample_rate)
        measure = signal
        if speech_mask is not None and speech_mask.size == signal.size and np.any(speech_mask):
            measure = signal[speech_mask]
        if measure.size < max(256, sample_rate // 10):
            fallback, fallback_stats = self._apply_rms_target(signal)
            fallback_stats["lufs_backend"] = "fallback_rms_short_input"
            return fallback, fallback_stats

        try:
            measured_lufs = float(meter.integrated_loudness(measure.astype(np.float64)))
        except Exception:
            fallback, fallback_stats = self._apply_rms_target(signal)
            fallback_stats["lufs_backend"] = "fallback_rms_error"
            return fallback, fallback_stats

        target = float(self.config.targets.lufs_target)
        gain_db = _clamp(target - measured_lufs, -12.0, float(self.config.targets.max_gain_db))
        gain_linear = float(10.0 ** (gain_db / 20.0))
        out = signal * gain_linear
        return out.astype(np.float32, copy=False), {
            "lufs_backend": "pyloudnorm",
            "speech_lufs": round(measured_lufs, 2),
            "target_lufs": round(target, 2),
            "applied_gain_db": round(gain_db, 2),
        }

    def _apply_dynaudnorm_like(
        self,
        signal: np.ndarray,
        sample_rate: int,
        speech_mask: np.ndarray | None,
    ) -> tuple[np.ndarray, dict[str, Any]]:
        if self.config.mode == "high_quality":
            frame_len_ms = 500
            smooth_window = 31
        else:
            # Fast mode intentionally uses a shorter analysis window to reduce post-record latency.
            frame_len_ms = 250
            smooth_window = 13
        frame_len = max(1, int(round(sample_rate * (frame_len_ms / 1000.0))))
        max_gain = min(float(self.config.targets.max_gain_db), 10.0)
        max_gain_linear = 10.0 ** (max_gain / 20.0)
        peak_target = 0.95

        # Threshold gate to avoid lifting near-silence.
        noise_db = self._estimate_noise_floor_db(signal)
        gate_db = noise_db + 8.0

        frame_gains: list[float] = []
        for start in range(0, signal.size, frame_len):
            frame = signal[start : min(signal.size, start + frame_len)]
            rms_db = self._estimate_rms_dbfs(frame)
            peak = float(np.max(np.abs(frame))) if frame.size else 0.0
            if rms_db < gate_db:
                desired_gain = 1.0
            else:
                desired_gain = peak_target / max(peak, 1e-5)
                desired_gain = _clamp(desired_gain, 1.0, max_gain_linear)
            frame_gains.append(float(desired_gain))

        if not frame_gains:
            return signal, {
                "loudness_backend": "dynaudnorm_like",
                "applied_gain_db": 0.0,
                "noise_gate_db": round(gate_db, 2),
            }

        smoothed = self._smooth_curve(np.array(frame_gains, dtype=np.float32), window=smooth_window)
        out = np.empty_like(signal, dtype=np.float32)
        for idx, start in enumerate(range(0, signal.size, frame_len)):
            end = min(signal.size, start + frame_len)
            out[start:end] = signal[start:end] * float(smoothed[idx])

        # keep threshold gating on non-speech area if we have mask
        if speech_mask is not None and speech_mask.size == out.size:
            out[~speech_mask] = signal[~speech_mask]

        applied_gain_db = 20.0 * math.log10(max(float(np.mean(smoothed)), 1e-7))
        return out.astype(np.float32, copy=False), {
            "loudness_backend": "dynaudnorm_like",
            "applied_gain_db": round(applied_gain_db, 2),
            "noise_gate_db": round(gate_db, 2),
            "dyn_peak_target": peak_target,
            "dyn_max_gain_db": max_gain,
            "dyn_frame_len_ms": frame_len_ms,
            "dyn_gauss_window": smooth_window,
        }

    def _apply_rms_target(self, signal: np.ndarray) -> tuple[np.ndarray, dict[str, Any]]:
        target_map = {
            "fast_dsp": -24.0,
            "high_quality": -22.0,
            "custom": -24.0,
        }
        target_db = target_map.get(self.config.mode, -24.0)
        measured = self._estimate_rms_dbfs(signal)
        gain_db = _clamp(target_db - measured, 0.0, float(self.config.targets.max_gain_db))
        gain_linear = 10.0 ** (gain_db / 20.0)
        out = signal * gain_linear
        return out.astype(np.float32, copy=False), {
            "loudness_backend": "rms_target",
            "applied_gain_db": round(gain_db, 2),
            "target_rms_dbfs": round(target_db, 2),
        }

    def _apply_dynamics_stage(self, signal: np.ndarray) -> tuple[np.ndarray, dict[str, Any]]:
        if self.config.dynamics == "off":
            return signal, {"dynamics_backend": "off"}

        compressed, comp_stats = self._apply_upward_compressor(signal)
        if self.config.dynamics == "upward_comp":
            comp_stats["dynamics_backend"] = "upward_comp"
            return compressed, comp_stats

        limited, limiter_stats = self._apply_limiter(
            compressed,
            force_enable=True,
            threshold_override=min(self.config.limiter.threshold, 0.99),
        )
        merged = dict(comp_stats)
        merged.update({f"dyn_{key}": value for key, value in limiter_stats.items()})
        merged["dynamics_backend"] = "comp_limiter"
        return limited, merged

    def _apply_upward_compressor(self, signal: np.ndarray) -> tuple[np.ndarray, dict[str, Any]]:
        threshold = 0.125
        ratio = 2.0
        attack_ms = 20.0
        release_ms = 250.0
        sample_rate = 16000.0

        attack = math.exp(-1.0 / max(1.0, (attack_ms / 1000.0) * sample_rate))
        release = math.exp(-1.0 / max(1.0, (release_ms / 1000.0) * sample_rate))

        env = 0.0
        out = np.empty_like(signal, dtype=np.float32)
        gain_trace = np.empty_like(signal, dtype=np.float32)
        max_gain = 10.0 ** (min(self.config.targets.max_gain_db, 18.0) / 20.0)

        for i, sample in enumerate(signal):
            level = abs(float(sample))
            coef = attack if level > env else release
            env = coef * env + (1.0 - coef) * level
            if env < threshold:
                gain = (threshold / max(env, 1e-5)) ** (1.0 - 1.0 / ratio)
            else:
                gain = 1.0
            gain = _clamp(gain, 1.0, max_gain)
            out[i] = sample * gain
            gain_trace[i] = gain

        avg_gain = float(np.mean(gain_trace))
        return out.astype(np.float32, copy=False), {
            "upward_comp_avg_gain_db": round(20.0 * math.log10(max(avg_gain, 1e-7)), 2),
            "upward_comp_peak_gain_db": round(
                20.0 * math.log10(max(float(np.max(gain_trace)), 1e-7)),
                2,
            ),
            "upward_comp_threshold": threshold,
            "upward_comp_ratio": ratio,
        }

    def _apply_limiter(
        self,
        signal: np.ndarray,
        force_enable: bool = False,
        threshold_override: float | None = None,
    ) -> tuple[np.ndarray, dict[str, Any]]:
        limiter_cfg = self.config.limiter
        enabled = force_enable or limiter_cfg.enabled
        if not enabled:
            return signal, {"limiter_enabled": False, "limiter_reduction_db": 0.0}

        threshold = _clamp(
            float(threshold_override if threshold_override is not None else limiter_cfg.threshold),
            0.6,
            0.999,
        )
        attack_ms = max(0.1, float(limiter_cfg.attack_ms))
        release_ms = max(1.0, float(limiter_cfg.release_ms))

        sample_rate = 16000.0
        attack = math.exp(-1.0 / max(1.0, (attack_ms / 1000.0) * sample_rate))
        release = math.exp(-1.0 / max(1.0, (release_ms / 1000.0) * sample_rate))

        gain = 1.0
        gains = np.empty_like(signal, dtype=np.float32)
        out = np.empty_like(signal, dtype=np.float32)

        for i, sample in enumerate(signal):
            abs_sample = abs(float(sample))
            target_gain = 1.0 if abs_sample <= threshold else threshold / max(abs_sample, 1e-6)
            coef = attack if target_gain < gain else release
            gain = coef * gain + (1.0 - coef) * target_gain
            gains[i] = gain
            out[i] = sample * gain

        out = np.clip(out, -1.0, 1.0).astype(np.float32, copy=False)
        reduction_db = -20.0 * math.log10(max(float(np.min(gains)), 1e-7))
        return out, {
            "limiter_enabled": True,
            "limiter_threshold": round(threshold, 4),
            "limiter_reduction_db": round(reduction_db, 2),
            "limiter_attack_ms": round(attack_ms, 2),
            "limiter_release_ms": round(release_ms, 2),
        }

    def _map_ns_level(self) -> int:
        mapping = {
            "low": 0,
            "moderate": 1,
            "high": 2,
            "veryhigh": 3,
        }
        return mapping.get(self.config.noise_suppression_level, 1)

    def _map_agc_params(self) -> tuple[int, int]:
        if self.config.mode == "high_quality":
            return 18, 68
        return 20, 58

    def _estimate_rms_dbfs(self, signal: np.ndarray) -> float:
        if signal.size == 0:
            return -120.0
        rms = float(np.sqrt(np.mean(np.square(signal, dtype=np.float64))))
        return 20.0 * math.log10(max(rms, 1e-7))

    def _estimate_peak_dbfs(self, signal: np.ndarray) -> float:
        if signal.size == 0:
            return -120.0
        peak = float(np.max(np.abs(signal)))
        return 20.0 * math.log10(max(peak, 1e-7))

    def _estimate_noise_floor_db(self, signal: np.ndarray) -> float:
        if signal.size == 0:
            return -120.0
        abs_signal = np.abs(signal)
        p20 = float(np.percentile(abs_signal, 20))
        return 20.0 * math.log10(max(p20, 1e-7))

    def _float_to_pcm16(self, signal: np.ndarray) -> np.ndarray:
        clipped = np.clip(signal, -1.0, 1.0)
        return np.round(clipped * 32767.0).astype(np.int16, copy=False)

    def _smooth_curve(self, values: np.ndarray, window: int) -> np.ndarray:
        if values.size <= 1:
            return values
        length = max(3, int(window) | 1)
        sigma = max(1.0, length / 6.0)
        half = length // 2
        xs = np.arange(-half, half + 1, dtype=np.float32)
        kernel = np.exp(-(xs ** 2) / (2.0 * sigma * sigma))
        kernel /= np.sum(kernel)
        padded = np.pad(values, (half, half), mode="edge")
        return np.convolve(padded, kernel, mode="valid").astype(np.float32, copy=False)
