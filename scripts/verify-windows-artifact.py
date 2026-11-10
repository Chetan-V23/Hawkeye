#!/usr/bin/env python3
"""Inspect the actual Windows bundle without running Windows code."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import struct
import zipfile
import zlib


def string_at(data, position):
    length = 0
    shift = 0
    while True:
        value = data[position]
        position += 1
        length |= (value & 127) << shift
        if value < 128:
            break
        shift += 7
        if shift > 28:
            raise ValueError("Invalid bundle string")
    return data[position:position + length].decode(), position + length


def bundle_files(data):
    signature = bytes.fromhex("8b1202b96a612038727b930214d7a03213f5b9e6efae3318ee3b2dce24b36aae")
    marker = data.find(signature)
    assert marker >= 8, "Missing .NET single-file marker"
    position = struct.unpack_from("<Q", data, marker - 8)[0]
    major, minor, count = struct.unpack_from("<III", data, position)
    assert major >= 6 and minor == 0 and 0 < count < 10000, "Invalid .NET bundle header"
    _, position = string_at(data, position + 12)
    position += 40
    files = {}
    for _ in range(count):
        offset, size, compressed = struct.unpack_from("<qqq", data, position)
        position += 25
        name, position = string_at(data, position)
        assert offset >= 0 and 0 <= size <= len(data) * 20 and offset + (compressed or size) <= len(data), "Invalid embedded file bounds"
        files[name] = (offset, size, compressed)
    return files


def embedded(data, entry):
    offset, size, compressed = entry
    result = zlib.decompress(data[offset:offset + compressed], -15) if compressed else data[offset:offset + size]
    assert len(result) == size, "Embedded file size mismatch"
    return result


def native_code(data):
    pe = struct.unpack_from("<I", data, 60)[0]
    count = struct.unpack_from("<H", data, pe + 6)[0]
    optional_size = struct.unpack_from("<H", data, pe + 20)[0]
    position = pe + 24 + optional_size
    for _ in range(count):
        if data[position:position + 8].rstrip(b"\0") == b".text":
            size, offset = struct.unpack_from("<II", data, position + 16)
            return data[offset:offset + size]
        position += 40
    raise ValueError("Missing native code section")


def verify(path):
    data = path.read_bytes()
    assert data[:2] == b"MZ", "Not a Windows executable"
    pe = struct.unpack_from("<I", data, 60)[0]
    assert data[pe:pe + 4] == b"PE\0\0", "Invalid PE header"
    assert struct.unpack_from("<H", data, pe + 4)[0] == 0x8664, "Expected x64 Windows executable"
    assert struct.unpack_from("<H", data, pe + 24 + 68)[0] == 2, "Expected a GUI executable"
    files = bundle_files(data)
    for name in ("Hawkeye.dll", "Hawkeye.Core.dll", "Hawkeye.Platform.dll", "Interop.UIAutomationClient.dll",
                 "System.Private.CoreLib.dll", "Avalonia.Controls.dll", "libSkiaSharp.dll"):
        assert name in files, f"Missing embedded dependency {name}"
    runtime = json.loads(embedded(data, files["Hawkeye.runtimeconfig.json"]))["runtimeOptions"]
    assert runtime.get("includedFrameworks") and not runtime.get("frameworks") and not runtime.get("framework"), "The app requires an installed .NET runtime"
    version = next(framework["version"] for framework in runtime["includedFrameworks"] if framework["name"] == "Microsoft.NETCore.App")
    packages = Path(os.environ.get("NUGET_PACKAGES", Path.home() / ".nuget/packages"))
    template = packages / f"microsoft.netcore.app.host.win-x64/{version}/runtimes/win-x64/native/singlefilehost.exe"
    assert native_code(data) == native_code(template.read_bytes()), "Native code differs from the SDK's self-contained runtime host"
    assembly = embedded(data, files["Hawkeye.dll"])
    assert "--browser-automation-helper".encode("utf-16le") in assembly, "Missing native browser helper entry point"
    assert b"NativeBrowserHelper" in embedded(data, files["Hawkeye.Platform.dll"]), "Missing native browser helper implementation"
    assert b"Hawkeye.BrowserPayload.zip" in assembly, "Missing browser payload resource"
    end = assembly.rfind(b"PK\x05\x06")
    assert end >= 0, "Missing browser setup zip"
    end += 22 + struct.unpack_from("<H", assembly, end + 20)[0]
    with zipfile.ZipFile(io.BytesIO(assembly[:end])) as payload:
        assert payload.testzip() is None, "Corrupt browser setup payload"
        host = payload.read("browser-host/Hawkeye.BrowserHost.exe")
        host_files = bundle_files(host)
        host_runtime = json.loads(embedded(host, host_files["Hawkeye.BrowserHost.runtimeconfig.json"]))["runtimeOptions"]
        assert host[:2] == b"MZ" and host_runtime.get("includedFrameworks"), "Browser host is not self-contained"
        for browser in ("chromium", "firefox"):
            manifest = json.loads(payload.read(f"browser-extension/{browser}/manifest.json"))
            assert "nativeMessaging" in manifest["permissions"]
            assert payload.read(f"browser-extension/{browser}/background.js")
    digest = hashlib.sha256(data).hexdigest()
    assert digest == path.with_suffix(".sha256").read_text().split()[0], "Checksum mismatch"
    with zipfile.ZipFile(path.with_suffix(".zip")) as archive:
        assert archive.testzip() is None
        assert hashlib.sha256(archive.read(path.name)).hexdigest() == digest, "Distribution zip contains a different executable"
    print(json.dumps({"artifact": str(path), "format": "Windows x64 GUI", "singleFile": True,
                      "runtimeEmbedded": True, "nativeHostVerifiedAgainstSdk": True, "browserHostAndExtensionsEmbedded": True,
                      "nativeWindowsBrowserAccessEmbedded": True,
                      "bundleFiles": len(files), "bytes": len(data), "sha256": digest}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact", nargs="?", type=Path, default=Path("dist/Hawkeye-Windows-x64.exe"))
    verify(parser.parse_args().artifact)
