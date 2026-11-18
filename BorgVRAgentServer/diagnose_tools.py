"""Synthetic tool-calling diagnostic; run inside the existing agent container via stdin."""

import argparse
import asyncio
import json
import time

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
    def __init__(self, settings, model, label, transfer_function=False):
        super().__init__(None, settings, model, asyncio.Semaphore(1))
        self.called = []
        self.label = label
        self.transfer_function = transfer_function
        self.sample_counts = []
        self.started = time.monotonic()

    async def send(self, value):
        pass  # Progress is deliberately not sent to any native client.

    async def call_tool(self, definition, arguments):
        # Only this isolated synthetic run may display arguments; production never logs them.
        encoded = json.dumps(arguments, ensure_ascii=True, separators=(",", ":"))
        emit(test=self.label, phase="tool_arguments", tool=definition.name,
             arguments_json=encoded[:4096], truncated=len(encoded) > 4096,
             elapsed_seconds=round(time.monotonic() - self.started, 2))
        try:
            validate_arguments(definition, arguments)
        except (ValueError, TypeError) as error:
            raise ModelRetry(str(error)) from error
        if definition.name == "get_application_state":
            self.called.append(definition.name)
            return {"dataset": {"id": "synthetic-test", "description": "Synthetic CT-like test volume",
                                "componentCount": 1, "bytesPerComponent": 2, "valueRange": [0, 4095]},
                    "rendererReady": True, "transferFunctionCount": 1}
        if self.transfer_function and definition.name in {"get_transfer_function", "set_transfer_function"}:
            if "get_application_state" not in self.called:
                raise ModelRetry("Read get_application_state before changing the view")
            if arguments.get("channel", 0) != 0:
                raise ModelRetry("The synthetic volume has only channel 0")
            if definition.name == "set_transfer_function":
                self.sample_counts.append(len(arguments["samples"]))
            self.called.append(definition.name)
            return {"channel": 0, "samples": [[0, 0, 0, 0], [128, 128, 128, 0],
                                               [255, 255, 255, 128], [255, 255, 255, 255]],
                    "originalSampleCount": 256, "samplesArePreview": True}
        raise ModelRetry("This synthetic diagnostic only permits state reads and its selected TF test tools")


async def diagnose(settings, model, catalog, scenario="state"):
    tools = select_tools([ToolDefinition.model_validate(value) for value in catalog])
    minimal = [value for value in tools if value.name == "get_application_state"]
    if len(minimal) != 1:
        raise ValueError("The diagnostic catalog must contain get_application_state")
    if scenario == "transfer-function":
        tf_tools = [value for value in tools if value.name in {
            "get_application_state", "get_transfer_function", "set_transfer_function"}]
        if len(tf_tools) != 3:
            raise ValueError("The TF diagnostic requires state, TF getter and TF setter")
        compact = [value.model_copy(deep=True) for value in tf_tools]
        for value in compact:
            if value.name == "set_transfer_function":
                samples = value.inputSchema["properties"]["samples"]
                samples["maxItems"] = min(samples.get("maxItems", 65536), 16)
                value.description += " Use at most 16 uniformly spaced RGBA samples, not a full table."
        cases = (("transfer_function", tf_tools), ("compact_transfer_function", compact))
        prompt = ("Stell mir eine TF ein, die Knochen hervorhebt. Lies zuerst den Zustand und wende "
                  "die TF mit set_transfer_function an. Dies ist ein rein synthetischer Diagnosetest, "
                  "keine medizinische Auswertung. Fordere kein Bild an.")
    else:
        cases = (("minimal_catalog", minimal), ("native_catalog", tools))
        prompt = ("Lies mit get_application_state den aktuellen Zustand und nenne den Namen des Datensatzes. "
                  "Aendere nichts, fordere kein Bild an. Dies ist ein rein synthetischer Diagnosetest.")
    passed = True
    for label, definitions in cases:
        session = SyntheticSession(settings, model, label, transfer_function=scenario == "transfer-function")
        session.tools = definitions
        session.agent = session.build_agent()
        emit(test=label, phase="start", model=settings.model, tools=len(definitions))
        try:
            async with asyncio.timeout(90):
                await session.agent.run(
                    prompt,
                    model_settings=settings.inference.request_settings(),
                    usage_limits=UsageLimits(request_limit=8 if scenario == "transfer-function" else 4,
                                             tool_calls_limit=12 if scenario == "transfer-function" else 8),
                )
            if "get_application_state" not in session.called:
                raise ValueError("The model did not call the required tool")
            if scenario == "transfer-function" and not session.sample_counts:
                raise ValueError("The model did not apply a synthetic transfer function")
            emit(test=label, passed=True, successful_state_reads=session.called.count("get_application_state"),
                 tf_sample_counts=session.sample_counts,
                 elapsed_seconds=round(time.monotonic() - session.started, 2))
        except Exception as error:
            passed = False
            emit(test=label, passed=False, successful_state_reads=session.called.count("get_application_state"),
                 tf_sample_counts=session.sample_counts,
                 elapsed_seconds=round(time.monotonic() - session.started, 2), errors=error_details(error))
    return passed


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog-json", required=True)
    parser.add_argument("--scenario", choices=("state", "transfer-function"), default="state")
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
        return await diagnose(settings, model, catalog, args.scenario)


if __name__ == "__main__":
    raise SystemExit(0 if asyncio.run(main()) else 1)
