# Architecture

University Local AI Platform on workstation V-OAK-106-02 (Windows 11, Docker Desktop + WSL2,
NVIDIA RTX PRO 4000 Blackwell 24 GB). Source of requirements: the project spec (sections cited as §n).

## Starting point (Phase 1 inspection, 2026-11-17)

- `FDU-AI/` was empty: no code, dependencies or git history, so nothing was overwritten.
- The repository root **is** the spec's `university-ai/` tree (§13). A nested `university-ai/` folder
  would only add a level; persistent data lives separately under `C:\university-ai\` (§4).
- Pre-existing on the host and left untouched: WSL distro `FDU-GPU` (stopped), Docker network
  `quantum-circuit-generation_default` and two stopped `quantum-circuit-generation-*` containers.

## System overview

```
            LAN / campus clients (HTTPS)
                        |
              [university-ai-nginx]         only published entry point (Phase 2+)
               /                 \
 [university-ai-frontend]   [university-ai-backend] -- model registry, routing, queue, auth, RAG, agents
                              |      |        |
          [university-ai-postgres] [university-ai-qdrant]   |  http://model-runner.docker.internal/engines/v1
  ------------------------------------------------------------|------------------- Docker network `university-ai`
                                                              v
                                  Docker Desktop Model Runner (Windows host process)
                                  llama.cpp b9879-cuda, Qwen3.8-27B GGUF, GPU
                                  host TCP 127.0.0.1:12434 (localhost only)
```

| Component | Role | Persistent data | Phase |
| --- | --- | --- | --- |
| Docker Model Runner | Serves Qwen3.8-27B (`ai/qwen3.8:27b`) through an OpenAI-compatible API on the GPU | `%USERPROFILE%\.docker\models` | 1 |
| university-ai-backend | FastAPI: auth/RBAC, model registry + provider abstraction, routing, request queue, chat, RAG, agents | logs | 2 |
| university-ai-postgres | users, departments, conversations, messages, usage | `C:\university-ai\postgres` | 2 |
| university-ai-frontend | React/TS/Vite/Tailwind student + admin UI | none | 3-4 |
| university-ai-qdrant | embeddings / RAG | `C:\university-ai\qdrant` | 5 |
| university-ai-nginx | reverse proxy, TLS termination | certs/config | 2-3 |

Each platform container is started, stopped and restarted by its own PowerShell script
(`scripts\start-*.ps1`); no Docker Compose (§1, §16). All container base images are pinned to explicit
tags (§4). Inference is managed by `scripts\start-inference.ps1` / `stop-all.ps1` through the
`docker model` CLI.

### How the backend reaches the model

Docker Desktop resolves `model-runner.docker.internal` inside every container to its internal Model
Runner endpoint, so the backend uses `http://model-runner.docker.internal/engines/v1` from the
`university-ai` bridge network without any published port. `host.docker.internal:12434` also works
because of the host TCP listener. Verified from a `python:3.13-slim` container on `university-ai`
(`scripts\test-inference.ps1`). The host TCP listener is bound to 127.0.0.1 and was confirmed
unreachable from the LAN address.

### Multi-model design (§5)

The backend never hardcodes Qwen. Model Runner is one *provider endpoint* (`provider: openai-compatible`);
the backend's model registry (Phase 2, Postgres-backed, seeded from `inference/configs/models/*.json`)
records model ID, display name, provider, repository, engine, quantization, context window, endpoint,
enabled flag, GPU requirements and default generation settings. Phase 1 ships the seed record for
`qwen3.8-27b`. Adding a model = new inference profile (`inference/configs/<profile>.env`) + registry record;
a vLLM or SGLang container can be added later as another provider without changing the backend.

### Request path and capacity (§11)

One 24 GB GPU serves one 27B model. llama.cpp runs 4 parallel slots sharing one 32,768-token KV cache;
the backend (Phase 2) owns the fair-share queue, per-user rate limits, max context / output tokens,
timeouts and cancellation, and returns a graceful "busy" response instead of overloading the GPU.
20-50 registered students are expected, not 50 simultaneous generations; no concurrency claim is made
without the Phase 6 load test. Measured: ~28 tok/s for one request, ~78 tok/s aggregate (20 tok/s each)
for 4 parallel requests.

## Model selection summary

Full evidence: [model-configuration.md](model-configuration.md).

- Target model (what the platform identifies as selected): **Qwen/Qwen3.8-27B**.
- Served artifact: **`docker.io/ai/qwen3.8:27b`** from Docker Hub, digest `sha256:c3858e97...9490`:
  `Qwen3.8-27B-UD-Q4_K_M.gguf` (16.56 GB, Unsloth Dynamic 4-bit) + `mmproj-F16.gguf` (0.93 GB, vision).
- Engine: **llama.cpp b9879-cuda** inside Docker Desktop Model Runner, all layers on the GPU.
- Decision (2026-11-17, user): Model Runner replaces the Phase 1 vLLM container
  (RedHatAI INT4 on vLLM v0.34.0), which was removed together with its weights and image.

## Deviations from the spec (accepted with the Model Runner decision)

| Spec | What changed | Consequence / mitigation |
| --- | --- | --- |
| §3 engines: vLLM or SGLang preferred | llama.cpp (via Model Runner) serves the model | Weaker batching than vLLM under load (4 slots, no paged attention); measured throughput is still higher than the eager-mode vLLM build. vLLM remains an option as a second provider. |
| §4 pinned image tags; §13 `inference/Dockerfile` | Inference is not a container we build or control; there is no inference Dockerfile or image tag | The model is pinned by **digest** (`MODEL_DIGEST` in the profile); `gpu-check.ps1` fails on a different digest and `start-inference.ps1` refuses to serve it. The llama.cpp backend version is reported by `status.ps1`, but Docker Desktop updates it; record it after each Desktop upgrade. |
| §1 container-per-service started by its own script | Model Runner is a Docker Desktop feature running as a host process | `start-inference.ps1` / `stop-all.ps1` still own its lifecycle (enable, configure, load, unload). |
| Inference API protected by an API key (Phase 1 vLLM design) | Model Runner has no authentication | Only reachable from 127.0.0.1 and local containers. Any local container can also call its management API (`/models` pull/delete); Phase 2+ must run only trusted containers on this host. The backend is the only component that may call it. |
| §12 no prompt logging by default | llama.cpp logs request metadata, not prompts, in `docker model logs` | Re-check after Docker Desktop upgrades. |
| GPU memory budget enforced by the engine | llama.cpp has no memory budget; on Windows (WDDM) an overrun may spill into shared system memory instead of failing | `gpu-check.ps1` checks the calculated footprint + 1 GiB margin before loading; `status.ps1` shows VRAM. |

## GPU / model compatibility risks

| # | Risk | Impact | Mitigation |
| --- | --- | --- | --- |
| 1 | The RTX PRO 4000 also drives the Windows display (WDDM); desktop apps hold ~2 GiB and it fluctuates. | Only ~2.6 GiB left free with the model loaded; spill to shared memory slows inference. | 1 GiB margin enforced by `gpu-check.ps1`. **Recommended:** connect monitors to the Core Ultra 9 285K iGPU to free ~2 GiB. |
| 2 | 24 GB is below every official Qwen artifact (BF16 55.6 GB, FP8 30.9 GB). | A third-party 4-bit build is required. | Docker Hub `ai/` namespace build of Unsloth's UD-Q4_K_M GGUF; disclosed in the registry `quantization_format`; no silent substitution. |
| 3 | Docker Desktop upgrades can replace the llama.cpp backend or change Model Runner behaviour. | Untested engine version. | Re-run `gpu-check.ps1` and `test-inference.ps1` after each Desktop upgrade. |
| 4 | Model Runner's backend install depends on `%USERPROFILE%\.docker\bin`; when missing it silently falls back to "not installed" and requests hang. | No answers (observed 2026-11-17). | `gpu-check.ps1` requires the CUDA backend to be Running; fix in troubleshooting.md. |
| 5 | Hybrid Gated DeltaNet architecture (48 linear + 16 full-attention layers) is new. | Engine bugs in llama.cpp. | Smoke tests cover chat, thinking, tools, streaming; Phase 6 load test. |
| 6 | Vision projector is loaded (0.9 GiB). | Less VRAM headroom. | Kept because the model artifact bundles it; images become usable in a later phase. |

## Phase plan (§14)

| Phase | Scope | Exit criteria |
| --- | --- | --- |
| 1 (this) | Repo structure, Docker network, GPU verification, model compatibility check, digest-verified model pull, Qwen inference via Model Runner | `gpu-check.ps1` PASS; `test-inference.ps1` PASS, including the container path |
| 2 | FastAPI backend, PostgreSQL + Alembic, JWT auth/RBAC (no public registration), model registry + provider interface + health checks, request queue/limits, nginx | Backend tests (auth, authz, registry, health, chat API, limits) green; `/api/models` returns Qwen3.8-27B |
| 3 | React student chat: streaming, Markdown/code highlighting, history, rename/delete, regenerate/stop, usage modes | E2E chat through nginx |
| 4 | Admin dashboard: users/departments, enable/disable models, GPU/container health, usage stats | Admin flows tested |
| 5 | Qdrant + RAG: upload/extract/chunk/embed, per-user isolation, citations | Document isolation tests |
| 6 | Agent tools with allowlist, isolated Python sandbox container, security hardening, load test | Load-test report sets the published concurrency limits |
