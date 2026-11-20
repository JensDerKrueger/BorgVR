"""Offline descriptive baseline. No model calls, app commands, or persistent profile access."""

import argparse
from collections import Counter
from dataclasses import dataclass
import json
import math
from pathlib import Path
from uuid import UUID

GOALS = {"inspect_values", "expose_region", "unspecified"}
ACTIONS = {"transform", "clipping", "lighting", "rendering", "annotations", "volume", "transfer_function"}
OUTCOMES = ("reached", "not_reached", "unknown")
MAX_EPISODES = 128
MAX_ACTIONS = 256
MAX_FILE_BYTES = 16 * 1024
MIN_SUPPORT = 3


@dataclass(frozen=True)
class Episode:
    id: str
    goal: str
    actions: tuple[str, ...]
    outcome: str
    end: str
    evidence: dict | None = None


def _unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key")
        result[key] = value
    return result


def load_episode(path: Path) -> Episode:
    if not path.is_file():
        raise ValueError("Expected a demonstration file")
    with path.open("rb") as stream:
        raw = stream.read(MAX_FILE_BYTES + 1)
    return decode_episode(raw)


def decode_episode(raw: bytes) -> Episode:
    if len(raw) > MAX_FILE_BYTES:
        raise ValueError("Demonstration exceeds size limit")
    value = json.loads(raw, object_pairs_hook=_unique_keys)
    fields = {"version", "id", "goal", "actions", "outcome", "end"}
    if not isinstance(value, dict) or type(value.get("version")) is not int:
        raise ValueError("Unexpected demonstration fields")
    version = value["version"]
    if version not in (1, 2):
        raise ValueError("Unsupported demonstration version")
    if set(value) != fields | ({"evidence"} if version == 2 else set()):
        raise ValueError("Unexpected demonstration fields")
    identifier, goal, actions, outcome, end = (value[k] for k in ("id", "goal", "actions", "outcome", "end"))
    if not isinstance(identifier, str) or len(identifier) != 36:
        raise ValueError("Invalid demonstration identifier")
    identifier = str(UUID(identifier))
    if not isinstance(goal, str) or goal not in GOALS:
        raise ValueError("Invalid demonstration goal")
    if outcome not in OUTCOMES or end not in ("finished", "interrupted", "limit"):
        raise ValueError("Invalid demonstration outcome or ending")
    if end != "finished" and outcome != "unknown":
        raise ValueError("Only a finished demonstration may have a rating")
    if (not isinstance(actions, list) or not 1 <= len(actions) <= MAX_ACTIONS
            or any(not isinstance(action, str) or action not in ACTIONS for action in actions)
            or any(a == b for a, b in zip(actions, actions[1:]))):
        raise ValueError("Invalid action sequence")
    evidence = validate_evidence(value["evidence"]) if version == 2 and end == "finished" else None
    if version == 2 and evidence is None:
        raise ValueError("Evidence requires a finished demonstration")
    return Episode(identifier, goal, tuple(actions), outcome, end, evidence)


def validate_evidence(pair):
    def axis_values(items, count, low, high):
        if (not isinstance(items, list) or len(items) != count or
                any(type(x) not in (int, float) or not low <= x <= high or not math.isfinite(x) for x in items)):
            raise ValueError("Invalid evidence vector")
        return [float(x) for x in items]

    if not isinstance(pair, dict) or set(pair) != {"before", "after"}:
        raise ValueError("Evidence requires a before and an after snapshot")
    snapshots = {}
    for phase, state in pair.items():
        if not isinstance(state, dict) or set(state) != {"clip_minimum", "clip_maximum", "rotation"}:
            raise ValueError("Unexpected evidence fields")
        lower = axis_values(state["clip_minimum"], 3, 0, 1)
        upper = axis_values(state["clip_maximum"], 3, 0, 1)
        rotation = axis_values(state["rotation"], 4, -1.001, 1.001)
        if any(a > b for a, b in zip(lower, upper)) or not 0.99 <= sum(x * x for x in rotation) <= 1.01:
            raise ValueError("Invalid evidence bounds or rotation")
        snapshots[phase] = {"clip_minimum": lower, "clip_maximum": upper, "rotation": rotation}
    return snapshots


def find_patterns(episodes: list[Episode]) -> dict:
    if len(episodes) > MAX_EPISODES or len({episode.id for episode in episodes}) != len(episodes):
        raise ValueError("Too many demonstrations or duplicate demonstration IDs")
    ignored = Counter()
    groups = {goal: [] for goal in sorted(GOALS - {"unspecified"})}
    for episode in episodes:
        if episode.end != "finished":
            ignored[episode.end] += 1
        elif episode.goal == "unspecified":
            ignored["unknown_goal"] += 1
        else:
            groups[episode.goal].append(episode)

    patterns = []
    for goal, cases in groups.items():
        for length in (1, 2):
            # A short demonstration is still a case against a longer opening pattern.
            counts = Counter(case.actions[:length] for case in cases if len(case.actions) >= length)
            for prefix, support in sorted(counts.items()):
                if support < MIN_SUPPORT or support * 2 <= len(cases):
                    continue
                matching = [case for case in cases if case.actions[:length] == prefix]
                alternatives = [case for case in cases if case.actions[:length] != prefix]

                def outcomes(rows):
                    totals = Counter(row.outcome for row in rows)
                    return {outcome: totals[outcome] for outcome in OUTCOMES}

                patterns.append({
                    "goal": goal, "opening_sequence": list(prefix), "support": support, "total": len(cases),
                    "examples": sorted(case.id for case in matching),
                    "counterexamples": sorted(case.id for case in alternatives),
                    "self_reported_outcomes": {"matching": outcomes(matching), "other": outcomes(alternatives)},
                })
    return {"version": 1, "type": "descriptive_patterns_not_verified_rules",
            "episodes": len(episodes), "ignored": dict(sorted(ignored.items())), "patterns": patterns}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("demonstrations", nargs="+", type=Path,
                        help="explicitly selected JSON exports from one user; not a shared corpus")
    args = parser.parse_args()
    if len(args.demonstrations) > MAX_EPISODES:
        parser.error(f"Analyze at most {MAX_EPISODES} demonstrations per run")
    try:
        result = find_patterns([load_episode(path) for path in args.demonstrations])
    except (OSError, ValueError, RecursionError) as error:
        parser.exit(2, f"Cannot analyze demonstrations ({type(error).__name__}).\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
