"""Deterministic comparison and texture hints for isolated volume previews."""

import base64
import io

from PIL import Image, ImageChops, ImageDraw, ImageFilter

MAX_RENDERS = 32
MIN_WIDTH = 0.01
SPECKLE_THRESHOLD = 0.2
TEXTURE_THRESHOLD = 0.25
TEXTURE_DELTA = 4
NOISE_GAP_THRESHOLD = 0.2


def equal_bands(_, count):
    return [{"low": i / count, "high": (i + 1) / count} for i in range(count)]


def observe_band(run, band, image):
    preview = run.images[image]
    mask = preview.getchannel("A").point(lambda value: 255 if value else 0)
    visible = mask.histogram()[255]
    speckle = texture = None
    if visible and min(mask.size) >= 3:
        # Median filtering highlights isolated pixels in the silhouette, not just sparse coverage.
        smooth = mask.filter(ImageFilter.MedianFilter(3))
        union = ImageChops.lighter(mask, smooth).histogram()[255]
        speckle = ImageChops.difference(mask, smooth).histogram()[255] / union
        # Ignore object boundaries when measuring rapid changes in apparent brightness.
        interior = mask.filter(ImageFilter.MinFilter(3))
        inside = interior.histogram()[255]
        if inside:
            gray = preview.convert("L")
            residual = ImageChops.difference(gray, gray.filter(ImageFilter.BoxBlur(1)))
            peaks = residual.point(lambda value: 255 if value >= TEXTURE_DELTA else 0)
            texture = ImageChops.darker(interior, peaks).histogram()[255] / inside
    return {"low": band["low"], "high": band["high"], "image": image,
            "coverage": visible / (mask.width * mask.height),
            "speckle_fraction": speckle, "fine_texture_fraction": texture}


def noise_candidate(leaf):
    return ((leaf.get("speckle_fraction") or 0) >= SPECKLE_THRESHOLD
            or (leaf.get("fine_texture_fraction") or 0) >= TEXTURE_THRESHOLD)


def noise_gap(left, right):
    return max(abs((left.get(key) or 0) - (right.get(key) or 0))
               for key in ("speckle_fraction", "fine_texture_fraction"))


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
    gaps = [max(difference(run, a, b), noise_gap(a, b) * threshold / NOISE_GAP_THRESHOLD)
            for a, b in zip(leaves, leaves[1:])]
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
    leaves = state["leaves"]
    if len(leaves) > MAX_RENDERS:
        raise ValueError("Too many band previews")
    groups = []
    previous = None
    for leaf in leaves:
        if (previous is None or bool(previous["coverage"]) != bool(leaf["coverage"])
                or difference(run, previous, leaf) >= threshold
                or noise_candidate(previous) != noise_candidate(leaf)
                or noise_gap(previous, leaf) >= NOISE_GAP_THRESHOLD):
            groups.append([])
        groups[-1].append(leaf)
        previous = leaf

    visible = [leaf for leaf in leaves if leaf["coverage"] > 0]
    preview_numbers = {leaf["image"]: i + 1 for i, leaf in enumerate(visible)}
    if visible:
        columns = min(5, len(visible))
        rows = (len(visible) + columns - 1) // columns
        tile = 120
        sheet = Image.new("RGB", (columns * tile, rows * tile), "#222222")
        draw = ImageDraw.Draw(sheet)
        for i, leaf in enumerate(visible):
            x, y = (i % columns) * tile, (i // columns) * tile
            preview = run.images[leaf["image"]].copy()
            preview.thumbnail((tile - 12, tile - 26))
            sheet.paste(preview, (x + (tile - preview.width) // 2, y + 4), preview)
            draw.text((x + 6, y + tile - 19), f"{i + 1}: {leaf['low']:.3f} - {leaf['high']:.3f}", fill="white")
        buffer = io.BytesIO()
        sheet.save(buffer, format="PNG")
        run.sheet = base64.b64encode(buffer.getvalue()).decode("ascii")

    summary, bins = [], []
    for group in groups:
        row = {"interval": [group[0]["low"], group[-1]["high"]],
               "max_coverage": round(max(leaf["coverage"] for leaf in group), 4)}
        if row["max_coverage"] > 0:
            representative = max(group, key=lambda leaf: leaf["coverage"])
            row.update(preview=preview_numbers[representative["image"]],
                       preview_interval=[representative["low"], representative["high"]])
        summary.append(row)
        for leaf in group:
            bin_row = {"interval": [round(leaf["low"], 6), round(leaf["high"], 6)],
                       "coverage": round(leaf["coverage"], 4), "noise_candidate": noise_candidate(leaf)}
            for key in ("speckle_fraction", "fine_texture_fraction"):
                value = leaf.get(key)
                bin_row[key] = round(value, 4) if value is not None else None
            if leaf["coverage"] > 0:
                bin_row["preview"] = preview_numbers[leaf["image"]]
            bins.append(bin_row)
    return {"normalized": True, "view": "coarse_dataset_z_projection", "difference_threshold": threshold,
            "difference_metric": "fraction_of_pixels_with_different_alpha", "rendered_previews": state["renders"],
            "stop_reason": state["stop_reason"], "intervals": summary, "bins": bins,
            "noise_metrics": {"speckle_fraction": "Fraction of the silhouette changed by a 3x3 median filter.",
                              "fine_texture_fraction": "Fraction of opaque interior with a brightness change of at least 4/255 after a 3x3 box blur.",
                              "noise_candidate": "Speckle >= 0.20 or fine texture >= 0.25. Real thin features or texture can also trigger this hint."}}
