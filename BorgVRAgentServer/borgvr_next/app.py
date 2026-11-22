"""Experimental entry point; no imports from the current agent or its configuration."""

import asyncio
from contextlib import asynccontextmanager, suppress
import hmac
import os
from pathlib import Path
import sqlite3

from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse
import httpx
from jsonschema import SchemaError
from pydantic import ValidationError

from .evidence import Evidence
from .procedures import CHECKPOINT_BYTES
from .model import ModelFailure, VLLM
from .session import Session
from .wire import InvalidMessage, decode


def create_app(*, token, model, evidence=None, sequences=2, lifespan=None):
    if len(token) < 32 or not 1 <= sequences <= 16:
        raise ValueError("Invalid server credentials or parallelism")
    app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    slots = asyncio.Semaphore(sequences)
    connected = 0

    def authorized(headers):
        values = headers.getlist("authorization")
        return len(values) == 1 and hmac.compare_digest(values[0].encode(), ("Bearer " + token).encode())

    async def observe(headers):
        values = headers.getlist("x-borgvr-observer")
        if not values:
            return None
        if evidence is None or len(values) != 1:
            raise InvalidMessage("Observer not available")
        profile = await asyncio.to_thread(evidence.profile, values[0])
        if profile is None:
            raise InvalidMessage("Invalid observer profile")
        return profile

    @app.get("/healthz")
    async def health():
        return {"status": "alive"}

    @app.head("/healthz")
    async def probe():
        return JSONResponse(None, headers={"BorgVR-Tool-Types": "1", "BorgVR-Expert-Knowledge": "1",
                                           "BorgVR-Time-Only-Turns": "1", "BorgVR-Knowledge-Bundles": "1"})

    @app.get("/readyz")
    async def ready(request: Request):
        if not authorized(request.headers):
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        try:
            if await model.ready():
                return {"status": "ready", "protocol": 1, "model": model.name,
                        "capabilities": {"tool_calling": True, "vision": True}}
        except ModelFailure:
            pass
        return JSONResponse({"status": "model_unavailable"}, status_code=503)

    @app.get("/v1/observer/hypotheses")
    async def hypotheses(request: Request):
        headers = {"Cache-Control": "no-store"}
        if evidence is None:
            return JSONResponse({"error": "not_available"}, status_code=404, headers=headers)
        try:
            profile = await observe(request.headers) if authorized(request.headers) else None
        except InvalidMessage:
            profile = None
        if profile is None:
            return JSONResponse({"error": "unauthorized"}, status_code=401, headers=headers)
        return JSONResponse(await asyncio.to_thread(evidence.read_proposals, profile), headers=headers)

    @app.get("/v1/observer/checkpoint")
    @app.post("/v1/observer/checkpoint/import")
    async def checkpoint(request: Request):
        headers = {"Cache-Control": "no-store"}
        if evidence is None:
            return JSONResponse({"error": "not_available"}, status_code=404, headers=headers)
        try:
            profile = await observe(request.headers) if authorized(request.headers) else None
        except InvalidMessage:
            profile = None
        if profile is None:
            return JSONResponse({"error": "unauthorized"}, status_code=401, headers=headers)
        try:
            if request.method == "GET":
                result = await asyncio.to_thread(evidence.read_checkpoint, profile)
                return JSONResponse(result, headers=headers)
            body = bytearray()
            async with asyncio.timeout(30):
                async for chunk in request.stream():
                    if len(body) + len(chunk) > CHECKPOINT_BYTES:
                        return JSONResponse({"error": "checkpoint_too_large"}, status_code=413, headers=headers)
                    body.extend(chunk)
            data = decode(bytes(body), CHECKPOINT_BYTES)
            status = await asyncio.to_thread(evidence.import_checkpoint, profile, data)
            return JSONResponse({"status": status}, status_code=409 if status == "conflict" else 200, headers=headers)
        except (InvalidMessage, TimeoutError):
            return JSONResponse({"error": "invalid_checkpoint"}, status_code=422, headers=headers)

    @app.websocket("/v1/session")
    async def websocket(socket: WebSocket):
        nonlocal connected
        if (not authorized(socket.headers) or "origin" in socket.headers or socket.url.query or connected >= 4):
            await socket.close(code=1008)
            return
        connected += 1
        session = None
        try:
            profile = await observe(socket.headers)
            session = Session(socket, model, slots, evidence, profile)
            await socket.accept()
            await session.run()
        except (InvalidMessage, ValidationError, SchemaError, TimeoutError, sqlite3.Error):
            with suppress(Exception):
                if session:
                    await session.send("error", code="invalid_message", message="Invalid or expired session message.")
                await socket.close(code=1008)
        except WebSocketDisconnect:
            pass
        finally:
            try:
                if session:
                    await session.stop()
            finally:
                connected -= 1

    return app


def from_env():
    http = httpx.AsyncClient(follow_redirects=False, trust_env=False)

    @asynccontextmanager
    async def lifespan(_):
        try:
            yield
        finally:
            await http.aclose()

    def secret(name):
        return Path(os.environ[name]).read_text().strip()

    model = VLLM(http, os.environ["BORGVR_VLLM_URL"], secret("BORGVR_VLLM_TOKEN_FILE"),
                 os.environ["BORGVR_MODEL"], int(os.environ.get("BORGVR_CONTEXT_LENGTH", "65536")),
                 thinking_mode=os.environ.get("BORGVR_THINKING_MODE", "off"))
    database = os.environ.get("BORGVR_NEXT_EVIDENCE_DB")
    return create_app(token=secret("BORGVR_TOKEN_FILE"), model=model,
                      evidence=Evidence(database) if database else None, lifespan=lifespan,
                      sequences=int(os.environ.get("BORGVR_NEXT_MODEL_SLOTS", "2")))
