# Model configuration

Selected target model: **Qwen/Qwen3.8-27B**. Served artifact: **`docker.io/ai/qwen3.8:27b`**
(digest `sha256:c3858e9716a395da25ba17d1f8e9eb7ff740a399fc5ff182ac99741ada149490`) on
**Docker Desktop Model Runner** with **llama.cpp b9879-cuda**.
Research, measurement and verification date: 2026-11-17, on V-OAK-106-02.

## Files

| File | Purpose |
| --- | --- |
| `inference/configs/qwen3.8-27b-dmr.env` | Inference profile: model reference + tested digest, context size, keep-alive, endpoints, compatibility-check inputs. |
| `inference/configs/models/qwen3.8-27b.json` | Model-registry seed record for the backend (Phase 2). |
| `inference/scripts/net-check.py` | Run in a container on `university-ai` by `test-inference.ps1` to verify the backend's path. |
| `.env` (from `.env.example`) | Host paths, pinned test images, `INFERENCE_PROFILE`. |

Changing any value in the profile changes its hash, so `gpu-check.ps1` must pass again before
`start-inference.ps1` will pull or load the model.

## Hardware facts (measured)

| Item | Value | Source |
| --- | --- | --- |
| GPU | NVIDIA RTX PRO 4000 Blackwell, compute capability **12.0 (sm_120)** | `nvidia-smi --query-gpu=compute_cap` |
| VRAM | 24,467 MiB = 23.89 GiB total; ~2 GiB used by the Windows desktop (the card drives the display) | `nvidia-smi` |
| Driver | 621.14 (Windows), CUDA 13.5 | `nvidia-smi` |
| Docker | Desktop 4.98.0, engine 29.9.2, WSL2; Model Runner with llama.cpp `b9879-cuda` | `docker model status` |

## Model facts (from Hugging Face, verified)

`Qwen/Qwen3.8-27B` (Apache-2.0, sha `37561816`): `Qwen3_5ForConditionalGeneration` (vision-language),
27.78 B parameters, 64 layers in a 3:1 hybrid: **48 Gated DeltaNet linear-attention layers**
(fixed-size recurrent state) and **16 full-attention layers** (GQA 24 Q / 4 KV heads, head_dim 256),
262,144 native context. Thinking mode on by default.
Qwen's sampling guidance: thinking `temperature=1.0, top_p=0.95, top_k=20`; non-thinking
`temperature=0.7, top_p=0.8, top_k=20, presence_penalty=1.5` (stored in the registry seed).

## Served artifact

| Item | Value |
| --- | --- |
| Reference | `ai/qwen3.8:27b` (Docker Hub, served id `docker.io/ai/qwen3.8:27b`) |
| Format | GGUF (`docker model inspect`: `"format": "gguf"`) |
| Weights | `Qwen3.8-27B-UD-Q4_K_M.gguf`, 16.56 GB (15.43 GiB): Unsloth Dynamic 4-bit, Q4_K_M base with selected tensors kept at higher precision |
| Vision projector | `mmproj-F16.gguf`, 0.93 GB, loaded (image input available) |
| Engine | llama.cpp `b9879-cuda` in Model Runner, all layers offloaded to the GPU |
| Runtime config | `docker model configure --context-size=32768 --keep-alive=-1 ai/qwen3.8:27b` |
| Parallelism | 4 slots sharing one unified KV cache of 32,768 tokens (F16) |
| Storage | `%USERPROFILE%\.docker\models` (~17.5 GB) |

Docker Hub tags are mutable, so the profile pins `MODEL_DIGEST`; `gpu-check.ps1` fails if the local
artifact has another digest and `start-inference.ps1` refuses to serve it.

The `UD-` file prefix is Unsloth's "Dynamic" quantization naming; the artifact metadata does not
record the upstream conversion further. A 4-bit GGUF is not an official Qwen artifact, which is
disclosed in the registry `quantization_format`.

## VRAM math (24 GB card, 32K context)

- Full-attention KV cache (F16): 16 layers x 4 KV heads x 256 x (K+V) x 2 bytes = **64 KiB/token**;
  32,768 tokens = **2.0 GiB**.
- Gated DeltaNet state: **~154 MB per slot**, independent of context length (~0.6 GiB for 4 slots).

| Component | GiB |
| --- | --- |
| Weights + projector + recurrent state + compute buffers (`EST_BASE_GIB`) | 16.6 |
| KV cache, 32,768 tokens F16 | 2.0 |
| **Model total (measured 18.65 GiB)** | **18.6** |
| Safety margin required free by `gpu-check.ps1` | 1.0 |
| Windows desktop (measured) | ~2.0 |
| GPU in use while serving (measured) | 21.2 of 23.9 |

llama.cpp has no memory budget flag, and under Windows WDDM an overrun can spill into shared system
memory and get much slower rather than fail, so the check runs before loading. Doubling the context to
65,536 tokens adds 2 GiB and leaves no margin with the desktop on this card.

## Measured results (2026-11-17, profile above)

| Metric | Value |
| --- | --- |
| Load time (files in OS cache) | 12-13 s to first answer (`start-inference.ps1` warm-up) |
| Decode, 1 request x 512 tokens | 27.1-27.7 tok/s (logs: 28.6-30 tok/s server-side) |
| Decode, 4 parallel x 512 tokens | **78.2 tok/s aggregate, 20.0 tok/s per request** |
| Prompt processing (logs) | ~80 tok/s for short prompts |
| Thinking mode (default) | Reasoning returned separately in `message.reasoning_content`; answer in `content` |
| Non-thinking | `chat_template_kwargs: {"enable_thinking": false}`; no reasoning text |
| Tool calling | OpenAI `tools` -> `finish_reason: tool_calls` with JSON arguments |
| Streaming | SSE chunks ending with `data: [DONE]` |
| Exposure | 127.0.0.1:12434 only; refused on the LAN address; reachable from containers via `model-runner.docker.internal` |
| Prompt logging | Prompts do not appear in `docker model logs` |

Interpretation: four conversations can decode in parallel at ~20 tok/s each. The 32K-token KV cache is
shared by the 4 slots, so the backend (Phase 2) must cap per-request context (e.g. 8K each when all 4
are busy) and queue the rest.

## Tuning procedure

1. Edit the profile (one change at a time), run `scripts\gpu-check.ps1`, then
   `scripts\start-inference.ps1 -Reload` and `scripts\test-inference.ps1 -Benchmark`.
2. Check VRAM with `nvidia-smi` and the load log with `docker model logs`.
3. Candidates: move the display to the iGPU (frees ~2 GiB) and then raise `CONTEXT_SIZE` to 65536;
   update `EST_BASE_GIB` from the new measurement.

## History: why the vLLM container was replaced

Phase 1 first served **RedHatAI/Qwen3.8-27B-INT4** (INT4 W4A16, 18.6 GB) on **vLLM v0.34.0**
(`vllm/vllm-openai:v0.34.0`, sm_120 kernels) in the `university-ai-inference` container, because BF16
(55.6 GB) and the official FP8 build (30.9 GB) do not fit and NVFP4 builds (21.9-26.4 GB) were validated
only on 32 GB cards. It worked (16K context, 4 sequences, FP8 KV, text-only, eager mode) but measured
17.9 tok/s single and 66.5 tok/s for 4 parallel requests, and it could not run alongside the user's
Model Runner model in 24 GB.

On 2026-11-17 the user chose Docker Desktop Model Runner (`ai/qwen3.8:27b`) as the only inference
backend. The vLLM Dockerfile, entrypoint, download script and profile were removed, and the RedHatAI
weights (19.47 GB) and the `vllm/vllm-openai` image were deleted with the user's approval. Model Runner
is faster here (28 / 78 tok/s), supports 32K context and vision, and is maintained by Docker Desktop;
the trade-offs are listed under "Deviations from the spec" in [architecture.md](architecture.md).
