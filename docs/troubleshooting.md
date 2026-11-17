# Troubleshooting

## Scripts

- **"running scripts is disabled on this system"**: run with
  `powershell -ExecutionPolicy Bypass -File .\scripts\<name>.ps1`.
- **"Docker engine is not reachable"**: start Docker Desktop and wait until the engine is running
  (`docker info` succeeds).
- **download-model / start-inference refuse to run**: they require a PASS from `scripts\gpu-check.ps1`
  for the current profile within 24 h. Re-run the check; any profile edit invalidates the previous result.

## GPU

- **`vram.free_at_start` FAIL/WARN**: the RTX card also drives the desktop. Close GPU-heavy apps
  (browsers with many tabs, Creative Cloud, video calls), or connect monitors to the motherboard iGPU.
  Lowering `GPU_MEMORY_UTILIZATION` also works but shrinks the KV cache; re-run gpu-check afterwards.
- **`docker run --gpus all` fails**: update the Windows NVIDIA driver, restart Docker Desktop, and make sure
  no Linux NVIDIA driver was installed inside WSL2.

## Inference container

- **Exits during startup with `ValueError: Free memory on device ... is less than desired GPU memory utilization`**:
  same cause as `vram.free_at_start`; free VRAM or lower `GPU_MEMORY_UTILIZATION`.
- **`torch.OutOfMemoryError` during CUDA graph capture** after setting `ENFORCE_EAGER=false`: graph capture
  allocates outside vLLM's budget. Set it back to `true` or lower `GPU_MEMORY_UTILIZATION`.
- **`max_model_len ... is larger than the maximum number of tokens that can be stored in KV cache`**:
  lower `MAX_MODEL_LEN` or `MAX_NUM_SEQS`.
- **`Using 'pin_memory=False' as WSL is detected`**: expected under Docker Desktop/WSL2; harmless.
- **Slow first start**: weights (~18.6 GB) are read through the Windows bind mount; allow several minutes.
- **Answers contain `<think>` text or are cut off early**: thinking is on by default. Keep
  `REASONING_PARSER=qwen3`, raise `max_tokens`, or send `chat_template_kwargs: {"enable_thinking": false}`.
