from __future__ import annotations

import base64
import ctypes
from ctypes import wintypes


class _DataBlob(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_byte))]


def unprotect_windows_secret(encoded: str) -> str:
    """Decrypt a DPAPI value saved by the WPF front end for this Windows user."""
    if not encoded:
        return ""
    encrypted = base64.b64decode(encoded)
    buffer = ctypes.create_string_buffer(encrypted)
    source = _DataBlob(len(encrypted), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_byte)))
    output = _DataBlob()
    if not ctypes.windll.crypt32.CryptUnprotectData(
        ctypes.byref(source), None, None, None, None, 0, ctypes.byref(output)
    ):
        raise ctypes.WinError()
    try:
        plain = ctypes.string_at(output.pbData, output.cbData)
        return plain.decode("utf-8")
    finally:
        ctypes.windll.kernel32.LocalFree(output.pbData)
