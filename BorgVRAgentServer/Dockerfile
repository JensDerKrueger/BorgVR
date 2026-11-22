FROM python:3.12.15-slim-bookworm@sha256:6a0e06f5ba0b373d051aabd3fffb9b873f27f9a2a3a14bcbe37dee6f0e3bbc70
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 HOME=/tmp
WORKDIR /app
LABEL org.opencontainers.image.source="https://github.com/JensDerKrueger/BorgVR" \
      org.opencontainers.image.title="BorgVR Agent" \
      org.opencontainers.image.licenses="MIT" \
      org.borgvr.runtime="typed-v1"
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY borgvr_next ./borgvr_next
COPY schemas ./schemas
COPY client.py model_config.py LICENSE ./
RUN chmod -R a+rX borgvr_next && chmod a+r client.py model_config.py LICENSE requirements.txt
USER 10001:10001
CMD ["python", "-m", "uvicorn", "borgvr_next.app:from_env", "--factory", "--host", "0.0.0.0", "--port", "8766", "--ssl-certfile", "/run/tls/server.crt", "--ssl-keyfile", "/run/tls/server.key", "--ws", "websockets-sansio", "--ws-max-size", "4194304", "--ws-ping-interval", "20", "--ws-ping-timeout", "20", "--timeout-keep-alive", "5", "--no-access-log", "--no-proxy-headers"]
