param(
    [switch]$InstallWhisper,
    [switch]$PullOllamaModel,
    [string]$WhisperModel = 'whisper-large-v3',
    [int]$WhisperPort = 8000,
    [string]$OllamaModel = 'qwen2.5:14b'
)

$ErrorActionPreference = 'Stop'

if (-not $InstallWhisper -and -not $PullOllamaModel) {
    Write-Host 'Local AI setup skipped.'
    exit 0
}

Write-Host 'Preparing EchoScribe Local AI setup in WSL...'
$installWhisperFlag = if ($InstallWhisper.IsPresent) { '1' } else { '0' }
$pullOllamaFlag = if ($PullOllamaModel.IsPresent) { '1' } else { '0' }
Write-Host "  Install Whisper: $($InstallWhisper.IsPresent)"
Write-Host "  Pull Ollama:     $($PullOllamaModel.IsPresent)"

$wsl = Get-Command 'wsl.exe' -ErrorAction SilentlyContinue
if (-not $wsl) {
    throw 'wsl.exe was not found. Install WSL/Ubuntu before enabling local CUDA Whisper.'
}

$bashTemplate = @'
set -euo pipefail

INSTALL_WHISPER="__INSTALL_WHISPER__"
PULL_OLLAMA="__PULL_OLLAMA__"
WHISPER_MODEL="__WHISPER_MODEL__"
WHISPER_PORT="__WHISPER_PORT__"
OLLAMA_MODEL="__OLLAMA_MODEL__"
DEFAULT_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/echoscribe/local-ai"
ROOT="$DEFAULT_ROOT"
VENV="$ROOT/.venv"
LOG_DIR="$ROOT/logs"

mkdir -p "$LOG_DIR" "$ROOT/cache"
cd "$ROOT"

step() {
  echo "  - $*"
}

run_logged() {
  local name="$1"
  shift
  local log_file="$LOG_DIR/${name}.log"
  if "$@" >"$log_file" 2>&1; then
    return 0
  fi

  echo "    Failed. Last log lines from $log_file:"
  tail -n 80 "$log_file" || true
  return 1
}

if [ "$INSTALL_WHISPER" = "1" ]; then
  step "Preparing Python virtual environment..."
  if [ ! -x "$VENV/bin/python" ]; then
    if command -v uv >/dev/null 2>&1; then
      uv venv --python python3 "$VENV"
    else
      python3 -m venv "$VENV"
    fi
  fi

  step "Installing or updating Python packaging tools..."
  run_logged pip-bootstrap "$VENV/bin/python" -m pip install --disable-pip-version-check --quiet --upgrade pip wheel setuptools
  step "Installing or updating Whisper server dependencies..."
  run_logged pip-whisper "$VENV/bin/python" -m pip install --disable-pip-version-check --quiet --upgrade fastapi "uvicorn[standard]" python-multipart faster-whisper nvidia-cublas-cu12 nvidia-cudnn-cu12

  step "Writing Whisper API server files..."
  cat > "$ROOT/server.py" <<'PY'
from __future__ import annotations

import os
import tempfile
import threading
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, File, Form, UploadFile
from faster_whisper import WhisperModel

app = FastAPI(title="EchoScribe Local Whisper")
_models: dict[str, WhisperModel] = {}
_lock = threading.Lock()


def _resolve_model(name: Optional[str]) -> str:
    value = (name or os.environ.get("ECHOSCRIBE_WHISPER_MODEL") or "whisper-large-v3").strip()
    lower = value.lower()
    if lower in {"whisper-1", "whisper-large", "whisper-large-v3", "large-v3"}:
        return "large-v3"
    if lower.startswith("whisper-"):
        return lower.removeprefix("whisper-")
    return value


def _model_for(name: Optional[str]) -> WhisperModel:
    model_name = _resolve_model(name)
    with _lock:
        model = _models.get(model_name)
        if model is None:
            model = WhisperModel(
                model_name,
                device="cuda",
                compute_type="float16",
                download_root=str(Path(__file__).resolve().parent / "cache"),
            )
            _models[model_name] = model
        return model


@app.get("/health")
def health() -> dict[str, object]:
    return {
        "ok": True,
        "defaultModel": os.environ.get("ECHOSCRIBE_WHISPER_MODEL", "whisper-large-v3"),
        "device": "cuda",
    }


@app.post("/v1/audio/transcriptions")
async def transcribe(
    file: UploadFile = File(...),
    model: str = Form("whisper-large-v3"),
    response_format: str = Form("json"),
    language: Optional[str] = Form(None),
) -> dict[str, str]:
    suffix = Path(file.filename or "recording.wav").suffix or ".wav"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as handle:
        handle.write(await file.read())
        audio_path = handle.name

    try:
        kwargs = {
            "vad_filter": True,
            "beam_size": 5,
        }
        if language and language.lower() != "auto":
            kwargs["language"] = language
        segments, _ = _model_for(model).transcribe(audio_path, **kwargs)
        text = " ".join(segment.text.strip() for segment in segments).strip()
        return {"text": text}
    finally:
        try:
            os.unlink(audio_path)
        except FileNotFoundError:
            pass
PY

  cat > "$ROOT/start-whisper.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$ROOT/.venv"
MODEL="${1:-whisper-large-v3}"
PORT="${2:-8000}"
PID_FILE="$ROOT/whisper-server.pid"
LOG_FILE="$ROOT/logs/whisper-server.log"

mkdir -p "$ROOT/logs"

CUDA_LIBS="$(find "$VENV/lib" -type d \( -path '*/site-packages/nvidia/cublas/lib' -o -path '*/site-packages/nvidia/cudnn/lib' \) -print | paste -sd: -)"
export LD_LIBRARY_PATH="${CUDA_LIBS}:/usr/lib/wsl/lib:${LD_LIBRARY_PATH:-}"
export ECHOSCRIBE_WHISPER_MODEL="$MODEL"

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  PID="$(cat "$PID_FILE")"
  if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    if tr '\0' '\n' <"/proc/${PID}/environ" 2>/dev/null | grep -F "nvidia/cublas/lib" >/dev/null; then
      echo "EchoScribe Local Whisper already running on port ${PORT}."
      exit 0
    fi
    echo "Restarting EchoScribe Local Whisper to refresh CUDA library paths."
  else
    echo "Restarting stale EchoScribe Local Whisper process."
  fi
  kill "$PID" 2>/dev/null || true
  sleep 1
fi

cd "$ROOT"
nohup "$VENV/bin/python" -m uvicorn server:app --host 0.0.0.0 --port "$PORT" > "$LOG_FILE" 2>&1 &
echo "$!" > "$PID_FILE"
sleep 2
curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null
echo "EchoScribe Local Whisper started on port ${PORT} with model ${MODEL}."
SH
  chmod +x "$ROOT/start-whisper.sh"
  step "Downloading/loading Whisper model and checking CUDA..."
  ECHOSCRIBE_WHISPER_MODEL="$WHISPER_MODEL" "$VENV/bin/python" - <<'PY'
import os
from server import _model_for

_model_for(os.environ.get("ECHOSCRIBE_WHISPER_MODEL"))
print("Whisper model is downloaded and CUDA load check passed.")
PY
  step "Starting or reusing Local Whisper service on port ${WHISPER_PORT}..."
  "$ROOT/start-whisper.sh" "$WHISPER_MODEL" "$WHISPER_PORT"
fi

if [ "$PULL_OLLAMA" = "1" ]; then
  step "Checking Ollama model ${OLLAMA_MODEL}..."
  if command -v ollama >/dev/null 2>&1; then
    ollama pull "$OLLAMA_MODEL"
  else
    curl -fsS http://127.0.0.1:11434/api/pull \
      -H 'Content-Type: application/json' \
      -d "{\"name\":\"${OLLAMA_MODEL}\",\"stream\":false}" >/dev/null
  fi
  echo "Ollama model ${OLLAMA_MODEL} is available."
fi
'@

$bash = $bashTemplate.
    Replace('__INSTALL_WHISPER__', $installWhisperFlag).
    Replace('__PULL_OLLAMA__', $pullOllamaFlag).
    Replace('__WHISPER_MODEL__', $WhisperModel).
    Replace('__WHISPER_PORT__', [string]$WhisperPort).
    Replace('__OLLAMA_MODEL__', $OllamaModel)

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("echoscribe-local-ai-{0}.sh" -f ([guid]::NewGuid().ToString("N")))
[System.IO.File]::WriteAllText($temp, $bash, [System.Text.UTF8Encoding]::new($false))
try {
    Write-Host 'Running WSL Local AI setup...'
    if ($temp -notmatch '^([A-Za-z]):\\(.*)$') {
        throw "Could not map Windows temp script into WSL: $temp"
    }
    $drive = $Matches[1].ToLowerInvariant()
    $relativePath = $Matches[2].Replace('\', '/')
    $wslScriptPath = "/mnt/$drive/$relativePath"
    & $wsl.Source -- bash $wslScriptPath
    if ($LASTEXITCODE -ne 0) {
        throw "WSL Local AI setup failed with exit code $LASTEXITCODE."
    }
} finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
