from __future__ import annotations

from macscope.i18n import CATALOGS, Localizer


def test_language_catalogs_have_matching_keys() -> None:
    assert set(CATALOGS["zh-CN"]) == set(CATALOGS["en"])


def test_unknown_language_and_key_have_stable_fallbacks() -> None:
    localizer = Localizer("unknown")

    assert localizer("settings.title") == "SETTINGS"
    assert localizer("missing.key") == "missing.key"
