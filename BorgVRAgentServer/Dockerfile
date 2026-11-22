# syntax=docker/dockerfile:1.14
FROM python:3.12.15-slim-bookworm@sha256:6a0e06f5ba0b373d051aabd3fffb9b873f27f9a2a3a14bcbe37dee6f0e3bbc70
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 HOME=/tmp TOKENIZERS_PARALLELISM=false BORGVR_STRATEGY_ENCODER=/opt/borgvr/strategy-encoder
WORKDIR /app
LABEL org.opencontainers.image.source="https://github.com/JensDerKrueger/BorgVR" \
      org.opencontainers.image.title="BorgVR Agent" \
      org.opencontainers.image.licenses="MIT"
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
ADD --chmod=0644 --checksum=sha256:0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39 https://huggingface.co/Xenova/multilingual-e5-small/resolve/761b726dd34fb83930e26aab4e9ac3899aa1fa78/tokenizer.json /opt/borgvr/strategy-encoder/tokenizer.json
ADD --chmod=0644 --checksum=sha256:f80102d3f2a1229f387d3c81909990d8945513e347b0eab049f7de3c6f98c193 https://huggingface.co/Xenova/multilingual-e5-small/resolve/761b726dd34fb83930e26aab4e9ac3899aa1fa78/onnx/model_quantized.onnx /opt/borgvr/strategy-encoder/model.onnx
COPY borgvr_agent ./borgvr_agent
COPY client.py model_config.py LICENSE ./
# Normalize build permissions for the non-root user, including downloaded assets.
RUN chmod -R a+rX borgvr_agent \
    && chmod a+r client.py model_config.py LICENSE requirements.txt \
    && chmod 0755 /opt/borgvr /opt/borgvr/strategy-encoder \
    && chmod 0644 /opt/borgvr/strategy-encoder/model.onnx /opt/borgvr/strategy-encoder/tokenizer.json
USER 10001:10001
CMD ["python", "-m", "uvicorn", "borgvr_agent.app:create_app", "--factory", "--host", "0.0.0.0", "--port", "8766", "--ssl-certfile", "/run/tls/server.crt", "--ssl-keyfile", "/run/tls/server.key", "--ws", "websockets-sansio", "--ws-max-size", "4194304", "--ws-ping-interval", "20", "--ws-ping-timeout", "20", "--timeout-keep-alive", "5", "--no-access-log", "--no-proxy-headers"]
