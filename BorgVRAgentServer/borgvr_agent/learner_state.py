"""Portable, versioned evidence and hypotheses. Never contains app instructions or credentials."""

from collections import defaultdict
from dataclasses import asdict
import json

from .workflow_learner import MAX_EPISODES, MIN_SUPPORT, _unique_keys, decode_episode

STATE_VERSION = 1
MAX_STATE_BYTES = 2 * 1024 * 1024


def episode_payload(episode):
    value = asdict(episode)
    value["actions"] = list(episode.actions)
    value["version"] = 1 if episode.evidence is None else 2
    if episode.evidence is None:
        del value["evidence"]
    return value


def hypotheses_for(episodes):
    groups = defaultdict(list)
    for episode in episodes:
        if episode.end == "finished" and episode.goal != "unspecified":
            groups[episode.goal].append(episode)

    hypotheses = []
    for goal, examples in sorted(groups.items()):
        prefixes = {episode.actions[:length] for episode in examples for length in (1, 2)
                    if len(episode.actions) >= length}
        for prefix in sorted(prefixes):
            matching = [episode for episode in examples if episode.actions[:len(prefix)] == prefix]
            supporting = sorted(episode.id for episode in matching if episode.outcome == "reached")
            contradicting = sorted(episode.id for episode in examples if
                                   (episode in matching and episode.outcome == "not_reached") or
                                   (episode not in matching and episode.outcome == "reached"))
            observed = sorted(episode.id for episode in matching)
            status = ("candidate" if len(supporting) >= MIN_SUPPORT and len(supporting) > len(contradicting)
                      else "pending")
            hypotheses.append({"goal": goal, "opening_sequence": list(prefix), "status": status,
                               "observed_episode_ids": observed, "supporting_episode_ids": supporting,
                               "counterexample_episode_ids": contradicting})
    return hypotheses


def portable_state(episodes, hypotheses):
    return {"version": STATE_VERSION,
            "episodes": [episode_payload(episode) for episode in sorted(episodes, key=lambda item: item.id)],
            "hypotheses": hypotheses}


def decode_state(data):
    if len(data) > MAX_STATE_BYTES:
        raise ValueError("Workflow state is too large")
    value = json.loads(data, object_pairs_hook=_unique_keys)
    if (not isinstance(value, dict) or set(value) != {"version", "episodes", "hypotheses"} or
            type(value["version"]) is not int or value["version"] != STATE_VERSION or
            not isinstance(value["episodes"], list) or len(value["episodes"]) > MAX_EPISODES):
        raise ValueError("Invalid workflow state")
    episodes = [decode_episode(json.dumps(item, ensure_ascii=True, allow_nan=False).encode())
                for item in value["episodes"]]
    if len({episode.id for episode in episodes}) != len(episodes):
        raise ValueError("Duplicate workflow evidence")
    # The v1 baseline is deterministic. Imported hypotheses cannot introduce facts
    # or executable instructions unsupported by validated demonstrations.
    if hypotheses_for(episodes) != value["hypotheses"]:
        raise ValueError("Workflow hypotheses do not match their evidence")
    return episodes
