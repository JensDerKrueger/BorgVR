"""Bounded clipping-policy induction experiment; no app writes or background model calls."""

import argparse
import asyncio
from collections import Counter, defaultdict
import json
from pathlib import Path
import ssl
import sys
import time
from urllib.parse import urlsplit, urlunsplit
from uuid import UUID

from .workflow_learner import Episode, find_patterns, load_episode

AXES = "xyz"
CONDITIONS = {"unclipped", "x_clipped", "y_clipped", "z_clipped"}
EFFECTS = {f"{verb}_{axis}" for verb in ("tighten", "release") for axis in AXES}
MAX_CASES = 12
MIN_SUPPORT = 3


def initial_condition(before):
    axes = [axis for axis, low, high in zip(AXES, before["clip_minimum"], before["clip_maximum"])
            if high - low < 0.95]
    if not axes:
        return "unclipped"
    return axes[0] + "_clipped" if len(axes) == 1 else None


def observed_effect(evidence):
    def widths(state):
        return [b - a for a, b in zip(state["clip_minimum"], state["clip_maximum"])]
    effects = [(("tighten_" if change < 0 else "release_") + axis)
               for axis, a, b in zip(AXES, widths(evidence["before"]), widths(evidence["after"]))
               if abs(change := b - a) >= 0.10]
    return effects[0] if len(effects) == 1 else None


def eligible(cases):
    if len(cases) > MAX_CASES or len({case.id for case in cases}) != len(cases):
        raise ValueError("Expected at most 12 distinct demonstration IDs")
    return [case for case in cases if case.end == "finished" and case.goal == "expose_region"
            and "clipping" in case.actions and case.evidence is not None]


def evidence_baseline(cases):
    groups = defaultdict(Counter)
    for case in eligible(cases):
        if condition := initial_condition(case.evidence["before"]):
            groups[condition][observed_effect(case.evidence)] += 1
    return {
        condition: effect for condition, counts in groups.items()
        for effect, count in counts.items()
        if effect and count >= MIN_SUPPORT and count * 2 > sum(counts.values())
    }


def model_prompt(cases):
    # References are local to the experiment; no episode UUID or ownership data leaves this process.
    data = [{"case": f"case-{i + 1}", "before": row.evidence["before"], "after": row.evidence["after"],
             "self_reported_outcome": row.outcome} for i, row in enumerate(eligible(cases))]
    return """Analyze a synthetic volume visualization workflow experiment. This is data analysis, not an app operation.
The question: what final clipping change is commonly observed from each INITIAL clipping condition?
These are normalized, dataset-local XYZ box bounds. Compute each axis width as clip_maximum minus clip_minimum.
Initially an axis is clipped if its width is less than 0.95. Conditions: unclipped (none), x_clipped,
y_clipped, z_clipped (exactly that one axis). Ignore cases with multiple initially clipped axes.
An effect is tighten_x/y/z for a decrease of at least 0.10 on that one axis, or release_x/y/z for an increase
of at least 0.10 on that one axis. A change on two axes or none does not support a single-axis effect.
Rotation and self-reported outcome do not define a clipping effect. Do not infer that any effect caused success.
For each condition, propose a result only when at least three different examples show the same effect AND
they are a strict majority of all examples for that condition. Omit unsupported conditions, even if plausible.
Return only JSON, exactly this shape: {"hypotheses":[{"condition":"unclipped","effect":"tighten_y",
"cases":["case-1","case-2","case-3"]}]}. That JSON is a format example, not a result. Use {"hypotheses":[]}
if nothing qualifies. Evidence records to analyze follow:\n""" + json.dumps(data, separators=(",", ":"))


def model_hypotheses(text, cases):
    if len(text.encode()) > 8192:
        raise ValueError("Model result too large")
    text = text.strip()
    if text.startswith("```json\n") and text.endswith("```"):
        text = text[8:-3].strip()
    def unique(pairs):
        result = dict(pairs)
        if len(result) != len(pairs):
            raise ValueError("Duplicate object key")
        return result
    value = json.loads(text, object_pairs_hook=unique)
    if not isinstance(value, dict) or set(value) != {"hypotheses"}:
        raise ValueError("Expected hypothesis object")
    rows = value["hypotheses"]
    if not isinstance(rows, list) or len(rows) > len(CONDITIONS):
        raise ValueError("Invalid hypothesis count")
    lookup = {f"case-{i + 1}": row for i, row in enumerate(eligible(cases))}
    accepted, rejected, seen = {}, 0, set()
    for row in rows:
        if not isinstance(row, dict) or set(row) != {"condition", "effect", "cases"}:
            raise ValueError("Invalid hypothesis fields")
        condition, effect, references = row["condition"], row["effect"], row["cases"]
        if (not isinstance(condition, str) or condition not in CONDITIONS or condition in seen
                or not isinstance(effect, str) or effect not in EFFECTS
                or not isinstance(references, list) or len(references) > MAX_CASES
                or not all(isinstance(ref, str) and ref in lookup for ref in references)
                or len(references) != len(set(references))):
            raise ValueError("Invalid hypothesis values or references")
        seen.add(condition)
        conditioned = [case for case in lookup.values() if initial_condition(case.evidence["before"]) == condition]
        if (len(references) < MIN_SUPPORT or len(references) * 2 <= len(conditioned)
                or any(initial_condition(lookup[ref].evidence["before"]) != condition
                       or observed_effect(lookup[ref].evidence) != effect for ref in references)):
            rejected += 1
            continue
        accepted[condition] = effect
    return accepted, rejected


def synthetic_cases():
    def bounds():
        return {"clip_minimum": [0.0] * 3, "clip_maximum": [1.0] * 3, "rotation": [0.0, 0.0, 0.0, 1.0]}

    # Training conditions share identical action prefixes. Numeric changes and outcomes differ.
    cases = []
    for i in range(8):
        before, after = bounds(), bounds()
        if i < 3:
            after["clip_minimum"][0] = (0.14, 0.24, 0.31)[i]
        elif i < 6:
            before["clip_maximum"][2] = (0.76, 0.59, 0.42)[i - 3]
        else:
            before["clip_maximum"][1] = after["clip_maximum"][1] = 0.6
            after["clip_minimum"][i - 6] = 0.23
        after["rotation"] = [0.0, 0.0, 0.6, 0.8]
        cases.append(Episode(str(UUID(int=i + 1)), "expose_region", ("clipping", "transform"),
                             ("reached", "unknown", "not_reached")[i % 3], "finished",
                             {"before": before, "after": after}))
    # Distinct held-out view settings; their intended effect never enters the prompt.
    test = []
    for axis, widths, expected in ((None, (1.0, 1.0), "tighten_x"),
                                    (2, (0.52, 0.81), "release_z"),
                                    (1, (0.64, 0.38), None), (0, (0.55, 0.74), None)):
        for width in widths:
            before = bounds()
            before["rotation"] = [0.6, 0.0, 0.0, 0.8]
            if axis is not None:
                before["clip_maximum"][axis] = width
            test.append((before, expected))
    return cases, test


def score(predictions, test):
    choices = [(predictions.get(initial_condition(before)), expected) for before, expected in test]
    return {"total": len(choices),
            "correct_effects": sum(actual == expected and expected is not None for actual, expected in choices),
            "correct_abstentions": sum(actual is None and expected is None for actual, expected in choices),
            "wrong_or_unsupported_effects": sum(actual is not None and actual != expected for actual, expected in choices),
            "missed_effects": sum(actual is None and expected is not None for actual, expected in choices)}


async def via_agent(prompt, address, token, trust):
    # Reuse the existing deployment without advertising any app tools or sending real corpus data.
    from client import DirectConnect
    parts = urlsplit(address)
    if parts.scheme != "https" or not parts.hostname or parts.username or parts.password or parts.path not in ("", "/") or parts.query or parts.fragment:
        raise ValueError("Expected an HTTPS origin")
    endpoint = urlunsplit(("wss", parts.netloc, "/v1/session", "", ""))
    async with asyncio.timeout(90):
        async with DirectConnect(endpoint, ssl=trust, proxy=None, additional_headers={"Authorization": f"Bearer {token}"},
                                 max_size=65536, open_timeout=8, close_timeout=3) as socket:
            await socket.send(json.dumps({"type": "hello", "protocol": 1, "dataset_id": "synthetic-workflow-study",
                                          "context_id": "synthetic-only", "tools": []}))
            ready = json.loads(await socket.recv())
            if ready.get("type") != "ready":
                raise ValueError("Agent handshake failed")
            request_id, answer = "synthetic-ablation", None
            await socket.send(json.dumps({"type": "user_message", "request_id": request_id, "text": prompt}))
            for _ in range(16):
                event = json.loads(await socket.recv())
                if event.get("request_id") != request_id or event["type"] not in {"started", "assistant_message", "completed"}:
                    raise ValueError("Unexpected agent event")
                if event["type"] == "assistant_message" and event.get("final") is True:
                    answer = event["text"]
                if event["type"] == "completed" and isinstance(answer, str):
                    return ready.get("model", "unknown"), answer
    raise ValueError("No finite final reply")


def direct_endpoint(address):
    parts = urlsplit(address)
    local = parts.hostname in {"localhost", "127.0.0.1", "::1", "vllm"}
    if (not parts.hostname or (parts.scheme != "https" and not (local and parts.scheme == "http"))
            or parts.username is not None or parts.password is not None
            or parts.path not in {"/v1", "/v1/"} or parts.query or parts.fragment):
        raise ValueError("Expected a trusted /v1 endpoint; plain HTTP is for local vLLM only")
    return urlunsplit((parts.scheme, parts.netloc, "/v1/chat/completions", "", ""))


async def via_vllm(prompt, address, token, name, trust):
    import httpx
    async with asyncio.timeout(75):
        async with httpx.AsyncClient(timeout=70, follow_redirects=False, trust_env=False, verify=trust) as client:
            async with client.stream("POST", direct_endpoint(address),
                                         headers={"Authorization": f"Bearer {token}"}, json={
                "model": name, "temperature": 0, "max_tokens": 700,
                "messages": [{"role": "user", "content": prompt}],
                "response_format": {"type": "json_object"},
                "chat_template_kwargs": {"enable_thinking": False},
            }) as response:
                response.raise_for_status()
                body = bytearray()
                async for chunk in response.aiter_bytes(chunk_size=8192):
                    if len(body) + len(chunk) > 65536:
                        raise ValueError("Model response too large")
                    body.extend(chunk)
    return name, json.loads(body)["choices"][0]["message"]["content"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--agent-url", help="existing BorgVR server (synthetic experiment only)")
    target.add_argument("--vllm-url", help="trusted OpenAI-compatible /v1 base URL")
    parser.add_argument("--ca", type=Path)
    parser.add_argument("--token-file", type=Path)
    parser.add_argument("--model")
    parser.add_argument("--repeat", type=int, default=1, choices=range(1, 6))
    parser.add_argument("--demonstrations", type=Path, nargs="+", help="explicit local single-profile corpus; direct vLLM only")
    args = parser.parse_args()
    if args.demonstrations and not args.vllm_url:
        parser.error("Real demonstrations require an explicitly trusted direct model endpoint")
    if args.demonstrations and len(args.demonstrations) > MAX_CASES:
        parser.error(f"Select at most {MAX_CASES} demonstrations")
    if args.vllm_url and not args.model:
        parser.error("--model is required for direct vLLM")
    try:
        training, test = (list(map(load_episode, args.demonstrations)), []) if args.demonstrations else synthetic_cases()
        baseline = evidence_baseline(training)
        result = {"dataset": "user-selected (not scored)" if args.demonstrations else "synthetic",
                  "category_patterns": find_patterns(training)["patterns"],
                  "numeric_baseline": baseline, "model_runs": []}
        if test:
            result["category_baseline_score"] = score({}, test)
            result["numeric_baseline_score"] = score(baseline, test)
        if args.agent_url or args.vllm_url:
            if args.token_file:
                with args.token_file.open() as token_stream:
                    raw_token = token_stream.read(1025)
            else:
                raw_token = sys.stdin.readline(1025)
            token = raw_token.strip()
            if not token or len(raw_token) > 1024 or not all(33 <= ord(char) <= 126 for char in token):
                raise ValueError("Invalid bearer token")
            prompt = model_prompt(training)
            trust = ssl.create_default_context(cafile=str(args.ca) if args.ca else None)
            for _ in range(args.repeat):
                start = time.monotonic()
                model, text = asyncio.run(via_agent(prompt, args.agent_url, token, trust) if args.agent_url else
                                          via_vllm(prompt, args.vllm_url, token, args.model, trust))
                try:
                    if not isinstance(text, str):
                        raise ValueError("Expected a text response")
                    hypotheses, rejected = model_hypotheses(text, training)
                    row = {"hypotheses": hypotheses, "rejected_hypotheses": rejected, "valid_json": True}
                    if test:
                        row["score"] = score(hypotheses, test)
                except (ValueError, RecursionError):
                    row = {"valid_json": False}
                result["model_runs"].append({"model": model, "seconds": round(time.monotonic() - start, 2), **row})
        print(json.dumps(result, indent=2))
    except Exception as error:
        parser.exit(2, f"Experiment failed ({type(error).__name__}).\n")


if __name__ == "__main__":
    main()
