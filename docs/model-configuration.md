# Model configuration

Selected target model: **Qwen/Qwen3.8-27B**. Served checkpoint: **RedHatAI/Qwen3.8-27B-INT4**
(revision `e45c27e8f463817db788d141a73a3c235a0a7c0c`) on **vLLM v0.34.0**.
Research and verification date: 2026-11-17, on V-OAK-106-02.

## Files

| File | Purpose |
| --- | --- |
| `inference/configs/qwen3.8-27b-int4.env` | Inference profile: checkpoint, revision, serving limits, compatibility-check inputs. Passed to the container with `--env-file`. |
| `inference/configs/models/qwen3.8-27b.json` | Model-registry seed record for the backend (Phase 2). |
| `inference/scripts/entrypoint.sh` | Turns the profile into a `vllm serve` command. |
| `.env` (from `.env.example`) | Host paths, pinned images, `INFERENCE_PROFILE`, API key. |

Changing any value in the profile changes its hash, so `gpu-check.ps1` must pass again before
`download-model.ps1` or `start-inference.ps1` will run.

## Hardware facts (measured)

| Item | Value | Source |
| --- | --- | --- |
| GPU | NVIDIA RTX PRO 4000 Blackwell, compute capability **12.0 (sm_120)** | `nvidia-smi --query-gpu=compute_cap` |
| VRAM | 24,467 MiB = 23.89 GiB total; 1.9-2.2 GiB used by the Windows desktop (the card drives the display) | `nvidia-smi` |
| Driver | 621.14 (Windows), CUDA UMD 13.5; container sees driver 620.70.03 / KMD 621.14 | `nvidia-smi` host + container |
| Docker | Desktop 29.9.2, WSL2 engine, `nvidia` runtime registered, 64 GB / 24 CPUs to the VM | `docker info` |
| GPU in container | `docker run --rm --gpus all nvidia/cuda:13.0.2-base-ubuntu24.04 nvidia-smi` OK | gpu-check |

## Model facts (from Hugging Face, verified)

`Qwen/Qwen3.8-27B` exists (Apache-2.0, not gated, sha `37561816`). `config.json`:
`Qwen3_5ForConditionalGeneration` (vision-language), 27.78 B parameters (BF16), 64 layers in a
3:1 hybrid: **48 Gated DeltaNet linear-attention layers** (fixed-size recurrent state) and
**16 full-attention layers** (GQA 24 Q / 4 KV heads, head_dim 256), vocab 248,320, untied embeddings,
262,144 native context (1 M with YaRN), built-in MTP head. Thinking mode on by default.

Qwen's own deployment guidance (model card): use SGLang, vLLM or TokenSpeed, latest versions;
`--reasoning-parser qwen3`, `--tool-call-parser qwen3_coder`; sampling
thinking `temperature=1.0, top_p=0.95, top_k=20`, non-thinking `temperature=0.7, top_p=0.8, top_k=20, presence_penalty=1.5`.
The vLLM recipe requires vLLM >= 0.17.0 and transformers >= 5.8.0 (image ships 5.22.2).

## Checkpoints considered

Sizes are the sum of `*.safetensors` from the Hub API.

| Repository | Format | Size | Fits 24 GB here? | Notes |
| --- | --- | --- | --- | --- |
| Qwen/Qwen3.8-27B | BF16 | 55.56 GB | No | Official. |
| Qwen/Qwen3.8-27B-FP8 | FP8 block | 30.87 GB | No | Official; only other Qwen-published variant. |
| Inferact/Qwen3.8-27B-NVFP4 | NVFP4 W4A4 | 26.38 GB | No | vLLM recipe low-latency build. |
| unsloth/Qwen3.8-27B-NVFP4 | NVFP4 + FP8 mixed | 23.42 GB | No | |
| nvidia/Qwen3.8-27B-NVFP4 | NVFP4 MLP + FP8 attention | 21.92 GB | No (weights ~19.6 GiB text-only + overhead > budget) | Tested by NVIDIA on GB300; SGLang/vLLM verified on 32 GB sm_120 cards only. |
| RedHatAI/Qwen3.8-27B-MXFP4 | MXFP4 W4A4 (compressed-tensors) | 19.83 GB | Marginal (~20.2 GiB needed vs 20.55 budget) | vLLM: real W4A4 on SM100+, Marlin W4A16 fallback elsewhere; sm_120 path not verified. Runner-up. |
| amd/Qwen3.8-27B-Quark-AWQ-MXFP4 | Quark MXFP4 | 19.80 GB | Not evaluated | AMD-targeted export. |
| **RedHatAI/Qwen3.8-27B-INT4** | **INT4 W4A16, group 128 (AWQ + GPTQ)** | **18.60 GB + 0.85 GB MTP** | **Yes** | **Selected.** Recovery vs BF16: IFEval 99.7 %, MMLU-Pro 98.8 %, GPQA-D 98.5 %, AIME25 98.7 %, MATH-500 99.5 %. FP8 KV scales included. |
| GGUF builds (unsloth, bartowski, ggml-org, ...) | Q2-Q8 | various | Some | llama.cpp ecosystem, not vLLM/SGLang (§3); fallback only with CPU offload. |

No official Qwen INT4/AWQ/GPTQ/MXFP4/NVFP4 checkpoint exists; every 4-bit option is third-party.
RedHatAI is the org behind llm-compressor/compressed-tensors used by vLLM itself.

## Engine choice: vLLM over SGLang

- **SGLang** cookbook (v0.5.19) documents BF16, FP8 and NVFP4 checkpoints only, with the smallest
  validated card being the 32 GB RTX 5090. No INT4 W4A16 recipe for this model; the NVFP4 builds do not fit here.
- **vLLM** recipe lists INT4 (W4A16) and MXFP4 variants, verifies this model on sm_120 (RTX 5090), and the
  pinned image `vllm/vllm-openai:v0.34.0` (digest `sha256:20fdb089...1ce1`) is built with
  torch 2.14 + CUDA 13.0 and kernels for `sm_120`. Weight-only INT4 runs on Marlin kernels (sm_80+),
  so it does not depend on FP4 tensor-core paths whose sm_120 support differs from datacenter Blackwell (sm_100).
- Verified in the image: `--language-model-only`, `--enforce-eager`, `--kv-cache-dtype`,
  `--mamba-ssm-cache-dtype`, `qwen3_coder` / `qwen3_xml` tool parsers exist; request logging is opt-in
  (`--enable-log-requests` is off), so prompts are not logged by default (§12).

## VRAM math (24 GB card)

Per-token and per-sequence costs from `config.json` (matching the SGLang cookbook's figures):

- Full-attention KV cache: 16 layers x 4 KV heads x 256 x (K+V) = 16,384 values/token
  -> **32 KiB/token in FP8**, 64 KiB/token in BF16. 16K tokens = 0.5 GiB (FP8).
- Gated DeltaNet state: 48 layers x 48 heads x 128 x 128 x fp32 + conv state = **153.9 MB per sequence**
  (78.4 MB at bf16), independent of context length.

Budget for the selected profile (`GPU_MEMORY_UTILIZATION=0.86` -> 0.86 x 23.89 = **20.55 GiB**):

| Component | GiB |
| --- | --- |
| INT4 weights, text-only, MTP head not loaded (measured: "Model loading took 16.71 GiB") | 16.7 |
| CUDA context / non-torch (~1.1) + activation peak at 4,096 batched tokens, eager (0.57) (measured) | 1.7 |
| KV for one full 16,384-token sequence (FP8) | 0.5 |
| Linear-attention state, 4 sequences (fp32) | 0.57 |
| **Required minimum** | **19.47** |
| Spare for additional KV (shared by concurrent requests) | ~1.1 |

Pre-measurement estimates were 16.5 GiB weights / 1.5 GiB overhead (19.07 GiB required); the profile now
carries the measured values.

The 0.86 budget plus ~2 GiB desktop usage leaves ~1.3 GiB of the card untouched, which vLLM needs for
allocations outside its budget (e.g. CUDA graph capture is what failed on a 32 GB RTX 5090 with NVFP4,
hence `ENFORCE_EAGER=true` until measured). vLLM also requires `0.86 x total` to be **free** at startup;
`gpu-check.ps1` checks this with a 0.5 GiB margin.

Why the bigger options fail: FP8 weights alone are 28.7 GiB; NVIDIA NVFP4 text-only weights ~19.6 GiB + 1.5 GiB
overhead already exceed the 20.55 GiB budget before any KV cache.

## Offload / fallback options (not used; recorded for decisions)

- **vLLM `--cpu-offload-gb`** with the official FP8 build (~6-8 GiB offloaded): stays on an official Qwen
  artifact but streams weights over PCIe every step; under WSL2 pinned memory is disabled, so expect
  single-digit tokens/s. Not suitable for multi-user serving.
- **llama.cpp + GGUF with partial offload**: workable for a single user, but outside the §3 engine set.
- **Smaller model** (e.g. a smaller Qwen): only with explicit approval, and it must be registered as a
  separate model; the platform would continue to show Qwen3.8-27B as the selected target (§2).
- **Move the display to the iGPU**: not an offload, but frees ~2 GiB and is the cheapest improvement.

## Serving profile (conservative defaults)

| Setting | Value | Why |
| --- | --- | --- |
| `MAX_MODEL_LEN` | 16384 | Leaves KV headroom for 4 sequences; raise after measuring the KV pool. |
| `MAX_NUM_SEQS` | 4 | Each sequence also reserves 154 MB of linear-attention state. |
| `MAX_NUM_BATCHED_TOKENS` | 4096 | Bounds prefill activation memory and decode stalls. |
| `GPU_MEMORY_UTILIZATION` | 0.86 | Must be free at startup while the desktop uses ~2 GiB. |
| `KV_CACHE_DTYPE` | fp8 | Checkpoint ships FP8 KV scales; halves KV memory. |
| `LANGUAGE_MODEL_ONLY` | true | Skips the vision tower (no image input in Phase 1). |
| `ENFORCE_EAGER` | true | Avoids CUDA-graph capture outside the memory budget; costs decode speed. |
| `REASONING_PARSER` / `TOOL_CALL_PARSER` | qwen3 / qwen3_coder | Qwen + vLLM recipe guidance. |

## Tuning procedure

1. Edit the profile (one change at a time), run `scripts\gpu-check.ps1`, then
   `scripts\start-inference.ps1 -Recreate` and `scripts\test-inference.ps1`.
2. Read the KV pool from `docker logs university-ai-inference` (`GPU KV cache size: N tokens`, `Maximum concurrency`).
3. Candidates in order: `ENFORCE_EAGER=false` (faster decode, needs ~0.5-1 GiB outside the budget),
   `MAX_MODEL_LEN=32768`, MTP speculative decoding via
   `EXTRA_VLLM_ARGS=--speculative-config {"method":"mtp","num_speculative_tokens":1}` (loads the 0.85 GB MTP head).

## Measured results (2026-11-17, profile above, eager mode)

| Metric | Value |
| --- | --- |
| Download (19.45 GB, unauthenticated HF) | ~5 min (~65 MB/s); SHA-256 of both safetensors files matches the Hub LFS oids |
| Weight load from `C:\university-ai\models` (9P bind mount) | 55.7 s; container healthy 152 s after `docker run` |
| Kernels selected | `MarlinLinearKernel` (CompressedTensorsWNA16), FlashInfer GDN prefill, FLASHINFER attention |
| vLLM memory | free at start 22.4 / 23.87 GiB; weights + non-torch 17.8 GiB; peak activations 0.57 GiB; KV cache 2.15 GiB available |
| KV pool | 18,022 tokens (extended to 22 blocks of 1,600 tokens); max concurrency at a full 16,384-token request: **1.10x** |
| GPU memory in use while serving | 21.3 / 23.9 GiB (incl. ~2 GiB desktop) |
| Decode, 1 request x 512 tokens | 17.9 tok/s |
| Decode, 4 parallel x 512 tokens | 66.5 tok/s aggregate, 17.2 tok/s per request |

Interpretation: four short/medium conversations can decode in parallel at ~17 tok/s each, but only about one
request can use the full 16K window at a time; the backend queue (Phase 2) must enforce this. Eager mode costs
decode speed (the card's ~670 GB/s bandwidth over ~16.7 GiB of weights allows roughly 2x more); CUDA graphs and
MTP are the first tuning steps.
