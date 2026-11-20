"""Optional TLS endpoints for minimized demonstration data, separate from chat."""

import asyncio
import logging
import sqlite3

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from starlette.requests import ClientDisconnect

from .workflow_learner import MAX_FILE_BYTES, decode_episode
from .workflow_store import WorkflowError

logger = logging.getLogger(__name__)


async def run_workflow_worker(store, stop):
    while not stop.is_set():
        try:
            if await asyncio.to_thread(store.process_one):
                continue
        except sqlite3.Error:
            logger.warning("Workflow database temporarily unavailable")
        try:
            await asyncio.wait_for(stop.wait(), timeout=0.5)
        except TimeoutError:
            pass


def workflow_router(store):
    router = APIRouter(prefix="/v1/workflow")
    capacity = asyncio.Semaphore(8)

    def response(value, status=200):
        return JSONResponse(value, status_code=status, headers={"Cache-Control": "no-store"})

    async def handle(request, operation):
        if request.headers.get("origin") is not None or request.url.query:
            return response({"error": "invalid_request"}, 400)
        if capacity.locked():
            return response({"error": "busy"}, 503)
        async with capacity:
            try:
                headers = request.headers.getlist("authorization")
                digest = await asyncio.to_thread(store.authenticate, headers[0] if len(headers) == 1 else None)
                return await operation(request, digest)
            except WorkflowError as error:
                return response({"error": error.code}, error.status)
            except (ValueError, RecursionError, ClientDisconnect):
                return response({"error": "invalid_demonstration"}, 400)
            except TimeoutError:
                return response({"error": "receive_timeout"}, 408)
            except sqlite3.Error:
                return response({"error": "store_unavailable"}, 503)

    def corpus_guard(request):
        values = request.headers.getlist("x-borgvr-corpus")
        if len(values) != 1 or len(values[0]) != 36:
            raise WorkflowError(400, "corpus_required")
        return values[0]

    async def read_profile(_, digest):
        return response(await asyncio.to_thread(store.profile, digest))

    async def read_report(_, digest):
        return response(await asyncio.to_thread(store.report, digest))

    async def upload(request, digest):
        expected_corpus = corpus_guard(request)
        if request.headers.get("content-type", "").split(";", 1)[0].strip().lower() != "application/json":
            raise WorkflowError(415, "json_required")
        if request.headers.get("content-encoding", "identity").lower() != "identity":
            raise WorkflowError(415, "unsupported_content_encoding")
        lengths = request.headers.getlist("content-length")
        if lengths and (len(lengths) != 1 or not 1 <= len(lengths[0]) <= 10
                        or not lengths[0].isascii() or not lengths[0].isdigit() or int(lengths[0]) == 0):
            raise WorkflowError(400, "invalid_length")
        if lengths and int(lengths[0]) > MAX_FILE_BYTES:
            raise WorkflowError(413, "episode_too_large")
        data = bytearray()
        async with asyncio.timeout(10):
            async for chunk in request.stream():
                if len(data) + len(chunk) > MAX_FILE_BYTES:
                    raise WorkflowError(413, "episode_too_large")
                data.extend(chunk)
        if lengths and len(data) != int(lengths[0]):
            raise WorkflowError(400, "invalid_length")
        episode = decode_episode(bytes(data))
        created = await asyncio.to_thread(store.upload, digest, expected_corpus, episode)
        return response({"accepted": True, "created": created, "episode_id": episode.id}, 202 if created else 200)

    async def clear(request, digest):
        return response(await asyncio.to_thread(store.clear, digest, corpus_guard(request)))

    @router.get("/profile")
    async def profile(request: Request):
        return await handle(request, read_profile)

    @router.post("/episodes")
    async def episodes(request: Request):
        return await handle(request, upload)

    @router.get("/report")
    async def report(request: Request):
        return await handle(request, read_report)

    @router.delete("/corpus")
    async def delete(request: Request):
        return await handle(request, clear)

    return router
