# University Local AI Platform

Self-hosted AI chat platform for university students, running entirely on one workstation
(V-OAK-106-02: Windows 11, Docker Desktop + WSL2, NVIDIA RTX PRO 4000 Blackwell 24 GB).
No external paid LLM APIs. Selected model: **Qwen3.8-27B** (served as the RedHatAI INT4 build on vLLM).

Status: **Phase 1** (project structure, Docker network, GPU verification, model compatibility check,
inference container). Backend, frontend, database, RAG and agents follow in Phases 2-6;
see [docs/architecture.md](docs/architecture.md).

## Repository layout

```
backend/         FastAPI service (Phase 2)
frontend/        React + TypeScript + Vite + Tailwind (Phase 3)
inference/       Dockerfile, configs/ (profiles + model registry seeds), scripts/ (container-side)
infrastructure/  nginx/, database/, qdrant/ configs (Phase 2+)
scripts/         PowerShell operations scripts (one per container + checks)
docs/            architecture, model configuration, troubleshooting
```

Persistent data lives outside the containers in `C:\university-ai\`
(`models\`, `hf-cache\`, `postgres\`, `qdrant\`, `logs\`, `backups\`).

## Prerequisites (Windows)

1. NVIDIA Windows driver with WSL2 support (tested: 621.14). Do **not** install a CUDA toolkit or Linux
   NVIDIA drivers inside WSL2; Docker Desktop provides GPU access.
2. Docker Desktop (tested: 29.9.2) using the WSL2 backend and Linux containers.
3. Git, and ~25 GB free on the drive holding `C:\university-ai\`.
4. Recommended: plug monitors into the motherboard (iGPU) so the RTX card's VRAM is not shared with the desktop.

## Install and start inference (Phase 1)

Run from the repository root in PowerShell. If scripts are blocked, prefix each with
`powershell -ExecutionPolicy Bypass -File`.

```powershell
# 1. Data directories, .env with generated API key, Docker network 'university-ai'
.\scripts\setup.ps1

# 2. GPU + VRAM + disk compatibility check (writes C:\university-ai\logs\compatibility-check.json)
.\scripts\gpu-check.ps1

# 3. Download the pinned checkpoint (~19.5 GB). Refuses to run without a recent PASS from step 2.
.\scripts\download-model.ps1          # detached; add -Wait to block
.\scripts\status.ps1                  # shows download progress

# 4. Build and start the inference container, wait for /health
.\scripts\start-inference.ps1

# 5. Smoke-test the OpenAI-compatible API (auth, models, chat, thinking, streaming)
.\scripts\test-inference.ps1
```

The API listens inside the Docker network at `http://university-ai-inference:8000/v1` (alias `inference`)
and, for local testing only, on `http://127.0.0.1:8000/v1`. It requires
`Authorization: Bearer <INFERENCE_API_KEY from .env>`. Set `INFERENCE_HOST_PORT=` (empty) in `.env`
to stop publishing it on localhost.

## Operations

| Task | Command |
| --- | --- |
| Status (GPU, network, containers, model, API) | `.\scripts\status.ps1` |
| Restart inference with a changed profile | `.\scripts\gpu-check.ps1; .\scripts\start-inference.ps1 -Recreate` |
| Rebuild the inference image | `.\scripts\start-inference.ps1 -Build -Recreate` |
| Logs | `docker logs -f university-ai-inference` |
| GPU usage | `nvidia-smi` |
| Stop everything (data kept) | `.\scripts\stop-all.ps1` (add `-Remove` to delete containers) |

## Documentation

- [docs/architecture.md](docs/architecture.md): architecture, risks, phase plan
- [docs/model-configuration.md](docs/model-configuration.md): checkpoint/engine evidence, VRAM math, tuning
- [docs/troubleshooting.md](docs/troubleshooting.md): known failure modes
