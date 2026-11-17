#!/usr/bin/env bash
# Builds the `vllm serve` command from the profile env file (inference/configs/*.env)
# passed with --env-file. The API key comes from VLLM_API_KEY, which vLLM reads itself.
set -euo pipefail

: "${MODEL_PATH:?MODEL_PATH must point at the downloaded checkpoint, e.g. /models/RedHatAI--Qwen3.8-27B-INT4}"
: "${SERVED_MODEL_NAME:?}" "${MAX_MODEL_LEN:?}" "${MAX_NUM_SEQS:?}" "${GPU_MEMORY_UTILIZATION:?}"

if [[ ! -f "${MODEL_PATH}/config.json" ]]; then
  echo "ERROR: ${MODEL_PATH}/config.json not found. Run scripts/download-model.ps1 first." >&2
  exit 2
fi
if [[ -z "${VLLM_API_KEY:-}" ]]; then
  echo "ERROR: VLLM_API_KEY is not set; refusing to serve an unauthenticated API." >&2
  exit 2
fi

is_true() { [[ "${1:-false}" =~ ^(1|true|yes|on)$ ]]; }

args=(
  serve "${MODEL_PATH}"
  --served-model-name "${SERVED_MODEL_NAME}"
  --host 0.0.0.0
  --port 8000
  --max-model-len "${MAX_MODEL_LEN}"
  --max-num-seqs "${MAX_NUM_SEQS}"
  --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION}"
)
[[ -n "${MAX_NUM_BATCHED_TOKENS:-}" ]] && args+=(--max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS}")
[[ -n "${KV_CACHE_DTYPE:-}" ]] && args+=(--kv-cache-dtype "${KV_CACHE_DTYPE}")
is_true "${LANGUAGE_MODEL_ONLY:-}" && args+=(--language-model-only)
is_true "${ENFORCE_EAGER:-}" && args+=(--enforce-eager)
is_true "${ENABLE_PREFIX_CACHING:-}" && args+=(--enable-prefix-caching)
[[ -n "${REASONING_PARSER:-}" ]] && args+=(--reasoning-parser "${REASONING_PARSER}")
if is_true "${ENABLE_AUTO_TOOL_CHOICE:-}"; then
  args+=(--enable-auto-tool-choice --tool-call-parser "${TOOL_CALL_PARSER:?TOOL_CALL_PARSER required with auto tool choice}")
fi

# Space-separated extra flags for experiments (e.g. "--speculative-config {...}"); keep empty in production.
if [[ -n "${EXTRA_VLLM_ARGS:-}" ]]; then
  read -r -a extra <<< "${EXTRA_VLLM_ARGS}"
  args+=("${extra[@]}")
fi

echo "Starting: vllm ${args[*]}"
exec vllm "${args[@]}"
