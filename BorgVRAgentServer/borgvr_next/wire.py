"""BorgVR protocol v1 boundary. No model or learner dependencies."""

import base64
import io
import json
import re
from typing import Annotated, Any, Literal

from jsonschema import Draft202012Validator
from jsonschema.exceptions import SchemaError
from PIL import Image
from pydantic import BaseModel, ConfigDict, Field, model_validator

FRAME_BYTES = 4 * 1024 * 1024
RESULT_BYTES = 256 * 1024
IMAGE_BYTES = 2 * 1024 * 1024
DEFAULT_TURN_SECONDS = 60 * 60
MIN_TURN_SECONDS = 5 * 60
MAX_TURN_SECONDS = 180 * 60
Name = Annotated[str, Field(pattern=r"^[a-z][a-z0-9_]{0,63}$")]
Identifier = Annotated[str, Field(min_length=1, max_length=128)]
RequestID = Annotated[str, Field(pattern=r"^[A-Za-z0-9_-]{1,64}$")]
Domain = Literal["transform", "clipping", "transfer_function", "lighting", "rendering", "annotations", "volume"]
ReadRole = Literal["application_state", "catalog_search", "render_image", "edit_state"]


class InvalidMessage(ValueError):
    pass


def encode(value):
    return json.dumps(value, ensure_ascii=True, allow_nan=False, separators=(",", ":"))


def decode(raw, limit=FRAME_BYTES):
    size = len(raw.encode("utf-8")) if isinstance(raw, str) else len(raw)
    if size > limit:
        raise InvalidMessage("Message exceeds bound")

    def object_pairs(pairs):
        result = dict(pairs)
        if len(pairs) != len(result):
            raise InvalidMessage("Duplicate object key")
        return result

    try:
        data = json.loads(raw, object_pairs_hook=object_pairs)
        encode(data)  # Reject nonfinite numbers even if written as an exponent.
    except (ValueError, RecursionError, UnicodeError) as error:
        raise InvalidMessage("Invalid JSON") from error
    if not isinstance(data, dict):
        raise InvalidMessage("Expected an object")
    return data


class Message(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class Execution(Message):
    kind: Literal["read", "mutation", "transition"]
    role: ReadRole | None = None
    transition: Literal["open", "close", "select_edit", "create_edit"] | None = None
    approval_group: Name | None = None
    timeout_seconds: Annotated[int, Field(ge=5, le=330)] = 45

    @model_validator(mode="after")
    def validate_effect(self):
        if (self.transition is not None) != (self.kind == "transition"):
            raise InvalidMessage("Scope changes require a transition type")
        if self.kind == "read" and self.approval_group is not None:
            raise InvalidMessage("A read cannot be used to approve a change")
        if self.role is not None and self.kind != "read":
            raise InvalidMessage("A write cannot attest a read")
        return self

    @property
    def changes_state(self):
        return self.kind != "read"


class Tool(Message):
    name: Name
    description: Annotated[str, Field(max_length=2048)]
    inputSchema: dict[str, Any]
    execution: Execution

    @property
    def takes_no_arguments(self):
        return self.inputSchema.get("properties", {}) == {} and set(self.inputSchema) <= {
            "type", "properties", "required", "additionalProperties", "description", "title"}

    def as_model_function(self):
        effect = encode(self.execution.model_dump(exclude_none=True))
        description = self.description + "\nApp-declared execution: " + effect
        function = {"name": self.name, "description": description, "parameters": self.inputSchema}
        if self.takes_no_arguments:
            # Provider strict mode can stall empty-argument calls. The agent validates them locally.
            function.update(parameters={**self.inputSchema, "properties": {}, "required": []},
                            description=description + "\nThis tool takes no arguments. Call it with exactly {}.")
        return {"type": "function", "function": function}


class Limits(Message):
    max_calls: Annotated[int, Field(ge=24, le=1024)] | None = None
    timeout_seconds: Annotated[int, Field(ge=60, le=MAX_TURN_SECONDS)]

    @model_validator(mode="after")
    def validate_time_only_turn(self):
        if self.max_calls is None and self.timeout_seconds < MIN_TURN_SECONDS:
            raise InvalidMessage("Time-only turns require at least five minutes")
        return self


class Hello(Message):
    type: Literal["hello"]
    protocol: Literal[1]
    dataset_id: Identifier | None
    context_id: Identifier
    tools: Annotated[list[Tool], Field(max_length=48)]
    application_session: bool = False
    dataset_opening: bool = False
    collaboration: bool = False
    execution_limits: Limits | None = None
    knowledge: Annotated[list[Annotated[str, Field(min_length=1, max_length=500)]], Field(max_length=16)] = []
    expert_knowledge_toml: Annotated[str, Field(min_length=1, max_length=65536)] | None = None
    expert_knowledge_bundle: dict[str, Any] | None = None

    @model_validator(mode="after")
    def validate_capabilities(self):
        if not self.application_session and (self.dataset_id is None or self.dataset_opening):
            raise InvalidMessage("Invalid legacy session")
        return self


class User(Message):
    type: Literal["user_message"]
    request_id: RequestID
    text: Annotated[str, Field(min_length=1, max_length=8192)]


class Transition(Message):
    dataset_id: Identifier | None
    context_id: Identifier
    tools: Annotated[list[Tool], Field(max_length=48)]


class Result(Message):
    type: Literal["tool_result"]
    request_id: RequestID
    call_id: Identifier
    dataset_id: Identifier | None
    context_id: Identifier
    result: Any = None
    error: Annotated[str, Field(max_length=1024)] | None = None
    image_png_base64: str | None = None
    view_revision: Annotated[int, Field(ge=0, le=2**53 - 1)] | None = None
    dataset_transition: Transition | None = None


class Cancel(Message):
    type: Literal["cancel"]
    request_id: RequestID


class ScopeChange(Message):
    type: Literal["context_changed"]
    dataset_id: Identifier | None
    context_id: Identifier
    tools: Annotated[list[Tool], Field(max_length=48)] | None = None


class ManualChange(Message):
    type: Literal["user_change"]
    dataset_id: Identifier
    context_id: Identifier
    revision: Annotated[int, Field(ge=1, le=2**53 - 1)]
    active: bool
    domains: Annotated[list[Domain], Field(max_length=7)]
    state: dict | None = None


def catalog(definitions, dataset_id, *, application_session=False, dataset_opening=False):
    if len(encode([tool.model_dump(exclude_none=True) for tool in definitions])) > 128 * 1024:
        raise InvalidMessage("Catalog exceeds bound")
    accepted = {}
    for tool in definitions:
        if tool.name in accepted:
            raise InvalidMessage("Duplicate tool name")
        effect = tool.execution
        if effect.transition is not None and not application_session:
            raise InvalidMessage("Scope changes require an application session")
        if effect.transition == "open" and not dataset_opening:
            raise InvalidMessage("Dataset opening was not negotiated")
        if effect.transition in {"close", "select_edit", "create_edit"} and dataset_id is None:
            raise InvalidMessage("Closing or changing edit state requires a dataset")
        schema = tool.inputSchema
        if schema.get("type") != "object" or schema.get("additionalProperties") is not False:
            raise InvalidMessage("A tool requires a closed object schema")
        nodes = 0

        def walk(item, depth):
            nonlocal nodes
            nodes += 1
            if depth > 16 or nodes > 4096:
                raise InvalidMessage("Schema exceeds complexity bound")
            if isinstance(item, dict):
                if {"$ref", "$dynamicRef", "$recursiveRef", "pattern", "patternProperties",
                    "$schema", "$id", "$vocabulary"} & item.keys():
                    raise InvalidMessage("Unsupported schema feature")
                for child in item.values():
                    walk(child, depth + 1)
            elif isinstance(item, list):
                for child in item:
                    walk(child, depth + 1)

        walk(schema, 0)
        try:
            Draft202012Validator.check_schema(schema)
        except SchemaError as error:
            raise InvalidMessage("Invalid tool schema") from error
        accepted[tool.name] = tool
    if any(tool.execution.changes_state for tool in accepted.values()) and not any(
            tool.execution.role == "application_state" for tool in accepted.values()):
        raise InvalidMessage("Missing state tool")
    return accepted


def validate_arguments(tool, arguments):
    return (len(encode(arguments)) <= RESULT_BYTES
            and Draft202012Validator(tool.inputSchema).is_valid(arguments))


def validate_png(encoded):
    if len(encoded) > ((IMAGE_BYTES + 2) // 3) * 4:
        raise InvalidMessage("Image exceeds bound")
    try:
        data = base64.b64decode(encoded, validate=True)
        if len(data) > IMAGE_BYTES or not data.startswith(b"\x89PNG\r\n\x1a\n"):
            raise InvalidMessage("Expected a bounded PNG")
        with Image.open(io.BytesIO(data), formats=["PNG"]) as image:
            if max(image.size) > 2048 or image.n_frames != 1:
                raise InvalidMessage("Invalid image shape")
            image.verify()
    except (ValueError, OSError, Image.DecompressionBombError) as error:
        raise InvalidMessage("Invalid PNG") from error
