"""Synthetic before/after visibility ablation using the deployed agent's read-only image tool."""

import argparse
import asyncio
import base64
import io
import json
import random
import ssl
import sys
import time
from urllib.parse import urlsplit, urlunsplit
from uuid import uuid4

from PIL import Image, ImageDraw, ImageFont

from .workflow_learner import _unique_keys

DATASET = "synthetic-visibility-study"
TARGET = "the small solid cyan circle (not the cyan triangle)"
UNKNOWN = ("unknown", "unknown")


def panel(seed, occluded):
    """Render a known target mask, separate from the RGB observation shown to the model."""
    rng = random.Random(seed)
    x, y = rng.randint(38, 86), rng.randint(34, 65)
    target = Image.new("1", (128, 96))
    ImageDraw.Draw(target).ellipse((x - 11, y - 11, x + 11, y + 11), fill=1)
    cover = Image.new("1", target.size)
    if occluded:
        ImageDraw.Draw(cover).rounded_rectangle((x - 15, y - 15, x + 15, y + 15), radius=5, fill=1)
    visible_pixels = sum(pixel and not hidden for pixel, hidden in
                         zip(target.get_flattened_data(), cover.get_flattened_data()))
    target_pixels = sum(target.get_flattened_data())
    label = "visible" if visible_pixels / target_pixels >= 0.95 else "hidden"
    gray = rng.randint(58, 80)
    rgb = Image.new("RGB", target.size, (22, 24, 30))
    draw = ImageDraw.Draw(rgb)
    draw.rounded_rectangle((7, 7, 120, 88), radius=13, fill=(gray, gray + 5, gray + 12))
    for stroke in range(3):
        draw.line((15, 19 + stroke * 28, 111, 19 + stroke * 28), fill=(90, 94, 101))
    draw.polygon(((96, 12), (107, 30), (87, 30)), fill=(47, 237, 245))
    draw.rectangle((16, 63, 27, 75), fill=(217, 147, 58))
    rgb.paste((47, 237, 245), mask=target)
    rgb.paste((107, 116, 131), mask=cover)
    return rgb, label


def fixture(batch):
    # Identical command/state evidence across rows; class balance and order fixed before querying.
    sequences = (
        ((True, False), (False, False), (True, True), (True, False), (False, True), (True, False)),
        ((True, True), (True, False), (False, True), (True, False), (True, False), (False, False)),
    )
    chart = Image.new("RGB", (612, 566), (12, 14, 18))
    draw = ImageDraw.Draw(chart)
    font = ImageFont.load_default(size=16)
    expected = {}
    for index, (before, after) in enumerate(sequences[batch]):
        left, start = panel(101 + batch * 29 + index, before)
        right, end = panel(101 + batch * 29 + index, after)
        case = f"{'A' if batch == 0 else 'B'}{index + 1}"
        x, y = 18 + (index % 2) * 300, 18 + (index // 2) * 182
        draw.text((x, y), case, font=font, fill="white")
        draw.text((x, y + 26), "BEFORE", font=font, fill="white")
        draw.text((x + 140, y + 26), "AFTER", font=font, fill="white")
        chart.paste(left, (x, y + 50))
        chart.paste(right, (x + 140, y + 50))
        expected[case] = (start, end)
    data = io.BytesIO()
    chart.save(data, format="PNG")
    return expected, data.getvalue()


def single_pair_fixtures():
    # New cases for the single-pair run; not crops of the contact-sheet evaluation.
    occlusions = ((True, False), (False, True), (True, True), (True, False),
                  (False, False), (True, False))
    for index, (before, after) in enumerate(occlusions):
        left, start = panel(389 + index * 17, before)
        right, end = panel(389 + index * 17, after)
        chart = Image.new("RGB", (552, 246), (12, 14, 18))
        draw = ImageDraw.Draw(chart)
        font = ImageFont.load_default(size=19)
        draw.text((10, 9), "BEFORE", font=font, fill="white")
        draw.text((286, 9), "AFTER", font=font, fill="white")
        chart.paste(left.resize((256, 192), Image.Resampling.NEAREST), (10, 44))
        chart.paste(right.resize((256, 192), Image.Resampling.NEAREST), (286, 44))
        data = io.BytesIO()
        chart.save(data, format="PNG")
        yield {f"C{index + 1}": (start, end)}, data.getvalue()


def prompt(cases, with_images):
    access = ("Call capture_screenshot once to inspect the labeled image: each case has its own "
              "BEFORE panel on the left and AFTER panel on the right. Read the labels. "
              if with_images else "No images or additional observations are available. ")
    return (f"This is a synthetic evaluation, not a request to modify an app. For each case, classify {TARGET} "
            "as visible, hidden, or unknown, separately before and after. "
            "All trials used the same clipping command and the same reported initial and final clipping "
            "bounds. Geometry and occlusion can differ across rows. There are no user outcome reports. "
            + access + "If the evidence does not determine visibility, use unknown. "
            "Return only JSON mapping each listed case to an array [before, after] of exactly two of "
            f'the strings "visible", "hidden", "unknown". Cases: {", ".join(cases)}.')


def predictions(answer, cases):
    if not isinstance(answer, str) or len(answer) > 4096:
        raise ValueError("Missing or oversized visibility response")
    answer = answer.strip()
    if answer.startswith("```json\n") and answer.endswith("```"):
        answer = answer[8:-3].strip()
    rows = json.loads(answer, object_pairs_hook=_unique_keys)
    if not isinstance(rows, dict) or set(rows) != set(cases):
        raise ValueError("Response does not match the provided case IDs")
    if any(not isinstance(pair, list) or len(pair) != 2 or
           any(label not in ("visible", "hidden", "unknown") for label in pair) for pair in rows.values()):
        raise ValueError("Invalid visibility response")
    return {case: tuple(pair) for case, pair in rows.items()}


def metrics(actual, expected):
    became_visible = ("hidden", "visible")
    confirmed = [(actual[case], want) for case, want in expected.items() if case in actual]
    return {"cases": len(expected),
            "correct_pairs": sum(pair == want for pair, want in confirmed),
            "newly_visible_detected": sum(pair == want == became_visible for pair, want in confirmed),
            "false_newly_visible": sum(pair == became_visible and want != became_visible for pair, want in confirmed),
            "correct_not_newly_visible": sum("unknown" not in pair and pair != became_visible
                                             and want != became_visible for pair, want in confirmed),
            "abstained": sum("unknown" in pair for pair, _ in confirmed),
            "unscored": len(expected) - len(confirmed)}


async def ask(endpoint, token, trust, cases, chart):
    from client import DirectConnect

    tools = [{"name": "capture_screenshot", "description": "Read the fixed synthetic before/after contact sheet.",
              "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}}] if chart else []
    request, context = uuid4().hex, uuid4().hex
    async with asyncio.timeout(90):
        async with DirectConnect(endpoint, ssl=trust, proxy=None, additional_headers={"Authorization": f"Bearer {token}"},
                                 max_size=65536, open_timeout=8, close_timeout=3) as socket:
            await socket.send(json.dumps({"type": "hello", "protocol": 1, "dataset_id": DATASET,
                                          "context_id": context, "tools": tools}))
            ready = json.loads(await socket.recv())
            if ready.get("type") != "ready" or (chart and "capture_screenshot" not in ready.get("tools", [])):
                raise ValueError("Agent did not accept the synthetic evaluation")
            await socket.send(json.dumps({"type": "user_message", "request_id": request, "text": prompt(cases, bool(chart))}))
            answer, calls = None, 0
            for _ in range(16):
                event = json.loads(await socket.recv())
                if event.get("request_id") != request:
                    raise ValueError("Unexpected request")
                match event.get("type"):
                    case "started":
                        pass
                    case "assistant_message":
                        if event.get("final"):
                            answer = event["text"]
                    case "completed" if not chart or calls:
                        return ready["model"], answer, calls
                    case "tool_call" if chart:
                        arguments = event.get("arguments")
                        calls += 1
                        if (calls > 2 or event.get("name") != "capture_screenshot" or
                                event.get("context_id") != context or event.get("dataset_id") != DATASET or
                                not isinstance(arguments, dict) or set(arguments) - {"include_alpha"}):
                            raise ValueError("Unexpected synthetic tool call")
                        await socket.send(json.dumps({"type": "tool_result", "request_id": request,
                            "call_id": event["call_id"], "dataset_id": DATASET, "context_id": context,
                            "result": {"description": "Labeled synthetic before/after contact sheet"},
                            "image_png_base64": base64.b64encode(chart).decode("ascii")}))
                    case _:
                        raise ValueError("Unexpected evaluation event")
    raise ValueError("No final response")


async def run(endpoint, token, trust, layout):
    all_expected, text, images = {}, {}, {}
    fixtures = single_pair_fixtures() if layout == "single-pair" else map(fixture, range(2))
    for batch, (expected, chart) in enumerate(fixtures, 1):
        all_expected.update(expected)
        for condition, evidence, collected in (("text", None, text), ("before_after", chart, images)):
            start = time.monotonic()
            try:
                model, answer, calls = await ask(endpoint, token, trust, expected, evidence)
                scores = predictions(answer, expected)
                collected.update(scores)
                result = {"model": model, "image_reads": calls, **metrics(scores, expected)}
            except Exception as error:
                result = {"failure": type(error).__name__}
            print(json.dumps({"batch": batch, "condition": condition, "seconds": round(time.monotonic() - start, 2),
                              **result}), flush=True)
    baseline = dict.fromkeys(all_expected, UNKNOWN)
    print(json.dumps({"layout": layout, "category_baseline": metrics(baseline, all_expected),
                      "llm_text": metrics(text, all_expected),
                      "llm_before_after": metrics(images, all_expected)}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent-url", required=True)
    parser.add_argument("--ca", required=True)
    parser.add_argument("--layout", choices=("contact-sheet", "single-pair"), default="contact-sheet")
    args = parser.parse_args()
    url = urlsplit(args.agent_url)
    if (url.scheme != "https" or not url.hostname or url.username is not None or url.password is not None
            or url.path not in ("", "/") or url.query or url.fragment):
        parser.error("Use a trusted HTTPS origin")
    raw = sys.stdin.readline(1025)
    token = raw.strip()
    if not token or len(raw) > 1024 or not all(33 <= ord(char) <= 126 for char in token):
        parser.error("Supply the private bearer token via standard input")
    trust = ssl.create_default_context(cafile=args.ca)
    asyncio.run(run(urlunsplit(("wss", url.netloc, "/v1/session", "", "")), token, trust, args.layout))


if __name__ == "__main__":
    main()
