"""Summarize truncated provider responses without retaining or logging their contents."""

def _characters(value):
    return len(value) if isinstance(value, str) else 0


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
    for call in calls[:8]:
        function = call.get("function") if isinstance(call, dict) else None
        if not isinstance(function, dict):
            continue
        name, arguments = function.get("name"), function.get("arguments")
        if isinstance(name, str) and name in advertised:
            names.append(name)
        argument_chars += _characters(arguments)
    return {
        "reasoning_tokens": reasoning_tokens,
        "reasoning_chars": max(_characters(message.get("reasoning_content")), _characters(message.get("reasoning"))),
        "text_chars": _characters(message.get("content")),
        "tool_calls": len(calls),
        "tools": ",".join(names) or "-",
        "argument_chars": argument_chars,
    }
