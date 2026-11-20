from copy import deepcopy
import json

import pytest

import audit_capabilities as audit


def current():
    return json.loads(audit.CATALOG.read_text()), audit.read_inventory()


def test_all_declared_commands_tools_gsc_ui_registries_and_settings_are_classified():
    catalog, inventory = current()
    assert audit.validate(catalog, inventory) == []
    assert inventory["agent"] < inventory["mcp"]
    assert {"list_datasets", "edit_volume", "clear_objects", "clear_measurements", "upsert_mesh_instance"} <= inventory["mcp"] - inventory["agent"]
    assert {"search_datasets", "open_dataset", "upsert_measurement", "upsert_sphere_marker", "upsert_stroke_marker",
            "remove_object", "remove_measurement", "clear_annotations"} <= inventory["agent"]
    assert inventory["settings"]["screen"] and inventory["settings"]["vision"]


def test_checked_in_report_is_current_and_links_to_the_implementation_plan():
    catalog, inventory = current()
    report = audit.REPORT.read_text()
    assert report == audit.render(catalog, inventory)
    assert (audit.ROOT / "BorgVRAgentServer/CAPABILITY_PLAN.md").is_file()
    assert "CAPABILITY_PLAN.md" in report
    assert "`get_application_state`, `search_datasets` und `open_dataset`" in report


@pytest.mark.parametrize("field,value", [("symbols", "BorgVRCommand.newOperation"),
    ("symbols", "MacRenderShortcut.newAction"), ("mcp", "new_mcp_tool"), ("gsc", "newgsccommand")])
def test_new_registry_entries_cannot_silently_disappear_from_the_inventory(field, value):
    catalog, inventory = current()
    inventory[field].add(value)
    errors = audit.validate(catalog, inventory)
    assert any(f"Unclassified {field}:" in error and value in error for error in errors)


def test_new_internal_model_tools_require_separate_classification():
    catalog, inventory = current()
    inventory["internal_agent"].add("a_new_learning_tool")
    assert "Unclassified or stale internal agent tool" in audit.validate(catalog, inventory)


def test_removed_commands_and_renamed_tools_are_reported_as_stale():
    catalog, inventory = current()
    inventory["mcp"].remove("edit_volume")
    assert any("Unknown mcp: edit_volume" in error for error in audit.validate(catalog, inventory))


def test_invalid_source_and_duplicate_operation_cannot_claim_coverage():
    catalog, inventory = current()
    catalog["operations"].append(deepcopy(catalog["operations"][0]))
    catalog["operations"][0]["evidence"] = ["a-nonexistent-source.swift"]
    errors = audit.validate(catalog, inventory)
    assert "Duplicate operation IDs" in errors
    assert any("Missing evidence/test file" in error for error in errors)


def test_enum_reader_ignores_nested_switch_cases_and_preserves_multiline_payloads():
    text = '''enum Example: Codable {
  case one
  case two(
    value: String,
    count: Int
  )
  var value: Int {
    switch self {
      case .one: 1
      case .two: 2
    }
  }
}
'''
    assert audit.enum_cases(text, "Example") == {"one", "two"}


@pytest.mark.parametrize("declaration", ["case one, two", "case one(Int), two(Int)"])
def test_unsupported_grouped_enum_cases_fail_instead_of_undercounting(declaration):
    with pytest.raises(ValueError, match="Grouped case"):
        audit.enum_cases(f"enum Example {{\n  {declaration}\n}}", "Example")


def test_app_start_import_and_fusion_gaps_are_not_mistaken_for_existing_commands():
    catalog, _ = current()
    operations = {operation["id"]: operation for operation in catalog["operations"]}
    for name in ("conversion.file", "conversion.dicom", "conversion.images", "conversion.fusion", "conversion.jobs"):
        assert not operations[name]["mcp"]
        assert operations[name]["core"] in {"partial", "service"}
    assert operations["datasets.catalog"]["mcp"] == ["list_datasets"]
    assert operations["app.assistant"]["context"] == "application"
    assert operations["windows.immersive"]["platforms"] == ["visionOS"]
    assert operations["windows.main"]["platforms"] == ["macOS"]
    assert operations["diagnostics.rotation"]["platforms"] == ["visionOS"]


def test_experimental_catalog_does_not_grant_runtime_tools_or_bypass_the_bridge():
    sources = list((audit.ROOT / "BorgVRAgentServer/borgvr_agent").glob("*.py"))
    sources += list((audit.ROOT / "AppSupport/Voice").glob("*.swift"))
    for file in sources:
        text = file.read_text()
        assert "capabilities.json" not in text and "audit_capabilities" not in text
    for file in ("VoiceAgentController.swift", "VoiceAgentApplicationBridge.swift"):
        text = (audit.ROOT / "AppSupport/Voice" / file).read_text()
        for concrete_type in ("ConverterView", "BorgVRVolumeConversionService", "AppModel", "BorgVRMCPToolRouter"):
            assert concrete_type not in text
    for file in ("AppSupport/Application/BorgVRSession.swift", "BORGVR-IO/Importers/BorgVRVolumeConversionService.swift"):
        assert "VoiceAgent" not in (audit.ROOT / file).read_text()
