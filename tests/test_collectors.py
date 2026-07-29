from __future__ import annotations

import math

from macscope.collectors.network import NetTopSampler, parse_nettop_row
from macscope.collectors.processes import ProcessCollector, exponential_average
from macscope.collectors.system import (
    parse_compressed_memory,
    parse_memory_pressure,
    pressure_label,
    temperature_label,
)
from macscope.formatting import bytes_value, duration, sparkline
from macscope.native import summarize_temperatures


def test_parse_nettop_process_summary() -> None:
    assert parse_nettop_row(["Google Chrome Helper.987", "1200", "345", ""]) == (
        987,
        "Google Chrome Helper",
        1200,
        345,
    )
    assert parse_nettop_row(["app.with.dots.42", "", "8"]) == (
        42,
        "app.with.dots",
        0,
        8,
    )
    assert parse_nettop_row(["", "bytes_in", "bytes_out"]) is None
    assert parse_nettop_row(["not-a-process", "1", "2"]) is None


def test_parse_macos_memory_metrics() -> None:
    pressure = "System-wide memory free percentage: 37%"
    vm_stat = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages occupied by compressor:                 127089.
"""
    assert parse_memory_pressure(pressure) == 37
    assert parse_compressed_memory(vm_stat) == 127089 * 16384
    assert pressure_label(37) == "Normal"
    assert pressure_label(15) == "Warning"
    assert pressure_label(5) == "Critical"


def test_temperature_sensor_summary_and_status() -> None:
    readings = summarize_temperatures(
        [
            ("PMU tdie1", 72.5),
            ("PMU tdie2", 68.0),
            ("gas gauge battery", 34.0),
            ("NAND CH0 temp", 42.0),
            ("invalid", -9200.0),
        ]
    )
    assert readings.soc_celsius == 72.5
    assert readings.battery_celsius == 34.0
    assert readings.storage_celsius == 42.0
    assert temperature_label(72.5) == "Normal"
    assert temperature_label(85.0) == "Warm"
    assert temperature_label(98.0) == "Hot"


def test_three_second_exponential_smoothing() -> None:
    result = exponential_average(0.0, 100.0, 3.0)
    assert math.isclose(result, 63.212, rel_tol=0.001)
    assert exponential_average(None, 17.0, 1.0) == 17.0


def test_unchanged_smoothing_keeps_scores() -> None:
    collector = ProcessCollector.__new__(ProcessCollector)
    collector.smoothing_seconds = 3.0
    collector._scores = {(1, 1.0): (1.0, 2.0, 3.0)}

    collector.set_smoothing(3.0)
    assert collector._scores

    collector.set_smoothing(5.0)
    assert collector._scores == {}


def test_network_interval_restarts_exactly_once(monkeypatch) -> None:
    sampler = NetTopSampler(interval=1.0)
    sampler._process = object()
    calls: list[str] = []

    def stop() -> None:
        calls.append("stop")
        sampler._process = None

    def start() -> None:
        calls.append("start")
        sampler._process = object()

    monkeypatch.setattr(sampler, "stop", stop)
    monkeypatch.setattr(sampler, "start", start)

    sampler.set_interval(2.0)
    assert calls == ["stop", "start"]
    assert sampler._process is not None

    sampler.set_interval(2.0)
    assert calls == ["stop", "start"]


def test_human_formatting_is_compact_and_stable() -> None:
    assert bytes_value(1536) == "1.5 KB"
    assert duration(65) == "01:05"
    assert duration(90_061) == "1d 01h"
    assert len(sparkline([0, 5, 10], width=3)) == 3
