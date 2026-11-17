#!/usr/bin/env bash
# Runs inside the throwaway download container started by scripts/download-model.ps1.
# Inputs (env): MODEL_REPO, MODEL_REVISION, TARGET_DIR.
set -euo pipefail

: "${MODEL_REPO:?}" "${MODEL_REVISION:?}" "${TARGET_DIR:?}"

echo "Downloading ${MODEL_REPO}@${MODEL_REVISION} -> ${TARGET_DIR}"
hf download "${MODEL_REPO}" --revision "${MODEL_REVISION}" --local-dir "${TARGET_DIR}"

printf '{"repo":"%s","revision":"%s","status":"complete","completed_at":"%s"}\n' \
  "${MODEL_REPO}" "${MODEL_REVISION}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${TARGET_DIR}/.uai-download.json"
echo "UAI_DOWNLOAD_COMPLETE"
