"""HTTPS/WebSocket entry point for the standalone BorgVR agent."""

import asyncio
import contextlib
import os
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse
from openai import AsyncOpenAI, DefaultAsyncHttpxClient
from pydantic import ValidationError
from pydantic_ai.models.openai import OpenAIResponsesModel
from pydantic_ai.providers.openai import OpenAIProvider

from .connection import Session
from .context import VLLMChatModel, bounded_history
from .policies import SPATIAL_PICKING_GUIDANCE
from .protocol import ProtocolError, decode_message
from .settings import Settings, authorized
from .strategies import MultilingualEncoder
from .workflow_api import workflow_router
from .workflow_store import WorkflowStore


def create_app(settings=None, model=None, *, strategy_encoder=None):
    settings = settings or Settings.from_env()
    if strategy_encoder is None and (directory := os.environ.get("BORGVR_STRATEGY_ENCODER")):
        strategy_encoder = MultilingualEncoder(Path(directory))
    workflow = WorkflowStore(settings.workflow_database) if settings.workflow_database is not None else None
    provider_client = None
    token_client = None
    use_openai = settings.backend == "openai"
    if model is None or use_openai:
        provider_client = AsyncOpenAI(
            base_url="https://api.openai.com/v1" if use_openai else settings.vllm_url,
            api_key=settings.openai_key if use_openai else settings.vllm_token,
            timeout=60, max_retries=0,
            http_client=DefaultAsyncHttpxClient(timeout=60, follow_redirects=False, trust_env=False),
        )
    if model is None:
        provider = OpenAIProvider(openai_client=provider_client)
        if use_openai:
            model = OpenAIResponsesModel(settings.model, provider=provider)
        else:
            token_client = httpx.AsyncClient(timeout=15, follow_redirects=False, trust_env=False)
            model = VLLMChatModel(settings.model, provider=provider,
                                  token_url=settings.vllm_url.removesuffix("/").removesuffix("/v1") + "/tokenize",
                                  token=settings.vllm_token, token_client=token_client)

    @asynccontextmanager
    async def lifespan(_):
        try:
            yield
        finally:
            try:
                if token_client is not None:
                    await token_client.aclose()
            finally:
                if provider_client is not None:
                    await provider_client.close()

    app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    if workflow is not None:
        app.include_router(workflow_router(workflow))
    app.state.sessions = 0
    run_slots = asyncio.Semaphore(settings.inference.sequences)

    @app.get("/healthz")
    async def health():
        return {"status": "alive"}

    @app.head("/healthz")
    async def expert_knowledge_support():
        return JSONResponse(None, headers={"BorgVR-Expert-Knowledge": "1"} if strategy_encoder is not None else {})

    @app.get("/readyz")
    async def ready(request: Request):
        if not authorized(request.headers.get("authorization"), settings.token):
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        result = {"status": "ready", "model": settings.model, "protocol": 1,
                  "capabilities": settings.capabilities(), "agent_context_tokens": settings.inference.context}
        try:
            async with asyncio.timeout(5):
                if use_openai:
                    await provider_client.models.retrieve(settings.model)
                    effort = settings.inference.request_settings().get("openai_reasoning_effort")
                    if effort is not None:
                        result["reasoning_effort"] = effort
                    return result
                async with httpx.AsyncClient(timeout=5, trust_env=False) as client:
                    async with client.stream("GET", f"{settings.vllm_url}/models",
                                             headers={"Authorization": f"Bearer {settings.vllm_token}"}) as response:
                        response.raise_for_status()
                        body = bytearray()
                        async for chunk in response.aiter_bytes():
                            body.extend(chunk)
                            if len(body) > 64 * 1024:
                                raise ProtocolError("Model response too large")
                        data = decode_message(body.decode())
                        model = next((item for item in data.get("data", [])
                                      if isinstance(item, dict) and item.get("id") == settings.model), None)
                        if model is None:
                            raise ProtocolError("Configured model is not loaded")
            window = model.get("max_model_len")
            if type(window) is int and 1 <= window <= 16 * 1048576:
                result["model_context_tokens"] = window
            return result
        except Exception:
            return JSONResponse({"status": "model_unavailable"}, status_code=503)

    @app.websocket("/v1/session")
    async def websocket(ws: WebSocket):
        if (not authorized(ws.headers.get("authorization"), settings.token)
            or ws.headers.get("origin") is not None or ws.url.query
            or app.state.sessions >= settings.max_sessions):
            await ws.close(code=1008)
            return
        app.state.sessions += 1
        session = Session(ws, settings, model, run_slots, strategy_encoder)
        try:
            await ws.accept()
            await session.serve()
        except (ProtocolError, ValidationError, ValueError, KeyError, TypeError, RecursionError):
            with contextlib.suppress(Exception):
                await session.send({"type": "error", "code": "invalid_message",
                                    "message": "Invalid, stale, or oversized protocol message."})
                await ws.close(code=1008)
        except TimeoutError:
            with contextlib.suppress(Exception):
                await ws.close(code=1008, reason="Session deadline exceeded")
        except WebSocketDisconnect:
            pass
        finally:
            await session.stop()
            app.state.sessions -= 1

    return app
