"""Inspect a synthetic model request; never reads BorgVR conversations or datasets."""

import asyncio
import json
import os
from pathlib import Path
import sys

import httpx

from borgvr_next.model import ContextLimit, ModelFailure, VLLM


class DiagnosticModel(VLLM):
    async def exchange(self, method, url, *, phase, seconds, body=None):
        async with asyncio.timeout(seconds):
            async with self.http.stream(method, url, json=body,
                    headers={"Authorization": "Bearer " + self.token},
                    timeout=httpx.Timeout(seconds, connect=5, pool=5)) as response:
                data = bytearray()
                async for chunk in response.aiter_bytes():
                    data.extend(chunk)
                    if len(data) > 65536:
                        raise ModelFailure("diagnostic_response_too_large", phase=phase)
                report = {"phase": phase, "http_status": response.status_code}
                if response.is_error:
                    # Only a fixed synthetic prompt was sent; still redact the credential.
                    report["error_body"] = data.decode("utf-8", errors="replace").replace(self.token, "[REDACTED]")[:4096]
                print(json.dumps(report), flush=True)
                if response.is_error:
                    raise ModelFailure("http_error", phase=phase, status=response.status_code)
                return json.loads(data)


async def diagnose(env=None):
    env = os.environ if env is None else env
    token = Path(env["BORGVR_VLLM_TOKEN_FILE"]).read_text().strip()
    if not token:
        raise ValueError("Empty vLLM credential")
    async with httpx.AsyncClient(trust_env=False, follow_redirects=False) as http:
        model = DiagnosticModel(http, env["BORGVR_VLLM_URL"], token, env["BORGVR_MODEL"],
            int(env.get("BORGVR_CONTEXT_LENGTH", "16384")), max_output_tokens=128,
            thinking_mode=env.get("BORGVR_THINKING_MODE", "off"),
            reasoning_parser=env.get("BORGVR_REASONING_PARSER"))
        try:
            await model.complete([{"role": "system", "content": "This is a synthetic server compatibility test."},
                                  {"role": "user", "content": "Reply with the word ready."}], [])
        except (ContextLimit, ModelFailure) as error:
            print(json.dumps({"result": "failed", "type": type(error).__name__,
                              "phase": getattr(error, "phase", "context"),
                              "code": getattr(error, "code", "context_limit")}), flush=True)
            return False
    print(json.dumps({"result": "passed"}), flush=True)
    return True


if __name__ == "__main__":
    try:
        passed = asyncio.run(diagnose())
    except (KeyError, OSError, ValueError, httpx.HTTPError, TimeoutError) as error:
        raise SystemExit("Diagnostic could not complete: " + type(error).__name__) from None
    sys.exit(0 if passed else 1)
