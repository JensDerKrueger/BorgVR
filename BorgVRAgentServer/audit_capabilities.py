"""Static product inventory, not a tool allowlist or proof of runtime support."""

import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
CATALOG = Path(__file__).with_name("capabilities.json")
REPORT = Path(__file__).with_name("CAPABILITIES.md")
REGISTRIES = {
    "BorgVRCommand": "AppSupport/Application/BorgVRSession.swift",
    "BorgVRRecordedAction": "AppSupport/Automation/VolumeEditingCommands.swift",
    "MacCommand": "macOSApp/MacKeyboardShortcuts.swift",
    "MacRenderShortcut": "macOSApp/MacKeyboardShortcuts.swift",
    "DockablePanelID": "macOSApp/DockingController.swift",
    "VolumeImportKind": "AppSupport/UI/ConverterChoiceView.swift",
}
SETTINGS = {
    "screen": "AppSupport/Application/AppSettings.swift",
    "vision": "VisionApp/AppModels/StoredAppModel.swift",
}


def enum_cases(text, name):
    # These registries are top-level Swift enums; nested switch cases are indented deeper.
    match = re.search(rf"(?ms)^enum {re.escape(name)}\b[^{{]*\{{(.*?)^\}}", text)
    if match is None:
        raise ValueError(f"Missing top-level enum {name}; update the inventory reader")
    cases = re.findall(r"^  case ([A-Za-z][A-Za-z0-9_]*)", match[1], re.M)
    for tail in re.findall(r"^  case [A-Za-z][A-Za-z0-9_]*(.*)$", match[1], re.M):
        if tail.lstrip().startswith(",") or re.search(r"\),\s*[A-Za-z]", tail):
            raise ValueError(f"Grouped case declarations in {name}; update the inventory reader")
    if not cases or len(cases) != len(set(cases)):
        raise ValueError(f"Unsupported or duplicate cases in {name}")
    return set(cases)


def swift_set(text, name):
    match = re.search(rf"(?ms)static let {name}: (?:Set<String>|\[String\]) = \[(.*?)^  \]", text)
    if match is None:
        raise ValueError(f"Missing Swift string registry {name}")
    return set(re.findall(r'"([A-Za-z][A-Za-z0-9_]*)"', match[1]))


def registered_settings(text):
    match = re.search(r"(?ms)static let values: \[String: Any\] = \[(.*?)^  \]", text)
    if match is None:
        raise ValueError("Missing settings defaults registry")
    return set(re.findall(r'^\s*"([A-Za-z][A-Za-z0-9_]*)":', match[1], re.M))


def read_inventory(root=ROOT):
    read = lambda name: (root / name).read_text()
    symbols = {f"{name}.{case}" for name, file in REGISTRIES.items() for case in enum_cases(read(file), name)}
    router = read("BORGVR-Services/BorgVRMCPServer.swift")
    mcp = set(re.findall(r'\btool\(\s*"([a-z_]+)"', router))
    dispatch = router.split("  func callTool(", 1)[1].split("  var toolDefinitions:", 1)[0]
    handlers = set(re.findall(r'case "([a-z_]+)":', dispatch))
    if mcp != handlers:
        raise ValueError(f"MCP definitions/dispatch differ: {sorted(mcp ^ handlers)}")
    voice_policy = read("AppSupport/Voice/VoiceAgentProtocol.swift")
    agent = swift_set(voice_policy, "allowed") | swift_set(voice_policy, "typedOnlyTools")
    local_client = agent - mcp
    diagnostic = {item["name"] for item in json.loads(read("BorgVRAgentServer/diagnostic_catalog.json"))}
    if agent != diagnostic:
        raise ValueError("Native client catalog and test fixture differ")
    gsc = set(re.findall(r"^([A-Za-z][A-Za-z0-9_]*)\(", read("Scripts/borgvr.gsccommands"), re.M))
    archive = read("BORGVR-IO/BorgVRSettingsArchive.swift")
    recorded = swift_set(archive, "recordingKeys")
    local = swift_set(archive, "localOnlyRecordingKeys")
    settings = {platform: registered_settings(read(file)) for platform, file in SETTINGS.items()}
    if recorded & local or not set.union(*settings.values()) <= recorded | local:
        raise ValueError("A registered setting has no unambiguous GSC recording policy")
    return {"symbols": symbols, "mcp": mcp, "agent": agent, "local_client": local_client,
            "internal_agent": set(), "gsc": gsc,
            "settings": settings, "recorded_settings": recorded, "local_settings": local}


def validate(catalog, inventory, root=ROOT):
    errors = []
    operations = catalog["operations"]
    identifiers = [operation["id"] for operation in operations]
    if len(identifiers) != len(set(identifiers)):
        errors.append("Duplicate operation IDs")
    if {tool["name"] for tool in catalog["internal_agent_tools"]} != inventory["internal_agent"]:
        errors.append("Unclassified or stale internal agent tool")
    if {tool for operation in operations for tool in operation.get("local_agent", [])} != inventory["local_client"]:
        errors.append("Unclassified or stale local client agent tool")
    for field in ("symbols", "mcp", "gsc"):
        covered = {value for operation in operations for value in operation[field]}
        missing, stale = inventory[field] - covered, covered - inventory[field]
        if missing:
            errors.append(f"Unclassified {field}: {', '.join(sorted(missing))}")
        if stale:
            errors.append(f"Unknown {field}: {', '.join(sorted(stale))}")
    categories = {category["id"] for category in catalog["categories"]}
    for operation in operations:
        if operation["category"] not in categories:
            errors.append(f"Unknown category for {operation['id']}")
        if operation["context"] not in {"application", "dataset", "job", "assistant"}:
            errors.append(f"Unknown context for {operation['id']}")
        if operation["core"] not in {"command", "service", "partial", "ui", "local", "internal"}:
            errors.append(f"Unknown command status for {operation['id']}")
        if not operation["platforms"] or not set(operation["platforms"]) <= {"macOS", "iOS", "visionOS"}:
            errors.append(f"Invalid platforms for {operation['id']}")
        for field in ("label", "query", "gap", "next", "risk"):
            if not operation.get(field):
                errors.append(f"Missing {field} for {operation['id']}")
        if not operation.get("evidence"):
            errors.append(f"Missing evidence for {operation['id']}")
        for path in operation.get("evidence", []) + operation.get("tests", []):
            if not (root / path).is_file():
                errors.append(f"Missing evidence/test file: {path}")
    return errors


def render(catalog, inventory):
    order = {category["id"]: index for index, category in enumerate(catalog["categories"])}
    labels = {category["id"]: category["label"] for category in catalog["categories"]}
    ops = sorted(catalog["operations"], key=lambda operation: (order[operation["category"]], operation["id"] != "app.assistant"))
    lines = ["# Funktionskatalog des BorgVR Assistenten", "",
        "Generiert aus `capabilities.json` und den Quellcode-Registern mit `python3 audit_capabilities.py --write`.",
        "Dies ist ein statischer Abdeckungsnachweis, keine Laufzeitfreigabe und kein Nachweis ausgeführter Tests.",
        "Plattformangaben beschreiben die Benutzerfunktion; konkrete MCP- und Agentenaufrufe haben zusätzliche Grenzen.",
        "Das Agentengespräch ist appweit auch im Startmenü nutzbar. **Ohne offenen Datensatz sind `get_application_state`, `search_datasets`, `open_dataset` und die kontextgebundene Befehlshistorie verfügbar.** Öffnen verlangt einen kürzlich zurückgelieferten Treffer und einen ausgehandelten, korrelierten Kontextwechsel. Renderer-Werkzeuge erfordern einen bereiten Datensatz; Import-/Fusionsjobs sind noch nicht freigeschaltet.", "",
        f"Erfasst: **{len(ops)} Funktionsgruppen**, **{len(inventory['mcp'])} MCP-Werkzeuge**, "
        f"**{len(inventory['agent'])} maximal erlaubte native Agentenwerkzeuge**, "
        f"**{len(inventory['symbols'])} Command-/UI-Registereinträge**, **{len(inventory['gsc'])} unterschiedliche GSC-Namen**.", "",
        "Der Agent filtert weiter nach Plattform, RGB/RGBA und Bildfreigabe. Beispiel: Hintergrund/Projektion entfallen auf visionOS.",
        "GSC meint benannte macOS-DSL-Befehle. `sessioncommand` kann weitere native Commands verlustfrei auf allen nativen Plattformen wiedergeben;",
        "daraus folgt weder eine Agentenfreigabe noch eine benannte DSL-Funktion. Tool-Definitionen sind nicht automatisch UI-/Zustands-/Test-Vollständigkeit.", "",
        "Der Agent verwendet den je Verbindung von BorgVR gelieferten Werkzeugkatalog.", "",
        "## Übersicht", "", "| Bereich | Funktion | Kontext | Command-Pfad | MCP | Agent |", "|---|---|---|---|---|---|"]
    status = {"command": "vorhanden", "service": "Service/Abfrage", "partial": "teilweise", "ui": "nur UI", "local": "lokale Funktion", "internal": "intern"}
    for op in ops:
        defined = set(op["mcp"]) | set(op.get("local_agent", []))
        allowed = defined & inventory["agent"]
        agent = "nein" if not allowed else ("ja*" if allowed == defined else "teilweise*")
        lines.append(f"| {labels[op['category']]} | [{op['label']}](#{op['id'].replace('.', '-')}) | {op['context']} | {status[op['core']]} | {'ja' if op['mcp'] else 'nein'} | {agent} |")
    lines += ["", "* Kontextabhängig: App-Zustand, begrenzte Metadatensuche und autorisiertes Öffnen sind ohne Renderer nutzbar; ein erlaubter Teilaufruf bedeutet nicht, dass der gesamte Workflow abgedeckt ist.", "",
              "## Details", ""]
    for op in ops:
        lines += [f"<a id=\"{op['id'].replace('.', '-')}\"></a>", f"### {op['label']}", "",
            f"- Kennung: `{op['id']}`; Plattformen: {', '.join(op['platforms'])}; Kontext: `{op['context']}`; Wirkung: {op['risk']}.",
            "- Register: " + (", ".join(f"`{value}`" for value in op["symbols"]) or "kein spezifischer Command/UI-Registereintrag"),
            "- MCP: " + (", ".join(f"`{value}`" for value in op["mcp"]) or "fehlt"),
            "- Native Agentenwerkzeuge: " + (", ".join(f"`{value}`" for value in sorted(
                (set(op["mcp"]) | set(op.get("local_agent", []))) & inventory["agent"])) or "fehlen"),
            "- Benannte GSC-Befehle (macOS): " + (", ".join(f"`{value}`" for value in op["gsc"]) or "keine; Command-Payloads ggf. separat verfügbar"),
            f"- Zustandsabfrage: {op['query']}", f"- Lücke: {op['gap']}", f"- Nächster Schritt: {op['next']}",
            "- Quellen: " + ", ".join(f"[{path}](../{path})" for path in op["evidence"]),
            "- Vorhandene Testquellen: " + (", ".join(f"[{path}](../{path})" for path in op.get("tests", [])) or "kein spezifischer Test zugeordnet"), ""]
    lines += ["## Registrierte Einstellungen", "",
        "Alle folgenden Schlüssel stammen aus den beiden Defaults-Registern. `setSettings`/Archivimport ist keine einzelne typisierte Einstellungsschnittstelle.",
        "MCP bietet derzeit Archiv speichern/laden/zurücksetzen, aber keinen allgemeinen Einstellungs-Getter/-Setter. Der Agent bietet keines davon an.",
        "Weitere lokale Einstellungen (etwa Serverlisten, Panel-Layout, Assistent und Erklärungsdialoge) sind in den Funktionsgruppen gesondert erfasst.", "",
        "| Schlüssel | Defaults-Register | GSC-Aufzeichnung |", "|---|---|---|"]
    for key in sorted(set.union(*inventory["settings"].values())):
        platforms = ", ".join(name for name, keys in inventory["settings"].items() if key in keys)
        policy = "aufgezeichnet, ohne Geheimnisse" if key in inventory["recorded_settings"] else "bewusst lokal/ausgeschlossen"
        lines.append(f"| `{key}` | {platforms} | {policy} |")
    lines += ["", "## Grenzen des Abgleichs", "",
        "Neue Registereinträge müssen einer Funktionsgruppe zugeordnet werden. Neue freie UI-Aktionen ohne Register werden dadurch nicht automatisch erkannt.",
        "Die Quellenliste muss deshalb bei UI-Änderungen mitgepflegt werden. Ein UI-Button oder ein generischer `writeFiles`-Command ersetzt keinen fachlichen Import-/Exportauftrag.",
        "Betriebssystemdialoge und Hardwareberechtigungen bleiben lokale Vermittlung; die fachliche Aktion soll trotzdem über denselben Command-Service erreichbar werden.",
        "Startarchitektur, fehlende Aufträge und Abnahmekriterien: [Umsetzungsplan](CAPABILITY_PLAN.md).", ""]
    return "\n".join(lines)


def main():
    if sys.version_info < (3, 10):
        raise SystemExit("Use Python 3.10 or later (the agent development environment uses Python 3.12).")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="Regenerate the checked-in report")
    args = parser.parse_args()
    catalog = json.loads(CATALOG.read_text())
    inventory = read_inventory()
    errors = validate(catalog, inventory)
    if errors:
        raise SystemExit("\n".join(errors))
    report = render(catalog, inventory)
    if args.write:
        REPORT.write_text(report)
    elif not REPORT.exists() or REPORT.read_text() != report:
        raise SystemExit("Stale CAPABILITIES.md; run python3 audit_capabilities.py --write")
    print(f"Capability audit passed: {len(catalog['operations'])} groups, {len(inventory['mcp'])} MCP tools, "
          f"{len(inventory['agent'])} native agent tools, complete declared-register coverage")


if __name__ == "__main__":
    main()
