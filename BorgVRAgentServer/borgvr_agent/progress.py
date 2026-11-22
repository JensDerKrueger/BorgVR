"""Fixed activity messages, never model-generated findings or follow-up questions."""

from typing import Literal


ProgressActivity = Literal[
    "read_state", "search_catalog", "open_dataset", "prepare_view", "inspect_view",
    "compare_views", "apply_changes", "wait_for_render", "verify_result", "import_data", "export_data",
]
ProgressLanguage = Literal["de", "en"]


_MESSAGES: dict[ProgressActivity, tuple[str, str]] = {
    "read_state": ("Ich prüfe den aktuellen Zustand.", "I'm checking the current state."),
    "search_catalog": ("Ich suche im Datensatzkatalog.", "I'm searching the dataset catalog."),
    "open_dataset": ("Ich öffne den Datensatz.", "I'm opening the dataset."),
    "prepare_view": ("Ich stelle die Ansicht ein.", "I'm adjusting the view."),
    "inspect_view": ("Ich prüfe die aktuelle Ansicht.", "I'm inspecting the current view."),
    "compare_views": ("Ich vergleiche mehrere Ansichten.", "I'm comparing several views."),
    "apply_changes": ("Ich bearbeite den Datensatz.", "I'm editing the dataset."),
    "wait_for_render": ("Ich warte auf die aktualisierte Ansicht.", "I'm waiting for the updated view."),
    "verify_result": ("Ich überprüfe das Ergebnis.", "I'm checking the result."),
    "import_data": ("Ich begleite den Import.", "I'm monitoring the import."),
    "export_data": ("Ich begleite den Export.", "I'm monitoring the export."),
}


def progress_message(activity: ProgressActivity, language: ProgressLanguage) -> str:
    german, english = _MESSAGES[activity]
    return german if language == "de" else english
