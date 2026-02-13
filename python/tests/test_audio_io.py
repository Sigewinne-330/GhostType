from __future__ import annotations

from pathlib import Path
import tempfile
import unittest
import wave

import numpy as np

from audio_io import WavFormatError, load_wav_pcm16_mono


FIXTURE_WAV = Path(__file__).resolve().parent / "fixtures" / "mono16k_pcm16.wav"


class AudioIOTests(unittest.TestCase):
    def test_load_wav_pcm16_mono_returns_float32_waveform(self):
        waveform = load_wav_pcm16_mono(FIXTURE_WAV)

        self.assertEqual(waveform.dtype, np.float32)
        self.assertGreater(waveform.size, 0)
        self.assertLessEqual(float(np.max(waveform)), 1.0)
        self.assertGreaterEqual(float(np.min(waveform)), -1.0)

    def test_load_wav_pcm16_mono_rejects_non_mono(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            bad_wav = Path(temp_dir) / "stereo.wav"
            with wave.open(str(bad_wav), "wb") as wf:
                wf.setnchannels(2)
                wf.setsampwidth(2)
                wf.setframerate(16_000)
                wf.writeframes(b"\x00\x00" * 100)

            with self.assertRaises(WavFormatError):
                load_wav_pcm16_mono(bad_wav)

    def test_load_wav_pcm16_mono_rejects_non_16k(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            bad_wav = Path(temp_dir) / "sr8k.wav"
            with wave.open(str(bad_wav), "wb") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(8_000)
                wf.writeframes(b"\x00\x00" * 100)

            with self.assertRaises(WavFormatError):
                load_wav_pcm16_mono(bad_wav)


if __name__ == "__main__":
    unittest.main()
