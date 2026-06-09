"""Windows backend for EchoScribe using Win32 APIs through ctypes."""

from __future__ import annotations

import ctypes
import logging
import os
import shutil
import struct
import subprocess
import tempfile
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from .config import Config


LOG = logging.getLogger(__name__)


VK_CODES: dict[str, int] = {
    "ctrl": 0x11,
    "control": 0x11,
    "leftctrl": 0x11,
    "rightctrl": 0x11,
    "alt": 0x12,
    "option": 0x12,
    "leftalt": 0x12,
    "rightalt": 0x12,
    "shift": 0x10,
    "leftshift": 0x10,
    "rightshift": 0x10,
    "win": 0x5B,
    "cmd": 0x5B,
    "meta": 0x5B,
    "space": 0x20,
    "enter": 0x0D,
    "return": 0x0D,
    "tab": 0x09,
    "esc": 0x1B,
    "escape": 0x1B,
    "backspace": 0x08,
    "delete": 0x2E,
    "insert": 0x2D,
    "home": 0x24,
    "end": 0x23,
    "pageup": 0x21,
    "pagedown": 0x22,
    "up": 0x26,
    "down": 0x28,
    "left": 0x25,
    "right": 0x27,
}


@dataclass(frozen=True)
class WindowsHotkey:
    label: str
    codes: frozenset[int]


@dataclass(frozen=True)
class Binding:
    name: str
    hotkeys: list[WindowsHotkey]
    on_start: Callable[[], None]
    on_stop: Callable[[], None]


def parse_combo_list(value: str | list[str]) -> list[WindowsHotkey]:
    values = [value] if isinstance(value, str) else value
    return [parse_combo(item) for item in values]


def parse_combo(combo: str) -> WindowsHotkey:
    parts = [part.strip().lower() for part in combo.split("+") if part.strip()]
    if not parts:
        raise ValueError("Empty hotkey")
    return WindowsHotkey(label=combo, codes=frozenset(vk_code(part) for part in parts))


def vk_code(name: str) -> int:
    if len(name) == 1 and "a" <= name <= "z":
        return ord(name.upper())
    if len(name) == 1 and "0" <= name <= "9":
        return ord(name)
    if name.startswith("f") and name[1:].isdigit():
        number = int(name[1:])
        if 1 <= number <= 24:
            return 0x6F + number
    try:
        return VK_CODES[name]
    except KeyError as exc:
        raise ValueError(f"Unsupported Windows hotkey key: {name}") from exc


class WindowsHotkeyListener:
    def __init__(self, bindings: list[Binding], poll_interval: float = 0.025) -> None:
        self.bindings = bindings
        self.poll_interval = poll_interval
        self.active: Binding | None = None
        self.active_codes: frozenset[int] | None = None
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        user32()
        self._thread = threading.Thread(target=self._run, name="echoscribe-win-hotkeys", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)

    def _run(self) -> None:
        LOG.info("Watching Windows hotkeys")
        while not self._stop.is_set():
            pressed = current_pressed_codes({code for binding in self.bindings for hotkey in binding.hotkeys for code in hotkey.codes})
            if self.active is None:
                for binding in self.bindings:
                    for hotkey in binding.hotkeys:
                        if hotkey.codes.issubset(pressed):
                            self.active = binding
                            self.active_codes = hotkey.codes
                            LOG.info("Hotkey active: %s (%s)", binding.name, hotkey.label)
                            binding.on_start()
                            break
                    if self.active is not None:
                        break
            elif self.active_codes is not None and not self.active_codes.issubset(pressed):
                binding = self.active
                self.active = None
                self.active_codes = None
                LOG.info("Hotkey released: %s", binding.name)
                binding.on_stop()
            time.sleep(self.poll_interval)


def current_pressed_codes(codes: set[int]) -> set[int]:
    u32 = user32()
    return {code for code in codes if u32.GetAsyncKeyState(code) & 0x8000}


class WindowsAudioRecorder:
    def __init__(self, command_template: str = "", minimum_bytes: int = 2048) -> None:
        self.command_template = command_template.strip()
        self.minimum_bytes = minimum_bytes
        self.process: subprocess.Popen[bytes] | None = None
        self.path: Path | None = None
        self._wave: WinMMRecorder | None = None

    def start(self) -> Path:
        if self.path is not None:
            raise RuntimeError("Recorder is already running")
        fd, raw_path = tempfile.mkstemp(prefix="echoscribe_", suffix=".wav")
        close_fd(fd)
        Path(raw_path).unlink(missing_ok=True)
        self.path = Path(raw_path)
        if self.command_template:
            command = self.command_template.format(path=str(self.path))
            self.process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, shell=True)
            return self.path
        self._wave = WinMMRecorder(self.path)
        self._wave.start()
        return self.path

    def stop(self) -> Path:
        if self.path is None:
            raise RuntimeError("Recorder is not running")
        path = self.path
        self.path = None
        if self.process is not None:
            process = self.process
            self.process = None
            process.terminate()
            try:
                process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                process.kill()
        elif self._wave is not None:
            recorder = self._wave
            self._wave = None
            recorder.stop()
        if not path.exists() or path.stat().st_size < self.minimum_bytes:
            raise RuntimeError("Recording failed or was too short")
        return path

    def abort(self) -> None:
        if self.process is not None:
            self.process.terminate()
            self.process = None
        if self._wave is not None:
            self._wave.abort()
            self._wave = None
        self.path = None


class WinMMRecorder:
    sample_rate = 16000
    channels = 1
    bits_per_sample = 16
    buffer_count = 8
    buffer_ms = 100

    def __init__(self, path: Path) -> None:
        self.path = path
        self.handle = ctypes.c_void_p()
        self.buffers: list[ctypes.Array[ctypes.c_char]] = []
        self.headers: list[WAVEHDR] = []
        self.frames = bytearray()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        mm = winmm()
        fmt = WAVEFORMATEX(
            wFormatTag=1,
            nChannels=self.channels,
            nSamplesPerSec=self.sample_rate,
            nAvgBytesPerSec=self.sample_rate * self.channels * self.bits_per_sample // 8,
            nBlockAlign=self.channels * self.bits_per_sample // 8,
            wBitsPerSample=self.bits_per_sample,
            cbSize=0,
        )
        check_mm(mm.waveInOpen(ctypes.byref(self.handle), 0xFFFFFFFF, ctypes.byref(fmt), 0, 0, 0), "waveInOpen")
        size = self.sample_rate * self.channels * self.bits_per_sample // 8 * self.buffer_ms // 1000
        for _ in range(self.buffer_count):
            buf = ctypes.create_string_buffer(size)
            header = WAVEHDR(lpData=ctypes.cast(buf, ctypes.c_char_p), dwBufferLength=size)
            check_mm(mm.waveInPrepareHeader(self.handle, ctypes.byref(header), ctypes.sizeof(header)), "waveInPrepareHeader")
            check_mm(mm.waveInAddBuffer(self.handle, ctypes.byref(header), ctypes.sizeof(header)), "waveInAddBuffer")
            self.buffers.append(buf)
            self.headers.append(header)
        check_mm(mm.waveInStart(self.handle), "waveInStart")
        self._thread = threading.Thread(target=self._collect, name="echoscribe-win-audio", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        mm = winmm()
        if self.handle:
            mm.waveInStop(self.handle)
            mm.waveInReset(self.handle)
        if self._thread:
            self._thread.join(timeout=2)
        self._collect_done(requeue=False)
        self._close()
        write_wav(self.path, bytes(self.frames), self.sample_rate, self.channels, self.bits_per_sample)

    def abort(self) -> None:
        self._stop.set()
        if self.handle:
            mm = winmm()
            mm.waveInReset(self.handle)
        if self._thread:
            self._thread.join(timeout=1)
        self._close()

    def _collect(self) -> None:
        while not self._stop.is_set():
            self._collect_done(requeue=True)
            time.sleep(0.02)

    def _collect_done(self, requeue: bool) -> None:
        mm = winmm()
        for header in self.headers:
            if header.dwFlags & 0x00000001 and header.dwBytesRecorded:
                self.frames.extend(ctypes.string_at(header.lpData, header.dwBytesRecorded))
                header.dwBytesRecorded = 0
                if requeue and self.handle and not self._stop.is_set():
                    mm.waveInAddBuffer(self.handle, ctypes.byref(header), ctypes.sizeof(header))

    def _close(self) -> None:
        mm = winmm()
        if self.handle:
            for header in self.headers:
                mm.waveInUnprepareHeader(self.handle, ctypes.byref(header), ctypes.sizeof(header))
            mm.waveInClose(self.handle)
            self.handle = ctypes.c_void_p()


class WAVEFORMATEX(ctypes.Structure):
    _fields_ = [
        ("wFormatTag", ctypes.c_ushort),
        ("nChannels", ctypes.c_ushort),
        ("nSamplesPerSec", ctypes.c_uint),
        ("nAvgBytesPerSec", ctypes.c_uint),
        ("nBlockAlign", ctypes.c_ushort),
        ("wBitsPerSample", ctypes.c_ushort),
        ("cbSize", ctypes.c_ushort),
    ]


class WAVEHDR(ctypes.Structure):
    _fields_ = [
        ("lpData", ctypes.c_char_p),
        ("dwBufferLength", ctypes.c_uint),
        ("dwBytesRecorded", ctypes.c_uint),
        ("dwUser", ctypes.c_void_p),
        ("dwFlags", ctypes.c_uint),
        ("dwLoops", ctypes.c_uint),
        ("lpNext", ctypes.c_void_p),
        ("reserved", ctypes.c_void_p),
    ]


class WindowsClipboardPaster:
    def __init__(
        self,
        method: str = "auto",
        shortcut: str = "auto",
        paste_delay_ms: int = 120,
        gtk_clipboard_setter: object | None = None,
    ) -> None:
        del method, shortcut, gtk_clipboard_setter
        self.paste_delay_ms = paste_delay_ms

    def paste_text(self, text: str) -> None:
        set_clipboard_text(text)
        time.sleep(max(self.paste_delay_ms, 0) / 1000)
        send_ctrl_v()


class WindowsOverlay:
    def __init__(
        self,
        icon_path: Path,
        icon_size: int = 58,
        margin: int = 24,
        top: int = 72,
        toast_ms: int = 1800,
    ) -> None:
        del icon_path, icon_size, margin, top
        self.toast_ms = toast_ms
        self._stop = threading.Event()

    def show_toast(self, text: str) -> None:
        print(text, flush=True)

    def show_recording(self) -> None:
        self.show_toast("Recording...")

    def show_processing(self, text: str) -> None:
        self.show_toast(text)

    def run(self) -> None:
        while not self._stop.is_set():
            time.sleep(0.25)

    def stop(self) -> None:
        self._stop.set()


def set_clipboard_text(text: str) -> None:
    u32 = user32()
    k32 = kernel32()
    data = text.encode("utf-16le") + b"\x00\x00"
    if not u32.OpenClipboard(None):
        raise RuntimeError("Could not open Windows clipboard")
    handle = None
    try:
        if not u32.EmptyClipboard():
            raise RuntimeError("Could not empty Windows clipboard")
        handle = k32.GlobalAlloc(0x0002, len(data))
        if not handle:
            raise RuntimeError("Could not allocate clipboard memory")
        locked = k32.GlobalLock(handle)
        if not locked:
            raise RuntimeError("Could not lock clipboard memory")
        ctypes.memmove(locked, data, len(data))
        k32.GlobalUnlock(handle)
        if not u32.SetClipboardData(13, handle):
            raise RuntimeError("Could not set Windows clipboard text")
        handle = None
    finally:
        u32.CloseClipboard()
        if handle:
            k32.GlobalFree(handle)


def send_ctrl_v() -> None:
    u32 = user32()
    inputs = (INPUT * 4)(
        key_input(0x11, 0),
        key_input(ord("V"), 0),
        key_input(ord("V"), 0x0002),
        key_input(0x11, 0x0002),
    )
    sent = u32.SendInput(len(inputs), ctypes.byref(inputs), ctypes.sizeof(INPUT))
    if sent != len(inputs):
        raise RuntimeError("Could not send Ctrl+V")


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", ctypes.c_ushort),
        ("wScan", ctypes.c_ushort),
        ("dwFlags", ctypes.c_uint),
        ("time", ctypes.c_uint),
        ("dwExtraInfo", ctypes.c_void_p),
    ]


class INPUT_UNION(ctypes.Union):
    _fields_ = [("ki", KEYBDINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", ctypes.c_uint), ("union", INPUT_UNION)]


def key_input(vk: int, flags: int) -> INPUT:
    return INPUT(type=1, union=INPUT_UNION(ki=KEYBDINPUT(wVk=vk, wScan=0, dwFlags=flags, time=0, dwExtraInfo=None)))


def write_wav(path: Path, pcm: bytes, sample_rate: int, channels: int, bits_per_sample: int) -> None:
    byte_rate = sample_rate * channels * bits_per_sample // 8
    block_align = channels * bits_per_sample // 8
    header = b"".join(
        [
            b"RIFF",
            struct.pack("<I", 36 + len(pcm)),
            b"WAVEfmt ",
            struct.pack("<IHHIIHH", 16, 1, channels, sample_rate, byte_rate, block_align, bits_per_sample),
            b"data",
            struct.pack("<I", len(pcm)),
        ]
    )
    path.write_bytes(header + pcm)


def windows_doctor(config: Config) -> list[str]:
    del config
    return [
        "platform: windows",
        "hotkeys: Win32 GetAsyncKeyState polling",
        "audio recorder: WinMM waveIn PCM WAV",
        "paste: clipboard + SendInput Ctrl+V",
        "overlay/toast: console fallback",
        f"ffmpeg: {shutil.which('ffmpeg') or 'missing'}",
        f"powershell: {shutil.which('powershell') or shutil.which('pwsh') or 'missing'}",
        "autostart: pending",
    ]


def user32() -> ctypes.WinDLL:
    return ctypes.windll.user32


def kernel32() -> ctypes.WinDLL:
    dll = ctypes.windll.kernel32
    dll.GlobalAlloc.restype = ctypes.c_void_p
    dll.GlobalLock.restype = ctypes.c_void_p
    dll.GlobalFree.restype = ctypes.c_void_p
    return dll


def winmm() -> ctypes.WinDLL:
    return ctypes.windll.winmm


def check_mm(result: int, operation: str) -> None:
    if result != 0:
        raise RuntimeError(f"{operation} failed with WinMM error {result}")


def close_fd(fd: int) -> None:
    try:
        os.close(fd)
    except OSError:
        pass

