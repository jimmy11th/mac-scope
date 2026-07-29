from __future__ import annotations

import json

import pytest

from macscope.themes import BUILTIN_THEMES, ThemeRepository, contrast_ratio


def write_theme(path, payload) -> None:
    path.write_text(json.dumps(payload), encoding="utf-8")


def test_builtin_themes_are_complete_and_readable(tmp_path) -> None:
    repository = ThemeRepository(tmp_path / "themes")

    for theme_id in BUILTIN_THEMES:
        colors = repository.resolved_colors(theme_id)
        assert contrast_ratio(colors["text"], colors["background"]) >= 4.5
        assert repository.textual_theme(theme_id).name == f"macscope-{theme_id}"


def test_import_resolves_inheritance_before_writing(tmp_path) -> None:
    repository = ThemeRepository(tmp_path / "themes")
    source = tmp_path / "ocean.macscope-theme.json"
    write_theme(
        source,
        {
            "format": "macscope-theme",
            "version": 1,
            "id": "ocean",
            "name": "Ocean",
            "mode": "dark",
            "extends": "graphite-dark",
            "colors": {"accent": "#123456", "cpu": "#123456"},
        },
    )

    imported = repository.import_file(source)

    assert imported.id == "ocean"
    assert repository.resolved_colors("ocean")["accent"] == "#123456"
    assert (repository.directory / "ocean.macscope-theme.json").exists()


def test_import_rejects_missing_base_without_saving(tmp_path) -> None:
    repository = ThemeRepository(tmp_path / "themes")
    source = tmp_path / "broken.macscope-theme.json"
    write_theme(
        source,
        {
            "format": "macscope-theme",
            "version": 1,
            "id": "broken",
            "name": "Broken",
            "mode": "dark",
            "extends": "missing-theme",
            "colors": {"accent": "#123456"},
        },
    )

    with pytest.raises(ValueError, match="unknown base theme"):
        repository.import_file(source)

    assert not repository.directory.exists()


def test_export_contains_portable_resolved_colors(tmp_path) -> None:
    repository = ThemeRepository(tmp_path / "themes")
    destination = repository.export_file("paper-light", tmp_path / "paper")
    payload = json.loads(destination.read_text(encoding="utf-8"))

    assert destination.name == "paper.macscope-theme.json"
    assert payload["format"] == "macscope-theme"
    assert payload["version"] == 1
    assert "extends" not in payload
    assert payload["colors"] == repository.resolved_colors("paper-light")
