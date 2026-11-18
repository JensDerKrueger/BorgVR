"""Synthetic tool-calling diagnostic; run inside the existing agent container via stdin."""

import argparse
import asyncio
import json

from openai import AsyncOpenAI, DefaultAsyncHttpxClient
from pydantic import ValidationError
from pydantic_ai import ModelRetry, UsageLimits
from pydantic_ai.exceptions import UnexpectedModelBehavior
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider

from borgvr_agent.app import Session, Settings
from borgvr_agent.protocol import ToolDefinition, select_tools, validate_arguments


def emit(**values):
    print(json.dumps(values, ensure_ascii=True), flush=True)


def error_details(error):
    details, seen = [], set()
    while error is not None and len(details) < 5 and id(error) not in seen:
        seen.add(id(error))
        item = {"type": type(error).__name__}
        if isinstance(error, (UnexpectedModelBehavior, ModelRetry)):
            # Never print provider bodies, HTTP headers, actual prompts or tool results.
            item["message"] = error.message[:2048]
        if isinstance(error, ValidationError):
            item["validation_types"] = [entry["type"] for entry in error.errors(include_input=False, include_context=False)][:20]
        if isinstance(getattr(error, "status_code", None), int):
            item["http_status"] = error.status_code
        details.append(item)
        error = error.__cause__ or error.__context__
    return details


class SyntheticSession(Session):
    def __init__(self, settings, model, label):
        super().__init__(None, settings, model, asyncio.Semaphore(1))
        self.called = []
        self.label = label

    async def send(self, value):
        pass  # Progress is deliberately not sent to any native client.

    async def call_tool(self, definition, arguments):
        # Only this isolated synthetic run may display arguments; production never logs them.
        encoded = json.dumps(arguments, ensure_ascii=True, separators=(",", ":"))
        emit(test=self.label, phase="tool_arguments", tool=definition.name,
             arguments_json=encoded[:4096], truncated=len(encoded) > 4096)
        try:
            validate_arguments(definition, arguments)
        except (ValueError, TypeError) as error:
            raise ModelRetry(str(error)) from error
        if definition.name != "get_application_state":
            raise ModelRetry("This synthetic diagnostic only permits get_application_state")
        self.called.append(definition.name)
        return {"dataset": {"id": "synthetic-test", "description": "Synthetic tool diagnostic"},
                "rendererReady": True, "transferFunctionCount": 1}


async def diagnose(settings, model, catalog):
    tools = select_tools([ToolDefinition.model_validate(value) for value in catalog])
    minimal = [value for value in tools if value.name == "get_application_state"]
    if len(minimal) != 1:
        raise ValueError("The diagnostic catalog must contain get_application_state")
    passed = True
    for label, definitions in (("minimal_catalog", minimal), ("native_catalog", tools)):
        session = SyntheticSession(settings, model, label)
        session.tools = definitions
        session.agent = session.build_agent()
        emit(test=label, phase="start", model=settings.model, tools=len(definitions))
        try:
            async with asyncio.timeout(90):
                await session.agent.run(
                    "Lies mit get_application_state den aktuellen Zustand und nenne den Namen des Datensatzes. "
                    "Aendere nichts, fordere kein Bild an. Dies ist ein rein synthetischer Diagnosetest.",
                    model_settings=settings.inference.request_settings(),
                    usage_limits=UsageLimits(request_limit=4, tool_calls_limit=8),
                )
            if not session.called:
                raise ValueError("The model did not call the required tool")
            emit(test=label, passed=True, successful_state_reads=len(session.called))
        except Exception as error:
            passed = False
            emit(test=label, passed=False, successful_state_reads=len(session.called), errors=error_details(error))
    return passed


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog-json", required=True)
    args = parser.parse_args()
    if len(args.catalog_json.encode()) > 65536:
        parser.error("Catalog is too large")
    catalog = json.loads(args.catalog_json)
    if not isinstance(catalog, list) or len(catalog) > 32:
        parser.error("Expected at most 32 tool definitions")
    settings = Settings.from_env()
    async with AsyncOpenAI(base_url=settings.vllm_url, api_key=settings.vllm_token,
        timeout=60, max_retries=0, http_client=DefaultAsyncHttpxClient(
            timeout=60, follow_redirects=False, trust_env=False)) as client:
        model = OpenAIChatModel(settings.model, provider=OpenAIProvider(openai_client=client))
        return await diagnose(settings, model, catalog)


if __name__ == "__main__":
    raise SystemExit(0 if asyncio.run(main()) else 1)
