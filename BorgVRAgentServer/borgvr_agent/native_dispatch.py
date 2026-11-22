"""Native calls: validate, dispatch and reconcile one command at a time."""

import asyncio
import contextlib
import logging
import time
import uuid
from dataclasses import dataclass

from pydantic_ai import BinaryContent, ToolReturn

from .annotations import ANNOTATION_DELETES, ANNOTATION_WRITES, annotation_lists_for
from .context import CHECKPOINT_REPLAY_CODE
from .continuation import channel_mask
from .model_diagnostics import RetryCategory, diagnostic_retry
from .protocol import (
    DATASET_TRANSITIONS, EDIT_STATE_WRITES, FILE_TOOLS, ProtocolError, ToolArgumentError,
    changes_view, decode_image, validate_arguments,
)

logger = logging.getLogger("borgvr_agent")


@dataclass(frozen=True, slots=True)
class PendingNativeCall:
    call_id: str
    name: str
    result: asyncio.Future


async def dispatch_native(self, definition, arguments):
    if self.collaboration is not None and self.collaboration.changed.is_set():
        return {"ok": False, "not_applied": True, "code": "user_changed_view",
                "note": "The user is changing the scene. Replan from their updated state; no command was sent."}
    try:
        validate_arguments(definition, arguments)
    except (ValueError, TypeError) as error:
        reason, field = ((error.reason, error.field) if isinstance(error, ToolArgumentError)
                         else ("argument_processing_failed", None))
        logger.warning("Agent tool validation: trace=%s tool=%s reason=%s field=%s",
                       self.turn.continuation.trace_id, definition.name, reason, field or "-")
        raise diagnostic_retry(RetryCategory.ARGUMENTS_REJECTED, str(error)) from error
    mutation = changes_view(definition.name) or definition.name in ANNOTATION_WRITES
    resumed_edit = (self.turn.continuation.resumed or self.turn.continuation.count > 0) and definition.name == "edit_volume"
    if mutation and not resumed_edit and self.turn.continuation.already_applied(self.context_id, definition.name, arguments):
        return {"ok": False, "not_applied": True, "code": CHECKPOINT_REPLAY_CODE,
                "note": "The same command was confirmed earlier in this request and was not sent again. Read current state and continue only unfinished work."}
    if mutation and not self.turn.state_seen:
        raise diagnostic_retry(RetryCategory.STATE_REQUIRED, "Read get_application_state before changing the view")
    if definition.name == "edit_volume":
        if self.turn.volume_edit_declined:
            return {"ok": False, "not_applied": True, "code": "user_declined"}
        if not self.turn.volume_edit_state_seen:
            raise diagnostic_retry(RetryCategory.EDIT_STATE_REQUIRED, "Read get_volume_edit_state before editing volume regions.")
        if resumed_edit:
            if not self.turn.continuation.edit_history_complete:
                return {"ok": False, "not_applied": True, "code": "edit_history_incomplete",
                        "note": "The complete edit history could not be retained. Do not perform further volume edits in this task."}
            repeated = self.turn.continuation.edit_replay_indices(self.context_id, arguments, self.turn.edit_channels)
            if repeated:
                self.turn.continuation.blocked_actions[definition.name] += 1
                return {"ok": False, "not_applied": True, "code": CHECKPOINT_REPLAY_CODE,
                        "confirmed_sample_indices": repeated,
                        "note": "No samples in this batch were sent. Zero-based indices identify already confirmed samples. Submit only the remaining new samples, if needed."}
    if definition.name in EDIT_STATE_WRITES:
        if definition.name == "delete_edit_state" and self.turn.edit_state_deletion_declined:
            return {"ok": False, "not_applied": True, "code": "user_declined"}
        if not self.turn.volume_edit_state_seen:
            raise diagnostic_retry(RetryCategory.EDIT_STATE_REQUIRED, "Read get_volume_edit_state before managing saved edit states.")
    if definition.name in ANNOTATION_DELETES and self.turn.deletion_declined:
        return {"ok": False, "not_applied": True, "code": "user_declined", "note": "The user declined deletion. Finish without deleting or asking again."}
    missing_lists = annotation_lists_for(definition.name, arguments) - self.turn.annotation_reads
    if missing_lists:
        raise diagnostic_retry(RetryCategory.ANNOTATION_LIST_REQUIRED,
                               f"Read {', '.join(sorted(missing_lists))} before changing annotations; preserve existing fields and IDs.")
    if definition.name == "open_dataset":
        if not self.dataset_opening or self.turn.opened_this_turn:
            raise diagnostic_retry(RetryCategory.CALL_LIMIT, "A dataset can be opened at most once per user request.")
        if self.search_results.get(arguments["id"], 0) <= time.monotonic():
            raise diagnostic_retry(RetryCategory.CATALOG_RESULT_REQUIRED,
                                   "Search the catalog and use a dataset ID returned within five minutes; never guess an ID.")
        self.turn.open_target = arguments["id"]
    if definition.name == "select_edit_state":
        self.turn.edit_state_target = arguments["id"]
    if definition.name in FILE_TOOLS and self.turn.file_selection_declined:
        return {"ok": False, "not_applied": True, "code": "user_declined"}
    if self.turn.native_calls >= self.native_call_limit:
        raise diagnostic_retry(RetryCategory.CALL_LIMIT,
                               "BorgVR call budget exhausted. Finish with the received evidence; do not request another action.")
    self.turn.native_calls += 1
    call_id = uuid.uuid4().hex
    future = asyncio.get_running_loop().create_future()
    self.pending = PendingNativeCall(call_id, definition.name, future)
    try:
        outgoing = {
            "type": "tool_call", "request_id": self.request_id, "call_id": call_id,
            "dataset_id": self.dataset_id, "context_id": self.context_id,
            "name": definition.name, "arguments": arguments,
        }
        if self.collaboration is not None:
            outgoing["view_revision"] = self.collaboration.revision
        await self.send(outgoing)
        timeout = max(self.settings.tool_timeout, 330 if definition.name == "open_dataset" else 310 if definition.name in ANNOTATION_DELETES or definition.name in FILE_TOOLS or definition.name == "delete_edit_state" else 145 if definition.name == "create_edit_state" else 135 if definition.name == "edit_volume" else 75 if definition.name == "search_datasets" else 45 if definition.name in DATASET_TRANSITIONS else 0)
        async with asyncio.timeout(timeout):
            response = await future
        if response.error is not None:
            # A client-reported error must mean the command did NOT commit.
            return {"ok": False, "error": response.error}
        if (isinstance(response.result, dict) and response.result.get("not_applied") is True and
                response.result.get("code") == "user_changed_view"):
            self.turn.state_seen = False
            if self.collaboration is not None:
                self.collaboration.changed.set()
            return response.result
        if isinstance(response.result, dict) and response.result.get("not_applied") is True:
            if definition.name in FILE_TOOLS and response.result.get("code") == "user_declined":
                self.turn.file_selection_declined = True
            if definition.name in ANNOTATION_DELETES and response.result.get("code") == "user_declined":
                self.turn.deletion_declined = True
            if definition.name == "delete_edit_state" and response.result.get("code") == "user_declined":
                self.turn.edit_state_deletion_declined = True
            if definition.name == "edit_volume":
                self.turn.volume_edit_state_seen = False
                if response.result.get("code") == "user_declined":
                    self.turn.volume_edit_declined = True
            return response.result
        if definition.name in DATASET_TRANSITIONS or definition.name in EDIT_STATE_WRITES or definition.name in {"edit_volume", "configure_volume_brush"}:
            self.turn.volume_edit_state_seen = False
        if definition.name == "get_volume_edit_state":
            self.turn.volume_edit_state_seen = (isinstance(response.result, dict) and
                                           response.result.get("available") is True and
                                           response.result.get("shared") is False)
            self.turn.edit_channels = channel_mask(response.result)
            self.turn.active_edit_state_id = response.result.get("activeStateID") if self.turn.volume_edit_state_seen else None
        if definition.name == "search_datasets" and isinstance(response.result, dict):
            self.search_results = {key: expiry for key, expiry in self.search_results.items() if expiry > time.monotonic()}
            for item in response.result.get("matches", [])[:20]:
                if isinstance(item, dict) and isinstance(item.get("id"), str) and 0 < len(item["id"]) <= 128:
                    if len(self.search_results) >= 2000:
                        self.search_results.pop(next(iter(self.search_results)))
                    self.search_results[item["id"]] = time.monotonic() + 300
        if definition.name != "get_command_history":
            self.turn.operation_receipts.append({"tool": definition.name, "dataset_id": outgoing["dataset_id"], "result_received": True})
        if definition.name in {"list_objects", "list_measurements"}:
            self.turn.annotation_reads.add(definition.name)
        if mutation:
            self.turn.changes_applied = True
            channels = (channel_mask(response.result)
                        if isinstance(response.result, dict) and "channels" in response.result
                        else self.turn.edit_channels)
            self.turn.continuation.record(outgoing["context_id"], definition.name, arguments, channels,
                result_context_id=self.context_id if definition.name == "create_edit_state" else None)
        if definition.name == "get_application_state":
            self.turn.state_seen = (self.collaboration is None or
                               (response.view_revision == self.collaboration.revision and
                                self.collaboration.idle.is_set() and not self.collaboration.changed.is_set()))
        if response.image_png_base64 is not None:
            if definition.name != "capture_screenshot":
                raise ProtocolError("Only capture_screenshot may return an image")
            if self.collaboration is not None and response.view_revision != self.collaboration.revision:
                return {"stale_observation": True, "note": "The user changed the view while this image was captured."}
            image = await asyncio.to_thread(decode_image, response.image_png_base64)
            self.turn.screenshot_count += 1
            return ToolReturn(response.result, content=[BinaryContent(image, media_type="image/png")])
        return response.result
    except (TimeoutError, asyncio.CancelledError) as error:
        self.uncertain |= mutation
        if not mutation:
            self.retire_read(call_id, outgoing)
        with contextlib.suppress(Exception):
            await self.send({"type": "tool_cancel", "request_id": self.request_id, "call_id": call_id})
        if not mutation and isinstance(error, TimeoutError):
            return {"ok": False, "not_applied": True, "code": "read_timeout",
                    "note": "This observation did not arrive. Retry only if it is necessary, or explain what remains unverified."}
        raise
    finally:
        self.pending = None
        if not future.done():
            future.cancel()
