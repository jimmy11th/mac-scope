from __future__ import annotations

from datetime import timedelta

UNITS = ("B", "KB", "MB", "GB", "TB", "PB")
SPARKS = "▁▂▃▄▅▆▇█"


def bytes_value(value: float, *, precision: int = 1) -> str:
    amount = max(0.0, float(value))
    unit = UNITS[0]
    for unit in UNITS:
        if amount < 1024.0 or unit == UNITS[-1]:
            break
        amount /= 1024.0
    if unit == "B":
        return f"{amount:.0f} {unit}"
    return f"{amount:.{precision}f} {unit}"


def rate(value: float) -> str:
    return f"{bytes_value(value)}/s"


def temperature(value: float | None, unit: str = "celsius") -> str:
    if value is None:
        return "—"
    if unit == "fahrenheit":
        return f"{value * 9 / 5 + 32:.0f}°F"
    return f"{value:.0f}°C"


def percent(value: float, *, width: int = 5) -> str:
    return f"{value:{width}.1f}%"


def duration(seconds: float) -> str:
    seconds = max(0, int(seconds))
    delta = timedelta(seconds=seconds)
    days = delta.days
    hours, remainder = divmod(delta.seconds, 3600)
    minutes, secs = divmod(remainder, 60)
    if days:
        return f"{days}d {hours:02d}h"
    if hours:
        return f"{hours:02d}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


def sparkline(values: tuple[float, ...] | list[float], *, width: int = 16) -> str:
    if not values:
        return "·" * min(width, 8)
    sampled = list(values[-width:])
    high = max(sampled)
    if high <= 0:
        return SPARKS[0] * len(sampled)
    return "".join(SPARKS[min(7, int((value / high) * 7))] for value in sampled)


def clipped(value: str, width: int) -> str:
    if len(value) <= width:
        return value
    if width <= 1:
        return value[:width]
    return value[: width - 1] + "…"
