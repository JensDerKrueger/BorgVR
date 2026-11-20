"""Versioned, bounded application protocol; not MCP-over-WebSocket."""

import base64
import binascii
import io
import json
import warnings
from typing import Annotated, Any, Literal
from uuid import UUID

from jsonschema import Draft202012Validator
from jsonschema.exceptions import SchemaError
from PIL import Image
from pydantic import BaseModel, ConfigDict, Field, model_validator
from .annotations import ANNOTATION_WRITES, validate_annotation_arguments

MAX_MESSAGE_BYTES = 4 * 1024 * 1024
MAX_RESULT_BYTES = 256 * 1024
MAX_IMAGE_BYTES = 2 * 1024 * 1024
MAX_HISTORY_BYTES = 8 * 1024 * 1024
MAX_TOOLS = 48

# Annotation bulk deletion still requires local approval in the native client.
ALLOWED_TOOLS = frozenset({
    "search_datasets", "open_dataset", "close_dataset", "get_command_history",
    "get_application_state", "get_transfer_function", "get_background",
    "set_render_mode", "set_transform", "rotate_view", "set_iso_value",
    "set_clipping", "set_lighting", "set_background", "set_transfer_function",
    "set_bounding_box", "set_screen_projection", "reset_state", "get_volume_edit_state", "edit_volume",
    "wait_volume_edits", "wait_until_rendered",
    "select_edit_state", "configure_volume_brush", "save_visualization_state", "export_edited_dataset", "cancel_volume_export",
    "import_volume", "fuse_volumes", "get_import_status", "cancel_import",
    "capture_screenshot", "pick_screenshot_positions",
    "list_objects", "upsert_sphere_marker", "upsert_stroke_marker",
    "list_measurements", "upsert_measurement", "set_annotation_visibility",
    "remove_object", "remove_measurement", "clear_annotations",
})
CONVERSION_TOOLS = frozenset({"import_volume", "fuse_volumes"})
LOCAL_CLIENT_TOOLS = frozenset({"get_command_history", "import_volume", "fuse_volumes", "get_import_status", "cancel_import"})
APPLICATION_TOOLS = LOCAL_CLIENT_TOOLS | {"get_application_state", "search_datasets", "open_dataset"}
DATASET_TRANSITIONS = frozenset({"open_dataset", "close_dataset", "select_edit_state"})
FILE_TOOLS = CONVERSION_TOOLS | {"save_visualization_state", "export_edited_dataset"}


def changes_view(name):
    return name.startswith("set_") or name in DATASET_TRANSITIONS or name in FILE_TOOLS or name in {
        "rotate_view", "reset_state", "edit_volume", "configure_volume_brush", "cancel_volume_export", "cancel_import",
    }


class ProtocolError(ValueError):
    pass


class ToolArgumentError(ProtocolError):
    def __init__(self, message: str, reason: str, field: str | None = None):
        super().__init__(message)
        self.reason, self.field = reason, field


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
    dataset_opening: bool = False
    context_id: str = Field(min_length=1, max_length=128)
    tools: list[ToolDefinition] = Field(max_length=MAX_TOOLS)
    execution_limits: ExecutionLimits | None = None
    collaboration: bool = False
    knowledge: list[Annotated[str, Field(min_length=1, max_length=500)]] = Field(default_factory=list, max_length=16)

    @model_validator(mode="after")
    def require_dataset_for_legacy_session(self):
        if self.dataset_id is None and not self.application_session:
            raise ValueError("A dataset-free session requires application_session")
        if self.dataset_opening and not self.application_session:
            raise ValueError("Dataset transitions require application_session")
        return self


class UserMessage(Message):
    type: Literal["user_message"]
    request_id: str = Field(pattern=r"^[A-Za-z0-9_-]{1,64}$")
    text: str = Field(min_length=1, max_length=8192)


class DatasetTransition(Message):
    dataset_id: Annotated[str, Field(min_length=1, max_length=128)] | None
    context_id: str = Field(min_length=1, max_length=128)
    tools: list[ToolDefinition] = Field(max_length=MAX_TOOLS)


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
    dataset_transition: DatasetTransition | None = None


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
    tools: list[ToolDefinition] | None = Field(default=None, max_length=MAX_TOOLS)


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
    if any(changes_view(d.name) or d.name in ANNOTATION_WRITES for d in selected):
        if "get_application_state" not in {d.name for d in selected}:
            raise ProtocolError("Visualization changes require get_application_state")
    return selected


_SCHEMA_FAILURE_REASONS = {
    "additionalProperties": "unexpected_fields",
    "required": "missing_fields",
    "type": "wrong_type",
    "enum": "invalid_choice",
    "const": "invalid_choice",
    "maxItems": "too_many_items",
    "minItems": "too_few_items",
    "uniqueItems": "duplicate_items",
    "minLength": "text_too_short",
    "maxLength": "text_too_long",
    "minimum": "below_minimum",
    "exclusiveMinimum": "below_minimum",
    "maximum": "above_maximum",
    "exclusiveMaximum": "above_maximum",
    "oneOf": "invalid_variant",
    "anyOf": "invalid_variant",
    "format": "invalid_format",
    "pattern": "invalid_format",
}


def _edit_schema_field(name, path):
    # Use only fixed public field labels, never instance keys, indices or values.
    if name != "edit_volume" or not path:
        return None
    if path[0] == "mode":
        return "mode"
    if path[0] != "samples":
        return None
    if len(path) == 1:
        return "samples"
    if len(path) > 2 and path[2] == "center_meters":
        return "samples.item.center_meters"
    if len(path) > 2 and path[2] == "radius_meters":
        return "samples.item.radius_meters"
    return "samples.item"


def validate_arguments(definition: ToolDefinition, arguments: dict) -> None:
    if len(json_bytes(arguments)) > MAX_RESULT_BYTES:
        raise ToolArgumentError("Tool arguments too large", "arguments_too_large")
    failure = next(Draft202012Validator(definition.inputSchema).iter_errors(arguments), None)
    if failure is not None:
        reason = _SCHEMA_FAILURE_REASONS.get(failure.validator, "schema_constraint_failed")
        field = _edit_schema_field(definition.name, failure.absolute_path)
        if definition.inputSchema.get("properties") == {}:
            raise ToolArgumentError(f"Tool {definition.name} takes no arguments. Retry with exactly {{}}. "
                                    "Do not include reason, action, or any other fields.", reason, field)
        if definition.name == "set_transfer_function":
            raise ToolArgumentError(
                "Invalid TF arguments. Each samples entry must contain EXACTLY four integer bytes "
                "[R,G,B,A] in 0...255, NOT [position,R,G,B,A] and not normalized floats. "
                "Positions are implicit and uniformly spaced across [0,1]; do not add a position. "
                "Use a valid zero-based channel and respect the advertised sample-count limits. "
                'Retry with a short ramp, for example {"channel":0,"samples":[[0,0,0,0],[255,255,255,255]]}.',
                reason, field,
            )
        raise ToolArgumentError("Arguments do not match the advertised tool schema. "
                                "Use only its declared properties, include required fields, and respect their types and bounds.",
                                reason, field)
    if definition.name == "capture_screenshot" and set(arguments) - {"include_alpha"}:
        raise ToolArgumentError("Saving screenshot files is not allowed", "unexpected_fields")
    if definition.name == "pick_screenshot_positions":
        try:
            value = arguments["screenshot_id"]
            if not isinstance(value, str) or str(UUID(value)) != value.lower():
                raise ValueError("Non-canonical capture ID")
        except (KeyError, ValueError) as error:
            raise ToolArgumentError("Use the exact screenshotId returned by capture_screenshot",
                                    "invalid_screenshot_id") from error
    if definition.name == "reset_state" and (set(arguments) != {"scope"} or arguments["scope"] not in (
            "transform", "clipping", "transfer_function", "lighting", "all")):
        raise ToolArgumentError("Reset requires an explicit visualization scope", "invalid_reset_scope")
    if definition.name == "edit_volume":
        feedback = "Use erase or restore with 1 to 256 spherical samples in physical meters"
        if {"mode", "samples"} - set(arguments):
            raise ToolArgumentError(feedback, "missing_fields")
        if set(arguments) - {"mode", "samples"}:
            raise ToolArgumentError(feedback, "unexpected_fields")
        if arguments["mode"] not in ("erase", "restore"):
            raise ToolArgumentError(feedback, "invalid_choice", "mode")
        samples = arguments["samples"]
        if not isinstance(samples, list):
            raise ToolArgumentError(feedback, "wrong_type", "samples")
        if not samples:
            raise ToolArgumentError(feedback, "too_few_items", "samples")
        if len(samples) > 256:
            raise ToolArgumentError(feedback, "too_many_items", "samples")
    if definition.name == "wait_volume_edits" and (
        set(arguments) - {"timeout_seconds"} or type(arguments.get("timeout_seconds", 5)) not in (int, float)
        or not 0.1 <= arguments.get("timeout_seconds", 5) <= 10
    ):
        raise ToolArgumentError("Volume edit waits are between 0.1 and 10 seconds", "invalid_edit_wait")
    try:
        validate_annotation_arguments(definition.name, arguments)
    except ValueError as error:
        raise ToolArgumentError(str(error), "annotation_constraint_failed") from error


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
