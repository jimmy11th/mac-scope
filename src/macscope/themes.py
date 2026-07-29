from __future__ import annotations

import json
import os
import re
import tempfile
from dataclasses import dataclass
from pathlib import Path

from textual.theme import Theme

COLOR_TOKENS = (
    "background",
    "surface",
    "surface_alt",
    "border",
    "text",
    "muted",
    "accent",
    "focus",
    "selection_background",
    "selection_text",
    "cpu",
    "memory",
    "disk",
    "network",
    "normal",
    "warning",
    "danger",
)
COLOR_PATTERN = re.compile(r"^#[0-9a-fA-F]{6}$")
ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")


@dataclass(frozen=True, slots=True)
class ThemeDefinition:
    id: str
    name: str
    mode: str
    colors: dict[str, str]
    author: str = "MacScope"
    extends: str = ""
    builtin: bool = False


def _theme(theme_id: str, name: str, mode: str, colors: dict[str, str]) -> ThemeDefinition:
    return ThemeDefinition(theme_id, name, mode, colors, builtin=True)


BUILTIN_THEMES: dict[str, ThemeDefinition] = {
    "graphite-dark": _theme(
        "graphite-dark",
        "Graphite Dark",
        "dark",
        {
            "background": "#0D1015",
            "surface": "#151A21",
            "surface_alt": "#12171E",
            "border": "#2B3440",
            "text": "#D7DDE5",
            "muted": "#8994A3",
            "accent": "#62A8FF",
            "focus": "#607086",
            "selection_background": "#273241",
            "selection_text": "#FFFFFF",
            "cpu": "#62A8FF",
            "memory": "#58D6A9",
            "disk": "#E5B95C",
            "network": "#EF7BA9",
            "normal": "#58D6A9",
            "warning": "#E5B95C",
            "danger": "#FF6B6B",
        },
    ),
    "paper-light": _theme(
        "paper-light",
        "Paper Light",
        "light",
        {
            "background": "#F5F7F9",
            "surface": "#FFFFFF",
            "surface_alt": "#EDF1F4",
            "border": "#C6CDD5",
            "text": "#20262D",
            "muted": "#66717D",
            "accent": "#0068B8",
            "focus": "#397EAE",
            "selection_background": "#CDE5F7",
            "selection_text": "#15202A",
            "cpu": "#0068B8",
            "memory": "#187A55",
            "disk": "#966000",
            "network": "#A73568",
            "normal": "#187A55",
            "warning": "#966000",
            "danger": "#C43838",
        },
    ),
    "solarized-dark": _theme(
        "solarized-dark",
        "Solarized Dark",
        "dark",
        {
            "background": "#002B36",
            "surface": "#073642",
            "surface_alt": "#0A3D49",
            "border": "#3B5961",
            "text": "#EEE8D5",
            "muted": "#93A1A1",
            "accent": "#268BD2",
            "focus": "#2AA198",
            "selection_background": "#174B57",
            "selection_text": "#FDF6E3",
            "cpu": "#268BD2",
            "memory": "#859900",
            "disk": "#B58900",
            "network": "#D33682",
            "normal": "#859900",
            "warning": "#CB8B16",
            "danger": "#DC322F",
        },
    ),
    "nord": _theme(
        "nord",
        "Nord",
        "dark",
        {
            "background": "#2E3440",
            "surface": "#3B4252",
            "surface_alt": "#353B49",
            "border": "#4C566A",
            "text": "#ECEFF4",
            "muted": "#AAB3C4",
            "accent": "#88C0D0",
            "focus": "#81A1C1",
            "selection_background": "#434C5E",
            "selection_text": "#FFFFFF",
            "cpu": "#81A1C1",
            "memory": "#A3BE8C",
            "disk": "#EBCB8B",
            "network": "#B48EAD",
            "normal": "#A3BE8C",
            "warning": "#EBCB8B",
            "danger": "#BF616A",
        },
    ),
    "monokai": _theme(
        "monokai",
        "Monokai",
        "dark",
        {
            "background": "#272822",
            "surface": "#32332D",
            "surface_alt": "#2D2E29",
            "border": "#56574F",
            "text": "#F8F8F2",
            "muted": "#A6A69F",
            "accent": "#66D9EF",
            "focus": "#A6E22E",
            "selection_background": "#49483E",
            "selection_text": "#FFFFFF",
            "cpu": "#66D9EF",
            "memory": "#A6E22E",
            "disk": "#E6DB74",
            "network": "#F92672",
            "normal": "#A6E22E",
            "warning": "#FD971F",
            "danger": "#F92672",
        },
    ),
    "high-contrast": _theme(
        "high-contrast",
        "High Contrast",
        "dark",
        {
            "background": "#000000",
            "surface": "#0B0B0B",
            "surface_alt": "#141414",
            "border": "#FFFFFF",
            "text": "#FFFFFF",
            "muted": "#C6C6C6",
            "accent": "#00D7FF",
            "focus": "#FFFFFF",
            "selection_background": "#FFFFFF",
            "selection_text": "#000000",
            "cpu": "#00D7FF",
            "memory": "#5FFF87",
            "disk": "#FFD75F",
            "network": "#FF5FAF",
            "normal": "#5FFF87",
            "warning": "#FFD75F",
            "danger": "#FF5F5F",
        },
    ),
}


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")
    return (slug or "custom-theme")[:64]


def validate_colors(colors: dict[str, str], *, partial: bool = False) -> dict[str, str]:
    if not isinstance(colors, dict):
        raise TypeError("colors must be an object")
    unknown = set(colors) - set(COLOR_TOKENS)
    if unknown:
        raise ValueError(f"unknown color token: {min(unknown)}")
    if not partial:
        missing = set(COLOR_TOKENS) - set(colors)
        if missing:
            raise ValueError(f"missing color token: {min(missing)}")
    normalized: dict[str, str] = {}
    for key, value in colors.items():
        if not isinstance(value, str) or not COLOR_PATTERN.fullmatch(value):
            raise ValueError(f"invalid color for {key}: {value}")
        normalized[key] = value.upper()
    return normalized


def contrast_ratio(foreground: str, background: str) -> float:
    def luminance(color: str) -> float:
        channels = [int(color[index : index + 2], 16) / 255 for index in (1, 3, 5)]
        linear = [
            value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4
            for value in channels
        ]
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]

    first = luminance(foreground)
    second = luminance(background)
    light, dark = max(first, second), min(first, second)
    return (light + 0.05) / (dark + 0.05)


def textual_theme_from_colors(name: str, mode: str, colors: dict[str, str]) -> Theme:
    colors = validate_colors(colors)
    return Theme(
        name=name,
        primary=colors["accent"],
        secondary=colors["network"],
        warning=colors["warning"],
        error=colors["danger"],
        success=colors["normal"],
        accent=colors["accent"],
        foreground=colors["text"],
        background=colors["background"],
        surface=colors["surface"],
        panel=colors["surface_alt"],
        dark=mode != "light",
        variables={
            "cpu": colors["cpu"],
            "memory": colors["memory"],
            "disk": colors["disk"],
            "network": colors["network"],
            "border": colors["border"],
            "muted": colors["muted"],
            "focus": colors["focus"],
            "selection": colors["selection_background"],
            "selection-text": colors["selection_text"],
            "surface-alt": colors["surface_alt"],
            "block-cursor-background": colors["selection_background"],
            "block-cursor-foreground": colors["selection_text"],
            "block-cursor-text-style": "none",
            "block-cursor-blurred-background": colors["selection_background"],
            "block-cursor-blurred-foreground": colors["selection_text"],
            "block-cursor-blurred-text-style": "none",
            "block-hover-background": colors["surface_alt"],
        },
    )


class ThemeRepository:
    def __init__(self, directory: Path) -> None:
        self.directory = directory
        self.custom: dict[str, ThemeDefinition] = {}
        self.warnings: list[str] = []
        self.reload()

    def reload(self) -> None:
        self.custom = {}
        self.warnings = []
        if not self.directory.exists():
            return
        for path in sorted(self.directory.glob("*.macscope-theme.json")):
            try:
                definition = self._read_definition(path)
                self.custom[definition.id] = definition
            except (OSError, TypeError, ValueError, json.JSONDecodeError) as exc:
                self.warnings.append(f"{path.name}: {exc}")
        invalid: dict[str, str] = {}
        for theme_id in self.custom:
            try:
                self.resolved_colors(theme_id)
            except (TypeError, ValueError) as exc:
                invalid[theme_id] = str(exc)
        for theme_id, warning in invalid.items():
            del self.custom[theme_id]
            self.warnings.append(f"{theme_id}: {warning}")

    def all(self) -> tuple[ThemeDefinition, ...]:
        return tuple(BUILTIN_THEMES.values()) + tuple(
            sorted(self.custom.values(), key=lambda theme: theme.name.casefold())
        )

    def exists(self, theme_id: str) -> bool:
        return theme_id in BUILTIN_THEMES or theme_id in self.custom

    def get(self, theme_id: str) -> ThemeDefinition:
        if theme_id in BUILTIN_THEMES:
            return BUILTIN_THEMES[theme_id]
        if theme_id in self.custom:
            return self.custom[theme_id]
        return BUILTIN_THEMES["graphite-dark"]

    def resolved_colors(self, theme_id: str) -> dict[str, str]:
        return self._resolve(theme_id, set())

    def _resolve(self, theme_id: str, seen: set[str]) -> dict[str, str]:
        if theme_id in seen:
            raise ValueError("theme inheritance cycle")
        if not self.exists(theme_id):
            raise ValueError(f"unknown base theme: {theme_id}")
        definition = self.get(theme_id)
        if definition.builtin:
            return dict(definition.colors)
        seen.add(theme_id)
        base_id = definition.extends or "graphite-dark"
        colors = self._resolve(base_id, seen)
        colors.update(definition.colors)
        return validate_colors(colors)

    def textual_theme(self, theme_id: str, *, name: str | None = None) -> Theme:
        definition = self.get(theme_id)
        colors = self.resolved_colors(theme_id)
        return textual_theme_from_colors(
            name or self.textual_name(theme_id), definition.mode, colors
        )

    @staticmethod
    def textual_name(theme_id: str) -> str:
        return f"macscope-{theme_id}"

    def save_custom(
        self,
        name: str,
        colors: dict[str, str],
        *,
        theme_id: str = "",
        mode: str = "dark",
        author: str = "Custom",
    ) -> ThemeDefinition:
        if not name.strip():
            raise ValueError("theme name cannot be empty")
        if mode not in {"dark", "light"}:
            raise ValueError("mode must be dark or light")
        colors = validate_colors(colors)
        identifier = theme_id if theme_id in self.custom else self._available_id(slugify(name))
        definition = ThemeDefinition(identifier, name.strip(), mode, colors, author=author)
        self._write_definition(definition, self.directory / f"{identifier}.macscope-theme.json")
        self.custom[identifier] = definition
        return definition

    def import_file(self, source: Path) -> ThemeDefinition:
        definition = self._read_definition(source.expanduser())
        identifier = definition.id
        if self.exists(identifier):
            identifier = self._available_id(slugify(f"{identifier}-custom"))
        definition = ThemeDefinition(
            identifier,
            definition.name,
            definition.mode,
            definition.colors,
            definition.author,
            definition.extends,
        )
        self._resolved_definition_colors(definition)
        self._write_definition(definition, self.directory / f"{identifier}.macscope-theme.json")
        self.custom[identifier] = definition
        return definition

    def _resolved_definition_colors(self, definition: ThemeDefinition) -> dict[str, str]:
        if not definition.extends:
            return validate_colors(definition.colors)
        if definition.extends == definition.id:
            raise ValueError("theme inheritance cycle")
        if not self.exists(definition.extends):
            raise ValueError(f"unknown base theme: {definition.extends}")
        colors = self.resolved_colors(definition.extends)
        colors.update(definition.colors)
        return validate_colors(colors)

    def export_file(self, theme_id: str, destination: Path) -> Path:
        definition = self.get(theme_id)
        exported = ThemeDefinition(
            definition.id,
            definition.name,
            definition.mode,
            self.resolved_colors(theme_id),
            definition.author,
        )
        destination = destination.expanduser()
        if destination.suffix != ".json":
            destination = destination.with_suffix(".macscope-theme.json")
        self._write_definition(exported, destination)
        return destination

    def _available_id(self, base: str) -> str:
        base = slugify(base)
        if not self.exists(base):
            return base
        for number in range(2, 1000):
            suffix = f"-{number}"
            candidate = f"{base[: 64 - len(suffix)]}{suffix}"
            if not self.exists(candidate):
                return candidate
        raise ValueError("unable to allocate a unique theme id")

    def _read_definition(self, path: Path) -> ThemeDefinition:
        with path.open(encoding="utf-8") as handle:
            data = json.load(handle)
        if not isinstance(data, dict):
            raise TypeError("theme root must be an object")
        if data.get("format") != "macscope-theme" or data.get("version") != 1:
            raise ValueError("unsupported theme format or version")
        theme_id = data.get("id")
        name = data.get("name")
        mode = data.get("mode", "dark")
        extends = data.get("extends", "")
        if not isinstance(theme_id, str) or not ID_PATTERN.fullmatch(theme_id):
            raise ValueError("invalid theme id")
        if not isinstance(name, str) or not name.strip():
            raise ValueError("invalid theme name")
        if mode not in {"dark", "light"}:
            raise ValueError("mode must be dark or light")
        if not isinstance(extends, str):
            raise TypeError("extends must be a theme id")
        if extends and not ID_PATTERN.fullmatch(extends):
            raise ValueError("invalid base theme id")
        colors = validate_colors(data.get("colors", {}), partial=bool(extends))
        return ThemeDefinition(
            theme_id,
            name.strip(),
            mode,
            colors,
            str(data.get("author", "Custom")),
            extends,
        )

    def _write_definition(self, definition: ThemeDefinition, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "format": "macscope-theme",
            "version": 1,
            "id": definition.id,
            "name": definition.name,
            "author": definition.author,
            "mode": definition.mode,
            "colors": definition.colors,
        }
        if definition.extends:
            payload["extends"] = definition.extends
        descriptor, temporary_name = tempfile.mkstemp(
            prefix="theme-", suffix=".json", dir=path.parent
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, indent=2, sort_keys=True)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary_name, path)
        except Exception:
            try:
                os.unlink(temporary_name)
            except OSError:
                pass
            raise
