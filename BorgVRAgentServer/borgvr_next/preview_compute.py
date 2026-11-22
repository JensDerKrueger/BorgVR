"""Deterministic comparison of alpha masks from isolated volume previews."""

import base64
import io

from PIL import Image, ImageChops, ImageDraw

MAX_RENDERS = 32
MIN_WIDTH = 0.01


def equal_bands(_, count):
    return [{"low": i / count, "high": (i + 1) / count} for i in range(count)]


def observe_band(run, band, image):
    mask = run.images[image].getchannel("A")
    return {"low": band["low"], "high": band["high"], "image": image,
            "coverage": 1 - mask.histogram()[0] / (mask.width * mask.height)}


def band_state(_, leaves):
    return {"leaves": leaves, "renders": len(leaves), "done": False, "stop_reason": "depth_limit"}


def difference(run, left, right):
    a, b = (run.images[row["image"]].getchannel("A") for row in (left, right))
    if a.size != b.size:
        raise ValueError("Preview dimensions differ")
    equal = sum(ImageChops.difference(a, b).histogram()[:16])
    return (a.width * a.height - equal) / (a.width * a.height)


def plan_refinement(run, state, threshold, initial):
    leaves = state["leaves"]
    if not leaves and state["renders"] == 0:
        return {"kept": [], "children": initial, "renders": 0, "stop_reason": "depth_limit"}
    gaps = [difference(run, a, b) for a, b in zip(leaves, leaves[1:])]
    eligible = []
    for i, leaf in enumerate(leaves):
        score = max(gaps[i - 1] if i else 0, gaps[i] if i < len(gaps) else 0)
        if score >= threshold and (leaf["high"] - leaf["low"]) / 2 >= MIN_WIDTH:
            eligible.append((score, i))
    slots = max(0, (MAX_RENDERS - state["renders"]) // 2)
    selected = {i for _, i in sorted(eligible, key=lambda item: (-item[0], item[1]))[:slots]}
    children = []
    for i, leaf in enumerate(leaves):
        if i not in selected:
            continue
        low, high = leaf["low"], leaf["high"]
        middle = (low + high) / 2
        children.extend(({"low": low, "high": middle}, {"low": middle, "high": high}))
    stop_reason = ("render_budget" if eligible and not selected else
                   "minimum_width" if not selected and any(gap >= threshold for gap in gaps) else
                   "stable" if not selected else "depth_limit")
    return {"kept": [leaf for i, leaf in enumerate(leaves) if i not in selected],
            "children": children, "renders": state["renders"], "stop_reason": stop_reason}


def update_bands(_, plan, children):
    if len(children) != len(plan["children"]):
        raise ValueError("Missing band previews")
    return {"leaves": sorted([*plan["kept"], *children], key=lambda band: band["low"]),
            "renders": plan["renders"] + len(children), "done": not children, "stop_reason": plan["stop_reason"]}


def report_bands(run, state, threshold):
    groups = []
    previous = None
    for leaf in state["leaves"]:
        if (previous is None or bool(previous["coverage"]) != bool(leaf["coverage"])
                or difference(run, previous, leaf) >= threshold):
            groups.append([])
        groups[-1].append(leaf)
        previous = leaf

    visible = [(index, max(group, key=lambda leaf: leaf["coverage"])) for index, group in enumerate(groups)
               if any(leaf["coverage"] > 0 for leaf in group)]
    if len(visible) > 8:
        visible = [visible[round(i * (len(visible) - 1) / 7)] for i in range(8)]
    representatives = {index: (i + 1, leaf) for i, (index, leaf) in enumerate(visible)}
    if visible:
        columns = min(4, len(visible))
        rows = (len(visible) + columns - 1) // columns
        tile = 148
        sheet = Image.new("RGB", (columns * tile, rows * tile), "#222222")
        draw = ImageDraw.Draw(sheet)
        for i, (_, leaf) in enumerate(visible):
            x, y = (i % columns) * tile, (i // columns) * tile
            preview = run.images[leaf["image"]].copy()
            preview.thumbnail((tile - 12, tile - 26))
            sheet.paste(preview, (x + (tile - preview.width) // 2, y + 4), preview)
            draw.text((x + 6, y + tile - 19), f"{i + 1}: {leaf['low']:.3f} - {leaf['high']:.3f}", fill="white")
        buffer = io.BytesIO()
        sheet.save(buffer, format="PNG")
        run.sheet = base64.b64encode(buffer.getvalue()).decode("ascii")

    summary = []
    for i, group in enumerate(groups):
        row = {"interval": [group[0]["low"], group[-1]["high"]],
               "max_coverage": round(max(leaf["coverage"] for leaf in group), 4)}
        if i in representatives:
            number, leaf = representatives[i]
            row.update(preview=number, preview_interval=[leaf["low"], leaf["high"]])
        summary.append(row)
    return {"normalized": True, "view": "coarse_dataset_z_projection", "difference_threshold": threshold,
            "difference_metric": "fraction_of_pixels_with_different_alpha", "rendered_previews": state["renders"],
            "stop_reason": state["stop_reason"], "intervals": summary}
