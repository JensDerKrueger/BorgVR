"""Privacy-safe classification of terminal model and tool retries."""

import re
from enum import StrEnum

from pydantic import ValidationError
from pydantic_ai import ModelRetry
from pydantic_ai.exceptions import ContentFilterError, OutputTokenLimitExceeded, ToolRetryError, UnexpectedModelBehavior
from pydantic_ai.messages import RetryFeedbackPart, ToolReturnPart

from .protocol import ALLOWED_TOOLS


class RetryCategory(StrEnum):
    ARGUMENTS_REJECTED = "tool_arguments_rejected"
    STATE_REQUIRED = "tool_application_state_required"
    EDIT_STATE_REQUIRED = "tool_edit_state_required"
    ANNOTATION_LIST_REQUIRED = "tool_annotation_list_required"
    CATALOG_RESULT_REQUIRED = "tool_catalog_result_required"
    IMAGE_REQUIRED = "tool_image_required"
    FEEDBACK_REQUIRED = "tool_user_feedback_required"
    INPUT_LIMIT = "tool_input_limit"
    CALL_LIMIT = "tool_call_limit"


def diagnostic_retry(category: RetryCategory, message: str) -> ModelRetry:
    # The SDK still receives the same exception type and retry text.
    error = ModelRetry(message)
    error.borgvr_diagnostic_category = category
    return error


_SDK_TOOL_RETRY = re.compile(r"""^Tool ['"]([a-z][a-z0-9_]{0,63})['"] exceeded max retries count of """)


def model_failure(error: UnexpectedModelBehavior, tools) -> tuple[str, str | None]:
    """Never return an exception string or a model-supplied tool name."""
    # This pinned SDK reports the failed tool in the terminal retry message when
    # the chained cause is the original validation error rather than a ToolRetryError.
    heading = error.message[:256]
    match = _SDK_TOOL_RETRY.match(heading)
    candidate = match[1] if match else None
    chain = []
    cause = error.__cause__
    while cause is not None and len(chain) < 8:
        chain.append(cause)
        if candidate is None and isinstance(cause, ToolRetryError) and isinstance(cause.tool_retry, ToolReturnPart):
            candidate = cause.tool_retry.tool_name
        cause = cause.__cause__
    tool = candidate if candidate in tools or candidate in ALLOWED_TOOLS else None

    if isinstance(error, OutputTokenLimitExceeded):
        return "model_output_token_limit", tool
    if isinstance(error, ContentFilterError):
        return "model_content_filtered", tool
    if heading.startswith("Invalid response from ") and " chat completions endpoint" in heading:
        return "provider_response_invalid", None
    if heading.startswith(("Function tool calls must have unique ", "Deferred tool calls must have unique ")):
        return "duplicate_tool_call_id", None

    output_retry = heading.startswith("Exceeded maximum output retries")
    for cause in chain:
        if isinstance(cause, ModelRetry):
            category = getattr(cause, "borgvr_diagnostic_category", None)
            if isinstance(category, RetryCategory):
                return category.value, tool
            if type(cause).__name__ == "_UnknownTool":
                return "tool_unknown", tool
            if type(cause).__name__ == "_ToolUnavailable":
                return "tool_unavailable", tool
        if isinstance(cause, ValidationError):
            if output_retry:
                return "model_output_invalid", None
            if match or tool:
                details = cause.errors(include_input=False, include_context=False, include_url=False)
                return ("tool_json_invalid" if any(item["type"] == "json_invalid" for item in details)
                        else "tool_arguments_invalid"), tool
        if isinstance(cause, ToolRetryError):
            part = cause.tool_retry
            retry_cause = part.retry.cause if part.retry is not None else None
            if isinstance(part, RetryFeedbackPart):
                if retry_cause == "no_output":
                    return "model_output_empty", None
                if retry_cause == "validation_error":
                    return "model_output_invalid", None
            elif retry_cause == "unknown_tool":
                return "tool_unknown", tool
            elif retry_cause == "unavailable_tool":
                return "tool_unavailable", tool
            elif retry_cause == "validation_error":
                return ("model_output_invalid", None) if output_retry else ("tool_arguments_invalid", tool)

    if output_retry:
        return "model_output_retries_exhausted", None
    if match or tool:
        return "tool_retries_exhausted", tool
    return "unexpected_model_behavior", None
