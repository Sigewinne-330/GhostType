#!/usr/bin/env bash
set -euo pipefail

PYTHON_BIN="${1:-python3}"
if [[ ! -x "${PYTHON_BIN}" ]]; then
  echo "python binary is not executable: ${PYTHON_BIN}" >&2
  exit 1
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/webrtc_apm_build.XXXXXX")"
cleanup() {
  rm -rf "${WORKDIR}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${PYTHON_BIN}" -m pip download --no-binary :all: "webrtc-audio-processing==0.1.3" -d "${WORKDIR}" >/dev/null
tar -xzf "${WORKDIR}/webrtc_audio_processing-0.1.3.tar.gz" -C "${WORKDIR}"
SRC_DIR="${WORKDIR}/webrtc_audio_processing-0.1.3"

"/usr/bin/python3" - <<'PY' "${SRC_DIR}"
from pathlib import Path
import sys

src = Path(sys.argv[1])
setup_path = src / "setup.py"
event_timer_path = src / "webrtc-audio-processing/webrtc/system_wrappers/source/event_timer_posix.cc"

setup_text = setup_path.read_text(encoding="utf-8")
setup_text = setup_text.replace(
    "include_dirs = ['src', 'webrtc-audio-processing']\n"
    "libraries = ['pthread', 'stdc++']\n"
    "define_macros = [\n"
    "    ('WEBRTC_LINUX', None),\n",
    "include_dirs = ['src', 'webrtc-audio-processing']\n"
    "libraries = ['pthread', 'stdc++']\n"
    "is_darwin = sys.platform == 'darwin'\n"
    "define_macros = [\n"
    "    ('WEBRTC_MAC', None) if is_darwin else ('WEBRTC_LINUX', None),\n",
)
setup_text = setup_text.replace("extra_compile_args = ['-std=c++11']", "extra_compile_args = []")
setup_text = setup_text.replace(
    "if platform.machine().find('arm') >= 0:\n"
    "    ap_sources = [src for src in ap_sources if src.find('mips.') < 0 and src.find('sse') < 0]\n"
    "    extra_compile_args.append('-mfloat-abi=hard')\n"
    "    extra_compile_args.append('-mfpu=neon')\n"
    "    define_macros.append(('WEBRTC_HAS_NEON', None))\n"
    "else:\n"
    "    ap_sources = [src for src in ap_sources if src.find('mips.') < 0 and src.find('neon.') < 0]\n",
    "if platform.machine().find('arm') >= 0:\n"
    "    ap_sources = [src for src in ap_sources if src.find('mips.') < 0 and src.find('sse') < 0]\n"
    "    if not is_darwin:\n"
    "        extra_compile_args.append('-mfloat-abi=hard')\n"
    "        extra_compile_args.append('-mfpu=neon')\n"
    "        define_macros.append(('WEBRTC_HAS_NEON', None))\n"
    "    else:\n"
    "        ap_sources = [src for src in ap_sources if src.find('neon.') < 0]\n"
    "else:\n"
    "    ap_sources = [src for src in ap_sources if src.find('mips.') < 0 and src.find('neon.') < 0]\n",
)
setup_path.write_text(setup_text, encoding="utf-8")

event_text = event_timer_path.read_text(encoding="utf-8")
event_text = event_text.replace(
    "#ifdef WEBRTC_CLOCK_TYPE_REALTIME\n"
    "  pthread_cond_init(&cond_, 0);\n"
    "#else\n"
    "  pthread_condattr_t cond_attr;\n"
    "  pthread_condattr_init(&cond_attr);\n"
    "  pthread_condattr_setclock(&cond_attr, CLOCK_MONOTONIC);\n"
    "  pthread_cond_init(&cond_, &cond_attr);\n"
    "  pthread_condattr_destroy(&cond_attr);\n"
    "#endif\n",
    "#ifdef WEBRTC_CLOCK_TYPE_REALTIME\n"
    "  pthread_cond_init(&cond_, 0);\n"
    "#else\n"
    "#ifdef WEBRTC_MAC\n"
    "  pthread_cond_init(&cond_, 0);\n"
    "#else\n"
    "  pthread_condattr_t cond_attr;\n"
    "  pthread_condattr_init(&cond_attr);\n"
    "  pthread_condattr_setclock(&cond_attr, CLOCK_MONOTONIC);\n"
    "  pthread_cond_init(&cond_, &cond_attr);\n"
    "  pthread_condattr_destroy(&cond_attr);\n"
    "#endif\n"
    "#endif\n",
)
event_timer_path.write_text(event_text, encoding="utf-8")
PY

"${PYTHON_BIN}" -m pip install --no-cache-dir "${SRC_DIR}"
"${PYTHON_BIN}" - <<'PY'
import importlib.util
if not importlib.util.find_spec("webrtc_audio_processing"):
    raise SystemExit(1)
print("webrtc_audio_processing installed")
PY
