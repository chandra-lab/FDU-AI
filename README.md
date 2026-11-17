# University Local AI Platform

Self-hosted AI chat platform for university students, running entirely on one workstation
(V-OAK-106-02: Windows 11, Docker Desktop + WSL2, NVIDIA RTX PRO 4000 Blackwell 24 GB).
No external paid LLM APIs. Selected model: **Qwen3.8-27B**, served by **Docker Desktop Model Runner**
(`docker.io/ai/qwen3.8:27b`, GGUF UD-Q4_K_M on llama.cpp with CUDA).

Status: **Phase 1** (project structure, Docker network, GPU verification, model compatibility check,
inference backend). Backend, frontend, database, RAG and agents follow in Phases 2-6;
see [docs/architecture.md](docs/architecture.md).

## Repository layout

```
backend/         FastAPI service (Phase 2)
frontend/        React + TypeScript + Vite + Tailwind (Phase 3)
inference/       configs/ (inference profile + model registry seeds), scripts/ (container-side checks)
infrastructure/  nginx/, database/, qdrant/ configs (Phase 2+)
scripts/         PowerShell operations scripts (one per service + checks)
docs/            architecture, model configuration, troubleshooting
```

Persistent platform data lives outside the containers in `C:\university-ai\`
(`postgres\`, `qdrant\`, `logs\`, `backups\`). The model itself is stored by Docker Model Runner
under `%USERPROFILE%\.docker\models`.

## Prerequisites (Windows)

1. NVIDIA Windows driver with WSL2 support (tested: 621.14). Do **not** install a CUDA toolkit or Linux
   NVIDIA drivers inside WSL2.
2. Docker Desktop (tested: 4.98.0, engine 29.9.2) with the WSL2 backend and **Model Runner** available
   (Settings > AI). `start-inference.ps1` enables it with GPU support and localhost-only TCP.
3. Git, and ~25 GB free under `%USERPROFILE%` for the model (17.5 GB).
4. Recommended: plug monitors into the motherboard (iGPU) so the RTX card's VRAM is not shared with the desktop.

## Install and start inference (Phase 1)

Run from the repository root in PowerShell. If scripts are blocked, prefix each with
`powershell -ExecutionPolicy Bypass -File`.

```powershell
# 1. Data directories, .env, Docker network 'university-ai'
.\scripts\setup.ps1

# 2. GPU, Model Runner, VRAM and disk compatibility check (writes C:\university-ai\logs\compatibility-check.json)
.\scripts\gpu-check.ps1

# 3. Enable Model Runner (GPU, TCP 127.0.0.1:12434), pull the model only after a PASS from step 2,
#    verify its digest, apply context size / keep-alive, load it
.\scripts\start-inference.ps1

# 4. Smoke-test the OpenAI-compatible API (models, chat, thinking, tools, streaming, container access)
.\scripts\test-inference.ps1          # add -Benchmark for 1 vs 4 parallel tok/s
```

API endpoints (OpenAI-compatible, no API key):

| Client | Base URL | Model id |
| --- | --- | --- |
| Containers (backend) on `university-ai` | `http://model-runner.docker.internal/engines/v1` | `docker.io/ai/qwen3.8:27b` |
| Host, local testing | `http://127.0.0.1:12434/engines/v1` | same |

Model Runner binds its TCP port to 127.0.0.1 only; it is not reachable from the LAN. Students will reach
the model only through nginx and the backend (Phase 2), which adds authentication.

## Operations

| Task | Command |
| --- | --- |
| Status (GPU, network, containers, Model Runner, API) | `.\scripts\status.ps1` |
| Apply a changed profile | `.\scripts\gpu-check.ps1; .\scripts\start-inference.ps1 -Reload` |
| Loaded models / runtime config | `docker model ps`, `docker model configure show ai/qwen3.8:27b` |
| Model Runner logs | `docker model logs` |
| GPU usage | `nvidia-smi` |
| Stop everything and unload the model (data and model kept) | `.\scripts\stop-all.ps1` (add `-Remove` to delete containers) |

## Documentation

- [docs/architecture.md](docs/architecture.md): architecture, risks, deviations from the spec, phase plan
- [docs/model-configuration.md](docs/model-configuration.md): model artifact, VRAM math, measured performance, history
- [docs/troubleshooting.md](docs/troubleshooting.md): known failure modes
