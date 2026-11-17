# Troubleshooting

## Scripts

- **"running scripts is disabled on this system"**: run with
  `powershell -ExecutionPolicy Bypass -File .\scripts\<name>.ps1`.
- **"Docker engine is not reachable"**: start Docker Desktop and wait until the engine is running
  (`docker info` succeeds).
- **start-inference refuses to run**: it requires a PASS from `scripts\gpu-check.ps1` for the current
  profile within 24 h. Re-run the check; any profile edit invalidates the previous result.

## GPU

- **`vram.fit` FAIL**: the RTX card also drives the desktop. Close GPU-heavy apps (browsers with many tabs,
  Creative Cloud, video calls), connect monitors to the motherboard iGPU, or lower `CONTEXT_SIZE`
  (64 KiB per token); re-run gpu-check afterwards.
- **Generation suddenly much slower with VRAM near full**: Windows (WDDM) spills GPU allocations into
  shared system memory instead of failing. Check `nvidia-smi`; free VRAM or lower `CONTEXT_SIZE`, then
  `start-inference.ps1 -Reload`.
- **`docker run --gpus all` fails** (`docker.gpu` WARN): update the Windows NVIDIA driver, restart Docker
  Desktop, and make sure no Linux NVIDIA driver was installed inside WSL2. Model Runner runs on the host
  and does not need this, but other GPU containers do.

## Docker Model Runner

- **Chat in Docker Desktop spins forever / requests hang; `docker model status` shows llama.cpp
  "not installed" or an install error mentioning `com.docker.nv-gpu-info.exe`**: the backend installer
  needs `%USERPROFILE%\.docker\bin\inference`. Create it, copy the bundled binaries and restart Desktop
  (Model Runner then downloads the CUDA build into the same folder):

  ```powershell
  New-Item -ItemType Directory -Force "$env:USERPROFILE\.docker\bin\inference" | Out-Null
  Copy-Item "$env:ProgramFiles\Docker\Docker\resources\model-runner\bin\*" "$env:USERPROFILE\.docker\bin\inference\" -Force
  docker desktop restart
  ```

  Then `docker model status` must show `llama.cpp ... Running ... b9879-cuda`.
- **`dmr.backend` FAIL because the backend is not CUDA (CPU only, very slow)**: re-enable with GPU
  support and restart Desktop: `docker desktop enable model-runner --gpu=enable --tcp=12434 --cors=none`.
- **`docker desktop enable model-runner --tcp 12434` hangs**: use the `--flag=value` form shown above.
- **`dmr.tcp` FAIL (bound to a non-loopback address)**: do not expose Model Runner on the LAN; it has no
  authentication. Re-run the enable command above, which binds to 127.0.0.1.
- **`dmr.model` FAIL (digest differs)**: the `ai/qwen3.8:27b` tag was updated on Docker Hub. Do not use it
  unverified: test the new digest with `test-inference.ps1`, then update `MODEL_DIGEST` in the profile
  (and the registry seed) deliberately.
- **`docker model unload --all` says "No models are running" while `docker model ps` lists the model**:
  happens with keep-alive `-1`. Unload by the listed name, e.g. `docker model unload qwen3.8:27b`;
  `stop-all.ps1` does this.
- **First request after a while takes ~13 s**: the model was unloaded. The profile sets `KEEP_ALIVE=-1`
  (stay loaded); check with `docker model configure show ai/qwen3.8:27b`.
- **Backend container cannot reach the model**: use `http://model-runner.docker.internal/engines/v1`
  (not `localhost`) and the model id `docker.io/ai/qwen3.8:27b`; `test-inference.ps1` checks this path.
- **Answers are empty or cut off**: thinking mode is on by default and the reasoning is returned in
  `reasoning_content`. Raise `max_tokens` or send `chat_template_kwargs: {"enable_thinking": false}`.
