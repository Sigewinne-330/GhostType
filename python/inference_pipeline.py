#!/usr/bin/env python3
"""GhostType pipeline: ASR (mlx-whisper) -> refinement (mlx-lm)."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import inspect
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Any

import numpy as np

from audio_io import WavFormatError, load_wav_pcm16_mono


SYSTEM_PROMPT = (
    "你是一个拥有极高认知水平的“首席速记员”。你的唯一任务是提取用户杂乱口语中的【最终意图】，并输出为极其干净、结构化的书面文本。\n\n"
    "【绝对遵循以下五大铁律】：\n"
    "1. 智能纠错 (Contextual Autocorrect)：\n"
    "原始语音识别文本中可能包含同音字/近音字错漏（例如：“去尝试买牛奶”应为“去超市买牛奶”）。你必须结合上下文逻辑，毫不犹豫地修正这些不符合常理的词汇。\n"
    "2. 执行自我纠正 (Resolve Self-Corrections)：\n"
    "用户在说话时经常会改变主意（出现如“算了”、“不要X了”、“换成Y”、“哦不对”等词汇）。你【必须且只能】保留用户最终决定的结果！绝对禁止把用户犹豫、修改的过程写进最终文本里。\n"
    "3. 绝对的无情降噪 (Ruthless Denoising)：\n"
    "彻底删除所有寒暄（如“你好”、“强森”）、所有的语气词（如“嗯”、“啊”、“吧”、“好吧”、“就这样”）、以及没有实质意义的口头禅。\n"
    "4. 格式化输出 (Formatting)：\n"
    "用专业的书面语重构句子。如果包含多个独立事项，请自然地使用 Markdown 无序列表 (-) 进行排版。绝对不要输出任何前缀（如“好的，整理如下：”），只输出最终结果。\n"
    "5. 句法完整性与主语保留 (Syntactic Completeness & Subject Retention)：\n"
    "禁止将句子压缩为祈使句或命令（如“去买牛奶”）。必须保留原句中的主语（如“我”、“我们要”、“他”）；如果原句省略了主语但语境隐含是“我”，请在输出时补全主语“我”。输出必须是通顺、自然的书面陈述句。\n"
    "范例：❌ 错误：明天去超市。✅ 正确：我明天准备去超市。\n\n"
    "【Few-shot 示例】\n"
    "[示例 1]\n"
    "User: \"明天我准备去超市买一根香蕉和牛奶，算了，还是只买牛奶吧，然后之后去健身房。\"\n"
    "Assistant:\n"
    "- 我明天准备去超市买牛奶。\n"
    "- 之后我会去健身房。\n\n"
    "[示例 2]\n"
    "User: \"嘿，想给老板发个邮件，问一下那个项目...哦不对，是问一下合同进度。\"\n"
    "Assistant:\n"
    "- 我想给老板发邮件询问合同的进度。"
)


@dataclass
class PipelineConfig:
    audio_path: Path
    asr_model: str
    llm_model: str
    language: str
    max_tokens: int
    skip_llm: bool


def apply_background_scheduling() -> dict[str, str]:
    """Best-effort QoS downgrade so inference does not contend with UI threads."""
    status: dict[str, str] = {}

    try:
        os.nice(10)
        status["nice"] = "set_to_10"
    except OSError as exc:
        status["nice"] = f"not_set ({exc})"

    if sys.platform == "darwin":
        pid = str(os.getpid())
        try:
            subprocess.run(
                ["/usr/bin/renice", "10", "-p", pid],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            status["renice"] = "applied"
        except FileNotFoundError:
            status["renice"] = "missing"

        try:
            subprocess.run(
                ["/usr/sbin/taskpolicy", "-b", "-p", pid],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            status["taskpolicy"] = "background_applied"
        except FileNotFoundError:
            status["taskpolicy"] = "missing"

    return status


def _transcribe_with_fallback(audio_path: str, model_id: str, language: str) -> dict[str, Any]:
    from mlx_whisper import transcribe

    if language.lower() == "auto":
        language_value: str | None = None
    else:
        language_value = language

    transcribe_input, requires_ffmpeg = _prepare_transcribe_input(audio_path, transcribe)

    try:
        with _ffmpeg_decode_environment(requires_ffmpeg):
            return transcribe(
                transcribe_input,
                path_or_hf_repo=model_id,
                language=language_value,
                task="transcribe",
            )
    except TypeError:
        with _ffmpeg_decode_environment(requires_ffmpeg):
            return transcribe(transcribe_input, path_or_hf_repo=model_id, language=language_value)


def _prepare_transcribe_input(audio_path: str, transcribe_func: Any) -> tuple[str | np.ndarray, bool]:
    path = Path(audio_path)
    ffmpeg_path = _resolve_ffmpeg_path()
    is_wav = path.suffix.lower() == ".wav"

    if is_wav:
        try:
            waveform = load_wav_pcm16_mono(path)
        except WavFormatError as exc:
            if ffmpeg_path:
                return audio_path, True
            raise RuntimeError(
                "WAV format is not 16kHz mono PCM16 and ffmpeg is unavailable. "
                "Please re-record as WAV or install ffmpeg."
            ) from exc
        if _transcribe_supports_ndarray(transcribe_func):
            return waveform, False
        if ffmpeg_path:
            return audio_path, True
        raise RuntimeError(
            "Current mlx-whisper does not accept ndarray input and ffmpeg is unavailable."
        )

    if ffmpeg_path:
        return audio_path, True
    raise RuntimeError(
        "Non-WAV input requires ffmpeg. Please install ffmpeg or provide 16kHz mono PCM16 WAV."
    )


def _transcribe_supports_ndarray(transcribe_func: Any) -> bool:
    try:
        inspect.signature(transcribe_func).bind(np.zeros(1, dtype=np.float32), path_or_hf_repo="dummy")
        return True
    except Exception:
        return False


def _resolve_ffmpeg_path() -> str | None:
    bundled_path = str(os.environ.get("GHOSTTYPE_FFMPEG_PATH") or "").strip()
    if bundled_path and Path(bundled_path).is_file() and os.access(bundled_path, os.X_OK):
        return bundled_path
    return shutil.which("ffmpeg")


@contextmanager
def _ffmpeg_decode_environment(requires_ffmpeg: bool):
    if not requires_ffmpeg:
        yield
        return

    ffmpeg_path = _resolve_ffmpeg_path()
    if not ffmpeg_path:
        raise RuntimeError("ffmpeg is required for decoding this audio format but was not found.")

    ffmpeg_dir = str(Path(ffmpeg_path).resolve().parent)
    original_path = str(os.environ.get("PATH") or "")
    has_dir = ffmpeg_dir in [entry for entry in original_path.split(os.pathsep) if entry]
    if has_dir:
        yield
        return

    os.environ["PATH"] = f"{ffmpeg_dir}{os.pathsep}{original_path}" if original_path else ffmpeg_dir
    try:
        yield
    finally:
        os.environ["PATH"] = original_path


def run_asr(config: PipelineConfig) -> tuple[str, float]:
    t0 = time.perf_counter()
    result = _transcribe_with_fallback(
        audio_path=str(config.audio_path),
        model_id=config.asr_model,
        language=config.language,
    )
    raw_text = (result.get("text") or "").strip()
    elapsed_ms = (time.perf_counter() - t0) * 1000
    return raw_text, elapsed_ms


def _generate_with_fallback(model: Any, tokenizer: Any, prompt: str, max_tokens: int) -> str:
    from mlx_lm import generate

    try:
        return generate(
            model,
            tokenizer,
            prompt=prompt,
            max_tokens=max_tokens,
            temp=0.2,
            verbose=False,
        )
    except TypeError:
        try:
            return generate(model, tokenizer, prompt=prompt, max_tokens=max_tokens)
        except TypeError:
            return generate(model, tokenizer, prompt, max_tokens=max_tokens)


def run_llm(raw_text: str, config: PipelineConfig) -> tuple[str, float]:
    if not raw_text:
        return "", 0.0

    from mlx_lm import load

    t0 = time.perf_counter()
    model, tokenizer = load(config.llm_model)
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": raw_text},
    ]
    prompt = tokenizer.apply_chat_template(
        messages,
        tokenize=False,
        add_generation_prompt=True,
    )
    generated = _generate_with_fallback(
        model=model,
        tokenizer=tokenizer,
        prompt=prompt,
        max_tokens=config.max_tokens,
    )

    refined = generated
    if generated.startswith(prompt):
        refined = generated[len(prompt) :]

    refined = refined.strip()
    elapsed_ms = (time.perf_counter() - t0) * 1000
    return refined, elapsed_ms


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="GhostType inference pipeline")
    parser.add_argument(
        "--audio",
        required=True,
        help="Path to input audio file. 16kHz mono PCM16 WAV is preferred; other formats require ffmpeg.",
    )
    parser.add_argument(
        "--asr-model",
        default="mlx-community/whisper-small",
        help="ASR model repo/path for mlx-whisper",
    )
    parser.add_argument(
        "--llm-model",
        default="mlx-community/Qwen2.5-1.5B-Instruct-4bit",
        help="LLM model repo/path for mlx-lm",
    )
    parser.add_argument("--language", default="auto", help="Language code, e.g. zh, en, auto")
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--skip-llm", action="store_true", help="Only run ASR")
    parser.add_argument(
        "--output",
        choices=["json", "text"],
        default="json",
        help="Output format",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    audio_path = Path(args.audio).expanduser().resolve()
    if not audio_path.exists():
        print(f"Audio file not found: {audio_path}", file=sys.stderr)
        return 2

    config = PipelineConfig(
        audio_path=audio_path,
        asr_model=args.asr_model,
        llm_model=args.llm_model,
        language=args.language,
        max_tokens=args.max_tokens,
        skip_llm=args.skip_llm,
    )

    scheduling = apply_background_scheduling()

    try:
        raw_text, asr_ms = run_asr(config)
        if config.skip_llm:
            refined_text = raw_text
            llm_ms = 0.0
        else:
            refined_text, llm_ms = run_llm(raw_text, config)
            if not refined_text:
                refined_text = raw_text
    except Exception as exc:
        print(f"Pipeline failed: {exc}", file=sys.stderr)
        return 1

    payload = {
        "raw_text": raw_text,
        "refined_text": refined_text,
        "meta": {
            "audio_path": str(audio_path),
            "asr_model": config.asr_model,
            "llm_model": None if config.skip_llm else config.llm_model,
            "timing_ms": {
                "asr": round(asr_ms, 2),
                "llm": round(llm_ms, 2),
                "total": round(asr_ms + llm_ms, 2),
            },
            "scheduling": scheduling,
        },
    }

    if args.output == "text":
        print(refined_text)
    else:
        print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
