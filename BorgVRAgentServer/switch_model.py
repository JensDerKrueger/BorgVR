"""Interactive model switching without replacing the agent image or development source."""

import argparse
import fcntl
import os
from pathlib import Path
import subprocess
import sys

import configure
import development
from model_config import PROFILES

ROOT = Path(__file__).resolve().parent


def select_profile(current, *, ask=input, output=print):
    profiles = [(name, values) for name, values in PROFILES.items() if name != "custom"]
    output("\nBorgVR: Modell wechseln")
    for index, (name, values) in enumerate(profiles, 1):
        active = " [aktuell]" if values["MODEL"] == current else ""
        output(f"  {index}. {values['MODEL']}{active}")
    output("  0. Abbrechen")
    while True:
        try:
            answer = ask("Welches Modell? Nummer: ").strip()
        except EOFError:
            return None
        if answer == "0":
            return None
        if answer.isascii() and answer.isdecimal() and len(answer) <= 3 and 1 <= int(answer) <= len(profiles):
            return profiles[int(answer) - 1][0]
        output("Bitte eine der angezeigten Nummern eingeben.")


def run_setup(root, command):
    subprocess.run(["bash", str(root / "setup.sh"), command], check=True)


def switch(root, profile, *, context_length=None, run=run_setup):
    if profile not in PROFILES or profile == "custom":
        raise ValueError("Unbekanntes Modellprofil")
    existing = configure.read_configuration(root)
    same_model = existing.get("BORGVR_MODEL") == PROFILES[profile]["MODEL"]
    if same_model and context_length is None:
        print("Dieses Modell ist bereits eingestellt; nichts geändert.")
        return
    env = root / ".env"
    runtime = root / "runtime"
    if env.is_symlink() or runtime.is_symlink() or not runtime.is_dir():
        raise ValueError("Reguläre .env und runtime-Verzeichnis erforderlich")
    if same_model:
        key = "BORGVR_CONTEXT_LENGTH"
        length = str(configure.validate_model_gpu({**existing, key: context_length}).context)
        if existing.get(key) == length:
            print("Modell und Kontextlänge sind bereits eingestellt; nichts geändert.")
            return
        changes = {key: length}
    else:
        parser = argparse.ArgumentParser()
        configure.add_model_options(parser)
        parser.add_argument("--agent-image")
        options = ["--profile", profile]
        if context_length is not None:
            options += ["--context-length", context_length]
        changes = configure.inference_values(parser.parse_args(options), existing)
    if development.marker(root).exists() or development.marker(root).is_symlink():
        development.overlay_file(root)
        print("Entwicklungsmodus bleibt aktiv: Agentencode und SSH-Zugang bleiben erhalten.")
    print("GPU-Auswahl und Parallelisierung bleiben unverändert: "
          f"{existing.get('BORGVR_GPU', '0')}, TP={existing.get('BORGVR_TENSOR_PARALLEL_SIZE', '1')}")
    print("Laufende KI-Aufträge werden unterbrochen. Der erste Modelldownload kann lange dauern.")
    original = development.read_file(env, 65536)
    owner = env.stat()
    written = None
    restarting = False
    try:
        configure.write_configuration_changes(root, changes)
        written = development.read_file(env, 65536)
        run(root, "doctor")
        restarting = True
        # Restart retains Compose's development overlay and never pulls/builds agent images.
        run(root, "restart")
        run(root, "test")
    except (Exception, KeyboardInterrupt):
        current = development.read_file(env, 65536)
        if current not in (original, written):
            print("Die Konfiguration wurde zwischenzeitlich geändert. Keine automatische Rücksetzung. "
                  "Sicherungen unter runtime/env-before-update-* prüfen.", file=sys.stderr)
            raise
        development.atomic_file(env, original, 0o600)
        if os.geteuid() == 0:
            os.chown(env, owner.st_uid, owner.st_gid)
        print("Modellwechsel fehlgeschlagen; bisherige Konfiguration wiederhergestellt.", file=sys.stderr)
        if restarting:
            try:
                run(root, "restart")
                run(root, "test")
                print("Bisheriges Modell läuft wieder.", file=sys.stderr)
            except (Exception, KeyboardInterrupt):
                print("Auch der Wiederanlauf ist fehlgeschlagen. Bitte sudo ./setup.sh logs prüfen; "
                      "die bisherige Konfiguration ist wieder eingestellt.", file=sys.stderr)
        raise
    print("Modellwechsel erfolgreich. Bitte den Assistenten in BorgVR neu verbinden.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context-length", metavar="TOKENS", help="Override the selected model's context length.")
    args = parser.parse_args()
    if sys.platform != "linux" or os.geteuid() != 0:
        parser.error("Auf dem Linux-Server mit sudo ./switch-model.sh starten")
    existing = configure.read_configuration(ROOT)
    if not existing:
        raise ValueError("Zuerst den BorgVR-Server installieren")
    profile = select_profile(existing.get("BORGVR_MODEL"))
    if profile is None:
        print("Abgebrochen; nichts geändert.")
        return
    runtime = ROOT / "runtime"
    if runtime.is_symlink() or not runtime.is_dir():
        raise ValueError("Reguläres runtime-Verzeichnis erforderlich")
    with development.deployment_lock(runtime):
        switch(ROOT, profile, context_length=args.context_length)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit("Abgebrochen") from None
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error)) from None
