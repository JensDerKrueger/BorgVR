"""Summarize truncated provider responses without retaining or logging their contents."""

import json
import re

TF_TOOL = "set_transfer_function"
_SAMPLES = re.compile(r'"samples"\s*:\s*\[|<parameter=samples>\s*\[')
_TF_IN_TEXT = re.compile(r'<function=set_transfer_function>|"name"\s*:\s*"set_transfer_function"')
_DECODER = json.JSONDecoder()


def _characters(value):
    return len(value) if isinstance(value, str) else 0


def _rgba_rows(text):
    """Count complete byte tuples in the recognizable prefix, even if JSON is cut off."""
    match = _SAMPLES.search(text)
    if match is None:
        return None
    offset, count = match.end(), 0
    while offset < len(text) and count < 16384:
        while offset < len(text) and text[offset].isspace():
            offset += 1
        if offset == len(text) or text[offset] != "[":
            break
        try:
            row, offset = _DECODER.raw_decode(text, offset)
        except (ValueError, RecursionError):
            break
        if not isinstance(row, list) or len(row) != 4 or not all(type(byte) is int and 0 <= byte <= 255 for byte in row):
            break
        count += 1
        while offset < len(text) and text[offset].isspace():
            offset += 1
        if offset == len(text) or text[offset] != ",":
            break
        offset += 1
    return count


def summarize_output(choice, tools, usage):
    message = choice.get("message")
    message = message if isinstance(message, dict) else {}
    usage = usage if isinstance(usage, dict) else {}
    details = usage.get("completion_tokens_details")
    reasoning_tokens = details.get("reasoning_tokens") if isinstance(details, dict) else None
    reasoning_tokens = reasoning_tokens if type(reasoning_tokens) is int and 0 <= reasoning_tokens <= 16384 else None
    advertised = {tool["function"]["name"] for tool in tools}
    calls = message.get("tool_calls")
    calls = calls if isinstance(calls, list) else []
    names = []
    argument_chars = 0
    rows, source = None, None
    for call in calls[:8]:
        function = call.get("function") if isinstance(call, dict) else None
        if not isinstance(function, dict):
            continue
        name, arguments = function.get("name"), function.get("arguments")
        if isinstance(name, str) and name in advertised:
            names.append(name)
        argument_chars += _characters(arguments)
        if name == TF_TOOL and TF_TOOL in advertised and isinstance(arguments, str) and rows is None:
            rows = _rgba_rows(arguments)
            source = "tool_args" if rows is not None else None
    content = message.get("content")
    if rows is None and TF_TOOL in advertised and isinstance(content, str):
        marker = _TF_IN_TEXT.search(content)
        if marker is not None:
            rows = _rgba_rows(content[marker.end():])
            source = "assistant_text" if rows is not None else None
    return {
        "reasoning_tokens": reasoning_tokens,
        "reasoning_chars": max(_characters(message.get("reasoning_content")), _characters(message.get("reasoning"))),
        "text_chars": _characters(content),
        "tool_calls": len(calls),
        "tools": ",".join(names) or "-",
        "argument_chars": argument_chars,
        "rgba_rows": rows,
        "rgba_source": source,
    }
