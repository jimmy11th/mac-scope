from __future__ import annotations

import ctypes
import errno
from dataclasses import dataclass


class _RUsageInfoV2(ctypes.Structure):
    _fields_ = [
        ("ri_uuid", ctypes.c_uint8 * 16),
        ("ri_user_time", ctypes.c_uint64),
        ("ri_system_time", ctypes.c_uint64),
        ("ri_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_interrupt_wkups", ctypes.c_uint64),
        ("ri_pageins", ctypes.c_uint64),
        ("ri_wired_size", ctypes.c_uint64),
        ("ri_resident_size", ctypes.c_uint64),
        ("ri_phys_footprint", ctypes.c_uint64),
        ("ri_proc_start_abstime", ctypes.c_uint64),
        ("ri_proc_exit_abstime", ctypes.c_uint64),
        ("ri_child_user_time", ctypes.c_uint64),
        ("ri_child_system_time", ctypes.c_uint64),
        ("ri_child_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_child_interrupt_wkups", ctypes.c_uint64),
        ("ri_child_pageins", ctypes.c_uint64),
        ("ri_child_elapsed_abstime", ctypes.c_uint64),
        ("ri_diskio_bytesread", ctypes.c_uint64),
        ("ri_diskio_byteswritten", ctypes.c_uint64),
    ]


@dataclass(frozen=True, slots=True)
class ProcessDiskCounters:
    read_bytes: int
    write_bytes: int


@dataclass(frozen=True, slots=True)
class TemperatureReadings:
    soc_celsius: float | None
    battery_celsius: float | None
    storage_celsius: float | None
    hottest_sensor: str
    hottest_celsius: float | None


def summarize_temperatures(sensors: list[tuple[str, float]]) -> TemperatureReadings:
    valid = [(name, value) for name, value in sensors if 0 < value <= 150]
    soc = [value for name, value in valid if "tdie" in name.casefold()]
    battery = [value for name, value in valid if "battery" in name.casefold()]
    storage = [value for name, value in valid if "nand" in name.casefold()]
    if not soc:
        soc = [
            value
            for name, value in valid
            if "battery" not in name.casefold()
            and "nand" not in name.casefold()
            and "tcal" not in name.casefold()
        ]
    hottest = max(valid, key=lambda item: item[1]) if valid else ("", None)
    return TemperatureReadings(
        soc_celsius=max(soc) if soc else None,
        battery_celsius=(sum(battery) / len(battery)) if battery else None,
        storage_celsius=max(storage) if storage else None,
        hottest_sensor=hottest[0],
        hottest_celsius=hottest[1],
    )


class IOHIDTemperatureReader:
    """Read Apple Silicon temperature sensors through the local IOHID service."""

    _UTF8 = 0x08000100
    _SINT32 = 3
    _TEMPERATURE_EVENT = 15

    def __init__(self) -> None:
        self._cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        self._io = ctypes.CDLL("/System/Library/Frameworks/IOKit.framework/IOKit")
        self._configure_functions()

    def read(self) -> TemperatureReadings:
        resources: list[int] = []
        sensors: list[tuple[str, float]] = []
        try:
            keys = [self._cf_string("PrimaryUsagePage"), self._cf_string("PrimaryUsage")]
            values = [self._cf_number(0xFF00), self._cf_number(0x0005)]
            resources.extend(keys)
            resources.extend(values)
            key_array = (ctypes.c_void_p * 2)(*keys)
            value_array = (ctypes.c_void_p * 2)(*values)
            matching = self._cf.CFDictionaryCreate(None, key_array, value_array, 2, None, None)
            if not matching:
                return summarize_temperatures([])
            resources.append(matching)

            system = self._io.IOHIDEventSystemClientCreate(None)
            if not system:
                return summarize_temperatures([])
            resources.append(system)
            self._io.IOHIDEventSystemClientSetMatching(system, matching)
            services = self._io.IOHIDEventSystemClientCopyServices(system)
            if not services:
                return summarize_temperatures([])
            resources.append(services)

            product_key = self._cf_string("Product")
            resources.append(product_key)
            for index in range(self._cf.CFArrayGetCount(services)):
                service = self._cf.CFArrayGetValueAtIndex(services, index)
                if not service:
                    continue
                name_ref = self._io.IOHIDServiceClientCopyProperty(service, product_key)
                if not name_ref:
                    continue
                try:
                    name = self._from_cf_string(name_ref)
                finally:
                    self._cf.CFRelease(name_ref)
                event = self._io.IOHIDServiceClientCopyEvent(service, self._TEMPERATURE_EVENT, 0, 0)
                if not event:
                    continue
                try:
                    value = float(
                        self._io.IOHIDEventGetFloatValue(event, self._TEMPERATURE_EVENT << 16)
                    )
                finally:
                    self._cf.CFRelease(event)
                if 0 < value <= 150:
                    sensors.append((name, value))
        finally:
            for resource in reversed(resources):
                if resource:
                    self._cf.CFRelease(resource)
        return summarize_temperatures(sensors)

    def _cf_string(self, value: str) -> int:
        return int(self._cf.CFStringCreateWithCString(None, value.encode(), self._UTF8) or 0)

    def _cf_number(self, value: int) -> int:
        number = ctypes.c_int32(value)
        return int(self._cf.CFNumberCreate(None, self._SINT32, ctypes.byref(number)) or 0)

    def _from_cf_string(self, value: int) -> str:
        buffer = ctypes.create_string_buffer(256)
        if not self._cf.CFStringGetCString(value, buffer, len(buffer), self._UTF8):
            return "Unknown sensor"
        return buffer.value.decode("utf-8", errors="replace")

    def _configure_functions(self) -> None:
        pointer = ctypes.c_void_p
        self._cf.CFStringCreateWithCString.argtypes = [pointer, ctypes.c_char_p, ctypes.c_uint32]
        self._cf.CFStringCreateWithCString.restype = pointer
        self._cf.CFNumberCreate.argtypes = [pointer, ctypes.c_int32, pointer]
        self._cf.CFNumberCreate.restype = pointer
        self._cf.CFDictionaryCreate.argtypes = [
            pointer,
            ctypes.POINTER(pointer),
            ctypes.POINTER(pointer),
            ctypes.c_long,
            pointer,
            pointer,
        ]
        self._cf.CFDictionaryCreate.restype = pointer
        self._cf.CFArrayGetCount.argtypes = [pointer]
        self._cf.CFArrayGetCount.restype = ctypes.c_long
        self._cf.CFArrayGetValueAtIndex.argtypes = [pointer, ctypes.c_long]
        self._cf.CFArrayGetValueAtIndex.restype = pointer
        self._cf.CFStringGetCString.argtypes = [
            pointer,
            ctypes.c_char_p,
            ctypes.c_long,
            ctypes.c_uint32,
        ]
        self._cf.CFStringGetCString.restype = ctypes.c_bool
        self._cf.CFRelease.argtypes = [pointer]

        self._io.IOHIDEventSystemClientCreate.argtypes = [pointer]
        self._io.IOHIDEventSystemClientCreate.restype = pointer
        self._io.IOHIDEventSystemClientSetMatching.argtypes = [pointer, pointer]
        self._io.IOHIDEventSystemClientCopyServices.argtypes = [pointer]
        self._io.IOHIDEventSystemClientCopyServices.restype = pointer
        self._io.IOHIDServiceClientCopyProperty.argtypes = [pointer, pointer]
        self._io.IOHIDServiceClientCopyProperty.restype = pointer
        self._io.IOHIDServiceClientCopyEvent.argtypes = [
            pointer,
            ctypes.c_int64,
            ctypes.c_int32,
            ctypes.c_int64,
        ]
        self._io.IOHIDServiceClientCopyEvent.restype = pointer
        self._io.IOHIDEventGetFloatValue.argtypes = [pointer, ctypes.c_int64]
        self._io.IOHIDEventGetFloatValue.restype = ctypes.c_double


class LibProc:
    """Small wrapper around the stable macOS proc_pid_rusage API."""

    RUSAGE_INFO_V2 = 2

    def __init__(self) -> None:
        self._library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self._library.proc_pid_rusage.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_void_p,
        ]
        self._library.proc_pid_rusage.restype = ctypes.c_int

    def disk_counters(self, pid: int) -> ProcessDiskCounters | None:
        usage = _RUsageInfoV2()
        result = self._library.proc_pid_rusage(pid, self.RUSAGE_INFO_V2, ctypes.byref(usage))
        if result != 0:
            error = ctypes.get_errno()
            if error in {errno.ESRCH, errno.EPERM, errno.EACCES, 0}:
                return None
            raise OSError(error, f"proc_pid_rusage failed for PID {pid}")
        return ProcessDiskCounters(
            read_bytes=int(usage.ri_diskio_bytesread),
            write_bytes=int(usage.ri_diskio_byteswritten),
        )
