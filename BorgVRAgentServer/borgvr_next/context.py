"""Reduce model-facing receipts and images without changing the app's data."""

import base64
import io
import json

from PIL import Image

from .wire import encode

LARGE_RESULT_CHARS = 4096
MAX_ARRAY_ITEMS = 64
SAMPLE_SEGMENTS = 12


def numeric_row(value):
    row = value if isinstance(value, list) else [value]
    if 1 <= len(row) <= 8 and all(type(component) in (int, float) and abs(component) <= 1e100 for component in row):
        return row
    return None


def sample_indices(values):
    anchors = [(len(values) - 1) * i // SAMPLE_SEGMENTS for i in range(SAMPLE_SEGMENTS + 1)]
    rows = [numeric_row(value) for value in values]
    if rows[0] is None or any(row is None or len(row) != len(rows[0]) for row in rows):
        return anchors

    indices = set(anchors)
    for start, end in zip(anchors, anchors[1:]):
        # Keep one large departure from the local ramp, even if it falls between anchors.
        baseline = rows[start]
        slope = [(last - first) / (end - start) for first, last in zip(baseline, rows[end], strict=True)]
        peak_index, peak_error = start, 0
        for index in range(start + 1, end):
            error = max(abs(value - (first + step * (index - start)))
                        for value, first, step in zip(rows[index], baseline, slope, strict=True))
            if error > peak_error:
                peak_index, peak_error = index, error
        indices.add(peak_index)
    return sorted(indices)


def compact_value(value):
    if isinstance(value, dict):
        return {key: compact_value(item) for key, item in value.items()}
    if isinstance(value, list):
        if len(value) > MAX_ARRAY_ITEMS:
            return {"summary": "sampled_array", "total_items": len(value),
                    "samples_by_original_index": [[index, compact_value(value[index])] for index in sample_indices(value)]}
        return [compact_value(item) for item in value]
    return value


def compact_tool_results(messages):
    compacted, count = [], 0
    for message in messages:
        content = message.get("content")
        if message["role"] == "tool" and isinstance(content, str) and len(content) >= LARGE_RESULT_CHARS:
            try:
                summary = encode(compact_value(json.loads(content)))
            except (ValueError, RecursionError):
                summary = content
            if len(summary) < len(content):
                message = {**message, "content": summary}
                count += 1
        compacted.append(message)
    return compacted, count


def resize_model_images(messages, max_side=384):
    prefix = "data:image/png;base64,"
    resized, count = [], 0
    for message in messages:
        content = message.get("content")
        if not isinstance(content, list):
            resized.append(message)
            continue
        parts = []
        changed = False
        for part in content:
            url = part["image_url"]["url"] if part["type"] == "image_url" else ""
            if not url.startswith(prefix):
                parts.append(part)
                continue
            try:
                with Image.open(io.BytesIO(base64.b64decode(url[len(prefix):], validate=True)), formats=["PNG"]) as image:
                    if max(image.size) > max_side:
                        image.thumbnail((max_side, max_side), Image.Resampling.LANCZOS)
                        output = io.BytesIO()
                        image.save(output, format="PNG")
                        part = {**part, "image_url": {**part["image_url"], "url": prefix +
                                base64.b64encode(output.getvalue()).decode("ascii")}}
                        count += 1
                        changed = True
            except (OSError, ValueError):
                pass  # Incoming screenshots are already validated; do not lose evidence on a resize error.
            parts.append(part)
        if changed:
            parts.insert(0, {"type": "text", "text": "This observation is a lower-resolution copy of the same frame."})
        resized.append({**message, "content": parts} if changed else message)
    return resized, count


def omit_older_tool_details(messages):
    results = [index for index, message in enumerate(messages) if message["role"] == "tool"]
    reduced, count = list(messages), 0
    for index in results[:-2]:
        message = messages[index]
        if len(message["content"]) < 768:
            continue
        try:
            result = json.loads(message["content"])
        except (ValueError, RecursionError):
            continue
        summary = {"summary": "older_result_details_omitted"}
        if isinstance(result, dict):
            # Keep outcome fields, including refusals, without treating an omitted detail as a success.
            for key in ("ok", "not_applied", "code", "error"):
                if key in result:
                    value = result[key]
                    summary[key] = value if len(encode(value)) <= 192 else "Present in original receipt."
        content = encode(summary)
        if len(content) < len(message["content"]):
            reduced[index] = {**message, "content": content}
            count += 1
    return reduced, count
