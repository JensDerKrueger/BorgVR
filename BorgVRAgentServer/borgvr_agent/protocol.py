"""Versioned, bounded application protocol; not MCP-over-WebSocket."""

import base64
import binascii
import io
import json
import warnings
from typing import Annotated, Any, Literal

from jsonschema import Draft202012Validator
from jsonschema.exceptions import SchemaError
from PIL import Image
from pydantic import BaseModel, ConfigDict, Field, model_validator

MAX_MESSAGE_BYTES = 4 * 1024 * 1024
MAX_RESULT_BYTES = 256 * 1024
MAX_IMAGE_BYTES = 2 * 1024 * 1024
MAX_HISTORY_BYTES = 8 * 1024 * 1024

# No datasets can be opened/closed, edited, exported, or deleted by this agent.
ALLOWED_TOOLS = frozenset({
    "get_application_state", "get_transfer_function", "get_background",
    "set_render_mode", "set_transform", "rotate_view", "set_iso_value",
    "set_clipping", "set_lighting", "set_background", "set_transfer_function",
    "set_bounding_box", "set_screen_projection", "wait_until_rendered",
    "capture_screenshot",
})
APPLICATION_TOOLS = frozenset({"get_application_state"})


class ProtocolError(ValueError):
    pass


class Message(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class ToolDefinition(Message):
    name: str = Field(pattern=r"^[a-z][a-z0-9_]{0,63}$")
    description: str = Field(max_length=2048)
    inputSchema: dict[str, Any]


class ExecutionLimits(Message):
    max_calls: int = Field(ge=24, le=1024)
    timeout_seconds: int = Field(ge=60, le=7200)


class Hello(Message):
    type: Literal["hello"]
    protocol: Literal[1]
    dataset_id: str | None = Field(min_length=1, max_length=128)
    application_session: bool = False
    context_id: str = Field(min_length=1, max_length=128)
    tools: list[ToolDefinition] = Field(max_length=32)
    execution_limits: ExecutionLimits | None = None
    collaboration: bool = False
    knowledge: list[Annotated[str, Field(min_length=1, max_length=500)]] = Field(default_factory=list, max_length=16)

    @model_validator(mode="after")
    def require_dataset_for_legacy_session(self):
        if self.dataset_id is None and not self.application_session:
            raise ValueError("A dataset-free session requires application_session")
        return self


class UserMessage(Message):
    type: Literal["user_message"]
    request_id: str = Field(pattern=r"^[A-Za-z0-9_-]{1,64}$")
    text: str = Field(min_length=1, max_length=8192)


class ToolResult(Message):
    type: Literal["tool_result"]
    request_id: str
    call_id: str
    dataset_id: str | None
    context_id: str
    result: Any = None
    error: str | None = Field(default=None, max_length=1024)
    image_png_base64: str | None = None
    view_revision: int | None = Field(default=None, ge=0, le=2**53 - 1)


class UserChange(Message):
    type: Literal["user_change"]
    dataset_id: str
    context_id: str
    revision: int = Field(ge=1, le=2**53 - 1)
    active: bool
    domains: list[Literal["transform", "clipping", "transfer_function", "lighting", "rendering", "annotations", "volume"]] = Field(max_length=7)
    state: dict[str, Any] | None = None


class CollaborationFeedback(Message):
    type: Literal["collaboration_feedback"]
    request_id: str
    question_id: str = Field(min_length=1, max_length=128)
    text: str = Field(min_length=1, max_length=2000)


class RuleDecision(Message):
    type: Literal["rule_decision"]
    proposal_id: str = Field(min_length=1, max_length=128)
    accepted: bool


class Cancel(Message):
    type: Literal["cancel"]
    request_id: str


class ContextChanged(Message):
    type: Literal["context_changed"]
    dataset_id: str | None = Field(min_length=1, max_length=128)
    context_id: str = Field(min_length=1, max_length=128)
    tools: list[ToolDefinition] | None = Field(default=None, max_length=32)


def json_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=True, allow_nan=False, separators=(",", ":")).encode()


def decode_message(raw: str) -> dict:
    if len(raw.encode()) > MAX_MESSAGE_BYTES:
        raise ProtocolError("Message too large")

    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ProtocolError("Duplicate JSON key")
            result[key] = value
        return result

    def nonfinite(_):
        raise ProtocolError("Non-finite JSON number")

    try:
        value = json.loads(raw, object_pairs_hook=pairs, parse_constant=nonfinite)
        json_bytes(value)  # Also rejects overflowing numbers such as 1e999.
    except (ValueError, RecursionError) as error:
        raise ProtocolError("Invalid JSON") from error
    if not isinstance(value, dict):
        raise ProtocolError("Expected an object")
    return value


def select_tools(definitions: list[ToolDefinition]) -> list[ToolDefinition]:
    if len(json_bytes([d.model_dump() for d in definitions])) > 128 * 1024:
        raise ProtocolError("Tool catalog too large")
    selected = []
    names = set()
    for original in definitions:
        if original.name in names:
            raise ProtocolError("Duplicate tool name")
        names.add(original.name)
        if original.name not in ALLOWED_TOOLS:
            continue
        definition = original.model_copy(deep=True)
        schema = definition.inputSchema
        if schema.get("type") != "object" or schema.get("additionalProperties") is not False:
            raise ProtocolError("Tools must have a closed object schema")
        nodes = 0

        def check(node, depth=0):
            nonlocal nodes
            nodes += 1
            if depth > 16 or nodes > 4096:
                raise ProtocolError("Tool schema too complex")
            if isinstance(node, dict):
                if any(k in node for k in ("$ref", "$dynamicRef", "$recursiveRef", "pattern", "patternProperties")):
                    raise ProtocolError("References and regular expressions are not supported")
                for child in node.values():
                    check(child, depth + 1)
            elif isinstance(node, list):
                for child in node:
                    check(child, depth + 1)

        check(schema)
        try:
            Draft202012Validator.check_schema(schema)
        except SchemaError as error:
            raise ProtocolError("Invalid tool schema") from error
        if definition.name == "capture_screenshot":
            schema["properties"] = {"include_alpha": {"type": "boolean"}}
            schema.pop("required", None)
        selected.append(definition)
    if any(d.name.startswith("set_") or d.name == "rotate_view" for d in selected):
        if "get_application_state" not in {d.name for d in selected}:
            raise ProtocolError("Visualization changes require get_application_state")
    return selected


def validate_arguments(definition: ToolDefinition, arguments: dict) -> None:
    if len(json_bytes(arguments)) > MAX_RESULT_BYTES:
        raise ProtocolError("Tool arguments too large")
    if not Draft202012Validator(definition.inputSchema).is_valid(arguments):
        if definition.inputSchema.get("properties") == {}:
            raise ProtocolError(f"Tool {definition.name} takes no arguments. Retry with exactly {{}}. "
                                "Do not include reason, action, or any other fields.")
        if definition.name == "set_transfer_function":
            raise ProtocolError(
                "Invalid TF arguments. Each samples entry must contain EXACTLY four integer bytes "
                "[R,G,B,A] in 0...255, NOT [position,R,G,B,A] and not normalized floats. "
                "Positions are implicit and uniformly spaced across [0,1]; do not add a position. "
                "Use a valid zero-based channel and respect the advertised sample-count limits. "
                'Retry with a short ramp, for example {"channel":0,"samples":[[0,0,0,0],[255,255,255,255]]}.'
            )
        raise ProtocolError("Arguments do not match the advertised tool schema. "
                            "Use only its declared properties, include required fields, and respect their types and bounds.")
    if definition.name == "capture_screenshot" and set(arguments) - {"include_alpha"}:
        raise ProtocolError("Saving screenshot files is not allowed")


def decode_image(value: str) -> bytes:
    if len(value) > ((MAX_IMAGE_BYTES + 2) // 3) * 4:
        raise ProtocolError("Image too large")
    try:
        data = base64.b64decode(value, validate=True)
        if len(data) > MAX_IMAGE_BYTES or not data.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ProtocolError("Expected a bounded PNG image")
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(data)) as image:
                if image.format != "PNG" or max(image.size) > 2048 or image.n_frames != 1:
                    raise ProtocolError("Expected one PNG frame at most 2048 pixels per axis")
                image.verify()
        return data
    except (ValueError, OSError, binascii.Error, Image.DecompressionBombError, Image.DecompressionBombWarning) as error:
        raise ProtocolError("Invalid PNG image") from error
