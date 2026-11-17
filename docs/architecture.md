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
          [university-ai-postgres] [university-ai-qdrant] [university-ai-inference]
                                                           vLLM, OpenAI-compatible, GPU
  All containers: private bridge network `university-ai`; no DB/vector/inference ports published
  (inference optionally on 127.0.0.1:8000 for local testing only).
```

| Container | Role | Persistent data | Phase |
| --- | --- | --- | --- |
| university-ai-inference | vLLM serving Qwen3.8-27B (INT4 build), OpenAI-compatible API, API-key protected | `C:\university-ai\models` (ro) | 1 |
| university-ai-backend | FastAPI: auth/RBAC, model registry + provider abstraction, routing, request queue, chat, RAG, agents | logs | 2 |
| university-ai-postgres | users, departments, conversations, messages, usage | `C:\university-ai\postgres` | 2 |
| university-ai-frontend | React/TS/Vite/Tailwind student + admin UI | none | 3-4 |
| university-ai-qdrant | embeddings / RAG | `C:\university-ai\qdrant` | 5 |
| university-ai-nginx | reverse proxy, TLS termination | certs/config | 2-3 |

Each container is started, stopped and restarted by its own PowerShell script (`scripts\start-*.ps1`);
no Docker Compose (§1, §16). All base images are pinned to explicit tags (§4).

### Multi-model design (§5)

The backend never hardcodes Qwen. The inference container is one *provider endpoint*; the backend's
model registry (Phase 2, Postgres-backed, seeded from `inference/configs/models/*.json`) records model
ID, display name, provider, repository, engine, quantization, context window, endpoint, enabled flag,
GPU requirements and default generation settings. Phase 1 ships the seed record for
`qwen3.8-27b` so the registry has a single source of truth for what the inference container serves.
Adding a model = new inference profile (`inference/configs/<profile>.env`) + registry record.

### Request path and capacity (§11)

One 24 GB GPU serves one 27B model. vLLM is configured for at most 4 concurrent sequences; the backend
(Phase 2) owns the fair-share queue, per-user rate limits, max context / output tokens, timeouts and
cancellation, and returns a graceful "busy" response instead of overloading the GPU. 20-50 registered
students are expected, not 50 simultaneous generations; no concurrency claim is made without the
Phase 6 load test.

## Model selection summary

Full evidence: [model-configuration.md](model-configuration.md).

- Target model (what the platform identifies as selected): **Qwen/Qwen3.8-27B**.
- Served checkpoint: **RedHatAI/Qwen3.8-27B-INT4** (weight-only INT4 W4A16 of the same model, revision
  `e45c27e8`), because BF16 (55.6 GB) and the official FP8 build (30.9 GB) cannot fit in 24 GB.
- Engine: **vLLM v0.34.0** (`vllm/vllm-openai:v0.34.0`, CUDA 13.0, compiled for sm_120).

## GPU / model compatibility risks

| # | Risk | Impact | Mitigation |
| --- | --- | --- | --- |
| 1 | The RTX PRO 4000 also drives the Windows display (WDDM); desktop apps hold 1.9-2.2 GiB and it fluctuates. | vLLM refuses to start if free VRAM < its budget; less KV cache. | `gpu-check.ps1` requires budget + 0.5 GiB free. **Recommended:** connect monitors to the Core Ultra 9 285K iGPU (motherboard output) to free ~2 GiB. |
| 2 | 24 GB is below every official Qwen artifact (BF16, FP8). | Must use a third-party 4-bit build. | RedHatAI INT4 (vLLM/llm-compressor maintainers; 98.5-101 % benchmark recovery reported). Disclosed in the registry `quantization` field; no silent substitution. |
| 3 | FP4 formats (NVFP4/MXFP4 W4A4) are validated on 32 GB sm_120 cards only; NVFP4 builds are 21.9-26.4 GB. | Would not fit / unverified on this card. | Weight-only INT4 uses Marlin kernels (sm_80+), no FP4 tensor-core dependency. |
| 4 | Thin VRAM headroom (~1.5 GiB beyond one 16K sequence). | Low context x concurrency envelope. | Conservative profile: 16K context, 4 seqs, fp8 KV, text-only, eager mode; tune from measured KV pool. |
| 5 | WSL2: vLLM disables pinned memory; model loads over the Windows bind mount. | Slower load and host<->GPU copies; CPU offload impractical. | Offload not used. Weights read once at start. |
| 6 | Hybrid Gated DeltaNet architecture (48 linear + 16 full-attention layers) is new. | Engine bugs / kernel gaps on sm_120. | vLLM recipe verifies this model family on RTX 5090 (sm_120); engine image pinned, upgrades tested via profile. |
| 7 | Vision tower disabled (`--language-model-only`). | No image input in Phase 1. | Re-enable in a later profile if VRAM allows (costs ~0.9 GiB + encoder cache). |
| 8 | vLLM v0.34.0 is one day old. | Possible regressions. | Validated end-to-end on this machine by `scripts\test-inference.ps1`; previous image tags remain available. |

## Phase plan (§14)

| Phase | Scope | Exit criteria |
| --- | --- | --- |
| 1 (this) | Repo structure, Docker network, GPU verification, model compatibility check, gated model download, Qwen inference container | `gpu-check.ps1` PASS; `test-inference.ps1` PASS against the running container |
| 2 | FastAPI backend, PostgreSQL + Alembic, JWT auth/RBAC (no public registration), model registry + provider interface + health checks, request queue/limits, nginx | Backend tests (auth, authz, registry, health, chat API, limits) green; `/api/models` returns Qwen3.8-27B |
| 3 | React student chat: streaming, Markdown/code highlighting, history, rename/delete, regenerate/stop, usage modes | E2E chat through nginx |
| 4 | Admin dashboard: users/departments, enable/disable models, GPU/container health, usage stats | Admin flows tested |
| 5 | Qdrant + RAG: upload/extract/chunk/embed, per-user isolation, citations | Document isolation tests |
| 6 | Agent tools with allowlist, isolated Python sandbox container, security hardening, load test | Load-test report sets the published concurrency limits |
