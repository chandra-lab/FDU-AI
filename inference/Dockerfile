# university-ai-inference: pinned vLLM OpenAI-compatible server + project entrypoint.
# Build: scripts\start-inference.ps1 -Build   (or: docker build -t <INFERENCE_IMAGE> inference)
ARG VLLM_IMAGE=vllm/vllm-openai:v0.34.0
FROM ${VLLM_IMAGE}

COPY scripts/entrypoint.sh /opt/uai/entrypoint.sh
RUN sed -i 's/\r$//' /opt/uai/entrypoint.sh && chmod 0755 /opt/uai/entrypoint.sh

# Weights are pre-downloaded by scripts/download-model.ps1; never fetch from the Hub at runtime.
ENV HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1 \
    HF_HUB_DISABLE_TELEMETRY=1 \
    VLLM_NO_USAGE_STATS=1 \
    DO_NOT_TRACK=1

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=900s --retries=3 \
  CMD python3 -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4).status == 200 else 1)"

ENTRYPOINT ["/opt/uai/entrypoint.sh"]
