"""Agent-only annotation policy; no renderer, GUI, file or BorgVR implementation access."""

from uuid import UUID

ANNOTATION_DELETES = frozenset({"remove_object", "remove_measurement", "clear_annotations"})
ANNOTATION_WRITES = frozenset({"upsert_sphere_marker", "upsert_stroke_marker", "upsert_measurement"}) | ANNOTATION_DELETES
ANNOTATION_PROMPT = """
You can create/edit sphere, directional and stroke markers and length/area/volume measurements
using the offered annotation tools. Read application state and list_objects/list_measurements
before upserts. Coordinates are dataset-local [0,1], not pixels, world meters or patient axes.
A screenshot alone does not establish an exact 3D point; ask for missing location information
and label approximate placement honestly. Omit id for creation; use returned UUIDs for edits.
Upsert replaces the complete item: preserve unmodified fields and measurement point IDs.
Follow pagination, never replace a detailsOmitted summary, and list again after changes.
Report BorgVR's returned values/units and missing physical calibration, not image-derived sizes.
Length is a polyline, area a planar polygon, volume a convex hull, NOT segmented organ volume.
Correct rejected geometry instead of claiming success. Delete only on explicit user request,
never as rendering cleanup. Use listed UUIDs for individual deletion. For bulk deletion use
clear_annotations with scope all/markers/measurements and confirm true; that flag does NOT
replace the app's local human confirmation. The app also confirms deleting the last item.
If the user declines, stop deleting and do not bypass the decision with individual calls.
Placed meshes are preserved. Mesh placement remains unavailable.
"""


def annotation_lists_for(name, arguments):
    if name in {"upsert_sphere_marker", "upsert_stroke_marker", "remove_object"}:
        return {"list_objects"}
    if name in {"upsert_measurement", "remove_measurement"}:
        return {"list_measurements"}
    if name == "clear_annotations":
        scope = arguments.get("scope", "all")
        return ({"list_objects"} if scope == "markers" else {"list_measurements"} if scope == "measurements"
                else {"list_objects", "list_measurements"})
    return set()


def validate_annotation_arguments(name, arguments):
    if name not in ANNOTATION_WRITES:
        return
    if name == "clear_annotations" and arguments.get("confirm") is not True:
        raise ValueError("Explicit confirm true is required; the app will separately ask the user before deletion.")
    ids = [arguments["id"]] if "id" in arguments else []
    points = arguments.get("points", [])
    if name == "upsert_measurement":
        minimum = {"length": 2, "area": 3, "volume": 4}.get(arguments.get("kind"), 257)
        if not minimum <= len(points) <= 256:
            raise ValueError("Length needs at least 2 points, area 3, and volume 4; at most 256 points.")
        point_ids = [point["id"] for point in points if "id" in point]
        if len({str(value).lower() for value in point_ids}) != len(point_ids):
            raise ValueError("Measurement point IDs must be unique; preserve listed IDs when editing.")
        ids += point_ids
    elif name == "upsert_stroke_marker" and not 1 <= len(points) <= 256:
        raise ValueError("Use 1 through 256 stroke points.")
    for value in ids:
        try:
            parsed = UUID(value)
        except (ValueError, AttributeError, TypeError) as error:
            raise ValueError("Use listed UUIDs when editing; omit id to create an annotation.") from error
        if str(parsed) != value.lower():
            raise ValueError("Use canonical UUIDs with hyphens.")
    if name == "upsert_sphere_marker" and arguments.get("shows_direction") and "direction_origin" not in arguments:
        raise ValueError("A directional marker requires direction_origin.")
