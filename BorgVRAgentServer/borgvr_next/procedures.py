"""Session-local programs interpreted against a fixed, typed operation catalog."""

import asyncio
import base64
from dataclasses import dataclass
import io
import json
from pathlib import Path
from uuid import uuid4

from jsonschema import Draft202012Validator
from jsonschema.exceptions import SchemaError
from PIL import Image

from . import preview_compute as compute
from .wire import Execution, InvalidMessage, Tool, encode, validate_arguments, validate_png

BUNDLE_BYTES = 128 * 1024
CHECKPOINT_BYTES = 16 * 1024 * 1024
_SCHEMA = json.loads((Path(__file__).resolve().parents[1] / "schemas/knowledge-v1.schema.json").read_text())


def validator(name):
    return Draft202012Validator({"$defs": _SCHEMA["$defs"], "$ref": "#/$defs/" + name})


def _closed_schema(value, *, expect_object=False):
    def check(node, depth):
        if depth > 10:
            raise InvalidMessage("Schema too deeply nested")
        if isinstance(node, dict):
            if any(key.startswith("$") or key in {"pattern", "patternProperties", "format"} for key in node):
                raise InvalidMessage("Unsupported procedure schema feature")
            for part in node.values():
                check(part, depth + 1)
        elif isinstance(node, list):
            for part in node:
                check(part, depth + 1)

    if expect_object and (value.get("type") != "object" or value.get("additionalProperties") is not False
                          or "progress_message" in value.get("properties", {})):
        raise InvalidMessage("Expected a closed input object")
    check(value, 0)
    Draft202012Validator.check_schema(value)


@dataclass(frozen=True)
class Operation:
    arguments: dict
    run: object = None
    native: str | None = None


def shape(properties, required=None):
    return {"type": "object", "additionalProperties": False, "properties": properties,
            "required": sorted(properties) if required is None else required}


_OBJECT = {"type": "object"}
_NUMBER = {"type": "number"}
_ARRAY = {"type": "array", "maxItems": 48}
_HANDLE = {"type": "string", "maxLength": 32}
PREVIEW_ARGS = shape({
    "channel": {"type": "integer", "minimum": 0, "maximum": 3},
    "low": {"type": "number", "minimum": 0, "maximum": 1},
    "high": {"type": "number", "minimum": 0, "maximum": 1},
    "palette": {"type": "string", "enum": ["grayscale", "rainbow"]},
})

# Domain-specific operations are registered here, not in the turn or WebSocket loop.
OPERATIONS = {
    "app.render_tf_preview": Operation(PREVIEW_ARGS, native="capture_tf_preview"),
    "compute.equal_bands": Operation(shape({"count": {"type": "integer", "minimum": 2, "maximum": 8}}), compute.equal_bands),
    "compute.observe_band": Operation(shape({"band": _OBJECT, "image": _HANDLE}), compute.observe_band),
    "compute.band_state": Operation(shape({"leaves": _ARRAY}), compute.band_state),
    "compute.plan_refinement": Operation(shape({"state": _OBJECT, "threshold": _NUMBER, "initial": _ARRAY}), compute.plan_refinement),
    "compute.update_bands": Operation(shape({"plan": _OBJECT, "children": _ARRAY}), compute.update_bands),
    "compute.report_bands": Operation(shape({"state": _OBJECT, "threshold": _NUMBER}), compute.report_bands),
}


def _name(entry):
    return "flow_" + entry["id"].replace(".", "_").replace("-", "_")


def _dependencies(block, *, depth=0, count=None):
    count = [0] if count is None else count
    if depth > 8:
        raise InvalidMessage("Procedure nesting exceeds bound")
    names = set()
    for step in block["steps"]:
        count[0] += 1
        if count[0] > 256:
            raise InvalidMessage("Procedure too large")
        kind = step["kind"]
        if kind == "call":
            names.add((step["operation"], step["version"]))
        else:
            bodies = (step["then"], step["else"]) if kind == "if" else (step["body"],)
            for body in bodies:
                names.update(_dependencies(body, depth=depth + 1, count=count))
    return names


def _bindings(block, inputs):
    bound = set(inputs)

    def check(value, names):
        if "ref" in value and value["ref"].split(".")[0] not in names:
            raise InvalidMessage("Unknown procedure binding")

    for step in block["steps"]:
        name, kind = step["as"], step["kind"]
        if name in bound:
            raise InvalidMessage("Duplicate procedure binding")
        if kind == "call":
            for value in step["args"].values():
                check(value, bound)
        elif kind == "if":
            check(step["test"], bound)
            _bindings(step["then"], bound)
            _bindings(step["else"], bound)
        else:
            var = step["item"] if kind == "for_each" else step["state"]
            if var in bound:
                raise InvalidMessage("Duplicate procedure binding")
            check(step["items"] if kind == "for_each" else step["initial"], bound)
            _bindings(step["body"], bound | {var})
            if kind == "iterate":
                check(step["until"], bound | {var})
        bound.add(name)
    check(block["yield"], bound)


def parse_knowledge(bundle):
    if bundle is None:
        return []
    try:
        valid = len(encode(bundle).encode()) <= BUNDLE_BYTES and validator("bundle").is_valid(bundle)
    except RecursionError:
        valid = False
    if not valid or len({row["id"] for row in bundle["entries"]}) != len(bundle["entries"]):
        raise InvalidMessage("Invalid knowledge bundle")
    return bundle["entries"]


def validate_checkpoint(checkpoint):
    try:
        valid = validator("checkpoint").is_valid(checkpoint)
    except RecursionError:
        valid = False
    if not valid:
        raise InvalidMessage("Invalid learner checkpoint")
    ids = {field: {row["id"] for row in checkpoint[field]} for field in ("entries", "hypotheses", "evidence")}
    if any(len(keys) != len(checkpoint[field]) for field, keys in ids.items()):
        raise InvalidMessage("Duplicate checkpoint identity")
    evidence = ids["evidence"]
    entries = {row["id"]: row["revision"] for row in checkpoint["entries"]}
    for row in checkpoint["hypotheses"]:
        if "entry" in row and entries.get(row["entry"]["id"]) != row["entry"]["revision"]:
            raise InvalidMessage("Unknown checkpoint entry")
        if not {ref["id"] for ref in row["evidence"]} <= evidence:
            raise InvalidMessage("Unknown checkpoint evidence")
    if any(not set(row.get("evidence_ids", ())) <= evidence for row in checkpoint["entries"]):
        raise InvalidMessage("Unknown checkpoint evidence")
    for row in checkpoint["evidence"]:
        for image in row.get("images", ()):
            validate_png(image["png_base64"])


def draft_procedure(candidate):
    """Normalize learner output; the learner cannot approve anything it authors."""
    if not isinstance(candidate, dict):
        return None
    candidate = {**candidate, "review": "pending", "revision": 1}
    try:
        if not validator("procedure").is_valid(candidate):
            return None
        _closed_schema(candidate["input_schema"], expect_object=True)
        _closed_schema(candidate["output_schema"])
        if any((op not in OPERATIONS or version != 1) and not op.startswith("procedure.flow_")
               for op, version in _dependencies(candidate["program"])):
            return None
        _bindings(candidate["program"], {"input"})
    except (ValueError, TypeError, RecursionError, SchemaError):
        return None
    return candidate


def available(entries, native, dataset_id, opened=False):
    contexts = {"dataset_ready" if dataset_id is not None else "start_menu"}
    if opened:
        contexts.add("dataset_opened")
    flows, guidance, candidates, collisions = {}, [], {}, set()
    for entry in entries:
        if entry.get("contexts") and not contexts.intersection(entry["contexts"]):
            continue
        advice = entry.get("guidance")
        if advice and advice["review"] == "approved":
            guidance.append({"id": entry["id"], "goal": entry["goal"], "situation": entry["situation"],
                             "steps": [advice["text"]]})
        procedure = entry.get("procedure")
        if procedure is None or procedure["review"] != "approved":
            continue
        name = _name(entry)
        if len(name) > 64 or name in native:
            continue
        if name in candidates:
            collisions.add(name)
        candidates[name] = entry

    def resolve(name, chain):
        if name in collisions or name not in candidates or name in chain or len(chain) >= 8:
            raise InvalidMessage("Missing, conflicting or recursive procedure")
        if name in flows:
            return flows[name]
        entry = candidates[name]
        procedure = entry["procedure"]
        input_schema, output_schema = procedure["input_schema"], procedure["output_schema"]
        _closed_schema(input_schema, expect_object=True)
        _closed_schema(output_schema)
        dependencies = _dependencies(procedure["program"])
        _bindings(procedure["program"], {"input"})
        hint = procedure.get("announcement_hint", "")
        for op, version in sorted(dependencies):
            if op.startswith("procedure."):
                _, sub = resolve(op.removeprefix("procedure."), (*chain, name))
                if sub["revision"] != version:
                    raise InvalidMessage("Incompatible procedure version")
                hint = hint or sub.get("announcement_hint", "")
                continue
            operation = OPERATIONS.get(op)
            if version != 1 or operation is None:
                raise InvalidMessage("Missing procedure operation")
            if operation.native:
                tool = native.get(operation.native)
                if (tool is None or tool.execution.role != "render_image" or tool.inputSchema != operation.arguments):
                    raise InvalidMessage("Missing compatible preview capability")
        schema = {**input_schema, "properties": {**input_schema.get("properties", {}),
                  "progress_message": {"type": "string", "minLength": int(bool(hint)), "maxLength": 240}},
                  "required": [*input_schema.get("required", []), *(["progress_message"] if hint else [])]}
        notice = (" An announcement is required. Use this cue only as background, never verbatim: " + hint
                  if hint else " Omit the announcement for quick, inconspicuous work.")
        offer = Tool(name=name, execution=Execution(kind="read"), inputSchema=schema,
                     description=entry["goal"] + " " + entry["situation"] +
                     " Write any progress_message in your own words in the user's current language. "
                     "Describe what you are about to do, not the result." + notice)
        flows[name] = (offer, {**procedure, "announcement_hint": hint})
        return flows[name]

    for name in candidates:
        try:
            resolve(name, ())
        except (ValueError, TypeError, RecursionError, SchemaError):
            continue
    return flows, guidance


def procedure_inputs(definition, arguments):
    defaults = {name: schema["default"] for name, schema in definition["input_schema"].get("properties", {}).items()
                if isinstance(schema, dict) and "default" in schema}
    return {**defaults, **arguments}


class Run:
    def __init__(self, port, turn, revision, max_calls):
        self.port, self.turn, self.revision = port, turn, revision
        self.remaining = max_calls
        self.remaining_steps = 512
        self.sub_budgets = []
        self.images = {}
        self.sheet = None

    def check(self):
        if self.port.revision != self.revision or not self.port.manual_idle.is_set():
            raise InvalidMessage("user_changed_view")

    async def call(self, name, version, args):
        self.check()
        self.remaining -= 1
        self.sub_budgets = [amount - 1 for amount in self.sub_budgets]
        if self.remaining < 0 or any(amount < 0 for amount in self.sub_budgets):
            raise InvalidMessage("procedure_budget")
        if name.startswith("procedure."):
            found = self.port.procedures.get(name.removeprefix("procedure."))
            if not found or found[1]["revision"] != version or len(self.sub_budgets) >= 7:
                raise InvalidMessage("procedure_capability")
            definition = found[1]
            self.sub_budgets.append(definition["limits"]["max_calls"])
            try:
                return await self.execute(definition, args)
            finally:
                self.sub_budgets.pop()
        op = OPERATIONS.get(name)
        if version != 1 or op is None or not Draft202012Validator(op.arguments).is_valid(args):
            raise InvalidMessage("procedure_arguments")
        if op.native:
            tool = self.port.tools.get(op.native)
            if (tool is None or tool.execution.role != "render_image" or tool.inputSchema != op.arguments
                    or not validate_arguments(tool, args)):
                raise InvalidMessage("procedure_capability")
            if self.port.max_calls is not None and self.turn.dispatched >= self.port.max_calls:
                raise InvalidMessage("procedure_budget")
            result, image = await self.port.dispatch(self.turn, op.native, args, self.revision)
            self.check()
            if image is None or not isinstance(result, dict):
                raise InvalidMessage("preview_unavailable")
            with Image.open(io.BytesIO(base64.b64decode(image, validate=True)), formats=["PNG"]) as png:
                if not 0 < png.width <= 192 or not 0 < png.height <= 192 or len(self.images) >= 48:
                    raise InvalidMessage("preview_bound")
                decoded = png.convert("RGBA")
            key = uuid4().hex
            self.images[key] = decoded
            return key
        return op.run(self, **args)

    @staticmethod
    def value(expr, values):
        if "literal" in expr:
            return expr["literal"]
        value = values
        for member in expr["ref"].split("."):
            if not isinstance(value, dict) or member not in value:
                raise InvalidMessage("procedure_reference")
            value = value[member]
        return value

    async def block(self, block, initial):
        values = dict(initial)
        for step in block["steps"]:
            self.check()
            self.remaining_steps -= 1
            if self.remaining_steps < 0:
                raise InvalidMessage("procedure_budget")
            name, kind = step["as"], step["kind"]
            if name in values:
                raise InvalidMessage("procedure_binding")
            if kind == "call":
                args = {key: self.value(expr, values) for key, expr in step["args"].items()}
                result = await self.call(step["operation"], step["version"], args)
            elif kind == "if":
                test = self.value(step["test"], values)
                if type(test) is not bool:
                    raise InvalidMessage("procedure_type")
                result = await self.block(step["then" if test else "else"], values)
            elif kind == "for_each":
                items = self.value(step["items"], values)
                if not isinstance(items, list) or len(items) > step["limit"] or step["item"] in values:
                    raise InvalidMessage("procedure_iteration")
                result = [await self.block(step["body"], {**values, step["item"]: item}) for item in items]
            else:
                state = step["state"]
                if state in values:
                    raise InvalidMessage("procedure_binding")
                result = self.value(step["initial"], values)
                for _ in range(step["limit"]):
                    result = await self.block(step["body"], {**values, state: result})
                    stop = self.value(step["until"], {**values, state: result})
                    if type(stop) is not bool:
                        raise InvalidMessage("procedure_type")
                    if stop:
                        break
            values[name] = result
        return self.value(block["yield"], values)

    async def execute(self, definition, arguments):
        data = procedure_inputs(definition, arguments)
        self.check()
        if not Draft202012Validator(definition["input_schema"]).is_valid(data):
            raise InvalidMessage("procedure_arguments")
        async with asyncio.timeout(definition["limits"]["timeout_seconds"]):
            result = await self.block(definition["program"], {"input": data})
        self.check()
        if not Draft202012Validator(definition["output_schema"]).is_valid(result) or len(encode(result)) > 64 * 1024:
            raise InvalidMessage("procedure_result")
        return result


async def run_procedure(port, turn, definition, arguments, revision):
    data = {**arguments}
    progress = data.pop("progress_message", "").strip()
    hint = definition.get("announcement_hint")
    if hint and (not progress or progress.casefold() == hint.strip().casefold()):
        return {"ok": False, "not_applied": True, "code": "missing_progress"}, None
    context = Run(port, turn, revision, definition["limits"]["max_calls"])
    try:
        context.check()
        if progress:
            await port.send("assistant_message", request_id=turn.request_id, text=progress, final=False)
        result = await context.execute(definition, data)
        return result, context.sheet
    except TimeoutError:
        reason = "procedure_timeout"
    except InvalidMessage as error:
        reason = str(error)
    except (ValueError, TypeError, KeyError, IndexError, OSError):
        reason = "procedure_operation_failed"
    return {"ok": False, "not_applied": True, "code": reason}, None
